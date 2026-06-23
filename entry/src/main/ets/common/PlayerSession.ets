import { AppLog } from './AppLog';
import { AbilityConstant, common } from '@kit.AbilityKit';
import { AvPlayerController, VideoData, PlayerState, StateChangeListener } from 'mediaservice';
import { VideoInfo, VideoItem } from 'youtube_core';
import { YouTubePlayService } from '../features/player/YouTubePlayService';
import { PlayQueueManager } from '../features/player/PlayQueueManager';
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

function getFallbackThumbnailUrl(videoId: string): string {
  return videoId ? `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg` : '';
}

export class PlayerSession {
  private static instance: PlayerSession | null = null;

  private _controller: AvPlayerController;
  private _currentVideo: VideoItem | null = null;
  private _defaultSource: VideoData;
  private _context: common.UIAbilityContext;
  private _watchSaveTimerId: number = -1;
  private _watchVideoId: string = '';
  private _activePlayPromise: Promise<VideoData | null> | null = null;
  private _activePlayVideoId: string = '';

  private _cachedVideoSource: VideoData | null = null;
  private _lastPlayError: ErrorInfo | null = null;
  private _cachedChannelProfiles: Map<string, CachedChannelProfile> = new Map();
  private _activeExtrasVideoId: string = '';
  private _pendingResumeSec: number = -1;
  private _pendingAutoPlay: boolean | null = null;
  /** 画中画是否激活（由 PiPManager.onStateChange 设置） */
  private _isPiPActive: boolean = false;
  /** release() 时调用，用于停止 PiP（避免循环 import，由 PiPManager 注入） */
  onStopPiP: (() => Promise<void>) | null = null;

  /** PlayerSession 被 release 销毁时由外部（Index.ets）设置的回调，用于清理 NavStack */
  onSessionReleased?: () => void;

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
      this.resetSession();
    }
    await this._controller.initAVPlayer();
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
      this.resetSession();
    }

    const videoId = video.videoId || YOUTUBE_VIDEO_ID;

    if (this._currentVideo?.videoId === video.videoId && this._controller.vm.isReady) {
      logger.info(`${TAG} play() skipped: same video ${videoId} already ready`);
      return this._defaultSource;
    }

    if (this._activePlayVideoId === videoId && this._activePlayPromise) {
      logger.info(`${TAG} play() dedup: same video ${videoId} already extracting, returning existing promise`);
      return this._activePlayPromise;
    }

    this._currentVideo = video;
    this._activePlayVideoId = videoId;
    logger.info(`${TAG} play() called for ${videoId}`);

    const promise = this.doPlay(video, videoId);
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

  private async doPlay(video: VideoItem, videoId: string): Promise<VideoData | null> {
    try {
      const playService = YouTubePlayService.getInstance(this._context);
      const result = await playService.play(videoId);

      if (this._currentVideo?.videoId !== videoId) {
        logger.info(`${TAG} doPlay() result discarded: video changed during extraction`);
        return null;
      }

      if (result.success && result.videoInfo) {
        const videoStream = result.videoInfo.streams?.find((s) => s.hasVideo && s.width && s.height);
        if (this._currentVideo) {
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
        this._controller.updateVideoSource(videoSource);
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

  private fetchPlaybackExtrasInBackground(playService: YouTubePlayService, videoInfo: VideoInfo): void {
    const videoId = videoInfo.videoId;
    this._activeExtrasVideoId = videoId;
    const startedAt = Date.now();
    logger.info(`${TAG} playback extras start video=${videoId}`);
    playService.fetchPlaybackExtrasFor(videoInfo).then((extras) => {
      if (!extras || this._currentVideo?.videoId !== videoId || this._activeExtrasVideoId !== videoId) {
        return;
      }
      logger.info(`${TAG} playback extras done video=${videoId} elapsed=${Date.now() - startedAt}ms like=${extras.likeCount ?? -1} related=${extras.relatedItems?.length || 0}`);

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
    this.saveWatchHistory();
    this.stopWatchSaveTimer();
    this._controller.releaseVideo(0);
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
    this.resetSession();
  }

  private resetSession(): void {
    this._controller.releaseVideo(0);
    this._currentVideo = null;
    this._watchVideoId = '';
    this._activePlayPromise = null;
    this._activePlayVideoId = '';
    this._cachedVideoSource = null;
    this._cachedChannelProfiles.clear();
    // 清 PiP 激活状态：避免会话在 PiP 激活时被 reset 后，_isPiPActive / AppStorage.isPiPActive
    // 残留为 true，导致占位层显示残留或返回键误判已在 PiP。
    this.setPiPActive(false);
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
