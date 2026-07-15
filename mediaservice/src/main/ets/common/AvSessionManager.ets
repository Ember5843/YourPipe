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
import { PlaybackEngineState } from '../engine/PlaybackEngine';

const TAG = '[AvSessionManager]';

export class AvSessionManager {
  private static instance: AvSessionManager | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
  private currentMetadata: avSession.AVMetadata | undefined = undefined;
  private audioSessionManager: audio.AudioSessionManager | undefined = undefined;
  private audioSessionActivated: boolean = false;
  private audioActivationGeneration: number = 0;
  private pendingPlaybackState: avSession.AVPlaybackState | null = null;
  private playbackStateWriteInFlight: boolean = false;
  /** Serializes singleton AVSession destroy/init across controller replacement. */
  private lifecycleChain: Promise<void> = Promise.resolve();

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

  /**
   * Unified audio-focus entry for the player controller (scheme A).
   * AvSessionManager only forwards system hints; policy lives in AvPlayerController.
   * Stable log tag for filtering: [AudioFocus]
   */
  public onAudioFocusHint: ((hint: audio.AudioSessionStateChangeHint) => void) | undefined = undefined;

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
    const task = this.lifecycleChain.then(() => this.initInternal());
    this.lifecycleChain = task.catch((e: Error) => {
      Logger.error(TAG, `lifecycle init failed: ${e.message}`);
    });
    await task;
  }

  private async initInternal(): Promise<void> {
    this.context = AppStorage.get<common.UIAbilityContext>('context');
    if (!this.context) {
      Logger.error(TAG, 'init failed: context is undefined');
      return;
    }

    // AudioSession is NOT activated here. Activation follows playback state:
    // AvPlayerController.syncPlay() → activateForPlayback()
    // AvPlayerController.syncPause() / syncStop() → deactivateForPause()
    // Focus strategy (CONCURRENCY_MIX_WITH_OTHERS) applies only while playing;
    // pause/stop releases the session so background streams can resume.

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
    const task = this.lifecycleChain.then(() => this.destroyInternal());
    this.lifecycleChain = task.catch((e: Error) => {
      Logger.error(TAG, `lifecycle destroy failed: ${e.message}`);
    });
    await task;
  }

  private async destroyInternal(): Promise<void> {
    this.deactivateForPause();
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
    engineState: PlaybackEngineState,
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
    if (isCompleted) {
      // Natural EOF — system card may show replay button
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_COMPLETED;
    } else if (engineState === 'buffering' || isBuffering) {
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_BUFFERING;
    } else if (engineState === 'playing' || isPlaying) {
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    } else if (engineState === 'stopped') {
      playbackState = avSession.PlaybackState.PLAYBACK_STATE_STOP;
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
    this.pendingPlaybackState = state;
    this.flushPlaybackState();
  }

  private flushPlaybackState(): void {
    if (this.playbackStateWriteInFlight || !this.session || !this.pendingPlaybackState) return;
    const state: avSession.AVPlaybackState = this.pendingPlaybackState;
    this.pendingPlaybackState = null;
    this.playbackStateWriteInFlight = true;
    this.session.setAVPlaybackState(state, (err: BusinessError) => {
      this.playbackStateWriteInFlight = false;
      if (err) {
        Logger.error(TAG, `setAVPlaybackState failed: code=${err.code}, message=${err.message}`);
      }
      this.flushPlaybackState();
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
  // AudioSession — focus concurrency + interrupt forwarding
  //
  // HarmonyOS AudioSession (mediaservice owns policy, not native MPV):
  //   1. Activate with the default MEDIA concurrency policy before play so an
  //      existing media player yields audio focus instead of mixing with us.
  //   2. Deactivate on user pause/stop → release focus for background music.
  //   3. Re-activate on next play() / system RESUME after temporary PAUSE.
  //
  // Hints (PAUSE/RESUME/STOP/DUCK/UNDUCK/…) arrive via audioSessionStateChanged
  // and are forwarded to AvPlayerController.onAudioFocusHint (scheme A).
  //
  // Debug logs: filter with [AudioFocus]
  // ─────────────────────────────────────────────────────────────────────────

  public activateForPlayback(): void {
    const activationGeneration = ++this.audioActivationGeneration;
    try {
      if (!this.audioSessionManager) {
        const audioManager: audio.AudioManager = audio.getAudioManager();
        this.audioSessionManager = audioManager.getSessionManager();
      }

      // Always re-bind listeners; activation is idempotent when already active.
      try {
        this.audioSessionManager.off('audioSessionDeactivated');
        this.audioSessionManager.off('audioSessionStateChanged');
      } catch (_) {}

      this.audioSessionManager.setAudioSessionScene(
        audio.AudioSessionScene.AUDIO_SESSION_SCENE_MEDIA);
      const strategy: audio.AudioSessionStrategy = {
        concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT
      };

      this.audioSessionManager.on('audioSessionDeactivated',
        (event: audio.AudioSessionDeactivatedEvent) => {
          Logger.info(TAG, `[AudioFocus] sessionDeactivated reason=${event.reason}`);
          this.audioSessionActivated = false;
        });

      this.audioSessionManager.on('audioSessionStateChanged',
        (event: audio.AudioSessionStateChangedEvent) => {
          this.forwardFocusHint(event.stateChangeHint);
        });

      if (this.audioSessionActivated) {
        Logger.info(TAG, '[AudioFocus] session already active (DEFAULT)');
        return;
      }

      this.audioSessionManager.activateAudioSession(strategy).then(() => {
        if (activationGeneration !== this.audioActivationGeneration) {
          Logger.info(TAG, '[AudioFocus] stale activation completed; deactivating');
          this.audioSessionManager?.deactivateAudioSession().catch(() => {});
          return;
        }
        this.audioSessionActivated = true;
        Logger.info(TAG, '[AudioFocus] sessionActivated strategy=DEFAULT scene=MEDIA');
      }).catch((e: BusinessError) => {
        Logger.error(TAG, `[AudioFocus] activate failed code=${e.code} message=${e.message}`);
      });
    } catch (e) {
      Logger.error(TAG, `[AudioFocus] activate exception: ${(e as BusinessError).message}`);
    }
  }

  public deactivateForPause(): void {
    this.audioActivationGeneration++;
    if (!this.audioSessionManager) {
      return;
    }
    try {
      this.audioSessionManager.off('audioSessionDeactivated');
      this.audioSessionManager.off('audioSessionStateChanged');
    } catch (e) {
      Logger.warn(TAG, `off audioSession listeners failed: ${(e as BusinessError).message}`);
    }
    if (this.audioSessionActivated) {
      this.audioSessionManager.deactivateAudioSession().then(() => {
        Logger.info(TAG, '[AudioFocus] sessionDeactivated reason=user_or_controller');
      }).catch((e: BusinessError) => {
        Logger.error(TAG, `[AudioFocus] deactivate failed code=${e.code} message=${e.message}`);
      });
      this.audioSessionActivated = false;
    }
  }

  /** Named hint for hilog filtering (keep stable for regex). */
  public static focusHintName(hint: audio.AudioSessionStateChangeHint): string {
    switch (hint) {
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_PAUSE:
        return 'PAUSE';
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_RESUME:
        return 'RESUME';
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_STOP:
        return 'STOP';
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_DUCK:
        return 'DUCK';
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_UNDUCK:
        return 'UNDUCK';
      default:
        return `UNKNOWN_${hint}`;
    }
  }

  private forwardFocusHint(hint: audio.AudioSessionStateChangeHint): void {
    const name = AvSessionManager.focusHintName(hint);
    Logger.info(TAG, `[AudioFocus] hint=${name} raw=${hint}`);
    if (this.onAudioFocusHint) {
      this.onAudioFocusHint(hint);
    } else {
      Logger.warn(TAG, `[AudioFocus] hint=${name} dropped (no onAudioFocusHint handler)`);
    }
  }
}
