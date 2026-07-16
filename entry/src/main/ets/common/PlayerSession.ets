import { AppLog } from './AppLog';
import { AbilityConstant, common } from '@kit.AbilityKit';
import { AvPlayerController, VideoData, PlayerState, StateChangeListener, LocalMediaProxy } from 'mediaservice';
import { VideoInfo, VideoItem } from 'youtube_core';
import { YouTubePlayResult, YouTubePlayService } from '../features/player/YouTubePlayService';
import { PlayQueueManager, QueueSourceType } from '../features/player/PlayQueueManager';
import { WatchHistoryStore } from './WatchHistoryStore';
import { normalizeUrl } from '../features/home/utils/ThumbnailUtils';
import { YOUTUBE_VIDEO_ID } from './Constants';
import { ErrorInfo, ErrorInfoOptions } from './model/ErrorInfo';

export interface CachedChannelProfile {
  name: string;
  subscriberText: string;
  videoCountText: string;
  avatarUrl: string;
  description: string;
}

const logger = AppLog.getInstance('PlayerSession');
const TAG = '[PlayerSession]';

interface PreparedPlayback {
  result: YouTubePlayResult;
  generation: number;
  attemptId: string;
  startedAt: number;
}

function getFallbackThumbnailUrl(videoId: string): string {
  // Prefer maxres (highest). Client may 404 on some videos; UI has placeholder.
  return videoId ? `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg` : '';
}

export class PlayerSession {
  private static instance: PlayerSession | null = null;

  private _controller: AvPlayerController;
  private _currentVideo: VideoItem | null = null;
  private _defaultSource: VideoData;
  private _context: common.UIAbilityContext;
  private _watchSaveTimerId: number = -1;
  private _sleepTimerId: number = -1;
  private _sleepTimerEndsAt: number = 0;
  private _watchVideoId: string = '';
  private _activePlayPromise: Promise<VideoData | null> | null = null;
  private _activePlayVideoId: string = '';
  private _preparePromise: Promise<PreparedPlayback> | null = null;
  private _prepareVideoId: string = '';
  private _prepareGeneration: number = -1;
  private _prepareAttemptId: string = '';
  private _attemptSequence: number = 0;
  /** Invalidates async extraction/source submission across a fresh external open. */
  private _playGeneration: number = 0;
  /** Source already accepted by the controller; MPV may still be opening/decoding it. */
  private _submittedVideoId: string = '';

  private _cachedVideoSource: VideoData | null = null;
  private _lastPlayError: ErrorInfo | null = null;
  private _cachedChannelProfiles: Map<string, CachedChannelProfile> = new Map();
  private _activeExtrasVideoId: string = '';
  private _pendingResumeSec: number = -1;
  private _pendingAutoPlay: boolean | null = null;
  /** 画中画是否激活（由 PiPManager.onStateChange 设置） */
  private _isPiPActive: boolean = false;
  /**
   * 会话级「仅音频」：关视频轨 + 页内封面层。
   * 不写 Preferences；release / forceReset 时清除。
   */
  private _isAudioOnlyMode: boolean = false;
  /** release() 时调用，用于停止 PiP（避免循环 import，由 PiPManager 注入） */
  onStopPiP: (() => Promise<void>) | null = null;

  /** PlayerSession 被 release 销毁时由外部（Index.ets）设置的回调，用于清理 NavStack */
  onSessionReleased?: () => void;
  private playbackExtrasListeners: Set<(source: VideoData) => void> = new Set();

  subscribePlaybackExtras(listener: (source: VideoData) => void): void {
    this.playbackExtrasListeners.add(listener);
  }

  unsubscribePlaybackExtras(listener: (source: VideoData) => void): void {
    this.playbackExtrasListeners.delete(listener);
  }

  static getInstance(): PlayerSession {
    if (!PlayerSession.instance) {
      PlayerSession.instance = new PlayerSession();
    }
    return PlayerSession.instance;
  }

  private constructor() {
    this._context = AppStorage.get('context') as common.UIAbilityContext;

    this._defaultSource = {
      name: $r('app.string.module_desc'),
      description: '',
      time: '00:00',
      auto: true,
      head: $r('app.media.foreground'),
      likeCount: '0',
      commentCount: '0',
      shareCount: '0',
      play: false,
      index: 0
    };

    this._controller = new AvPlayerController(this._defaultSource);
    this.bindControllerQueueControls();
    this.bindQueueSwitchHandler();
    this.registerContinueStateListener();
    logger.debug(`${TAG} Session reset`);
  }

  get controller(): AvPlayerController {
    return this._controller;
  }

  get currentVideo(): VideoItem | null {
    return this._currentVideo;
  }

  get currentVideoSource(): VideoData {
    return this._defaultSource;
  }

  get isReleased(): boolean {
    return this._controller.playerState === PlayerState.RELEASED;
  }

  get playerState(): PlayerState {
    return this._controller.playerState;
  }

  get cachedVideoSource(): VideoData | null {
    return this._cachedVideoSource;
  }

  set cachedVideoSource(source: VideoData | null) {
    this._cachedVideoSource = source;
  }

  get lastPlayError(): ErrorInfo | null {
    return this._lastPlayError;
  }

  get isPiPActive(): boolean {
    return this._isPiPActive;
  }

  setPiPActive(active: boolean): void {
    if (this._isPiPActive !== active) {
      this._isPiPActive = active;
      AppStorage.setOrCreate('isPiPActive', active);
      logger.info(`${TAG} isPiPActive=${active}`);
    }
  }

  get isAudioOnlyMode(): boolean {
    return this._isAudioOnlyMode;
  }

  get sleepTimerRemainingMinutes(): number {
    if (this._sleepTimerEndsAt <= Date.now()) {
      return 0;
    }
    return Math.ceil((this._sleepTimerEndsAt - Date.now()) / 60000);
  }

  setSleepTimer(durationMinutes: number): void {
    this.cancelSleepTimer();
    const minutes = Math.max(0, Math.min(1439, Math.floor(durationMinutes)));
    if (minutes === 0) {
      logger.info(`${TAG} sleep timer cancelled by user`);
      return;
    }
    const durationMs = minutes * 60000;
    this._sleepTimerEndsAt = Date.now() + durationMs;
    this._sleepTimerId = setTimeout(() => {
      this._sleepTimerId = -1;
      this._sleepTimerEndsAt = 0;
      logger.info(`${TAG} sleep timer fired minutes=${minutes}`);
      this.release();
      this._context.terminateSelf().then(() => {
        logger.info(`${TAG} sleep timer terminated ability`);
      }).catch((e: Error) => {
        logger.error(`${TAG} sleep timer terminateSelf failed: ${e.message || e}`);
      });
    }, durationMs);
    logger.info(`${TAG} sleep timer scheduled minutes=${minutes} endsAt=${this._sleepTimerEndsAt}`);
  }

  cancelSleepTimer(): void {
    if (this._sleepTimerId >= 0) {
      clearTimeout(this._sleepTimerId);
      this._sleepTimerId = -1;
    }
    this._sleepTimerEndsAt = 0;
  }

  /**
   * 切换会话级仅音频：立刻 vid on/off；AppStorage 供播放页封面层订阅。
   * 不处理 PiP autoStart（由 PlayerPage 根据 isAudioOnlyMode 守卫）。
   */
  setAudioOnlyMode(enabled: boolean): void {
    if (this._isAudioOnlyMode === enabled) {
      return;
    }
    this._isAudioOnlyMode = enabled;
    AppStorage.setOrCreate('isAudioOnlyMode', enabled);
    logger.info(`${TAG} isAudioOnlyMode=${enabled}`);
    try {
      this._controller.setVideoOutputEnabled(!enabled);
    } catch (e) {
      logger.warn(`${TAG} setVideoOutputEnabled on audio-only failed: ${e}`);
    }
    if (enabled && this._isPiPActive && this.onStopPiP) {
      this.onStopPiP().catch((err: Error) => {
        logger.warn(`${TAG} stopPiP on audio-only failed: ${err.message}`);
      });
      this.setPiPActive(false);
    }
  }

  private clearAudioOnlyMode(): void {
    if (!this._isAudioOnlyMode) {
      AppStorage.setOrCreate('isAudioOnlyMode', false);
      return;
    }
    this._isAudioOnlyMode = false;
    AppStorage.setOrCreate('isAudioOnlyMode', false);
    logger.info(`${TAG} isAudioOnlyMode cleared`);
  }

  setContinuationRestoreOptions(progressSec: number, shouldPlay: boolean): void {
    this._pendingResumeSec = progressSec > 0 ? progressSec : 0;
    this._pendingAutoPlay = shouldPlay;
  }

  getCachedChannelProfile(channelId: string): CachedChannelProfile | undefined {
    return this._cachedChannelProfiles.get(channelId);
  }

  setCachedChannelProfile(channelId: string, profile: CachedChannelProfile): void {
    this._cachedChannelProfiles.set(channelId, profile);
  }

  private isSessionActive(): boolean {
    const s = this._controller.playerState;
    return s !== PlayerState.RELEASED && s !== PlayerState.IDLE;
  }

  private continueStateListener: ContinueStateListener | null = null;

  private registerContinueStateListener(): void {
    this.continueStateListener = new ContinueStateListener(this._context);
    this._controller.addStateListener(this.continueStateListener);
    this.handleContinueStateChange(this._controller.playerState);
  }

  private handleContinueStateChange(to: PlayerState): void {
    const activeStates: Set<PlayerState> = new Set<PlayerState>([
      PlayerState.PLAYING, PlayerState.PAUSED, PlayerState.BUFFERING, PlayerState.READY
    ]);
    const state: AbilityConstant.ContinueState = activeStates.has(to)
      ? AbilityConstant.ContinueState.ACTIVE
      : AbilityConstant.ContinueState.INACTIVE;
    try {
      this._context.setMissionContinueState(state);
    } catch (err) {
      logger.warn(`${TAG} setMissionContinueState(${to}→${state}) failed: ${JSON.stringify(err)}`);
    }
  }

  // ──── Surface 绑定 ────
  // Surface 管理现在由 UI 层（AVPlayer）直接负责
  // UI 层在 XComponent.onLoad 时调用 controller.setSurfaceID()

  async ensureInitialized(): Promise<void> {
    if (this._controller.playerState === PlayerState.RELEASED) {
      logger.warn(`${TAG} ensureInitialized called after release, reinitializing`);
      // Keep session audio-only across engine re-create (e.g. open with audio-only then play()).
      this.resetSession(true);
    }
    await this._controller.initAVPlayer();
  }

  /**
   * Start click-to-play work before PlayerPage lifecycle runs. This deliberately
   * stops before controller.updateVideoSource(), so MPV cannot load before the
   * player surface exists. play() consumes the same in-flight result.
   */
  beginPrepare(video: VideoItem): void {
    const videoId = video.videoId || YOUTUBE_VIDEO_ID;
    if (!videoId) return;
    const generation = this._playGeneration;
    if (this._preparePromise
      && this._prepareVideoId === videoId
      && this._prepareGeneration === generation) {
      return;
    }
    const attemptId = `${videoId}-${Date.now()}-${++this._attemptSequence}`;
    const startedAt = Date.now();
    this._prepareVideoId = videoId;
    this._prepareGeneration = generation;
    this._prepareAttemptId = attemptId;
    this._controller.setStartupAttempt(attemptId, startedAt);
    logger.info(`${TAG} [STARTUP] attempt=${attemptId} stage=card_click`);
    logger.info(`${TAG} [STARTUP] attempt=${attemptId} stage=prepare_start generation=${generation}`);
    const playService = YouTubePlayService.getInstance(this._context);
    const proxyTask = LocalMediaProxy.warmup().then((ok: boolean) => {
      logger.info(`${TAG} [STARTUP] attempt=${attemptId} stage=proxy_ready elapsed=${Date.now() - startedAt}ms ok=${ok}`);
      return ok;
    }).catch((e: Error) => {
      logger.warn(`${TAG} [STARTUP] attempt=${attemptId} stage=proxy_failed error=${e.message || e}`);
      return false;
    });
    const initTask = this.ensureInitialized().then(() => {
      logger.info(`${TAG} [STARTUP] attempt=${attemptId} stage=engine_ready elapsed=${Date.now() - startedAt}ms`);
    }).catch((e: Error) => {
      // Preparation is speculative with respect to page lifetime. Keep the
      // shared task settled even if the page is closed before it consumes it;
      // updateVideoSource retains its normal initialization/error path.
      logger.warn(`${TAG} [STARTUP] attempt=${attemptId} stage=engine_prepare_failed error=${e.message || e}`);
    });
    this._preparePromise = Promise.all([
      playService.play(videoId, attemptId),
      initTask,
      proxyTask
    ]).then((values) => ({
      result: values[0],
      generation: generation,
      attemptId: attemptId,
      startedAt: startedAt
    } as PreparedPlayback));
  }

  // ──── 播放控制 ────

  private bindControllerQueueControls(): void {
    this._controller.onNextCommand = () => {
      this.playNextFromQueue();
    };
    this._controller.onPreviousCommand = () => {
      this.playPreviousFromQueue();
    };
  }

  private bindQueueSwitchHandler(): void {
    PlayQueueManager.getInstance().onSwitchVideo = (video: VideoItem) => {
      this.switchToQueueVideo(video);
    };
  }

  private async switchToQueueVideo(video: VideoItem): Promise<void> {
    if (!video || !video.videoId) {
      return;
    }
    logger.info(`${TAG} queue switch -> ${video.videoId}`);
    AppStorage.setOrCreate('selectedVideo', video);
    await this.play(video);
  }

  canPlayNextFromQueue(): boolean {
    const queueManager = PlayQueueManager.getInstance();
    return queueManager.hasNext() || queueManager.hasMorePages;
  }

  canPlayPreviousFromQueue(): boolean {
    return PlayQueueManager.getInstance().hasPrev();
  }

  async playNextFromQueue(): Promise<boolean> {
    const video = await PlayQueueManager.getInstance().nextOrLoadMore();
    return video !== null;
  }

  async playPreviousFromQueue(): Promise<boolean> {
    const video = PlayQueueManager.getInstance().prev();
    return video !== null;
  }

  async play(video: VideoItem): Promise<VideoData | null> {
    if (!this.isSessionActive()) {
      // Critical: openVideoDetail may setAudioOnlyMode(true) before play().
      // Rebuilding the engine must not wipe that session preference.
      this.resetSession(true);
    }

    const videoId = video.videoId || YOUTUBE_VIDEO_ID;

    // Finish accounting for the old media before publishing the new current
    // video. Otherwise the history timer can write new metadata to the old ID
    // while extraction of the replacement source is still in flight.
    if (this._currentVideo?.videoId && this._currentVideo.videoId !== videoId) {
      this.saveWatchHistory();
      this.stopWatchSaveTimer();
      this._watchVideoId = '';
      this._activeExtrasVideoId = '';
      this._cachedVideoSource = null;
      logger.info(`${TAG} media switch ${this._currentVideo.videoId} -> ${videoId}`);
    }

    if (this._currentVideo?.videoId === video.videoId
      && (this._controller.vm.isReady || this._submittedVideoId === videoId)) {
      logger.info(`${TAG} play() skipped: same video ${videoId} already submitted/ready`);
      return this._defaultSource;
    }

    if (this._activePlayVideoId === videoId && this._activePlayPromise) {
      logger.info(`${TAG} play() dedup: same video ${videoId} already extracting, returning existing promise`);
      return this._activePlayPromise;
    }

    this._currentVideo = video;
    this._activePlayVideoId = videoId;
    logger.info(`${TAG} play() called for ${videoId}`);

    const generation = this._playGeneration;
    const promise = this.doPlay(video, videoId, generation);
    this._activePlayPromise = promise;
    try {
      return await promise;
    } finally {
      if (this._activePlayPromise === promise) {
        this._activePlayPromise = null;
        this._activePlayVideoId = '';
      }
    }
  }

  private async doPlay(video: VideoItem, videoId: string, generation: number): Promise<VideoData | null> {
    try {
      const playService = YouTubePlayService.getInstance(this._context);
      const startedAt = Date.now();
      let prepared: PreparedPlayback;
      if (this._preparePromise
        && this._prepareVideoId === videoId
        && this._prepareGeneration === generation) {
        prepared = await this._preparePromise;
      } else {
        this.beginPrepare(video);
        prepared = await this._preparePromise!;
      }
      const result = prepared.result;
      const attemptId = prepared.attemptId;
      logger.info(`${TAG} [TIMING] video=${videoId} extract+MPV init elapsed=${Date.now() - startedAt}ms`);

      if (prepared.generation !== this._playGeneration
        || generation !== this._playGeneration || this._currentVideo?.videoId !== videoId) {
        logger.info(`${TAG} doPlay() result discarded: session changed during extraction`);
        return null;
      }

      if (result.success && result.videoInfo) {
        const videoStream = result.videoInfo.streams?.find((s) => s.hasVideo && s.width && s.height);
        if (this._currentVideo) {
          if (result.videoInfo.title && this._currentVideo.title !== result.videoInfo.title) {
            this._currentVideo.title = result.videoInfo.title;
          }
          if (result.videoInfo.author && this._currentVideo.author !== result.videoInfo.author) {
            this._currentVideo.author = result.videoInfo.author;
          }
          if (result.videoInfo.channelId && this._currentVideo.channelId !== result.videoInfo.channelId) {
            this._currentVideo.channelId = result.videoInfo.channelId;
          }
          if (result.videoInfo.uploaderAvatarUrl) {
            const avatarUrl = normalizeUrl(result.videoInfo.uploaderAvatarUrl);
            if (this._currentVideo.channelAvatarUrl !== avatarUrl) {
              this._currentVideo.channelAvatarUrl = avatarUrl;
            }
          }
          // Keep the thumbnail selected by the feed stable throughout startup.
          // Replacing it while the loading cover is visible restarts MediaThumb's
          // fallback chain and produces a black flash between image requests.
          // Back-fill local history for cloud-synced rows missing author / channel meta.
          WatchHistoryStore.enrichMetadata(
            videoId,
            this._currentVideo.title || '',
            this._currentVideo.author || '',
            this._currentVideo.thumbnailUrl || '',
            result.videoInfo.lengthSeconds || 0,
            this._currentVideo.channelId || '',
            this._currentVideo.channelAvatarUrl || '',
            this._currentVideo.channelHandle || ''
          );
        }
        const videoSource: VideoData = {
          name: this._defaultSource.name,
          description: result.videoInfo.title || '',
          time: this._defaultSource.time,
          auto: this._defaultSource.auto,
          head: this._defaultSource.head,
          likeCount: this._defaultSource.likeCount,
          commentCount: this._defaultSource.commentCount,
          shareCount: this._defaultSource.shareCount,
          author: result.videoInfo.author || '',
          channelId: result.videoInfo.channelId || '',
          videoDescription: result.videoInfo.description || '',
          play: true,
          index: 0,
          width: videoStream?.width || 0,
          height: videoStream?.height || 0,
          error: undefined,
          streams: result.playerStreams ?? [],
          subtitleTracks: result.subtitleTracks ?? [],
          isLive: result.videoInfo.isLive || false,
          hlsUrl: result.videoInfo.hlsUrl,
          dashMpdUrl: result.videoInfo.dashMpdUrl,
          thumbnailUrl: video.thumbnailUrl || '',
          videoId: videoId,
          viewCount: result.videoInfo.viewCount || 0,
          publishDate: result.videoInfo.publishDate || '',
          tags: result.videoInfo.tags || []
        };

        this._defaultSource = videoSource;
        this._lastPlayError = null;
        this._watchVideoId = videoId;
        const resumeSec: number = this._pendingResumeSec >= 0
          ? this._pendingResumeSec
          : WatchHistoryStore.getProgress(videoId);
        const shouldPlay = this._pendingAutoPlay ?? true;
        this._pendingResumeSec = -1;
        this._pendingAutoPlay = null;
        if (resumeSec > 0) {
          logger.info(`${TAG} Will resume at ${resumeSec}s`);
          this._controller.setPendingStartFromSec(resumeSec);
        }
        videoSource.play = shouldPlay;
        videoSource.auto = shouldPlay;
        logger.info(`${TAG} stream ready, updating player source video=${videoId} streams=${videoSource.streams?.length || 0}`);
        logger.info(`${TAG} [STARTUP] attempt=${attemptId} stage=source_submit elapsed=${Date.now() - prepared.startedAt}ms`);
        await this._controller.updateVideoSource(videoSource);
        if (generation !== this._playGeneration || this._currentVideo?.videoId !== videoId) {
          logger.info(`${TAG} source completion discarded: session changed during submission`);
          return null;
        }
        this._submittedVideoId = videoId;
        logger.info(`${TAG} [STARTUP] attempt=${attemptId} stage=source_submitted elapsed=${Date.now() - prepared.startedAt}ms`);
        this.fetchPlaybackExtrasInBackground(playService, result.videoInfo);
        this.startWatchSaveTimer();
        return videoSource;
      } else {
        logger.error(`${TAG} play() failed: ${result.error}`);
        this._lastPlayError = result.error ?? null;
        return null;
      }
    } catch (e) {
      logger.error(`${TAG} play() exception: ${e}`);
      const options: ErrorInfoOptions = {
        isRetryable: true,
        exception: e as Error
      };
      this._lastPlayError = new ErrorInfo(
        'UNKNOWN_ERROR',
        (e as Error).message || $r('app.string.yt_error_playback_failed'),
        options
      );
      return null;
    }
  }

  private formatStatCount(count: number | undefined): string {
    if (count === undefined || count === null || count < 0) {
      return '0';
    }
    return count.toLocaleString();
  }

  private fetchPlaybackExtrasInBackground(playService: YouTubePlayService, videoInfo: VideoInfo): void {
    const videoId = videoInfo.videoId;
    this._activeExtrasVideoId = videoId;
    const startedAt = Date.now();
    logger.info(`${TAG} playback extras start video=${videoId}`);
    playService.fetchPlaybackExtrasFor(videoInfo).then((extras) => {
      if (!extras || this._currentVideo?.videoId !== videoId || this._activeExtrasVideoId !== videoId) {
        return;
      }
      logger.info(`${TAG} playback extras done video=${videoId} elapsed=${Date.now() - startedAt}ms like=${extras.likeCount ?? -1} dislike=${extras.dislikeCount ?? -1} related=${extras.relatedItems?.length || 0}`);

      const likeText = (extras.likeCount !== undefined && extras.likeCount >= 0)
        ? this.formatStatCount(extras.likeCount)
        : '';
      const dislikeText = (extras.dislikeCount !== undefined && extras.dislikeCount >= 0)
        ? this.formatStatCount(extras.dislikeCount)
        : '';
      this._defaultSource.likeCount = likeText.length > 0 ? likeText : this._defaultSource.likeCount;
      this._defaultSource.dislikeCount = dislikeText.length > 0 ? dislikeText : (this._defaultSource.dislikeCount || '0');
      if (extras.title) this._defaultSource.description = extras.title;
      if (extras.author) this._defaultSource.author = extras.author;
      if (extras.description) this._defaultSource.videoDescription = extras.description;
      if (extras.channelId) this._defaultSource.channelId = extras.channelId;
      if (extras.viewCount !== undefined && extras.viewCount >= 0) this._defaultSource.viewCount = extras.viewCount;
      if (extras.publishDate) this._defaultSource.publishDate = extras.publishDate;
      if (extras.tags && extras.tags.length > 0) this._defaultSource.tags = extras.tags;

      if (this._currentVideo?.videoId === videoId) {
        if (extras.title) this._currentVideo.title = extras.title;
        if (extras.author) this._currentVideo.author = extras.author;
        if (extras.channelId) this._currentVideo.channelId = extras.channelId;
      }

      if (extras.uploaderAvatarUrl && this._currentVideo) {
        const avatarUrl = normalizeUrl(extras.uploaderAvatarUrl);
        if (avatarUrl.length > 0) {
          this._currentVideo.channelAvatarUrl = avatarUrl;
        }
      }

      if (this._cachedVideoSource && this._cachedVideoSource.videoId === videoId) {
        this._cachedVideoSource = this._defaultSource;
      }
      for (const listener of this.playbackExtrasListeners) {
        try {
          listener(this._cachedVideoSource || this._defaultSource);
        } catch (e) {
          logger.warn(`${TAG} playback extras listener failed: ${e}`);
        }
      }

      const relatedItems = extras.relatedItems;
      if (relatedItems && relatedItems.length > 0) {
        const videoItems: VideoItem[] = relatedItems.map((r) => new VideoItem(
          0, r.videoId, r.title, r.author, '',
          normalizeUrl(r.thumbnailUrl || getFallbackThumbnailUrl(r.videoId)), !!r.isLive, '#CCCCCC',
          r.channelId || '', '', '', '', null
        ));
        PlayQueueManager.getInstance().setAutoQueueCandidates(videoItems);
      }
    }).catch((e: Error) => {
      logger.warn(`${TAG} fetchPlaybackExtrasInBackground failed: ${e.message || e}`);
    });
  }

  // ──── 历史记录 ────

  private startWatchSaveTimer(): void {
    this.stopWatchSaveTimer();
    this._watchSaveTimerId = setInterval(() => {
      this.saveWatchHistory();
    }, 10000);
  }

  private stopWatchSaveTimer(): void {
    if (this._watchSaveTimerId !== -1) {
      clearInterval(this._watchSaveTimerId);
      this._watchSaveTimerId = -1;
    }
  }

  private saveWatchHistory(): void {
    if (!this._watchVideoId) return;
    // release()/forceReset() 链路上，controller 可能已被 releaseVideo(0) 释放、
    // vm.currentTime 已被清零。强行落盘会把真实进度覆盖成 0。
    const state = this._controller.playerState;
    if (state === PlayerState.RELEASED || state === PlayerState.IDLE) {
      logger.info(`${TAG} saveWatchHistory skipped: controller state=${state} (already released)`);
      return;
    }
    try {
      const progressSec = this._controller.vm.currentTime;
      const durationSec = this._controller.vm.durationTime;
      WatchHistoryStore.record(
        this._watchVideoId,
        this._currentVideo?.title || '',
        this._currentVideo?.author || '',
        this._currentVideo?.thumbnailUrl || '',
        durationSec,
        progressSec,
        this._currentVideo?.channelId || '',
        this._currentVideo?.channelAvatarUrl || '',
        this._currentVideo?.channelHandle || ''
      );
      logger.info(`${TAG} Saved history: ${this._watchVideoId} at ${progressSec.toFixed(1)}s`);
    } catch (e) {
      logger.warn(`${TAG} saveWatchHistory failed: ${e}`);
    }
  }

  // ──── 生命周期 ────

  release(): void {
    if (this._controller.playerState === PlayerState.RELEASED) return;
    logger.info(`${TAG} release() called`);
    // 若画中画激活，先停止 PiP（释放播放器前关闭悬浮窗）
    if (this._isPiPActive && this.onStopPiP) {
      this.onStopPiP().catch((e: Error) => {
        logger.warn(`${TAG} stopPiP on release failed: ${e.message}`);
      });
      this.setPiPActive(false);
    }
    this.clearAudioOnlyMode();
    this.cancelSleepTimer();
    this.saveWatchHistory();
    this.stopWatchSaveTimer();
    this._controller.releaseVideo(0);
    const queue = PlayQueueManager.getInstance();
    if (queue.sourceType === QueueSourceType.ADHOC) {
      queue.clear();
    }
  }

  /**
   * 强制冷重置：把会话恢复到"应用首次播放"的干净状态。
   * 用于全新进入播放页（从列表/作者页点新视频）前，彻底清除上一次（尤其关闭 PiP）的残留状态。
   * 注意：不要在 PiP 恢复路径调用——那条必须保留存活引擎。
   */
  forceReset(): void {
    logger.info(`${TAG} forceReset() called`);
    this.saveWatchHistory();
    this.stopWatchSaveTimer();
    this.resetSession(false);
  }

  /**
   * @param preserveAudioOnly when true, keep isAudioOnlyMode and re-apply
   *   video-off on the new controller (used by play/ensureInitialized).
   *   forceReset/release always pass false.
   */
  private resetSession(preserveAudioOnly: boolean = false): void {
    this._playGeneration++;
    const keepAudioOnly = preserveAudioOnly && this._isAudioOnlyMode;
    this._controller.releaseVideo(0);
    this._currentVideo = null;
    this._watchVideoId = '';
    this._activePlayPromise = null;
    this._activePlayVideoId = '';
    this._preparePromise = null;
    this._prepareVideoId = '';
    this._prepareGeneration = -1;
    this._prepareAttemptId = '';
    this._submittedVideoId = '';
    this._cachedVideoSource = null;
    this._cachedChannelProfiles.clear();
    // 清 PiP 激活状态：避免会话在 PiP 激活时被 reset 后，_isPiPActive / AppStorage.isPiPActive
    // 残留为 true，导致占位层显示残留或返回键误判已在 PiP。
    this.setPiPActive(false);
    this.clearAudioOnlyMode();
    this._defaultSource = {
      name: $r('app.string.module_desc'),
      description: '',
      time: '00:00',
      auto: true,
      head: $r('app.media.foreground'),
      likeCount: '0',
      commentCount: '0',
      shareCount: '0',
      play: false,
      index: 0
    };
    this._controller = new AvPlayerController(this._defaultSource);
    this.bindControllerQueueControls();
    this.bindQueueSwitchHandler();
    this.registerContinueStateListener();
    if (keepAudioOnly) {
      // Re-arm after clear: AppStorage + deferred vid=no on the new controller.
      this._isAudioOnlyMode = true;
      AppStorage.setOrCreate('isAudioOnlyMode', true);
      try {
        this._controller.setVideoOutputEnabled(false);
      } catch (e) {
        logger.warn(`${TAG} re-apply audio-only after reset failed: ${e}`);
      }
      logger.info(`${TAG} Session reset (audio-only preserved)`);
    } else {
      logger.debug(`${TAG} Session reset`);
    }
  }
}

class ContinueStateListener implements StateChangeListener {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  onStateChange(_from: PlayerState, to: PlayerState): void {
    const activeStates: Set<PlayerState> = new Set<PlayerState>([
      PlayerState.PLAYING, PlayerState.PAUSED, PlayerState.BUFFERING, PlayerState.READY
    ]);
    const state: AbilityConstant.ContinueState = activeStates.has(to)
      ? AbilityConstant.ContinueState.ACTIVE
      : AbilityConstant.ContinueState.INACTIVE;
    try {
      this.context.setMissionContinueState(state);
    } catch (err) {
      logger.warn(`${TAG} setMissionContinueState(${to}→${state}) failed: ${JSON.stringify(err)}`);
    }
  }
}
