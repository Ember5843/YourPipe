/*
 * AVSession Manager for YourPipe
 * Bridges the AvPlayerController to the HarmonyOS system media session (AVSession),
 * enabling lock-screen & notification media controls and background task protection.
 *
 * Architecture note:
 *   This manager solely owns the AVSession lifecycle and the background task.
 */

import { common, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import Logger from '../utils/Logger';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';

const TAG = '[AvSessionManager]';

export class AvSessionManager {
  private static instance: AvSessionManager | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
  private currentMetadata: avSession.AVMetadata | undefined = undefined;
  private audioSessionManager: audio.AudioSessionManager | undefined = undefined;
  private audioSessionActivated: boolean = false;

  // Callbacks wired up by AvPlayerController
  public onPlayCommand: (() => void) | undefined = undefined;
  public onPauseCommand: (() => void) | undefined = undefined;
  public onSeekCommand: ((position: number) => void) | undefined = undefined;
  public onFastForwardCommand: ((skipIntervalSec?: number) => void) | undefined = undefined;
  public onRewindCommand: ((skipIntervalSec?: number) => void) | undefined = undefined;
  public onNextCommand: (() => void) | undefined = undefined;
  public onPreviousCommand: (() => void) | undefined = undefined;
  public onStopCommand: (() => void) | undefined = undefined;

  // Cast state
  public isCasting: boolean = false;
  public castDeviceName: string = '';
  public onCastStateChange: ((isCasting: boolean, deviceName: string) => void) | undefined = undefined;
  public onCastPlaybackStateChange: ((state: avSession.AVPlaybackState) => void) | undefined = undefined;

  private constructor() {}

  public static getInstance(): AvSessionManager {
    if (!AvSessionManager.instance) {
      AvSessionManager.instance = new AvSessionManager();
    }
    return AvSessionManager.instance;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  /**
   * Create and activate the AVSession. Should be called once when the player
   * is first initialized (e.g. in AvPlayerController.initAVPlayer).
   */
  public async init(): Promise<void> {
    this.context = AppStorage.get<common.UIAbilityContext>('context');
    if (!this.context) {
      Logger.error(TAG, 'init failed: context is undefined');
      return;
    }

    // Activate AudioSession BEFORE creating any audio stream.
    // CONCURRENCY_MIX_WITH_OTHERS lowers our stream's focus priority so the
    // system won't PAUSE/STOP us when transient streams (notifications, etc.)
    // arrive. Instead it will MIX or DUCK. The native ao_ohaudio.c already
    // handles DUCK/UNDUCK events (mpv multiply volume 0.2 / 5.0), so ducking
    // works out of the box. Without this, system default policy PAUSEs media
    // on ringtone/alarm/VoIP and the user has no "lower volume" option.
    this.activateAudioSession();

    if (this.session) {
      // Already initialized — just reactivate
      await this.session.activate().catch((e: BusinessError) => {
        Logger.error(TAG, `re-activate failed: ${e.message}`);
      });
      return;
    }

    try {
      this.session = await avSession.createAVSession(this.context, 'YourPipe', 'video');
      // 🔑 Pin session to AppStorage to prevent ArkTS GC from collecting the JS wrapper
      // (GC can destroy the NapiAVSession object even though the native side still holds it,
      //  causing the system to lose track of our session and apply background muting)
      AppStorage.setOrCreate('__avSession_pin', this.session);
      // Register launch intent so tapping the notification reopens the app
      this.setLaunchAbility();
      await this.session.activate();
      // 注：后台长时任务由 PlayerStateMachine 监听器统一管理（见 AvPlayerController），
      // 不再在此处启动，避免与状态机决策不同步。
      // Wire up control-center button callbacks
      this.registerSessionListeners();
      Logger.info(TAG, 'AVSession initialized and activated');
    } catch (e) {
      const err = e as BusinessError;
      Logger.error(TAG, `createAVSession failed: code=${err.code}, message=${err.message}`);
    }
  }

  /**
   * Deactivate and destroy the session, and cancel the background task.
   * Call when the player is fully stopped/released.
   */
  public async destroy(): Promise<void> {
    this.deactivateAudioSession();
    if (!this.session) {
      return;
    }
    try {
      this.session.off('play');
      this.session.off('pause');
      this.session.off('seek');
      this.session.off('fastForward');
      this.session.off('rewind');
      this.session.off('playNext');
      this.session.off('playPrevious');
      this.session.off('stop');
      // outputDeviceChange 未注册成功，无需 off
    } catch (e) {
      Logger.error(TAG, `unregister listeners failed: ${(e as BusinessError).message}`);
    }
    try {
      // 先显式推送 STOP 状态再销毁，避免锁屏卡片残留"播放中"
      if (this.session && this.currentMetadata) {
        const stopState: avSession.AVPlaybackState = {
          state: avSession.PlaybackState.PLAYBACK_STATE_STOP,
          position: { elapsedTime: 0, updateTime: Date.now() },
          speed: 1.0
        };
        this.session.setAVPlaybackState(stopState);
      }
      await this.session.deactivate();
      await this.session.destroy();
      this.session = undefined;
      this.currentMetadata = undefined;
      // Remove the GC pin now that we intentionally destroyed the session
      AppStorage.delete('__avSession_pin');
    } catch (e) {
      Logger.error(TAG, `session destroy failed: ${(e as BusinessError).message}`);
    }
    // 后台长时任务由 PlayerStateMachine 监听器统一停掉，这里不再做。
    Logger.info(TAG, 'AVSession destroyed');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Metadata & playback state — called by AvPlayerController
  // ─────────────────────────────────────────────────────────────────────────

  /**
   * Push video metadata (title, author, cover art, duration) to the system media panel.
   * Downloads the thumbnail as a PixelMap without forcing any target dimensions so the
   * original aspect ratio of the cover image is preserved in the lock-screen / notification
   * media card (system URL-string path always crops to 1:1).
   *
   * @param title       Video title string
   * @param artist      Channel / author name
   * @param duration    Total duration in seconds
   * @param thumbnailUrl  HTTP URL for thumbnail
   */
  public setMetadata(title: string, artist: string, duration: number, thumbnailUrl?: string): void {
    if (!this.session) {
      return;
    }
    const metadata: avSession.AVMetadata = {
      assetId: title || 'default',
      title: title,
      artist: artist,
      duration: Math.round(duration * 1000), // AVSession uses milliseconds
      filter: avSession.ProtocolType.TYPE_CAST_PLUS_STREAM
        | avSession.ProtocolType.TYPE_DLNA,
      skipIntervals: avSession.SkipIntervals.SECONDS_15,
    };

    const pushMetadata = (pixelMap?: image.PixelMap) => {
      if (pixelMap) {
        metadata.mediaImage = pixelMap;
      } else if (thumbnailUrl) {
        // Fallback: pass URL string if PixelMap creation failed
        metadata.mediaImage = thumbnailUrl;
      }
      this.session?.setAVMetadata(metadata).then(() => {
        this.currentMetadata = metadata;
        Logger.debug(TAG, `setAVMetadata: title=${title}, duration=${duration}s`);
      }).catch((e: BusinessError) => {
        Logger.error(TAG, `setAVMetadata failed: code=${e.code}, message=${e.message}`);
      });
    };

    if (thumbnailUrl) {
      // Download thumbnail and create a PixelMap without pre-scaling so the
      // system media card uses the image's own aspect ratio.
      this.downloadThumbnailPixelMap(thumbnailUrl)
        .then((pixelMap) => { pushMetadata(pixelMap); })
        .catch(() => { pushMetadata(undefined); });
    } else {
      pushMetadata(undefined);
    }
  }

  /**
   * Download an image from a URL and decode it to PixelMap without resizing.
   * Preserving the original dimensions lets the system media card show the
   * correct aspect ratio instead of always cropping to 1:1.
   */
  private async downloadThumbnailPixelMap(url: string): Promise<image.PixelMap | undefined> {
    try {
      const req = http.createHttp();
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 10000,
      });
      req.destroy();
      if (resp.responseCode !== 200 || !resp.result) {
        Logger.warn(TAG, `downloadThumbnailPixelMap: HTTP ${resp.responseCode}`);
        return undefined;
      }
      const buffer = resp.result as ArrayBuffer;
      const src = image.createImageSource(buffer);
      // No desiredSize → decode at native resolution, preserving aspect ratio
      const pixelMap = await src.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      src.release();
      return pixelMap;
    } catch (e) {
      Logger.warn(TAG, `downloadThumbnailPixelMap failed: ${(e as BusinessError).message}`);
      return undefined;
    }
  }

  /**
   * Push current playback state (play/pause/buffering/completed, position, speed) to the system.
   *
   * State priority (highest to lowest):
   *   1. BUFFERING  – player stalled or seek in flight
   *   2. COMPLETED  – reached natural EOF
   *   3. PLAY       – active playback
   *   4. PAUSE      – user-paused or stopped
   *
   * @param isPlaying   Whether the player is actively playing
   * @param positionSec Current playback position in seconds
   * @param speed       Current playback speed multiplier
   * @param isBuffering Whether the player is currently buffering / seeking
   * @param isCompleted Whether playback reached natural EOF
   */
  public setPlaybackState(
    isPlaying: boolean,
    positionSec: number,
    speed: number,
    isBuffering: boolean = false,
    isCompleted: boolean = false
  ): void {
    if (!this.session) {
      return;
    }
    let playbackState: avSession.PlaybackState;
    if (isBuffering) {
      // Highest priority: stalled or seek in flight — freeze the system progress bar
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_BUFFERING;
    } else if (isCompleted) {
      // Natural EOF — system card may show replay button
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_COMPLETED;
    } else if (isPlaying) {
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    } else {
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    }
    const state: avSession.AVPlaybackState = {
      state: playbackState,
      position: {
        elapsedTime: Math.round(positionSec * 1000), // milliseconds
        updateTime: Date.now()
      },
      speed: speed
    };
    this.session.setAVPlaybackState(state, (err: BusinessError) => {
      if (err) {
        Logger.error(TAG, `setAVPlaybackState failed: code=${err.code}, message=${err.message}`);
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal helpers
  // ─────────────────────────────────────────────────────────────────────────

  /**
   * Set the WantAgent so that tapping the notification card opens our app.
   */
  private setLaunchAbility(): void {
    if (!this.context || !this.session) {
      return;
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(wantAgentInfo).then((agent) => {
      this.session?.setLaunchAbility(agent).catch((e: BusinessError) => {
        Logger.error(TAG, `setLaunchAbility failed: ${e.message}`);
      });
    }).catch((e: BusinessError) => {
      Logger.error(TAG, `getWantAgent failed: ${e.message}`);
    });
  }

  /**
   * Register reverse-control callbacks from control center (play, pause, seek).
   */
  private registerSessionListeners(): void {
    if (!this.session) {
      return;
    }
    this.session.on('play', () => {
      Logger.debug(TAG, 'Control center → play');
      this.onPlayCommand?.();
    });
    this.session.on('pause', () => {
      Logger.debug(TAG, 'Control center → pause');
      this.onPauseCommand?.();
    });
    this.session.on('seek', (position: number) => {
      // AVSession delivers seek in milliseconds; convert to seconds for MPV
      Logger.debug(TAG, `Control center → seek to ${position}ms`);
      this.onSeekCommand?.(position / 1000);
    });
    this.session.on('fastForward', (skipIntervalSec?: number) => {
      Logger.debug(TAG, `Control center → fastForward ${skipIntervalSec}s`);
      this.onFastForwardCommand?.(skipIntervalSec);
    });
    this.session.on('rewind', (skipIntervalSec?: number) => {
      Logger.debug(TAG, `Control center → rewind ${skipIntervalSec}s`);
      this.onRewindCommand?.(skipIntervalSec);
    });
    this.session.on('playNext', () => {
      Logger.debug(TAG, 'Control center -> playNext');
      this.onNextCommand?.();
    });
    this.session.on('playPrevious', () => {
      Logger.debug(TAG, 'Control center -> playPrevious');
      this.onPreviousCommand?.();
    });
    this.session.on('stop', () => {
      Logger.debug(TAG, 'Control center → stop');
      this.onStopCommand?.();
    });
    // 注：当前系统版本 outputDeviceChange 事件名无效，如需监听投屏状态请改为定时轮询 getOutputDevice()
  }

  /**
   * 轮询检查投屏设备状态。当前系统版本 outputDeviceChange 事件无效，
   * 如需实时监听投屏状态，可由上层定时调用此方法（如每 3~5 秒一次）。
   */
  public async checkCastState(): Promise<void> {
    if (!this.session) {
      return;
    }
    try {
      const outputDevice = await this.session.getOutputDevice();
      const hasDevice = outputDevice !== undefined && outputDevice !== null;
      if (hasDevice !== this.isCasting) {
        this.isCasting = hasDevice;
        if (hasDevice) {
          Logger.info(TAG, `Cast connected`);
        } else {
          this.castDeviceName = '';
          Logger.info(TAG, `Cast disconnected`);
        }
        this.onCastStateChange?.(hasDevice, this.castDeviceName);
      }
    } catch (e) {
      Logger.warn(TAG, `checkCastState failed: ${(e as BusinessError).message}`);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // AudioSession — audio focus concurrency strategy
  //
  // The AVSession only manages the media control card (lock screen / notification
  // bar). AudioSession is what tells the OS *how* to handle audio focus when
  // other streams arrive. Without it, the system default policy PAUSEs our
  // STREAM_USAGE_MOVIE stream on ringtone/alarm/VoIP/notifications, giving the
  // user no "lower volume" (duck) option.
  //
  // CONCURRENCY_MIX_WITH_OTHERS lowers our stream's focus priority. The system
  // then prefers MIX or DUCK over PAUSE/STOP for transient interrupters. The
  // native ao_ohaudio.c + player_napi.cpp already handle DUCK/UNDUCK by
  // multiplying mpv volume by 0.2 / 5.0, so ducking works end-to-end.
  //
  // Must be activated BEFORE the OHAudio renderer is created (i.e. before mpv
  // load), otherwise the custom strategy does not take effect.
  // ─────────────────────────────────────────────────────────────────────────

  private activateAudioSession(): void {
    if (this.audioSessionActivated) {
      return;
    }
    try {
      if (!this.audioSessionManager) {
        const audioManager: audio.AudioManager = audio.getAudioManager();
        this.audioSessionManager = audioManager.getSessionManager();
      }
      const strategy: audio.AudioSessionStrategy = {
        concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS
      };
      this.audioSessionManager.activateAudioSession(strategy).then(() => {
        this.audioSessionActivated = true;
        Logger.info(TAG, 'AudioSession activated: CONCURRENCY_MIX_WITH_OTHERS');
      }).catch((e: BusinessError) => {
        Logger.error(TAG, `activateAudioSession failed: code=${e.code}, message=${e.message}`);
      });
      // Listen for unexpected deactivation (e.g. system reclaim) and re-activate
      // so the strategy persists across the entire playback session.
      this.audioSessionManager.on('audioSessionDeactivated',
        (event: audio.AudioSessionDeactivatedEvent) => {
          Logger.info(TAG, `AudioSession deactivated by system: reason=${event.reason}`);
          this.audioSessionActivated = false;
          // Re-activate if our AVSession is still alive (playback ongoing)
          if (this.session) {
            this.activateAudioSession();
          }
        });
    } catch (e) {
      Logger.error(TAG, `activateAudioSession exception: ${(e as BusinessError).message}`);
    }
  }

  private deactivateAudioSession(): void {
    if (!this.audioSessionManager) {
      return;
    }
    try {
      this.audioSessionManager.off('audioSessionDeactivated');
    } catch (e) {
      Logger.warn(TAG, `off audioSessionDeactivated failed: ${(e as BusinessError).message}`);
    }
    if (this.audioSessionActivated) {
      this.audioSessionManager.deactivateAudioSession().then(() => {
        Logger.info(TAG, 'AudioSession deactivated');
      }).catch((e: BusinessError) => {
        Logger.error(TAG, `deactivateAudioSession failed: code=${e.code}, message=${e.message}`);
      });
      this.audioSessionActivated = false;
    }
  }
}
