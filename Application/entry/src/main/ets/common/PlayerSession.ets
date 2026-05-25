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
import { AvPlayerController, VideoData, LocalMediaProxy } from 'mediaservice';
import { VideoItem } from 'youtube_core';
import { PlaybackConfig } from './PlaybackConfig';
import { PipWindowController, PipPlayerDelegate } from '../features/player/PipWindowController';
import { YouTubePlayService } from '../features/player/YouTubePlayService';
import { WatchHistoryStore } from './WatchHistoryStore';
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

/**
 * PiP 委托适配器 —— 将 AvPlayerController 桥接到 PipWindowController
 */
class SessionPipDelegate implements PipPlayerDelegate {
  private controller: AvPlayerController;

  constructor(controller: AvPlayerController) {
    this.controller = controller;
  }

  syncPlay(): void { this.controller.syncPlay(); }
  syncPause(): void { this.controller.syncPause(); }
  get isPlaying(): boolean { return this.controller.isPlaying; }
}

/**
 * 全局播放会话 —— 单例持有 AvPlayerController 与 PipWindowController。
 *
 * 设计目标：
 *   1. 播放器实例全局唯一，PlayerPage 只是 surface 挂载点。
 *   2. 按返回键退出播放页不结束播放，PIP 继续。
 *   3. 任何页面点击新视频都能直接切源，PIP 无缝衔接。
 *   4. PIP 恢复时自动确保 PlayerPage 回到栈顶。
 */
export class PlayerSession {
  private static instance: PlayerSession | null = null;

  /** 唯一 AvPlayerController */
  private _controller: AvPlayerController;
  /** 唯一 PipWindowController（懒加载，首次 attachSurface 时创建） */
  private _pipController?: PipWindowController;
  /** 当前绑定的 XComponentController */
  private _xComponentController?: XComponentController;
  /** 当前播放视频 */
  private _currentVideo: VideoItem | null = null;
  /** 默认空视频源，用于构造 AvPlayerController */
  private _defaultSource: VideoData;
  /** 是否已释放 */
  private _isReleased: boolean = false;
  /** UIAbilityContext */
  private _context: common.UIAbilityContext;
  /** 10 秒定时保存历史进度的 Timer ID */
  private _watchSaveTimerId: number = -1;
  /** 当前 videoId，用于历史记录 */
  private _watchVideoId: string = '';
  /** 当前正在进行的 play() Promise，用于防抖去重 */
  private _activePlayPromise: Promise<VideoData | null> | null = null;
  /** 当前正在进行提取的 videoId */
  private _activePlayVideoId: string = '';

  /** 缓存上次成功加载的 VideoData，供 PiP 恢复时跳过网络请求 */
  private _cachedVideoSource: VideoData | null = null;
  /** 最近一次提取失败的错误信息 */
  private _lastPlayError: string | Resource | null = null;
  /** 缓存频道信息（按 channelId），避免页面重建时重复请求 */
  private _cachedChannelProfiles: Map<string, CachedChannelProfile> = new Map();
  /** isReady listener 引用，用于在 resetSession 时移除 */
  private _isReadyListenerForPip: ((ready: boolean) => void) | null = null;

  /** PIP 恢复时由外部（Index.ets）设置的回调 */
  onPipRestore?: () => void;
  /** 标记当前是否正在从 PiP 恢复到全屏，防止恢复期间触发不必要的 play/reset */
  isRestoringFromPip: boolean = false;

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
    LocalMediaProxy.initCache(this._context);
    logger.debug(`${TAG} PlayerSession created`);
  }

  /** 外部只读访问控制器 */
  get controller(): AvPlayerController {
    return this._controller;
  }

  /** 外部只读访问 PIP 控制器 */
  get pipController(): PipWindowController | undefined {
    return this._pipController;
  }

  /** 销毁当前 PiP controller，下次 attachSurface 时会用新 XComponent 重建 */
  invalidatePipController(): void {
    this._pipController?.destroyPipController();
    this._pipController = undefined;
  }

  /** 当前播放的视频 */
  get currentVideo(): VideoItem | null {
    return this._currentVideo;
  }

  /** 当前视频源（用于同步 PlayerPage 的 videoSource） */
  get currentVideoSource(): VideoData {
    return this._defaultSource;
  }

  /** 是否已释放 */
  get isReleased(): boolean {
    return this._isReleased;
  }

  /** 缓存的 VideoData，PiP 恢复时供 PlayerPage 直接使用 */
  get cachedVideoSource(): VideoData | null {
    return this._cachedVideoSource;
  }

  set cachedVideoSource(source: VideoData | null) {
    this._cachedVideoSource = source;
  }

  /** 最近一次提取失败的错误（string 或 Resource） */
  get lastPlayError(): string | Resource | null {
    return this._lastPlayError;
  }

  /** 缓存频道信息 */
  getCachedChannelProfile(channelId: string): CachedChannelProfile | undefined {
    return this._cachedChannelProfiles.get(channelId);
  }

  setCachedChannelProfile(channelId: string, profile: CachedChannelProfile): void {
    this._cachedChannelProfiles.set(channelId, profile);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Surface 绑定（由 AVPlayer 的 aboutToAppear / aboutToDisappear 调用）
  // ─────────────────────────────────────────────────────────────────────────

  /**
   * 页面进入时注册 XComponent。
   * 首次注册时顺带初始化 AVPlayer 引擎并创建 PipWindowController。
   */
  async attachSurface(xComponentController: XComponentController): Promise<void> {
    if (this._isReleased) {
      logger.warn(`${TAG} attachSurface called after release, reinitializing`);
      this.resetSession();
    }

    this._xComponentController = xComponentController;

    // 初始化引擎（幂等）
    await this._controller.initAVPlayer();
    // 注意：setSurfaceID 由 AVPlayer 的 XComponent.onLoad 回调负责调用，
    // 不在此处立即绑定，因为 XComponent 可能尚未加载完成。

    // 懒创建 PipWindowController
    if (!this._pipController) {
      this._pipController = new PipWindowController(xComponentController);
      const delegate = new SessionPipDelegate(this._controller);
      const pipW = this._defaultSource.width || 1280;
      const pipH = this._defaultSource.height || 720;
      await this._pipController.createPipController(delegate, pipW, pipH);

      // 当播放器就绪后才启用 PiP autoStart，避免空白 PiP
      this._isReadyListenerForPip = (ready: boolean) => {
        if (ready && this._pipController) {
          const pbCfg = AppStorage.get('playbackConfig') as Record<string, Object> | undefined;
          const enablePip = (pbCfg?.enablePip as boolean) ?? true;
          this._pipController.updateAutoStart(enablePip);
        }
      };
      this._controller.addIsReadyListener(this._isReadyListenerForPip);

      this._pipController.onPipStop = () => {
        if (this.isRestoringFromPip) {
          logger.info(`${TAG} onPipStop ignored: restore in progress`);
          return;
        }
        const isAppBackground = AppStorage.get<boolean>('isAppBackground') ?? false;
        if (isAppBackground) {
          logger.info(`${TAG} onPipStop while background → pausing only`);
          this._controller.syncPause();
        } else {
          logger.info(`${TAG} onPipStop while foreground → releasing session`);
          this.release();
        }
      };

      // PIP 恢复 → 通知外部（Index）确保 PlayerPage 在栈中
      this._pipController.onPipRestore = () => {
        logger.info(`${TAG} onPipRestore triggered`);
        this.onPipRestore?.();
      };
    } else {
      // PlayerPage 重建后（如 PiP 恢复），更新 PiP 控制器持有的 XComponentController
      this._pipController.updateXComponentController(xComponentController);
    }
  }

  /**
   * 页面退出时解除当前 XComponent 绑定。
   * 不释放播放器，因为 PIP 可能还在运行。
   */
  detachSurface(): void {
    this._xComponentController = undefined;
    logger.debug(`${TAG} surface detached`);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 播放控制
  // ─────────────────────────────────────────────────────────────────────────

  /**
   * 加载并播放指定视频。
   * 任何页面调用都会让全局播放器切到新视频源。
   * 内置防抖：同一视频正在提取时返回进行中的 Promise，避免重复请求。
   */
  async play(video: VideoItem): Promise<VideoData | null> {
    if (this._isReleased) {
      this.resetSession();
    }

    // 每次播放前读取缓存配置并应用
    const pbCfg = PlaybackConfig.loadFromPreferences();
    LocalMediaProxy.applyCacheConfig(parseInt(pbCfg.cacheDiskSize), parseInt(pbCfg.cacheMaxAge));

    const videoId = video.videoId || YOUTUBE_VIDEO_ID;

    // 去重 1：同一视频且已加载过则跳过
    if (this._currentVideo?.videoId === video.videoId && this._controller.isReady) {
      logger.info(`${TAG} play() skipped: same video ${videoId} already ready`);
      return this._defaultSource;
    }

    // 去重 2：同一视频正在提取中则返回进行中的 Promise
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

      // 提取完成后若视频已切换，则丢弃本次结果，防止覆盖新视频
      if (this._currentVideo?.videoId !== videoId) {
        logger.info(`${TAG} doPlay() result discarded: video changed during extraction`);
        return null;
      }

      if (result.success && result.videoInfo) {
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
          width: result.videoInfo.streams?.[0]?.width || 1280,
          height: result.videoInfo.streams?.[0]?.height || 720,
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
        this._controller.updateVideoSource(videoSource);

        // API 12+: 切换视频后更新 PiP 窗口比例
        const videoWidth = result.videoInfo.streams?.[0]?.width || 1280;
        const videoHeight = result.videoInfo.streams?.[0]?.height || 720;
        this._pipController?.updatePipContentSize(videoWidth, videoHeight);

        // 恢复历史进度
        const resumeSec: number = WatchHistoryStore.getProgress(videoId);
        if (resumeSec > 0) {
          logger.info(`${TAG} Will resume at ${resumeSec}s`);
          this._controller.setPendingStartFromSec(resumeSec);
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

  /**
   * 主动进入 PIP（用于播放页按返回键时）。
   * API 20+: 进入前检查系统设置中的 PiP 开关。
   */
  async enterPip(): Promise<boolean> {
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
      // API 20 以下设备可能不支持，忽略并继续尝试
    }
    try {
      await this._pipController.pipController.startPiP();
      logger.info(`${TAG} enterPip succeeded`);
      return true;
    } catch (e) {
      logger.error(`${TAG} enterPip failed: ${e}`);
      return false;
    }
  }

  /**
   * 主动停止 PIP。
   */
  async exitPip(): Promise<void> {
    if (!this._pipController) return;
    try {
      await this._pipController.stopPiP();
      logger.info(`${TAG} exitPip succeeded`);
    } catch (e) {
      logger.error(`${TAG} exitPip failed: ${e}`);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 历史记录
  // ─────────────────────────────────────────────────────────────────────────

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

  // ─────────────────────────────────────────────────────────────────────────
  // 生命周期
  // ─────────────────────────────────────────────────────────────────────────

  /**
   * 彻底释放整个会话。
   * 用户点击 PIP ✕ 或明确停止播放时调用。
   */
  release(): void {
    if (this._isReleased) return;
    this._isReleased = true;

    logger.info(`${TAG} release() called`);
    this.saveWatchHistory();
    this.stopWatchSaveTimer();

    this._controller.releaseVideo(0);
    this._pipController?.destroyPipController();
    this._pipController = undefined;
    this._xComponentController = undefined;
  }

  /**
   * PiP 恢复完成后重建 PiP controller，使后续 PiP 操作正常。
   * 恢复后旧的 pipController 处于 STOPPED 状态，底层资源已释放，
   * 必须 destroy 后重新创建才能再次进入 PiP。
   */
  async recreatePipControllerIfNeeded(): Promise<void> {
    if (!this._xComponentController || this._isReleased) return;
    if (this._pipController) {
      this._pipController.destroyPipController();
      this._pipController = undefined;
    }
    this._pipController = new PipWindowController(this._xComponentController);
    const delegate = new SessionPipDelegate(this._controller);
    const pipW = this._defaultSource.width || 1280;
    const pipH = this._defaultSource.height || 720;
    await this._pipController.createPipController(delegate, pipW, pipH);
    this._pipController.onPipStop = () => {
      if (this.isRestoringFromPip) {
        logger.info(`${TAG} onPipStop ignored: restore in progress`);
        return;
      }
      const isAppBackground = AppStorage.get<boolean>('isAppBackground') ?? false;
      if (isAppBackground) {
        logger.info(`${TAG} onPipStop while background → pausing only`);
        this._controller.syncPause();
      } else {
        logger.info(`${TAG} onPipStop while foreground → releasing session`);
        this.release();
      }
    };
    this._pipController.onPipRestore = () => {
      logger.info(`${TAG} onPipRestore triggered`);
      this.onPipRestore?.();
    };
    logger.info(`${TAG} PiP controller recreated after restore`);
  }

  /**
   * 重置会话（释放后重新初始化）。
   */
  private resetSession(): void {
    if (this._isReadyListenerForPip) {
      this._controller.removeIsReadyListener(this._isReadyListenerForPip);
      this._isReadyListenerForPip = null;
    }
    this._controller.releaseVideo(0);

    this._isReleased = false;
    this._pipController = undefined;
    this._xComponentController = undefined;
    this._currentVideo = null;
    this._watchVideoId = '';
    this._activePlayPromise = null;
    this._activePlayVideoId = '';
    this._cachedVideoSource = null;
    this._cachedChannelProfiles.clear();
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
    logger.debug(`${TAG} Session reset`);
  }
}
