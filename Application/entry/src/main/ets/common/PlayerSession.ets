/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AppLog } from './AppLog';
import { common } from '@kit.AbilityKit';
import { AvPlayerController, VideoData, LocalMediaProxy, PlayerState } from 'mediaservice';
import { VideoInfo, VideoItem } from 'youtube_core';
import { PlaybackConfig } from './PlaybackConfig';
import { PipWindowController, PipPlayerDelegate } from '../features/player/PipWindowController';
import { YouTubePlayService } from '../features/player/YouTubePlayService';
import { PlayQueueManager } from '../features/player/PlayQueueManager';
import { WatchHistoryStore } from './WatchHistoryStore';
import { normalizeUrl } from '../features/home/utils/ThumbnailUtils';
import { YOUTUBE_VIDEO_ID } from './Constants';

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

class SessionPipDelegate implements PipPlayerDelegate {
  private controller: AvPlayerController;
  private session: PlayerSession;

  constructor(controller: AvPlayerController, session: PlayerSession) {
    this.controller = controller;
    this.session = session;
  }

  syncPlay(): void { this.controller.syncPlay(); }
  syncPause(): void { this.controller.syncPause(); }
  playNext(): void { this.session.playNextFromQueue(); }
  playPrevious(): void { this.session.playPreviousFromQueue(); }
  canPlayNext(): boolean { return this.session.canPlayNextFromQueue(); }
  canPlayPrevious(): boolean { return this.session.canPlayPreviousFromQueue(); }
  get isPlaying(): boolean { return this.controller.isPlaying; }
}

/**
 * 全局播放会话 —— 单例持有 AvPlayerController 与 PipWindowController。
 *
 * 状态驱动的松耦合设计：
 *   - PlayerState 是播放器生命周期的唯一权威。
 *   - 各子系统通过订阅 StateChangeListener 独立响应状态变更，
 *     不再由 PlayerSession 手动编排操作顺序。
 *   - 不再使用 _isReleased / isRestoringFromPip 等散落标志。
 */
export class PlayerSession {
  private static instance: PlayerSession | null = null;

  private _controller: AvPlayerController;
  private _pipController?: PipWindowController;
  private _xComponentController?: XComponentController;
  private _currentVideo: VideoItem | null = null;
  private _defaultSource: VideoData;
  private _context: common.UIAbilityContext;
  private _watchSaveTimerId: number = -1;
  private _watchVideoId: string = '';
  private _activePlayPromise: Promise<VideoData | null> | null = null;
  private _activePlayVideoId: string = '';

  private _cachedVideoSource: VideoData | null = null;
  private _lastPlayError: string | Resource | null = null;
  private _cachedChannelProfiles: Map<string, CachedChannelProfile> = new Map();
  private _activeExtrasVideoId: string = '';
  private _pipListenersBound: boolean = false;
  private _pendingResumeSec: number = -1;
  private _pendingAutoPlay: boolean | null = null;

  /** PIP 恢复时由外部（Index.ets）设置的回调 */
  onPipRestore?: () => void;
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
    LocalMediaProxy.initCache(this._context);
    logger.debug(`${TAG} PlayerSession created`);
  }

  get controller(): AvPlayerController {
    return this._controller;
  }

  get pipController(): PipWindowController | undefined {
    return this._pipController;
  }

  invalidatePipController(): void {
    this._pipController?.destroyPipController();
    this._pipController = undefined;
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

  get isRestoringFromPip(): boolean {
    return this._controller.playerState === PlayerState.PIP_RESTORING;
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

  get lastPlayError(): string | Resource | null {
    return this._lastPlayError;
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

  // ──── Surface 绑定 ────

  async attachSurface(xComponentController: XComponentController): Promise<void> {
    if (this._controller.playerState === PlayerState.RELEASED) {
      logger.warn(`${TAG} attachSurface called after release, reinitializing`);
      this.resetSession();
    }

    this._xComponentController = xComponentController;

    await this._controller.initAVPlayer();

    if (!this._pipController) {
      this.setupPipController(xComponentController);
    } else {
      this._pipController.updateXComponentController(xComponentController);
    }
  }

  detachSurface(): void {
    const state = this._controller.playerState;
    if (state === PlayerState.PIP_ACTIVE || state === PlayerState.PIP_ENTERING) {
      logger.debug(`${TAG} surface detach ignored while PiP active`);
      return;
    }
    this._xComponentController = undefined;
    logger.debug(`${TAG} surface detached`);
  }

  private async setupPipController(xComponentController: XComponentController): Promise<void> {
    this._pipController = new PipWindowController(xComponentController);
    const delegate = new SessionPipDelegate(this._controller, this);
    const pipW = this._defaultSource.width || 0;
    const pipH = this._defaultSource.height || 0;
    await this._pipController.createPipController(delegate, pipW, pipH);

    if (!this._pipListenersBound) {
      this._pipListenersBound = true;
      // READY 后启用 PiP autoStart
      this._controller.addIsReadyListener((ready: boolean) => {
        if (ready && this._pipController) {
          const pbCfg = AppStorage.get('playbackConfig') as Record<string, Object> | undefined;
          const enablePip = (pbCfg?.enablePip as boolean) ?? true;
          this._pipController.updateAutoStart(enablePip);
        }
        this._pipController?.syncQueueControlEnabled();
      });

      // 播放状态变更时同步 PiP 面板的播放/暂停状态
      this._controller.addIsPlayingListener((_isPlaying: boolean) => {
        this._pipController?.syncPipPlayState();
      });
    }

    this._pipController.onPipStop = () => {
      if (this._controller.playerState === PlayerState.PIP_RESTORING) {
        logger.info(`${TAG} onPipStop ignored: PIP_RESTORING in progress`);
        return;
      }
      const isAppBackground = AppStorage.get<boolean>('isAppBackground') ?? false;
      if (isAppBackground) {
        logger.info(`${TAG} onPipStop while background → pausing only`);
        this._controller.syncPause();
      } else {
        logger.info(`${TAG} onPipStop while foreground → releasing session`);
        this.onSessionReleased?.();
        this.release();
      }
    };

    this._pipController.onPipRestore = () => {
      logger.info(`${TAG} onPipRestore triggered`);
      this.onPipRestore?.();
    };
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

    const pbCfg = PlaybackConfig.loadFromPreferences();
    LocalMediaProxy.applyCacheConfig(parseInt(pbCfg.cacheDiskSize), parseInt(pbCfg.cacheMaxAge));

    const videoId = video.videoId || YOUTUBE_VIDEO_ID;

    if (this._currentVideo?.videoId === video.videoId && this._controller.isReady) {
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

        if (videoStream && videoStream.width && videoStream.height) {
          this._pipController?.updatePipContentSize(videoStream.width, videoStream.height);
        }

        this.startWatchSaveTimer();
        return videoSource;
      } else {
        logger.error(`${TAG} play() failed: ${result.error}`);
        this._lastPlayError = result.error ?? null;
        return null;
      }
    } catch (e) {
      logger.error(`${TAG} play() exception: ${e}`);
      this._lastPlayError = (e as Error).message || null;
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

  async enterPip(): Promise<boolean> {
    if (!this._xComponentController) {
      logger.warn(`${TAG} enterPip: XComponentController not ready`);
      return false;
    }

    try {
      if (this._controller.playerState !== PlayerState.PIP_ACTIVE &&
        this._controller.playerState !== PlayerState.PIP_ENTERING) {
        if (this._pipController) {
          this._pipController.destroyPipController();
          this._pipController = undefined;
        }
        await this.setupPipController(this._xComponentController);
        logger.info(`${TAG} PiP controller refreshed before enter`);
      }
    } catch (e) {
      logger.warn(`${TAG} refresh PiP controller before enter failed: ${e}`);
    }

    if (!this._pipController?.pipController) {
      logger.warn(`${TAG} enterPip: pipController not ready`);
      return false;
    }
    if (!this._controller.isReady) {
      logger.warn(`${TAG} enterPip: player not ready, skipping`);
      return false;
    }
    try {
      const systemEnabled = await this._pipController.pipController.getPiPSettingSwitch();
      if (!systemEnabled) {
        logger.info(`${TAG} enterPip skipped: system PiP setting is disabled`);
        return false;
      }
    } catch (_e) {
    }
    // 通过状态机声明意图
    if (!this._controller.getPlayerStateMachine().transition(PlayerState.PIP_ENTERING)) {
      logger.warn(`${TAG} enterPip: cannot transition to PIP_ENTERING from ${this._controller.playerState}`);
      return false;
    }
    try {
      await this._pipController.pipController.startPiP();
      this._controller.getPlayerStateMachine().transition(PlayerState.PIP_ACTIVE);
      logger.info(`${TAG} enterPip succeeded`);
      return true;
    } catch (e) {
      logger.error(`${TAG} enterPip failed: ${e}`);
      this._controller.getPlayerStateMachine().transition(PlayerState.PLAYING);
      return false;
    }
  }

  async exitPip(): Promise<void> {
    if (!this._pipController) return;
    try {
      await this._pipController.stopPiP();
      logger.info(`${TAG} exitPip succeeded`);
    } catch (e) {
      logger.error(`${TAG} exitPip failed: ${e}`);
    }
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
    try {
      const progressSec = this._controller.currentTime;
      const durationSec = this._controller.durationTime;
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
    this.saveWatchHistory();
    this.stopWatchSaveTimer();

    this._controller.releaseVideo(0);
    this._pipController?.destroyPipController();
    this._pipController = undefined;
    this._xComponentController = undefined;
  }

  async recreatePipControllerIfNeeded(): Promise<void> {
    if (!this._xComponentController || !this.isSessionActive()) return;
    if (this._pipController) {
      this._pipController.destroyPipController();
      this._pipController = undefined;
    }
    await this.setupPipController(this._xComponentController);
    logger.info(`${TAG} PiP controller recreated after restore`);
  }

  private resetSession(): void {
    this._controller.releaseVideo(0);

    this._pipController = undefined;
    this._xComponentController = undefined;
    this._currentVideo = null;
    this._watchVideoId = '';
    this._activePlayPromise = null;
    this._activePlayVideoId = '';
    this._cachedVideoSource = null;
    this._cachedChannelProfiles.clear();
    this._pipListenersBound = false;
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
    logger.debug(`${TAG} Session reset`);
  }
}
