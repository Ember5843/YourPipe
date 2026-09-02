import { AppLog } from './AppLog';
import { AbilityConstant, common } from '@kit.AbilityKit';
import { AvPlayerController, VideoData, PlayerState, StateChangeListener, LocalMediaProxy, SubtitleTrack } from 'mediaservice';
import { VideoInfo, VideoItem } from 'youtube_core';
import { YouTubePlayResult, YouTubePlayService } from '../features/player/YouTubePlayService';
// [DISABLED] P3：import { AsrLiveCaptionService } from '../features/player/asr/AsrLiveCaptionService';
import { PlayQueueManager, QueueSourceType } from '../features/player/PlayQueueManager';
import { WatchHistoryStore } from './WatchHistoryStore';
import { PreferencesStore } from './PreferencesStore';
import { TranslationService } from './TranslationService';
// [DISABLED] P2 gtx 已随菜单项注释关闭；恢复时取消注释本行与 autoSelectPreferredSubtitle 内的调用
// import { SubtitleTranslationService } from '../features/player/translate/SubtitleTranslationService';
import { normalizeUrl } from '../features/home/utils/ThumbnailUtils';
import { formatDurationHms } from './utils/FormatUtils';
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
  /** One-shot timer for the queue-next extraction prefetch (Layer 4). */
  private _queuePrefetchTimerId: number = -1;
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
  /** 下一次 prepare 跳过 prefetch,强制新鲜提取(失败重试用,一次性) */
  private _forceRefreshNextPrepare: boolean = false;
  /** 假结束/媒体层失败的原地重试预算(对齐 PipePipe/SmartTube:永不因瞬时错误跳下一首) */
  private _failureRetryCount: number = 0;
  private _failureRetryInFlight: boolean = false;
  private _failureRetryVideoId: string = '';
  private readonly MAX_FAILURE_RETRIES: number = 5;
  private readonly FAILURE_RETRY_BACKOFF_MS: number[] = [1000, 2000, 4000, 8000, 16000];
  /** 画中画是否激活（由 PiPManager.onStateChange 设置） */
  private _isPiPActive: boolean = false;
  private _pipHandoffPending: boolean = false;
  private _pipRestoring: boolean = false;
  private _explicitPageCloseHandled: boolean = false;
  /**
   * 会话级「仅音频」：关视频轨 + 页内封面层。
   * 不写 Preferences；release / forceReset 时清除。
   */
  private _isAudioOnlyMode: boolean = false;
  /** release() 时调用，用于停止 PiP（避免循环 import，由 PiPManager 注入） */
  onStopPiP: (() => Promise<void>) | null = null;

  private playbackExtrasListeners: Set<(source: VideoData) => void> = new Set();

  subscribePlaybackExtras(listener: (source: VideoData) => void): void {
    this.playbackExtrasListeners.add(listener);
  }

  unsubscribePlaybackExtras(listener: (source: VideoData) => void): void {
    this.playbackExtrasListeners.delete(listener);
  }

  private notifyPlaybackSourceChanged(source: VideoData, stage: string): void {
    logger.debug(`${TAG} playback source notify video=${source.videoId || ''} stage=${stage}`);
    for (const listener of this.playbackExtrasListeners) {
      try {
        listener(source);
      } catch (e) {
        logger.warn(`${TAG} playback source listener failed stage=${stage}: ${e}`);
      }
    }
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

  get isPipHandoffPending(): boolean {
    return this._pipHandoffPending;
  }

  get isPipRestoring(): boolean {
    return this._pipRestoring;
  }

  beginPipHandoff(): void {
    this._pipHandoffPending = true;
    AppStorage.setOrCreate('isPipHandoffPending', true);
    this.syncPipPlaceholderVisibility();
    logger.info(`${TAG} PiP handoff pending`);
  }

  cancelPipHandoff(): void {
    if (this._pipHandoffPending) {
      logger.info(`${TAG} PiP handoff cancelled`);
    }
    this._pipHandoffPending = false;
    AppStorage.setOrCreate('isPipHandoffPending', false);
    this.syncPipPlaceholderVisibility();
  }

  completePipHandoff(): void {
    this._pipHandoffPending = false;
    AppStorage.setOrCreate('isPipHandoffPending', false);
    this.syncPipPlaceholderVisibility();
    logger.info(`${TAG} PiP handoff completed`);
  }

  setPipRestoring(restoring: boolean): void {
    this._pipRestoring = restoring;
    AppStorage.setOrCreate('isPipRestoring', restoring);
    this.syncPipPlaceholderVisibility();
    logger.info(`${TAG} PiP restoring=${restoring}`);
  }

  /**
   * True while PiP owns media across page tear-down: enter handoff, active PiP,
   * or restore until the replacement PlayerPage finishes attach.
   * Must stay true through old-page aboutToDisappear during restore, or
   * closeForNavigation()/release() clears ADHOC queue and kills the engine.
   */
  shouldRetainMediaOnPageDisappear(): boolean {
    return this._pipHandoffPending || this._isPiPActive || this._pipRestoring;
  }

  /**
   * Placeholder ("画中画运行中") only when PiP owns the surface and the page is
   * not mid enter-handoff or restore. Avoids flash on startPiP+pop and restore.
   */
  shouldShowPipPlaceholder(): boolean {
    return this._isPiPActive && !this._pipHandoffPending && !this._pipRestoring;
  }

  consumeExplicitPageCloseHandled(): boolean {
    const handled = this._explicitPageCloseHandled;
    this._explicitPageCloseHandled = false;
    return handled;
  }

  setPiPActive(active: boolean): void {
    if (this._isPiPActive !== active) {
      this._isPiPActive = active;
      AppStorage.setOrCreate('isPiPActive', active);
      logger.info(`${TAG} isPiPActive=${active}`);
    }
    this.syncPipPlaceholderVisibility();
  }

  private syncPipPlaceholderVisibility(): void {
    AppStorage.setOrCreate('showPipPlaceholder', this.shouldShowPipPlaceholder());
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
      this.recreateReleasedController(true);
    }
    // Page binding and click preparation may happen before a media source is
    // ready. Keep this path MPV-only; AVSession/background ownership starts
    // when updateVideoSource submits the first source for this media session.
    await this._controller.prewarmPlaybackEngine();
  }

  async prewarmPlaybackEngine(): Promise<void> {
    if (this._controller.playerState === PlayerState.RELEASED) {
      this.recreateReleasedController(false);
    }
    await this._controller.prewarmPlaybackEngine();
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
      this.consumePrefetchOrPlay(playService, videoId, attemptId),
      initTask,
      proxyTask
    ]).then((values) => ({
      result: values[0],
      generation: generation,
      attemptId: attemptId,
      startedAt: startedAt
    } as PreparedPlayback));
  }

  /**
   * Layer 4: consume a prefetched extraction for this video when the queue
   * prefetch already ran; otherwise start the normal play() extraction.
   */
  private async consumePrefetchOrPlay(playService: YouTubePlayService,
    videoId: string, attemptId: string): Promise<YouTubePlayResult> {
    // 失败重试路径要求新鲜提取:跳过可能同样过期的 prefetch 结果(一次性标志)
    const forceRefresh = this._forceRefreshNextPrepare;
    this._forceRefreshNextPrepare = false;
    if (!forceRefresh) {
      const hit = await playService.takePrefetched(videoId);
      if (hit) {
        logger.info(`${TAG} [STARTUP] attempt=${attemptId} stage=prefetch_consume video=${videoId}`);
        return hit;
      }
    }
    return playService.play(videoId, attemptId);
  }

  /**
   * Layer 4: once playback of the current video is stable, prefetch the next
   * queue item's stream data on idle bandwidth. A generation/current-video
   * check at fire time prevents prefetching after a switch.
   */
  private scheduleQueuePrefetch(currentVideoId: string): void {
    if (this._queuePrefetchTimerId >= 0) {
      clearTimeout(this._queuePrefetchTimerId);
      this._queuePrefetchTimerId = -1;
    }
    const generation = this._playGeneration;
    this._queuePrefetchTimerId = setTimeout(() => {
      this._queuePrefetchTimerId = -1;
      if (!this.isPlayContextCurrent(generation, currentVideoId)) {
        return;
      }
      if (!this._controller.vm.isPlaying) {
        return;
      }
      const next = PlayQueueManager.getInstance().peekNext();
      if (next?.videoId && next.videoId !== currentVideoId) {
        logger.info(`${TAG} queue prefetch kick next=${next.videoId}`);
        YouTubePlayService.getInstance(this._context).prefetch(next.videoId);
      }
    }, 6000);
  }

  // ──── 播放控制 ────

  private bindControllerQueueControls(): void {
    this._controller.onNextCommand = () => {
      this.playNextFromQueue();
    };
    this._controller.onPreviousCommand = () => {
      this.playPreviousFromQueue();
    };
    this._controller.subscribeEnded(this.onPlaybackEnded);
    // 同 URL 快速重试耗尽后的升级:重新提取新鲜流 URL 原地重载当前条目
    this._controller.onRetryWithFreshStreams = (resumePosSec: number) => {
      this.retryCurrentWithFreshStreams(resumePosSec);
    };
    // 真正开播后重置失败重试预算
    this._controller.subscribePlaybackState((state) => {
      if (state.isPlaying && this._failureRetryCount > 0) {
        this._failureRetryCount = 0;
      }
    });
  }

  private _lastAutoAdvanceFromVideoId: string = '';

  private onPlaybackEnded = (): void => {
    // 切集窗口的假结束:新视频流尚未提交成功时收到的 End 必然来自旧媒体
    // (mpv 停旧源 / EDL 双轨收尾可能再次上报 End,relay 的边沿检测又已被
    // closeMediaSession 复位)。此时若跳转,会与首次 End 的跳转叠加成隔一个。
    const endingVideoId = this._currentVideo?.videoId || '';
    if (endingVideoId.length > 0 && this._submittedVideoId !== endingVideoId) {
      logger.warn(`${TAG} ended ignored: source for ${endingVideoId} not yet submitted (stale end from previous media)`);
      return;
    }
    // 假结束识别:代理上游 4xx / EDL 分段全灭会让 mpv 提前报 End(进度远未到片尾)。
    // 对齐 PipePipe/SmartTube:媒体层瞬时失败原地重试当前条目,绝不自动跳下一首。
    const state = this._controller.getPlaybackState();
    if (state.duration > 0 && state.currentTime < state.duration - 2) {
      logger.warn(`${TAG} premature end: pos=${state.currentTime.toFixed(2)}s dur=${state.duration.toFixed(2)}s `
        + `video=${this._currentVideo?.videoId || 'unknown'} — treating as failure, retrying in place`);
      this.retryCurrentWithFreshStreams(state.currentTime);
      return;
    }
    const autoPlay = AppStorage.get<boolean>('autoPlayQueue') ?? true;
    if (!autoPlay) {
      return;
    }
    const fromVideoId = this._currentVideo?.videoId || '';
    if (fromVideoId.length > 0 && fromVideoId === this._lastAutoAdvanceFromVideoId) {
      logger.warn(`${TAG} auto-advance suppressed: duplicate ended for ${fromVideoId}`);
      return;
    }
    this._lastAutoAdvanceFromVideoId = fromVideoId;
    logger.info(`${TAG} playback ended, auto-advancing from ${fromVideoId || 'unknown'}`);
    this.playNextFromQueue().catch((e: Error) => {
      logger.warn(`${TAG} auto-advance failed: ${e.message || e}`);
    });
  };

  /**
   * 失败原地重试:强制新鲜提取当前视频的流 URL 并原地重载
   * (PipePipe setRecovery+reloadPlayQueueManager / SmartTube reloadVideo 语义)。
   * 有界:同一 videoId 最多 MAX_FAILURE_RETRIES 次,退避 1/2/4/8/16s;
   * 预算耗尽走 _lastPlayError 错误通道,仍不跳下一首。
   */
  private retryCurrentWithFreshStreams(resumePosSec: number): void {
    const video = this._currentVideo;
    const videoId = video?.videoId || '';
    if (!video || videoId.length === 0) {
      return;
    }
    if (this._failureRetryInFlight) {
      logger.info(`${TAG} fresh-stream retry dedup: already in flight video=${videoId}`);
      return;
    }
    if (this._failureRetryVideoId !== videoId) {
      this._failureRetryVideoId = videoId;
      this._failureRetryCount = 0;
    }
    if (this._failureRetryCount >= this.MAX_FAILURE_RETRIES) {
      logger.error(`${TAG} fresh-stream retry budget exhausted video=${videoId}, giving up (queue NOT advanced)`);
      this._lastPlayError = new ErrorInfo(
        'PLAYBACK_FAILED',
        $r('app.string.yt_error_playback_failed'),
        { isRetryable: true }
      );
      return;
    }
    this._failureRetryInFlight = true;
    const attempt = this._failureRetryCount++;
    const delayMs = this.FAILURE_RETRY_BACKOFF_MS[Math.min(attempt, this.FAILURE_RETRY_BACKOFF_MS.length - 1)];
    const generation = this._playGeneration;
    logger.warn(`${TAG} fresh-stream retry #${attempt + 1}/${this.MAX_FAILURE_RETRIES} `
      + `video=${videoId} resume=${resumePosSec.toFixed(2)}s delay=${delayMs}ms`);
    setTimeout(async () => {
      if (!this.isPlayContextCurrent(generation, videoId)) {
        logger.info(`${TAG} fresh-stream retry discarded: session changed video=${videoId}`);
        this._failureRetryInFlight = false;
        return;
      }
      // 绕过 play() 去重与 prefetch(可能同样过期),强制新鲜提取
      this._submittedVideoId = '';
      this._preparePromise = null;
      this._forceRefreshNextPrepare = true;
      this._pendingResumeSec = resumePosSec;
      this._pendingAutoPlay = true;
      try {
        await this.play(video, true);
      } catch (e) {
        logger.warn(`${TAG} fresh-stream retry play() failed: ${(e as Error).message || e}`);
      } finally {
        this._failureRetryInFlight = false;
      }
    }, delayMs);
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

  async play(video: VideoItem, force: boolean = false): Promise<VideoData | null> {
    if (this._controller.playerState === PlayerState.RELEASED) {
      this.recreateReleasedController(true);
    }

    const videoId = video.videoId || YOUTUBE_VIDEO_ID;

    // Finish accounting for the old media before publishing the new current
    // video. Otherwise the history timer can write new metadata to the old ID
    // while extraction of the replacement source is still in flight.
    if (this._currentVideo?.videoId && this._currentVideo.videoId !== videoId) {
      this.saveWatchHistory();
      this.stopWatchSaveTimer();
      logger.info(`${TAG} media switch ${this._currentVideo.videoId} -> ${videoId}`);
      // Preserve PiP flags when switching media inside an active PiP session
      // (PiP panel NEXT/PREV or in-page queue switch): the system PiP window is
      // still showing, so clearing isPiPActive here would desync presentation,
      // play/pause sync and destroy() guards from the real window state.
      this.resetSession(true, false, this._isPiPActive);
    }

    // force=true（失败原地重试）必须绕过同视频去重：假结束时 vm.isReady 仍为 true，
    // 仅靠清 _submittedVideoId 不足以让重试通过这里的检查。
    if (!force && this._currentVideo?.videoId === video.videoId
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

  private isPlayContextCurrent(generation: number, videoId: string): boolean {
    return generation === this._playGeneration && this._currentVideo?.videoId === videoId;
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
        || !this.isPlayContextCurrent(generation, videoId)) {
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
          // 展示元数据直接以播放中的条目为准：tv_downgraded 等 client 的
          // /player 响应可能不带 videoDetails，此时用 feed 条目的标题/作者兜底，
          // 系统播控（AVSession）与播放页看到的始终是同一个标题。
          description: result.videoInfo.title || video.title || '',
          time: this._defaultSource.time,
          auto: this._defaultSource.auto,
          head: this._defaultSource.head,
          likeCount: this._defaultSource.likeCount,
          commentCount: this._defaultSource.commentCount,
          shareCount: this._defaultSource.shareCount,
          author: result.videoInfo.author || video.author || '',
          channelId: result.videoInfo.channelId || '',
          videoDescription: result.videoInfo.description || '',
          play: true,
          index: 0,
          width: videoStream?.width || 0,
          height: videoStream?.height || 0,
          error: undefined,
          streams: result.playerStreams ?? [],
          subtitleTracks: result.subtitleTracks ?? [],
          chapters: result.videoInfo.chapters || [],
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
        if (!this.isPlayContextCurrent(generation, videoId)) {
          logger.info(`${TAG} source completion discarded: session changed during submission`);
          return null;
        }
        this._submittedVideoId = videoId;
        this._lastAutoAdvanceFromVideoId = '';
        this._cachedVideoSource = videoSource;
        this.autoSelectPreferredSubtitle(videoSource);
        this.notifyPlaybackSourceChanged(videoSource, 'source-ready');
        // Live quality management: parse HLS variants in the background and
        // merge them into the quality list once ready. Playback never waits.
        if (videoSource.isLive && videoSource.hlsUrl) {
          this.fetchLiveVariantsInBackground(playService, result.videoInfo);
        }
        logger.info(`${TAG} [STARTUP] attempt=${attemptId} stage=source_submitted elapsed=${Date.now() - prepared.startedAt}ms`);
        this.fetchPlaybackExtrasInBackground(playService, result.videoInfo);
        this.startWatchSaveTimer();
        this.scheduleQueuePrefetch(videoId);
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

  /**
   * 字幕语言偏好自动选轨（NewPipe 行为）：用户在字幕菜单的选择会持久化到
   * cfg_subtitle_preferred_lang；新视频带字幕轨且偏好非空时自动开对应语言。
   * 偏好为空串表示用户显式关闭过字幕，不自动开启。
   * 偏好为 "ai:" 前缀（用户上次选择了 AI 翻译）时：有目标语言原生轨则选原生轨，
   * 否则异步触发 AI 翻译（gtx 通道，磁盘/内存缓存命中时瞬时完成）。
   */
  private autoSelectPreferredSubtitle(source: VideoData): void {
    const tracks = source.subtitleTracks;
    if (!tracks || tracks.length === 0) return;
    const preferred = PreferencesStore.getString('cfg_subtitle_preferred_lang', '');
    if (preferred.length === 0) return;
    if (preferred.startsWith('ai:')) {
      // [DISABLED] P2 gtx 自动触发已随菜单项注释关闭（产品只保留 tlang 官方自动翻译）；
      // ai: 偏好只保留"有原生轨选原生轨"的语义，不再后台触发 gtx 翻译。
      const target = TranslationService.targetLanguage();
      const nativeMatch = tracks.find((t: SubtitleTrack) => !t.isAutoTranslated
        && (t.languageCode === target || t.languageCode.startsWith(target)
          || (t.languageCode.length > 0 && target.startsWith(t.languageCode))));
      if (nativeMatch) {
        logger.info(`${TAG} auto-select native subtitle lang=${nativeMatch.languageCode} (ai preferred=${preferred}) video=${source.videoId}`);
        this._controller.switchSubtitle(nativeMatch.url);
      }
      return;
    }
    const match = tracks.find((t: SubtitleTrack) => t.languageCode === preferred)
      || tracks.find((t: SubtitleTrack) => t.languageCode.startsWith(preferred))
      || tracks.find((t: SubtitleTrack) => preferred.startsWith(t.languageCode));
    if (match) {
      logger.info(`${TAG} auto-select subtitle lang=${match.languageCode} (preferred=${preferred}) video=${source.videoId}`);
      this._controller.switchSubtitle(match.url);
    }
  }

  private formatStatCount(count: number | undefined): string {
    if (count === undefined || count === null || count < 0) {
      return '0';
    }
    return count.toLocaleString();
  }

  /** Live quality: background-parse HLS master variants and merge them into
   * the controller quality list. Fire-and-forget; playback never waits. */
  private fetchLiveVariantsInBackground(playService: YouTubePlayService, videoInfo: VideoInfo): void {
    const videoId = videoInfo.videoId;
    const startedAt = Date.now();
    playService.fetchLiveHlsVariants(videoInfo).then((variants) => {
      if (variants.length === 0 || this._currentVideo?.videoId !== videoId) {
        return;
      }
      logger.info(`${TAG} live HLS variants ready video=${videoId} count=${variants.length} elapsed=${Date.now() - startedAt}ms`);
      this._controller.addLiveHlsVariants(variants);
    }).catch((e: Error) => {
      logger.warn(`${TAG} live HLS variants failed video=${videoId}: ${e.message || e}`);
    });
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
      logger.info(`${TAG} playback extras done video=${videoId} elapsed=${Date.now() - startedAt}ms like=${extras.likeCount ?? -1} dislike=${extras.dislikeCount ?? -1} related=${extras.relatedItems?.length || 0} chapters=${extras.chapters?.length || 0}`);

      const likeText = (extras.likeCount !== undefined && extras.likeCount >= 0)
        ? this.formatStatCount(extras.likeCount)
        : '';
      const dislikeText = (extras.dislikeCount !== undefined && extras.dislikeCount >= 0)
        ? this.formatStatCount(extras.dislikeCount)
        : '';
      this._defaultSource.likeCount = likeText.length > 0 ? likeText : this._defaultSource.likeCount;
      this._defaultSource.dislikeCount = dislikeText.length > 0 ? dislikeText : (this._defaultSource.dislikeCount || '');
      if (extras.title) this._defaultSource.description = extras.title;
      if (extras.author) this._defaultSource.author = extras.author;
      if (extras.description) this._defaultSource.videoDescription = extras.description;
      if (extras.channelId) this._defaultSource.channelId = extras.channelId;
      if (extras.viewCount !== undefined && extras.viewCount >= 0) this._defaultSource.viewCount = extras.viewCount;
      if (extras.publishDate) this._defaultSource.publishDate = extras.publishDate;
      if (extras.tags && extras.tags.length > 0) this._defaultSource.tags = extras.tags;
      if (extras.chapters && extras.chapters.length > 0) {
        this._defaultSource.chapters = extras.chapters.slice();
      }

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
      this.notifyPlaybackSourceChanged(this._cachedVideoSource || this._defaultSource, 'extras-ready');

      const relatedItems = extras.relatedItems;
      if (relatedItems && relatedItems.length > 0) {
        const videoItems: VideoItem[] = relatedItems.map((r) => {
          const v = new VideoItem(
            0, r.videoId, r.title, r.author, r.viewCountText || '',
            normalizeUrl(r.thumbnailUrl || getFallbackThumbnailUrl(r.videoId)), !!r.isLive, '#CCCCCC',
            r.channelId || '', '', '', '', null
          );
          v.publishedTimeText = r.publishedTimeText || '';
          v.durationText = r.lengthSeconds && r.lengthSeconds > 0
            ? formatDurationHms(Math.max(0, r.lengthSeconds))
            : '';
          return v;
        });
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
      // 播放列表/本地队列来源：历史记录列表本身，点击回到列表而非单个视频
      const queue = PlayQueueManager.getInstance();
      if ((queue.sourceType === QueueSourceType.REMOTE || queue.sourceType === QueueSourceType.LOCAL)
        && queue.sourceId.trim().length > 0) {
        WatchHistoryStore.recordPlaylist(
          queue.sourceId,
          queue.sourceName,
          this._currentVideo?.thumbnailUrl || ''
        );
        logger.info(`${TAG} Saved playlist history: ${queue.sourceId}`);
        return;
      }
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

  /**
   * @param force explicit user exits (back key / page close button) pass true:
   *   the PiP retain guard exists only to protect passive page tear-down during
   *   system PiP restore/handoff; a deliberate exit must always tear down media,
   *   otherwise the page pops while playback continues invisibly (dangling player).
   */
  release(force: boolean = false): void {
    if (this._controller.playerState === PlayerState.RELEASED) return;
    if (this._controller.playerState === PlayerState.IDLE && !this._currentVideo && !this._preparePromise) {
      this._explicitPageCloseHandled = true;
      AppStorage.setOrCreate('playerLoading', false);
      return;
    }
    // Safety: never tear down media/queue while PiP restore/handoff owns the page.
    if (!force && this.shouldRetainMediaOnPageDisappear()) {
      logger.warn(`${TAG} release() ignored during PiP handoff/restore`);
      return;
    }
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
    this.resetSession(false, true);
    this._explicitPageCloseHandled = true;
    AppStorage.setOrCreate('playerLoading', false);
    const queue = PlayQueueManager.getInstance();
    if (queue.sourceType === QueueSourceType.ADHOC) {
      queue.clear();
    }
  }

  /** Normal navigation away from PlayerPage: close media but retain the queue. */
  closeForNavigation(): void {
    if (this.shouldRetainMediaOnPageDisappear()) {
      logger.warn(`${TAG} closeForNavigation() ignored during PiP handoff/restore`);
      return;
    }
    logger.info(`${TAG} closeForNavigation() called`);
    this.saveWatchHistory();
    this.stopWatchSaveTimer();
    this.resetSession(true, true);
    AppStorage.setOrCreate('playerLoading', false);
  }

  /**
   * 强制冷重置：把会话恢复到"应用首次播放"的干净状态。
   * 用于全新进入播放页（从列表/作者页点新视频）前，彻底清除上一次（尤其关闭 PiP）的残留状态。
   * 注意：不要在 PiP 恢复路径调用——那条必须保留存活引擎。
   */
  forceReset(): void {
    logger.info(`${TAG} forceReset() called`);
    this._explicitPageCloseHandled = false;
    this.saveWatchHistory();
    this.stopWatchSaveTimer();
    this.resetSession(false, false);
  }

  /**
   * @param preserveAudioOnly when true, keep isAudioOnlyMode and re-apply
   *   video-off on the new controller (used by play/ensureInitialized).
   *   forceReset/release always pass false.
   * @param preservePiP when true, keep the PiP ownership flags (isPiPActive /
   *   handoff / restoring). Only play() media switches inside an active PiP
   *   session pass true; every teardown path (release/closeForNavigation/
   *   forceReset) must clear them.
   */
  private resetSession(preserveAudioOnly: boolean = false, clearSurface: boolean = false, preservePiP: boolean = false): void {
    this._playGeneration++;
    // [DISABLED] P3 实时 ASR 已禁用（入口全注释，服务不可能 active；重新启用时恢复）：
    // 源切换/页面退出/冷重置都必须停掉 PCM tap（幂等）：AsrLiveCaptionService.getInstance().stop();
    const keepAudioOnly = preserveAudioOnly && this._isAudioOnlyMode;
    this._controller.closeMediaSession(clearSurface);
    this._currentVideo = null;
    this._watchVideoId = '';
    this._activePlayPromise = null;
    this._activePlayVideoId = '';
    this._preparePromise = null;
    this._prepareVideoId = '';
    this._prepareGeneration = -1;
    this._prepareAttemptId = '';
    if (this._queuePrefetchTimerId >= 0) {
      clearTimeout(this._queuePrefetchTimerId);
      this._queuePrefetchTimerId = -1;
    }
    this._submittedVideoId = '';
    this._lastAutoAdvanceFromVideoId = '';
    this._failureRetryCount = 0;
    this._failureRetryInFlight = false;
    this._failureRetryVideoId = '';
    this._forceRefreshNextPrepare = false;
    this._cachedVideoSource = null;
    this._lastPlayError = null;
    this._activeExtrasVideoId = '';
    this._cachedChannelProfiles.clear();
    if (!preservePiP) {
      // 清 PiP 标志与占位层，避免 reset 后残留「画中画运行中」或误判 isPiPActive。
      this._pipHandoffPending = false;
      this._pipRestoring = false;
      this._isPiPActive = false;
      AppStorage.setOrCreate('isPipHandoffPending', false);
      AppStorage.setOrCreate('isPipRestoring', false);
      AppStorage.setOrCreate('isPiPActive', false);
      AppStorage.setOrCreate('showPipPlaceholder', false);
    }
    if (!keepAudioOnly) {
      this.clearAudioOnlyMode();
    }
    this._defaultSource = this.createDefaultSource();
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

  private createDefaultSource(): VideoData {
    return {
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
  }

  /** Hard-release recovery only; ordinary media changes retain the controller and MPV. */
  private recreateReleasedController(preserveAudioOnly: boolean): void {
    this._playGeneration++;
    const keepAudioOnly = preserveAudioOnly && this._isAudioOnlyMode;
    this._defaultSource = this.createDefaultSource();
    this._controller = new AvPlayerController(this._defaultSource);
    this.bindControllerQueueControls();
    this.bindQueueSwitchHandler();
    this.registerContinueStateListener();
    if (keepAudioOnly) {
      AppStorage.setOrCreate('isAudioOnlyMode', true);
      this._controller.setVideoOutputEnabled(false);
    }
    logger.info(`${TAG} hard-released controller recreated audioOnly=${keepAudioOnly}`);
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
