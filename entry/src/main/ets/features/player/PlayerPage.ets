import { AppLog } from '../../common/AppLog';
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

import { uiObserver, window, curves } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileUri, fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { CommonConstants as Const, ChapterInfo, PlaybackState, PlayerState, VideoData } from 'mediaservice';
import { WindowUtil } from '../../common/utils/WindowUtil';
import { VideoPlayer } from './components/AVPlayer';
// 播放器错误统一由 VideoPlayer / AVPlayer 内部处理，不再使用 ErrorPage 短路
import { HttpDownloader, VideoItem } from 'youtube_core';
import { ActionHub, ActionHubEvent } from '../../common/ActionHub';
import { AvPlayerController, PlayerUiViewModel } from 'mediaservice';
import { PlayerSession } from '../../common/PlayerSession';
import { PlayerInfoPanel } from './components/PlayerInfoPanel';
import { PiPManager } from './pip/PiPManager';
import { PlaybackConfig } from '../../common/PlaybackConfig';
import { MediaThumb } from '../../common/components/MediaThumb';
import { ErrorInfo } from '../../common/model/ErrorInfo';

const logger = AppLog.getInstance('PlayerPage');

const TAG: string = '[PlayerLog][VideoPlayerPage]';

@Component
export struct VideoPlayerPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageProp('selectedVideo') @Watch('onVideoChange') video: VideoItem | null = null;
  // statusBarHeight 由 WindowUtil 在 avoidAreaChange 时实时更新（TYPE_SYSTEM / TYPE_CUTOUT max）
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  // Index Provide 的 safeAreaTop 作为兜底，避免 Storage 尚未写入时 inset 为 0
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  // 三种布局状态（全部由下方方法声明式派生，输入：@Env 窗口尺寸/二维断点 + 视频比例）：
  //   isFullLandscapeScreen → 沉浸全屏（视频 100%）：分屏，或手动全屏且朝向已 settle
  //   isWideLayout          → 宽窗口侧栏布局（左视频自适应 + 右信息固定宽）
  //   都为 false            → 竖屏/窄横屏（上视频 + 下 Tab）
  // isManualFullscreen：用户点了全屏按钮（事件驱动，唯一保留的布局 @State）。
  @State isManualFullscreen: boolean = false;
  /** 全屏/分屏/挤压铺满态下，信息面板 sheet 的可见性（入口在播放器菜单"视频信息"） */
  @State showInfoPanel: boolean = false;
  /** 仅分屏：视频默认铺满分屏窗口 */
  @StorageProp('isSplitScreen') @Watch('onSplitScreenChange') isSplitScreen: boolean = false;
  /** 悬浮窗：不沉浸、不隐藏系统栏 */
  @StorageProp('isFloatingWindow') isFloatingWindow: boolean = false;
  /** 响应式窗口尺寸（vp，API 23+）：布局派生的尺寸输入 */
  @Env(SystemProperties.WINDOW_SIZE) winSize: window.SizeInVP;
  /** 响应式系统二维断点（API 22+）：横向宽断点 + 纵向高宽比断点 */
  @Env(SystemProperties.BREAK_POINT) winBp: uiObserver.WindowSizeLayoutBreakpointInfo;
  @Consume('actionHub') actionHub: ActionHub;
  onFullScreenChange?: (isFullScreen: boolean) => void;

  @State videoSource: VideoData = {
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
  @State controller: AvPlayerController = PlayerSession.getInstance().controller;
  @State vm: PlayerUiViewModel = PlayerSession.getInstance().controller.vm;
  @State isPageShow: boolean = false;
  @State videoDescriptionError: string | null = null;
  @State errorInfo: ErrorInfo | null = null;
  @State detailLikeCount: string = '0';
  @State detailDislikeCount: string = '';
  @State detailChannelId: string = '';
  @State detailChannelAvatarUrl: string = '';
  @State chapters: ChapterInfo[] = [];
  @State isRetrying: boolean = false;
  @StorageLink('playerLoading') isLoading: boolean = false;
  /** 画中画是否激活（引擎/返回键逻辑；占位层见 showPipPlaceholder） */
  @StorageLink('isPiPActive') isPiPActive: boolean = false;
  /**
   * Only true when PiP owns the surface and page is not mid handoff/restore.
   * Prevents flash of "画中画运行中" on startPiP+pop and on restore.
   */
  @StorageLink('showPipPlaceholder') showPipPlaceholder: boolean = false;
  /** 会话级仅音频：封面 + 耳机层，禁止 PiP */
  @StorageLink('isAudioOnlyMode') @Watch('onAudioOnlyModeChange') isAudioOnlyMode: boolean = false;
  /** 播放设置（含 pipOnReturn） */
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  @StorageProp('isAppBackground') @Watch('onAppBackgroundChange') isAppBackground: boolean = false;
  private windowUtil: WindowUtil = WindowUtil.getInstance();
  private handleExitFullscreen: () => void = () => {
    this.handleFullScreenExit();
  };
  private cachedThumbnailUri: string = '';
  private pagePlaybackStateListener = (state: PlaybackState): void => {
    if (state.errorMsg) {
      this.isLoading = false;
      return;
    }
    if (this.isLoading && (state.isBuffered || (state.isReady && !state.isBuffering))) {
      this.isLoading = false;
      logger.info(`${TAG} first playable frame ready; loading cover dismissed`);
    }
  };

  private async cacheThumbnail(videoId: string, thumbnailUrl: string): Promise<void> {
    if (!videoId || !thumbnailUrl) {
      this.cachedThumbnailUri = '';
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const localPath = `${context.cacheDir}/thumb_${videoId}.jpg`;
    try {
      if (fs.accessSync(localPath)) {
        this.cachedThumbnailUri = fileUri.getUriFromPath(localPath);
        return;
      }
    } catch (e) {
      logger.debug(`${TAG} thumbnail cache skipped: ${e}`);
    }
    try {
      const downloader = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 5000,
        readTimeout: 8000,
      };
      HttpDownloader.applyProxyToOptions(options, thumbnailUrl);
      const data = await downloader.request(thumbnailUrl, options);
      downloader.destroy();
      if (data.responseCode === 200 && data.result instanceof ArrayBuffer) {
        const file = fs.openSync(localPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, data.result);
        fs.closeSync(file);
        this.cachedThumbnailUri = fileUri.getUriFromPath(localPath);
        logger.info(`${TAG} thumbnail cached: ${localPath}`);
      }
    } catch (e) {
      this.cachedThumbnailUri = '';
      logger.warn(`${TAG} cacheThumbnail failed: ${e}`);
    }
  }

  private knockShareCallback = (sharableTarget: harmonyShare.SharableTarget): void => {
    try {
      const video = PlayerSession.getInstance().currentVideo;
      if (!video || !video.videoId) {
        return;
      }
      const url = `https://www.youtube.com/watch?v=${video.videoId}`;
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.HYPERLINK,
        content: url,
        title: video.title || '',
        description: video.author || '',
        thumbnailUri: this.cachedThumbnailUri || ''
      });
      sharableTarget.share(shareData);
    } catch (err) {
      logger.error(`${TAG} knockShare failed: ${JSON.stringify(err)}`);
    }
  };

  private onAppBackgroundChange(): void {
    if (this.isAppBackground) {
      harmonyShare.off('knockShare', this.knockShareCallback);
    } else {
      harmonyShare.on('knockShare', this.knockShareCallback);
    }
  }

  /** 信息栏目标宽 = 窗口宽 × 1/3 */
  private static readonly PANEL_WIDTH_RATIO: number = 1 / 3;
  /** 信息栏宽度区间（vp）：超宽屏不膨胀、窄横屏不被挤没 */
  private static readonly PANEL_MIN_WIDTH_VP: number = 320;
  private static readonly PANEL_MAX_WIDTH_VP: number = 480;
  /** 侧栏准入的横版视频高度填充率保险值：仅挡极端方形窗口 */
  private static readonly SIDE_MIN_VIDEO_FILL: number = 0.45;

  /** 视频宽高比；尺寸未知时回退 16:9 */
  private getVideoAspect(): number {
    if (this.videoSource.width && this.videoSource.height) {
      return this.videoSource.width / this.videoSource.height;
    }
    return 16 / 9;
  }

  /** 信息栏宽度：窗口 1/3，clamp [320, 480] */
  private getInfoPanelWidthVp(): number {
    return Math.min(Math.max(this.winSize.width * VideoPlayerPage.PANEL_WIDTH_RATIO,
      VideoPlayerPage.PANEL_MIN_WIDTH_VP), VideoPlayerPage.PANEL_MAX_WIDTH_VP);
  }

  /**
   * 侧栏准入：真横屏（系统纵向断点 sm，H/W<0.8）+ 窗口宽 ≥ md（600vp）
   * + 横版视频弱填充率保险（(W−P) ≥ a·H·0.45，仅挡极端方形窗口）。
   * 类方形窗口（纵向断点 md，如双折内屏）与竖向窗口不侧栏。
   * 竖版视频高度天然用满，直接放行。
   */
  private isSideAdmission(): boolean {
    const widthBp = this.winBp.widthBreakpoint;
    if (widthBp === WidthBreakpoint.WIDTH_XS || widthBp === WidthBreakpoint.WIDTH_SM) {
      return false;
    }
    if (this.winBp.heightBreakpoint !== HeightBreakpoint.HEIGHT_SM) {
      return false;
    }
    const aspect = this.getVideoAspect();
    if (aspect < 1) {
      return true;
    }
    return (this.winSize.width - this.getInfoPanelWidthVp())
      >= aspect * this.winSize.height * VideoPlayerPage.SIDE_MIN_VIDEO_FILL;
  }

  /**
   * 挤压强制铺满（第四态）：非竖向窗口但容不下侧栏（过窄/过方）——
   * 视频像分屏一样铺满窗口，信息区不挂载，经播放器菜单"视频信息"以 sheet 打开。
   */
  private isCrampedFull(): boolean {
    if (this.winBp.heightBreakpoint === HeightBreakpoint.HEIGHT_LG) {
      return false;
    }
    return !this.isSideAdmission();
  }

  /**
   * 沉浸全屏（视频铺满）：分屏；手动全屏且窗口朝向已与视频比例 settle
   * （复刻 willRotate 等待语义）；或挤压窗口强制铺满。
   */
  private isFullLandscapeScreen(): boolean {
    if (this.isSplitScreen || this.windowUtil.isSplitScreenMode()) {
      return true;
    }
    if (this.isManualFullscreen) {
      return (this.winSize.width > this.winSize.height) === (this.getVideoAspect() >= 1);
    }
    return this.isCrampedFull();
  }

  /** 宽窗口侧栏布局：未被铺满状态接管，且满足侧栏准入。 */
  private isWideLayout(): boolean {
    if (this.isFullLandscapeScreen()) {
      return false;
    }
    return this.isSideAdmission();
  }

  /** 沉浸（顶部 inset 归零）：全屏铺满；或侧栏布局下短边<600vp 且非悬浮窗 */
  private isImmersive(): boolean {
    if (this.isFullLandscapeScreen()) {
      return true;
    }
    if (!this.isWideLayout()) {
      return false;
    }
    return Math.min(this.winSize.width, this.winSize.height) < 600 && !this.isFloatingWindow;
  }

  private getVideoHeightVp(): number {
    // 宽布局或全屏 → 撑满（build 中实际传 100%，此处兜底）
    if (this.isWideLayout() || this.isFullLandscapeScreen()) {
      return Math.max(this.winSize.width, this.winSize.height);
    }
    const shortSide = Math.min(this.winSize.width, this.winSize.height);
    const maxHeight = Math.max(this.winSize.width, this.winSize.height) * 0.45;
    // 按视频实际比例计算容器高度（比例未知时 getVideoAspect 回退 16:9）
    const rawHeight = shortSide / this.getVideoAspect();
    return Math.max(200, Math.min(maxHeight, rawHeight));
  }

  /** Non-immersive top inset under status bar / punch-hole. Immersive → 0. */
  private getTopSafeInsetVp(): number {
    if (this.isImmersive()) {
      return 0;
    }
    return Math.max(this.statusBarHeight || 0, this.safeAreaTop || 0);
  }

  /**
   * 重试加载视频信息（从获取视频详细信息和流开始）
   */
  private async retryLoadVideo(): Promise<void> {
    if (this.isRetrying || !this.video) return;
    this.isRetrying = true;
    const session = PlayerSession.getInstance();
    const audioOnly = session.isAudioOnlyMode;
    session.forceReset();
    session.setAudioOnlyMode(audioOnly);
    this.isLoading = true;
    session.beginPrepare(this.video);
    try {
      await this.onVideoChange();
    } finally {
      this.isRetrying = false;
    }
  }

  private openInBrowser(url: string): void {
    try {
      logger.info(`Opening URL in browser: ${url}`);
      const context = getContext(this) as common.UIAbilityContext;
      context.openLink(url, {
        appLinkingOnly: false
      });
    } catch (err) {
      logger.error(`Failed to open browser: ${JSON.stringify(err)}`);
    }
  }

  private syncDetailStateFromSource(source: VideoData): void {
    this.detailLikeCount = source.likeCount || '0';
    this.detailDislikeCount = source.dislikeCount || '';
    this.detailChannelId = source.channelId || this.video?.channelId || '';
    this.detailChannelAvatarUrl = this.video?.channelAvatarUrl || '';
    this.chapters = (source.chapters || []).slice();
  }

  private snapshotVideoSource(source: VideoData): VideoData {
    return {
      mediaSource: source.mediaSource,
      url: source.url,
      headers: source.headers,
      name: source.name,
      description: source.description,
      author: source.author,
      channelId: source.channelId,
      videoDescription: source.videoDescription,
      time: source.time,
      controller: source.controller,
      auto: source.auto,
      head: source.head,
      likeCount: source.likeCount,
      dislikeCount: source.dislikeCount,
      commentCount: source.commentCount,
      shareCount: source.shareCount,
      play: source.play,
      index: source.index,
      width: source.width,
      height: source.height,
      error: source.error,
      streams: source.streams ? source.streams.slice() : [],
      subtitleTracks: source.subtitleTracks ? source.subtitleTracks.slice() : [],
      chapters: source.chapters ? source.chapters.slice() : [],
      isLive: source.isLive,
      hlsUrl: source.hlsUrl,
      dashMpdUrl: source.dashMpdUrl,
      thumbnailUrl: source.thumbnailUrl,
      videoId: source.videoId,
      viewCount: source.viewCount,
      publishDate: source.publishDate,
      tags: source.tags ? source.tags.slice() : []
    };
  }

  private createPendingVideoSource(video: VideoItem): VideoData {
    return {
      name: this.videoSource.name,
      description: video.title || '',
      author: video.author || '',
      channelId: video.channelId || '',
      videoDescription: '',
      time: '00:00',
      auto: true,
      head: this.videoSource.head,
      likeCount: '0',
      dislikeCount: '',
      commentCount: '0',
      shareCount: '0',
      play: false,
      index: 0,
      streams: [],
      chapters: [],
      thumbnailUrl: video.thumbnailUrl || '',
      videoId: video.videoId,
      viewCount: 0,
      publishDate: '',
      tags: []
    };
  }

  private playbackExtrasListener = (source: VideoData): void => {
    if (!source || (this.video && source.videoId && source.videoId !== this.video.videoId)) {
      return;
    }
    // PlayerSession updates extras in place. Publish a new identity so ArkUI
    // refreshes view count/date even when the underlying source object is reused.
    this.videoSource = this.snapshotVideoSource(source);
    this.syncDetailStateFromSource(source);
  };

  async aboutToAppear(): Promise<void> {
    const session = PlayerSession.getInstance();
    this.controller = session.controller;
    this.vm = session.controller.vm;
    session.subscribePlaybackExtras(this.playbackExtrasListener);
    this.controller.subscribePlaybackState(this.pagePlaybackStateListener);

    // PiP restore: system recreates this page while media/queue must stay alive.
    // Attach to the live session first; do not treat as cold open / force re-extract.
    // Capture retain before attachRestoredMediaSession completes restore flags.
    const pipRestoreAttach = session.shouldRetainMediaOnPageDisappear();
    if (pipRestoreAttach) {
      this.attachRestoredMediaSession(session);
    } else if (session.playerState === PlayerState.IDLE && this.video) {
      this.isLoading = true;
    }

    // 进入播放页：不改朝向、不声明横向多窗；仅按当前窗口尺寸 + 是否分屏算布局
    this.isManualFullscreen = false;
    this.windowUtil.setPlayerFullscreenImmersive(false);
    this.windowUtil.setPlayerStatusBarStyle(true);
    this.windowUtil.disableLandscapeMultiWindow();
    this.windowUtil.setMainWindowOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);

    logger.info(`${TAG} entered layout full=${this.isFullLandscapeScreen()} wide=${this.isWideLayout()} split=${this.isSplitScreen}`
      + ` win=${Math.round(this.winSize.width)}x${Math.round(this.winSize.height)}`
      + ` wBp=${this.winBp.widthBreakpoint} hBp=${this.winBp.heightBreakpoint}`
      + ` aspect=${this.getVideoAspect().toFixed(2)} panel=${Math.round(this.getInfoPanelWidthVp())}`);

    // Restore path already bound videoSource above; skip extract unless missing.
    if (!pipRestoreAttach) {
      this.onVideoChange().catch((e: Error) => {
        logger.error(`${TAG} deferred onVideoChange failed: ${e.message || e}`);
        this.isLoading = false;
      });
    } else if (!this.videoSource.streams || this.videoSource.streams.length === 0) {
      this.onVideoChange().catch((e: Error) => {
        logger.error(`${TAG} restore fallback onVideoChange failed: ${e.message || e}`);
        this.isLoading = false;
      });
    }

    this.actionHub.on(ActionHubEvent.EXIT_FULLSCREEN, this.handleExitFullscreen);

    harmonyShare.on('knockShare', this.knockShareCallback);
  }

  /**
   * PiP → full page: reuse live controller + cached VideoData/queue.
   * Completes restore retain so subsequent real navigation can tear down.
   */
  private attachRestoredMediaSession(session: PlayerSession): void {
    this.controller = session.controller;
    this.vm = session.controller.vm;
    const cached = session.cachedVideoSource;
    if (cached && (!this.video || !cached.videoId || cached.videoId === this.video.videoId)) {
      this.videoSource = this.snapshotVideoSource(cached);
      this.syncDetailStateFromSource(cached);
    } else if (session.currentVideo && !this.video) {
      // System restore may rebuild page before selectedVideo AppStorage is wired;
      // keep queue identity via session current video.
      AppStorage.setOrCreate('selectedVideo', session.currentVideo);
    }
    const playbackState = this.controller.getPlaybackState();
    this.isLoading = !(playbackState.isBuffered
      || (playbackState.isReady && !playbackState.isBuffering));
    logger.info(`${TAG} PiP restore attach video=${this.video?.videoId || session.currentVideo?.videoId || cached?.videoId || '(none)'} `
      + `state=${session.playerState} streams=${this.videoSource.streams?.length ?? 0}`);
    // Defer completePageRestore one frame so concurrent old-page aboutToDisappear
    // still sees shouldRetainMediaOnPageDisappear() == true.
    setTimeout(() => {
      PiPManager.getInstance().completePageRestore();
    }, 0);
  }

  aboutToDisappear(): void {
    const session = PlayerSession.getInstance();
    session.unsubscribePlaybackExtras(this.playbackExtrasListener);
    this.controller.unsubscribePlaybackState(this.pagePlaybackStateListener);
    harmonyShare.off('knockShare', this.knockShareCallback);
    // 离开播放页：清除沉浸全屏标志，恢复主题状态栏颜色
    this.windowUtil.setPlayerFullscreenImmersive(false);
    this.windowUtil.setPlayerStatusBarStyle(false);
    this.windowUtil.disableLandscapeMultiWindow();
    this.windowUtil.setMainWindowOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    this.actionHub.off(ActionHubEvent.EXIT_FULLSCREEN, this.handleExitFullscreen);

    // 退出播放页：关闭 PiP 自动启动（避免非播放页 home 键误启），注销生命周期回调
    const pip = PiPManager.getInstance();
    pip.setAutoStart(false);
    pip.unregisterPipStateChangeListener();

    if (session.shouldRetainMediaOnPageDisappear()) {
      // Back→PiP: STARTED kept handoff pending so placeholder stayed hidden;
      // page is gone now — complete handoff while retaining media.
      if (session.isPipHandoffPending) {
        session.completePipHandoff();
      }
      logger.info(`${TAG} page disappeared for PiP handoff/restore; retaining media session`);
      return;
    }
    if (session.consumeExplicitPageCloseHandled()) {
      pip.destroy();
      logger.info(`${TAG} explicit page close already handled`);
      return;
    }
    session.closeForNavigation();
    pip.destroy();
  }

  // Guard against concurrent onVideoChange invocations (e.g. @Watch + explicit call)
  private isVideoChanging: boolean = false;
  private pendingVideoChange: boolean = false;

  private async onVideoChange(): Promise<void> {
    if (!this.video) return;
    if (this.isVideoChanging) {
      this.pendingVideoChange = true;
      logger.info(`${TAG} onVideoChange queued: already in progress`);
      return;
    }
    const session = PlayerSession.getInstance();
    this.isVideoChanging = true;
    this.controller = session.controller;
    this.vm = session.controller.vm;

    // 同视频已就绪：直接同步，使用缓存数据
    const cachedSource = session.cachedVideoSource;
    if (session.currentVideo?.videoId === this.video?.videoId
      && cachedSource?.videoId === this.video.videoId
      && (session.controller.vm.isReady || cachedSource.streams !== undefined)) {
      this.controller = session.controller;
      this.vm = session.controller.vm;
      this.videoSource = this.snapshotVideoSource(cachedSource);
      this.syncDetailStateFromSource(cachedSource);
      const playbackState = this.controller.getPlaybackState();
      this.isLoading = !(playbackState.isBuffered
        || (playbackState.isReady && !playbackState.isBuffering));
      this.isVideoChanging = false;
      return;
    }

    // 切换视频：清空旧流数据以显示加载占位图，清空元数据避免残留
    let waitForFirstFrame = false;
    try {
      const isSwitchingVideo = !!this.videoSource.videoId && this.videoSource.videoId !== this.video.videoId;
      if (isSwitchingVideo) {
        session.controller.syncPause();
      }
      this.isLoading = true;
      this.videoDescriptionError = null;
      this.errorInfo = null;
      this.detailLikeCount = '0';
      this.detailDislikeCount = '0';
      this.detailChannelId = this.video.channelId || '';
      this.detailChannelAvatarUrl = this.video.channelAvatarUrl || '';
      this.chapters = [];
      this.videoSource = this.createPendingVideoSource(this.video);
      const existingPip = PiPManager.getInstance();
      if (existingPip.isReady && !session.isPiPActive) {
        existingPip.destroy();
      }
      const newVideoSource = await session.play(this.video);

      this.controller = session.controller;
      this.vm = session.controller.vm;

      if (newVideoSource) {
        waitForFirstFrame = true;
        this.videoSource = this.snapshotVideoSource(newVideoSource);
        session.cachedVideoSource = newVideoSource;
        this.syncDetailStateFromSource(newVideoSource);
        this.cacheThumbnail(this.video.videoId, this.video.thumbnailUrl);
        if (this.controller.getPlaybackState().isBuffered || (this.vm.isReady && !this.vm.isBuffering)) {
          this.isLoading = false;
        }
        // 画中画：首次播放时创建 PiPController，切视频时更新 contentSize（调整 PiP 窗口比例）
        const pip = PiPManager.getInstance();
        if (pip.isPiPSupported()) {
          const vw = newVideoSource.width || 16;
          const vh = newVideoSource.height || 9;
          if (pip.isReady) {
            pip.updateContentSize(vw, vh);
          } else {
            const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
            pip.init(ctx, vw, vh).then((ok: boolean) => {
              if (ok) {
                logger.info(`${TAG} PiPController created for ${newVideoSource.videoId}`);
              }
            }).catch((e: Error) => {
              logger.warn(`${TAG} PiPController init failed: ${e.message}`);
            });
          }
        }
      } else {
        const err = session.lastPlayError;
        if (err === null) {
          this.videoDescriptionError = getContext().resourceManager.getStringSync(
            $r('app.string.yt_error_playback_failed').id);
          this.errorInfo = null;
        } else {
          this.errorInfo = err;
          this.videoDescriptionError = null;
        }
      }
    } catch (e) {
      logger.error(`${TAG} onVideoChange exception: ${e}`);
      this.videoDescriptionError = getContext().resourceManager.getStringSync(
        $r('app.string.yt_error_playback_failed').id);
    } finally {
      if (!waitForFirstFrame) {
        this.isLoading = false;
      }
      this.isVideoChanging = false;
      if (this.pendingVideoChange) {
        this.pendingVideoChange = false;
        setTimeout(() => this.onVideoChange(), 0);
      }
    }
  }

  onPageHide(): void {
    this.isPageShow = false;
    // onPageHide also fires when the ability goes to background. Do not disable
    // auto-start here or the Home gesture races against its own PiP request.
    // aboutToDisappear handles real navigation away from the player page.
  }

  onPageShow(): void {
    this.isPageShow = true;
    this.syncPiPAutoStart();

    const session = PlayerSession.getInstance();
    // Restore may land here before aboutToAppear fully binds; never cold-reload
    // while PiP restore retain is active (would re-extract and thrash queue).
    if (session.shouldRetainMediaOnPageDisappear()) {
      this.controller = session.controller;
      this.vm = session.controller.vm;
      if (session.cachedVideoSource && (!this.videoSource.streams || this.videoSource.streams.length === 0)) {
        this.attachRestoredMediaSession(session);
      } else {
        PiPManager.getInstance().completePageRestore();
      }
      return;
    }
    if ((session.isReleased || session.playerState === PlayerState.IDLE) && this.video) {
      this.isLoading = true;
      logger.info(`${TAG} Media session is closed while hidden, reloading video`);
      this.onVideoChange();
    }
  }

  private onAudioOnlyModeChange(): void {
    this.syncPiPAutoStart();
  }

  /** pipOnReturn + 页可见 + 非仅音频 → 允许 Home 自动 PiP */
  private syncPiPAutoStart(): void {
    const pip = PiPManager.getInstance();
    if (this.isPageShow
      && pip.isPiPSupported()
      && this.playbackConfig.pipOnReturn
      && !this.isAudioOnlyMode) {
      pip.setAutoStart(true);
    } else {
      pip.setAutoStart(false);
    }
  }

  private lastPublishedFullscreen: boolean = false;

  /**
   * 推送"手动全屏生效中"给宿主（Index 返回键判定：true → 返回=退出全屏；
   * 分屏/挤压铺满不发布，返回直接离开播放页）。值变化才发；
   * 根节点 onAreaChange 与各副作用路径都会调用，覆盖旋转 settle 等窗口驱动变化。
   */
  private publishFullscreenState(): void {
    const active = this.isManualFullscreen && this.isFullLandscapeScreen();
    if (active === this.lastPublishedFullscreen) {
      return;
    }
    this.lastPublishedFullscreen = active;
    if (this.onFullScreenChange) {
      this.onFullScreenChange(active);
    }
  }

  private onSplitScreenChange(): void {
    // 分屏状态是布局派生输入之一（isFullLandscapeScreen getter），此处只需同步副作用
    this.syncFullscreenSideEffects();
  }

  /** 全屏副作用收口：系统栏沉浸标志 + 通知宿主；仅随手动全屏/分屏状态变化调用 */
  private syncFullscreenSideEffects(): void {
    this.windowUtil.setPlayerFullscreenImmersive(
      this.isManualFullscreen || this.isSplitScreen || this.windowUtil.isSplitScreenMode());
    this.publishFullscreenState();
  }

  /** HDS 非线性动效：弹簧曲线驱动全屏进出布局收放（时长由弹簧物理参数决定，无需 duration） */
  private animateFullscreenLayout(change: () => void): void {
    this.getUIContext().animateTo({ curve: curves.springMotion() }, change);
  }

  private enterImmersiveFullscreen(): void {
    // 分屏已铺满，不锁朝向
    if (this.isSplitScreen || this.windowUtil.isSplitScreenMode()) {
      this.isManualFullscreen = false;
      this.syncFullscreenSideEffects();
      return;
    }

    // 仅用户主动全屏：按视频比例锁朝向（默认打开路径不会走到这里）
    const isLandscapeVideo = this.getVideoAspect() >= 1;
    const targetOrientation = isLandscapeVideo
      ? window.Orientation.LANDSCAPE
      : window.Orientation.PORTRAIT;

    // animateTo 帧内：视频区收放 + InfoPanel 转场联动；需旋转时 settle 前布局不变、不触发本动画
    this.animateFullscreenLayout(() => {
      this.isManualFullscreen = true;
    });
    this.windowUtil.setPlayerFullscreenImmersive(true);
    this.windowUtil.enableLandscapeMultiWindow();
    this.windowUtil.setMainWindowOrientation(targetOrientation, undefined, () => {
      // 锁向失败（如 TV/车机 ROM 不支持）：回滚全屏状态，避免卡在竖屏"全屏"小窗
      logger.warn(`${TAG} orientation lock failed; rolling back manual fullscreen`);
      this.isManualFullscreen = false;
      this.windowUtil.disableLandscapeMultiWindow();
      this.windowUtil.setPlayerFullscreenImmersive(false);
      this.publishFullscreenState();
    });
    // 布局由 getter 派生：窗口朝向 settle 后自动铺满，此处只需通知宿主
    this.publishFullscreenState();
  }

  handleFullScreenExit(): void {
    this.animateFullscreenLayout(() => {
      this.isManualFullscreen = false;
    });
    this.windowUtil.disableLandscapeMultiWindow();
    this.windowUtil.setMainWindowOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    this.syncFullscreenSideEffects();
  }

  @Builder
  VideoPlaceholder() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.video) {
        MediaThumb({
          imageUrl: this.video.thumbnailUrl || '',
          placeholderColor: this.video.thumbnailColor || '#000000',
          thumbId: 'thumb_' + this.video.id,
          fillParent: true,
          borderRadiusVp: 0
        })
          .brightness(0.4)
      } else {
        Rect()
          .width('100%')
          .height('100%')
          .fill(Color.Black)
      }

      if (this.errorInfo) {
        Column({ space: 16 }) {
          SymbolGlyph(this.errorInfo.getIcon())
            .fontSize(40)
            .fontColor([Color.White])

          Text(this.errorInfo.message)
            .fontColor('#CCFFFFFF')
            .fontSize(14)
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .padding({ left: 24, right: 24 })

          if (this.errorInfo.actionHint) {
            Text(this.errorInfo.actionHint)
              .fontColor('#99FFFFFF')
              .fontSize(12)
              .textAlign(TextAlign.Center)
              .maxLines(2)
              .padding({ left: 24, right: 24 })
          }

          Row({ space: 12 }) {
            if (this.errorInfo.isRetryable) {
              Button() {
                Row({ space: 6 }) {
                  SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                    .fontSize(16)
                    .fontColor([Color.White])
                  Text($r('app.string.yt_action_retry'))
                    .fontSize(14)
                    .fontColor(Color.White)
                }
              }
              .height(36)
              .padding({ left: 20, right: 20 })
              .backgroundColor(this.themePrimary)
              .borderRadius(18)
              .onClick(() => { this.retryLoadVideo(); })
            }

            if (this.errorInfo.openInBrowserUrl) {
              Button() {
                Row({ space: 6 }) {
                  SymbolGlyph($r('sys.symbol.arrow_up_right'))
                    .fontSize(16)
                    .fontColor([Color.White])
                  Text($r('app.string.yt_action_open_browser'))
                    .fontSize(14)
                    .fontColor(Color.White)
                }
              }
              .height(36)
              .padding({ left: 20, right: 20 })
              .backgroundColor('#666666')
              .borderRadius(18)
              .onClick(() => { this.openInBrowser(this.errorInfo!.openInBrowserUrl!); })
            }
          }
          .justifyContent(FlexAlign.Center)
        }
      } else if (this.videoDescriptionError) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
            .fontSize(40)
            .fontColor([Color.White])
          Text(this.videoDescriptionError)
            .fontColor('#CCFFFFFF')
            .fontSize(13)
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .padding({ left: 24, right: 24 })
          Button($r('app.string.yt_action_retry'))
            .height(36)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.themePrimary)
            .borderRadius(18)
            .onClick(() => { this.retryLoadVideo(); })
        }
      } else if (this.isLoading) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color(Color.White)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  // ── 信息面板：竖屏下方 / 横屏侧栏内联；全屏态经 sheet 打开（内容组件 PlayerInfoPanel）──
  @Builder
  InfoPanel() {
    PlayerInfoPanel({
      video: this.video,
      videoDescription: this.videoSource.videoDescription,
      streams: this.videoSource.streams || [],
      // Extractor sets videoInfo.isLive from isLiveNow only (not isLiveContent).
      // List badge item.isLive must not hide download on 直播回放.
      isLiveNow: this.videoSource.isLive === true,
      viewCount: this.videoSource.viewCount || 0,
      likeCount: this.detailLikeCount,
      dislikeCount: this.detailDislikeCount,
      publishDate: this.videoSource.publishDate || '',
      tags: this.videoSource.tags || [],
      channelId: this.detailChannelId,
      channelAvatarUrl: this.detailChannelAvatarUrl,
      vm: $vm,
    })
    // 宽布局：右栏固定宽（视频吃剩余空间）；竖屏/挤压态：占满剩余高度
    .width(this.isWideLayout() ? this.getInfoPanelWidthVp() : Const.WIDTH_FULL_PERCENT)
    .layoutWeight(this.isWideLayout() ? 0 : 1)
    .height(Const.HEIGHT_FULL_PERCENT)
    // 挂载/卸载转场：仅在 animateTo 帧内播放（全屏进出），其余场景即时
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.END)),
      TransitionEffect.OPACITY))
  }

  // ── 全屏/分屏/挤压铺满态的信息 sheet：CENTER 大面板，与 VideoDetails 的 BOTTOM 内层 sheet 形态错开 ──
  @Builder
  PlayerInfoSheetContent() {
    Column() {
      this.InfoPanel()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  VideoPlayerContent() {
    Stack({ alignContent: Alignment.Center }) {
      VideoPlayer({
        controller: $controller,
        vm: $vm,
        isFullLandscapeScreen: this.isFullLandscapeScreen(),
        // 强制全屏（分屏 / 挤压强制铺满）下退出全屏无意义，隐藏全屏切换按钮；
        // 仅用户手动全屏（isManualFullscreen）时保留退出入口
        showFullscreenButton: !this.isFullLandscapeScreen() || this.isManualFullscreen,
        onShowInfoPanel: () => {
          this.showInfoPanel = true;
        },
        onFullScreenClick: () => {
          // Toggle guard: 当前已是全屏 → 退出
          if (this.isFullLandscapeScreen()) {
            this.handleFullScreenExit();
            return;
          }
          this.enterImmersiveFullscreen();
        },
        onRetry: () => {
          this.retryLoadVideo();
        },
        onSurfaceReady: (xc: XComponentController) => {
          // 把播放页 XComponentController 注入 PiPManager 作为 PiP 的 componentController
          PiPManager.getInstance().setComponentController(xc);
        },
        curSource: $videoSource,
        chapters: this.chapters,
        curIndex: 0,
        index: 0,
      })

      if (this.isLoading || this.videoDescriptionError || !this.videoSource.streams || this.videoSource.streams.length === 0) {
        this.VideoPlaceholder()
      }

      // 仅驻留在栈上且 surface 已被 PiP 接管时显示；handoff/restore 过渡不显示，避免闪一下
      if (this.showPipPlaceholder && this.isPageShow) {
        this.PiPPlaceholderLayer()
      }
    }
  }

  @Builder
  PiPPlaceholderLayer() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.play_circle'))
          .fontSize(40)
          .fontColor([Color.White])
        Text($r('app.string.yt_pip_playing'))
          .fontColor(Color.White)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
        Text($r('app.string.yt_pip_restore_hint'))
          .fontColor('#99FFFFFF')
          .fontSize(13)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    // 非沉浸：视频画面整体下移 topSafeInset，不侵入状态栏/挖孔。
    // 沉浸全屏：系统栏隐藏，视频铺满。
    // 顶部 inset 不做高度动画，避免退出全屏时「先全屏再长出黑条」。
    // 状态栏图标在播放页强制白色（WindowUtil.setPlayerStatusBarStyle）。
    // XComponent SURFACE 可能溢出布局框，视频区 clip + 顶部黑条盖住避让区。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // Opaque top spacer: reserves layout space AND paints black under status bar.
        Column()
          .width(Const.WIDTH_FULL_PERCENT)
          .height(this.getTopSafeInsetVp())
          .backgroundColor(Color.Black)

        Flex({
          direction: this.isWideLayout() && !this.isFullLandscapeScreen()
            ? FlexDirection.Row : FlexDirection.Column
        }) {
          Stack() {
            this.VideoPlayerContent()
          }
          // 宽布局：视频吃剩余宽度（右栏固定宽）；其余状态铺满
          .width(this.isFullLandscapeScreen() ? Const.WIDTH_FULL_PERCENT :
            this.isWideLayout() ? 0 : Const.WIDTH_FULL_PERCENT)
          .layoutWeight(this.isWideLayout() && !this.isFullLandscapeScreen() ? 1 : 0)
          .height(this.isFullLandscapeScreen() ? Const.HEIGHT_FULL_PERCENT :
            this.isWideLayout() ? Const.HEIGHT_FULL_PERCENT :
            this.getVideoHeightVp())
          .clip(true)

          // 沉浸/分屏铺满时不占布局，避免详情 Tab 挤占小窗口高度
          if (!this.isFullLandscapeScreen()) {
            this.InfoPanel()
          }
        }
        .width(Const.WIDTH_FULL_PERCENT)
        .layoutWeight(1)
      }
      .width(Const.WIDTH_FULL_PERCENT)
      .height(Const.HEIGHT_FULL_PERCENT)

      // Extra cover: if native surface still paints above the spacer, this opaque
      // bar sits at the very top of the page stack and masks status-bar region.
      if (!this.isImmersive() && this.getTopSafeInsetVp() > 0) {
        Column()
          .width(Const.WIDTH_FULL_PERCENT)
          .height(this.getTopSafeInsetVp())
          .backgroundColor(Color.Black)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(Const.WIDTH_FULL_PERCENT)
    .height(Const.HEIGHT_FULL_PERCENT)
    .backgroundColor(Color.Black)
    .clip(true)
    // 布局变化（旋转 settle/分屏/全屏进出）后补发布"手动全屏生效中"（带变化去重）
    .onAreaChange(() => {
      this.publishFullscreenState();
    })
    // 全屏/分屏/挤压铺满态：信息面板以 CENTER sheet 打开（入口在播放器菜单"视频信息"）
    .bindSheet($$this.showInfoPanel, this.PlayerInfoSheetContent(), {
      detents: [SheetSize.LARGE],
      dragBar: true,
      preferType: SheetType.CENTER,
      // 关闭 sheet 自带的右上角关闭按钮：全屏态下它会与面板顶部 Tab 栏重叠，
      // 关闭交互由拖拽条（dragBar）和点击空白处承担
      showClose: false
    })
  }
}
