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

import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileUri, fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { CommonConstants as Const, PlaybackState, PlayerState, VideoData } from 'mediaservice';
import { WindowUtil } from '../../common/utils/WindowUtil';
import { VideoDetails } from './components/VideoDetails';
import { VideoPlayer } from './components/AVPlayer';
// 播放器错误统一由 VideoPlayer / AVPlayer 内部处理，不再使用 ErrorPage 短路
import { initTabData } from '../../common/model/TabViewModel';
import { TabItem } from '../../common/model/TabItem';
import { Constants } from '../../common/Constants';
import { YouTubePlayService } from './YouTubePlayService';
import { ChapterInfo, VideoItem } from 'youtube_core';
import { ActionHub, ActionHubEvent } from '../../common/ActionHub';
import { CommentNavWrapper } from './components/CommentNavWrapper';
import { AvPlayerController, PlayerUiViewModel } from 'mediaservice';
import { PlayerSession } from '../../common/PlayerSession';
import { PlayQueueList } from './components/PlayQueueList';
import { PiPManager } from './pip/PiPManager';
import { PlaybackConfig } from '../../common/PlaybackConfig';
import { MediaThumb } from '../../common/components/MediaThumb';
import { ErrorInfo } from '../../common/model/ErrorInfo';

const logger = AppLog.getInstance('PlayerPage');

const TAG: string = '[PlayerLog][VideoPlayerPage]';

@Component
export struct VideoPlayerPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @StorageProp('selectedVideo') @Watch('onVideoChange') video: VideoItem | null = null;
  @StorageProp('deviceHeight') deviceHeight: number =
    AppStorage.get<number>('deviceHeight') || 0;
  @StorageProp('deviceWidth') deviceWidth: number =
    AppStorage.get<number>('deviceWidth') || 0;
  // statusBarHeight 由 WindowUtil 在 avoidAreaChange 时实时更新（TYPE_SYSTEM / TYPE_CUTOUT max）
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  // Index Provide 的 safeAreaTop 作为兜底，避免 Storage 尚未写入时 inset 为 0
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  // 三种布局状态：
  //   isFullLandscapeScreen = true  → 沉浸全屏（视频 100%）
  //   isWideLayout         = true  → 宽窗口侧栏布局（左视频 60% + 右信息 40%）
  //   都为 false                 → 竖屏（上视频 + 下 Tab）
  // isManualFullscreen：用户点了全屏按钮。默认打开不强制全屏/横屏；仅分屏强制铺满。
  @State isFullLandscapeScreen: boolean = false;
  @State isWideLayout: boolean = false;
  @State isManualFullscreen: boolean = false;
  @State isImmersive: boolean = false;
  /** 仅分屏：视频默认铺满分屏窗口 */
  @StorageProp('isSplitScreen') @Watch('onSplitScreenChange') isSplitScreen: boolean = false;
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
  @State tabArray: Array<TabItem> = initTabData();
  @State currentTabIndex: number = 0;
  @State videoDescriptionError: string | null = null;
  @State errorInfo: ErrorInfo | null = null;
  @State detailLikeCount: string = '0';
  @State detailDislikeCount: string = '0';
  @State detailChannelId: string = '';
  @State detailChannelAvatarUrl: string = '';
  @State chapters: ChapterInfo[] = [];
  @State isRetrying: boolean = false;
  @StorageLink('playerLoading') isLoading: boolean = false;
  /** 画中画是否激活（订阅 PlayerSession.isPiPActive → 显示占位层） */
  @StorageLink('isPiPActive') isPiPActive: boolean = false;
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
  /**
   * Cross-orient exit only: keep full layout until portrait size settles,
   * so we never flash landscape-wide mid-rotate (0.5.1 gap).
   */
  private pendingOrientationSettle: boolean = false;
  /** Whether local playback was active before a cast session took ownership. */
  private resumeAfterCast: boolean = false;
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
      const data = await downloader.request(thumbnailUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 5000,
        readTimeout: 8000,
      });
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

  private getVideoHeightVp(): number {
    // 宽布局（折叠屏展开/平板横屏）或全屏 → 撑满
    if (this.isWideLayout || this.isFullLandscapeScreen) {
      return this.getUIContext().px2vp(Math.max(this.deviceWidth, this.deviceHeight));
    }
    const shortSide = Math.min(this.deviceWidth, this.deviceHeight);
    const maxHeight = this.getUIContext().px2vp(Math.max(this.deviceWidth, this.deviceHeight) * 0.45);
    // 视频尺寸已知时，按实际比例计算容器高度
    if (this.videoSource.width && this.videoSource.height) {
      const aspectRatio = this.videoSource.width / this.videoSource.height;
      const rawHeight = this.getUIContext().px2vp(shortSide / aspectRatio);
      return Math.max(200, Math.min(maxHeight, rawHeight));
    }
    // 视频尺寸未知时（加载中），按 16:9 预占高度（最常见比例）
    const defaultHeight = this.getUIContext().px2vp(shortSide / (16 / 9));
    return Math.max(200, Math.min(maxHeight, defaultHeight));
  }

  /** Non-immersive top inset under status bar / punch-hole. Immersive → 0. */
  private getTopSafeInsetVp(): number {
    if (this.isImmersive) {
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
    this.detailDislikeCount = source.dislikeCount || '0';
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
      dislikeCount: '0',
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
    if (session.playerState === PlayerState.IDLE && this.video) {
      this.isLoading = true;
    }

    // 进入播放页：不改朝向、不声明横向多窗；仅按当前窗口尺寸 + 是否分屏算布局
    this.isManualFullscreen = false;
    this.windowUtil.setPlayerFullscreenImmersive(false);
    this.windowUtil.setPlayerStatusBarStyle(true);
    this.windowUtil.disableLandscapeMultiWindow();
    this.windowUtil.setMainWindowOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);

    const initW = this.deviceWidth;
    const initH = this.deviceHeight;
    if (initW > 0 && initH > 0) {
      this.applyLayoutForWindowSize(initW, initH);
      logger.info(`${TAG} entered layout full=${this.isFullLandscapeScreen} wide=${this.isWideLayout} split=${this.isSplitScreen}`);
    }

    // 0.5.1 混合动画：
    //   跨向旋转 → animateTo(0) 禁用属性动画，系统旋转独占
    //   同向 full↔wide → 直接改状态，由容器 .animation(300) 驱动
    this.windowUtil.registerOnWindowSizeChange((size) => {
      this.onPlayerWindowSizeChange(size.width, size.height);
    });

    this.onVideoChange().catch((e: Error) => {
      logger.error(`${TAG} deferred onVideoChange failed: ${e.message || e}`);
      this.isLoading = false;
    });

    this.actionHub.on(ActionHubEvent.EXIT_FULLSCREEN, this.handleExitFullscreen);

    this.controller.onCastStateChange = (isCasting: boolean, deviceName: string) => {
      logger.info(`${TAG} Cast state changed: isCasting=${isCasting}, device=${deviceName}`);
      if (isCasting) {
        this.resumeAfterCast = this.vm.isPlaying;
        this.controller.syncPause();
      } else if (this.resumeAfterCast && this.isPageShow && !this.vm.isCasting) {
        this.resumeAfterCast = false;
        this.controller.syncPlay();
      } else {
        this.resumeAfterCast = false;
      }
    };

    harmonyShare.on('knockShare', this.knockShareCallback);
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
    this.windowUtil.registerOffWindowSizeChange();
    this.actionHub.off(ActionHubEvent.EXIT_FULLSCREEN, this.handleExitFullscreen);
    this.controller.onCastStateChange = undefined;
    this.resumeAfterCast = false;

    // 退出播放页：关闭 PiP 自动启动（避免非播放页 home 键误启），注销生命周期回调
    const pip = PiPManager.getInstance();
    pip.setAutoStart(false);
    pip.unregisterPipStateChangeListener();

    if (session.shouldRetainMediaOnPageDisappear()) {
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

  private notifyFullScreenChange(): void {
    if (this.onFullScreenChange) {
      this.onFullScreenChange(this.isFullLandscapeScreen);
    }
  }

  private onSplitScreenChange(): void {
    // 分屏进出时立刻按当前窗口尺寸重算布局（不依赖下一次 sizeChange）
    if (this.deviceWidth > 0 && this.deviceHeight > 0) {
      this.onPlayerWindowSizeChange(this.deviceWidth, this.deviceHeight);
    }
  }

  /**
   * 布局规则（默认打开不做强制全屏/横屏）：
   *   分屏 → 视频铺满分屏窗
   *   用户手动全屏 → 沉浸全屏
   *   否则仅按窗口宽高：横 → 宽布局，竖 → 竖屏详情
   */
  private applyLayoutForWindowSize(widthPx: number, heightPx: number): void {
    const isLandscape = widthPx > heightPx;
    const shortSideVp = this.getUIContext().px2vp(Math.min(widthPx, heightPx));
    const inSplit = this.isSplitScreen || this.windowUtil.isSplitScreenMode();

    if (inSplit) {
      // 分屏：仅布局铺满，不改系统朝向
      this.isFullLandscapeScreen = true;
      this.isWideLayout = false;
      this.isImmersive = true;
    } else if (this.isManualFullscreen) {
      this.isFullLandscapeScreen = true;
      this.isWideLayout = false;
      this.isImmersive = true;
    } else if (isLandscape) {
      this.isFullLandscapeScreen = false;
      this.isWideLayout = true;
      this.isImmersive = shortSideVp < 600;
    } else {
      this.isFullLandscapeScreen = false;
      this.isWideLayout = false;
      this.isImmersive = false;
    }
    // 系统栏：手动全屏或分屏沉浸时隐藏；其余交给 WindowUtil 方向策略
    this.windowUtil.setPlayerFullscreenImmersive(this.isManualFullscreen || inSplit);
    this.notifyFullScreenChange();
  }

  private onPlayerWindowSizeChange(widthPx: number, heightPx: number): void {
    // 0.5.1: duration:0 disables container .animation so system rotate owns the frame.
    // Do not invent intermediate layouts — apply flags from final width/height only.
    this.pendingOrientationSettle = false;
    animateTo({ duration: 0 }, () => {
      this.applyLayoutForWindowSize(widthPx, heightPx);
    });
  }

  private enterImmersiveFullscreen(): void {
    // 分屏已铺满，不锁朝向
    if (this.isSplitScreen || this.windowUtil.isSplitScreenMode()) {
      this.isManualFullscreen = false;
      this.applyLayoutForWindowSize(this.deviceWidth, this.deviceHeight);
      return;
    }

    // 仅用户主动全屏：按视频比例锁朝向（默认打开路径不会走到这里）
    const isLandscapeVideo = !!(this.videoSource.width && this.videoSource.height
      && this.videoSource.width > this.videoSource.height);
    const targetOrientation = isLandscapeVideo
      ? window.Orientation.LANDSCAPE
      : window.Orientation.PORTRAIT;
    const isCurrentLandscape = this.deviceWidth > this.deviceHeight;
    const willRotate = isLandscapeVideo !== isCurrentLandscape;

    this.isManualFullscreen = true;
    this.pendingOrientationSettle = false;
    this.windowUtil.setPlayerFullscreenImmersive(true);
    this.windowUtil.enableLandscapeMultiWindow();
    this.windowUtil.setMainWindowOrientation(targetOrientation);

    if (!willRotate) {
      this.isWideLayout = false;
      this.isFullLandscapeScreen = true;
      this.isImmersive = true;
      this.notifyFullScreenChange();
    }
  }

  handleFullScreenExit(): void {
    this.isManualFullscreen = false;
    this.pendingOrientationSettle = false;
    this.windowUtil.disableLandscapeMultiWindow();
    this.windowUtil.setMainWindowOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    this.applyLayoutForWindowSize(this.deviceWidth, this.deviceHeight);
  }

  @Builder
  tabBuilder(index: number, name: string | Resource) {
    Column() {
      Text(name)
        .fontColor(this.currentTabIndex === index ? this.themePrimary : $r('app.color.yourtube_text_secondary'))
        .fontSize(16)
        .fontWeight(this.currentTabIndex === index ? FontWeight.Normal : FontWeight.Medium)
        .lineHeight(22)
        .margin({ top: 17, bottom: 7 })
      Divider()
        .width(48)
        .strokeWidth(Constants.STROKE_WIDTH)
        .color(this.themePrimary)
        .opacity(this.currentTabIndex === index ? 1 : 0)
    }
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
            .height(32)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.themePrimary)
            .borderRadius(16)
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

  // ── 信息面板（详情 + 评论 Tab），手机竖屏和平板横屏复用 ──
  @Builder
  InfoPanel() {
    Column() {
      Tabs({ barPosition: BarPosition.Start }) {
        ForEach(this.tabArray, (item: TabItem) => {
          TabContent() {
            Column() {
              if (item.id === 0) {
                if (this.video) {
                  VideoDetails({
                    item: this.video,
                    videoDescription: this.videoSource.videoDescription,
                    streams: this.videoSource.streams || [],
                    viewCount: this.videoSource.viewCount || 0,
                    likeCount: this.detailLikeCount,
                    dislikeCount: this.detailDislikeCount,
                    publishDate: this.videoSource.publishDate || '',
                    tags: this.videoSource.tags || [],
                    channelId: this.detailChannelId,
                    channelAvatarUrl: this.detailChannelAvatarUrl,
                    mpvVideoWidth: this.vm.videoWidth,
                    mpvVideoHeight: this.vm.videoHeight,
                    mpvContainerFormat: this.vm.containerFormat,
                    mpvMediaTitle: this.vm.mediaTitle,
                    mpvVideoCodec: this.vm.videoCodec,
                    mpvVideoBitRate: this.vm.videoBitRate,
                    mpvFrameRate: this.vm.frameRate,
                    mpvAudioCodec: this.vm.audioCodec,
                    mpvAudioBitRate: this.vm.audioBitRate,
                    mpvAudioChannels: this.vm.audioChannels,
                    mpvAudioSampleRate: this.vm.audioSampleRate,
                    mpvFileSize: this.vm.fileSize,
                    mpvDuration: this.vm.durationTime,
                  })
                }
              } else if (item.id === 1) {
                CommentNavWrapper({ videoId: this.video?.videoId || '' })
              } else {
                PlayQueueList()
              }
            }
            .width(Const.WIDTH_FULL_PERCENT)
            .height(Const.HEIGHT_FULL_PERCENT)
          }.tabBar(this.tabBuilder(item.id, item.name))
        }, (item: TabItem, index: number) => JSON.stringify(item) + index)
      }
      .borderRadius({ topLeft: 16, topRight: 16 })
      .barMode(BarMode.Fixed)
      .barWidth(Const.WIDTH_FULL_PERCENT)
      .barHeight(52)
      .onAnimationStart((index: number, targetIndex: number) => {
        this.currentTabIndex = targetIndex;
      })
      .backgroundColor($r('app.color.yourtube_bg_page'))
    }
    .layoutWeight(1)
    .height(Const.HEIGHT_FULL_PERCENT)
  }

  @Builder
  VideoPlayerContent() {
    Stack({ alignContent: Alignment.Center }) {
      VideoPlayer({
        controller: $controller,
        vm: $vm,
        isFullLandscapeScreen: this.isFullLandscapeScreen,
        onFullScreenClick: () => {
          // Toggle guard: 当前已是全屏 → 退出
          if (this.isFullLandscapeScreen) {
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

      // 画中画激活时：typeNode 已迁移到 PiP 窗口，主页面显示占位层提示
      if (this.isPiPActive) {
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
          direction: this.isWideLayout && !this.isFullLandscapeScreen
            ? FlexDirection.Row : FlexDirection.Column
        }) {
          Stack() {
            this.VideoPlayerContent()
          }
          .width(this.isFullLandscapeScreen ? Const.WIDTH_FULL_PERCENT :
            this.isWideLayout ? '60%' : Const.WIDTH_FULL_PERCENT)
          .height(this.isFullLandscapeScreen ? Const.HEIGHT_FULL_PERCENT :
            this.isWideLayout ? Const.HEIGHT_FULL_PERCENT :
            this.getVideoHeightVp())
          .clip(true)
          // 0.5.1：同向宽布局↔沉浸 300ms；跨向时 windowSizeChange 用 animateTo(0) 关掉本动画
          .animation({ duration: 300, curve: Curve.EaseInOut })

          // 沉浸/分屏铺满时不占布局，避免详情 Tab 挤占小窗口高度
          if (!this.isFullLandscapeScreen) {
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
      if (!this.isImmersive && this.getTopSafeInsetVp() > 0) {
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
  }
}
