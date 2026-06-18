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
import { CommonConstants as Const, VideoData } from 'mediaservice';
import { WindowUtil } from '../../common/utils/WindowUtil';
import { VideoDetails } from './components/VideoDetails';
import { VideoPlayer } from './components/AVPlayer';
// 播放器错误统一由 VideoPlayer / AVPlayer 内部处理，不再使用 ErrorPage 短路
import { initTabData } from '../../common/model/TabViewModel';
import { TabItem } from '../../common/model/TabItem';
import { Constants } from '../../common/Constants';
import { YouTubePlayService } from './YouTubePlayService';
import { VideoItem } from 'youtube_core';
import { ActionHub, ActionHubEvent } from '../../common/ActionHub';
import { CommentNavWrapper } from './components/CommentNavWrapper';
import { AvPlayerController, PlayerUiViewModel } from 'mediaservice';
import { PlayerSession } from '../../common/PlayerSession';
import { PlayQueueList } from './components/PlayQueueList';
import { PlayQueueManager, QueueSourceType } from './PlayQueueManager';
import { PiPManager } from './pip/PiPManager';
import { PlaybackConfig } from '../../common/PlaybackConfig';
import { ErrorInfo } from '../../common/model/ErrorInfo';

const logger = AppLog.getInstance('PlayerPage');

const TAG: string = '[PlayerLog][VideoPlayerPage]';

@Component
export struct VideoPlayerPage {
  @StorageProp('selectedVideo') @Watch('onVideoChange') video: VideoItem | null = null;
  @StorageProp('deviceHeight') deviceHeight: number =
    AppStorage.get<number>('deviceHeight') || 0;
  @StorageProp('deviceWidth') deviceWidth: number =
    AppStorage.get<number>('deviceWidth') || 0;
  // statusBarHeight 由 WindowUtil 在 avoidAreaChange 时实时更新，包含刘海/状态栏高度
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  // 三种布局状态：
  //   isFullLandscapeScreen = true  → 沉浸全屏（视频 100%，隐藏系统栏）
  //   isWideLayout         = true  → 平板/折叠屏宽布局（左视频 60% + 右信息 40%）
  //   都为 false                 → 竖屏（上视频 + 下 Tab）
  // isManualFullscreen 标识"用户主动点了全屏按钮"，仅它为真时才进入沉浸全屏；
  // 否则系统横屏一律走宽布局。
  @State isFullLandscapeScreen: boolean = false;
  @State isWideLayout: boolean = false;
  @State isManualFullscreen: boolean = false;
  @State isImmersive: boolean = false;
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
  @State detailChannelId: string = '';
  @State detailChannelAvatarUrl: string = '';
  @State isRetrying: boolean = false;
  @State isLoading: boolean = false;
  /** 画中画是否激活（订阅 PlayerSession.isPiPActive → 显示占位层） */
  @StorageLink('isPiPActive') isPiPActive: boolean = false;
  /** 播放设置（含 pipOnReturn） */
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  private windowUtil: WindowUtil = WindowUtil.getInstance();
  private handleExitFullscreen: () => void = () => {
    this.handleFullScreenExit();
  };

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

  /**
   * 重试加载视频信息（从获取视频详细信息和流开始）
   */
  private async retryLoadVideo(): Promise<void> {
    if (this.isRetrying) return;
    this.isRetrying = true;
    await this.onVideoChange();
    this.isRetrying = false;
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
    this.detailChannelId = source.channelId || this.video?.channelId || '';
    this.detailChannelAvatarUrl = this.video?.channelAvatarUrl || '';
  }

  async aboutToAppear(): Promise<void> {
    const session = PlayerSession.getInstance();
    this.controller = session.controller;
    this.vm = session.controller.vm;

    let context: Context = this.getUIContext().getHostContext() as Context;

    // XComponent 方式 PiP：surface 由 AVPlayer 的内联 XComponent.onLoad 直接绑定，
    // 这里无需注册 surface 监听。仅注入 release 时停 PiP 的回调（避免 PlayerSession 循环 import）。
    PlayerSession.getInstance().onStopPiP = () => PiPManager.getInstance().stopPiP();

    // 移植 0.4.0 退出语义：PiP 被关闭时，后台仅暂停（保活后台播放），前台释放会话。
    PiPManager.getInstance().onPipStop = () => {
      const session = PlayerSession.getInstance();
      const isAppBackground = AppStorage.get<boolean>('isAppBackground') ?? false;
      if (isAppBackground) {
        logger.info(`${TAG} onPipStop while background → pause only`);
        session.controller.syncPause();
      } else {
        // 前台关闭 PiP：仅释放会话。不调用 closePage()——进入 PiP 时（返回键路径）
        // 播放页已被 navPathStack.pop() 弹出，此处再 pop 会多触发一次返回动作。
        logger.info(`${TAG} onPipStop while foreground → release session`);
        session.release();
      }
    };

    const initW = this.deviceWidth;
    const initH = this.deviceHeight;
    if (initW > 0 && initH > 0 && initW > initH) {
      this.isWideLayout = true;
      const shortSideVp = this.getUIContext().px2vp(Math.min(initW, initH));
      this.isImmersive = shortSideVp < 600;
      if (this.isImmersive) {
        this.windowUtil.disableWindowSystemBar();
      }
      logger.info(`${TAG} entered in landscape, wide layout, immersive=${this.isImmersive}`);
    }

    // 让系统旋转动画完整驱动布局：windowSizeChange 用 animateTo({duration:0})
    // 显式禁用属性动画，让系统旋转动画独占；否则属性动画会跟系统旋转动画打架。
    // isManualFullscreen 是权威标志，由按钮路径维护；这里只读取它决定布局，不修改。
    this.windowUtil.registerOnWindowSizeChange((size) => {
      const isLandscape = size.width > size.height;

      animateTo({ duration: 0 }, () => {
        if (this.isManualFullscreen) {
          // 用户主动沉浸全屏：任何方向都铺满（兼容竖向视频沉浸全屏）
          this.isFullLandscapeScreen = true;
          this.isWideLayout = false;
        } else if (isLandscape) {
          // 系统横屏：宽布局分栏
          this.isFullLandscapeScreen = false;
          this.isWideLayout = true;
        } else {
          // 系统竖屏：普通布局
          this.isFullLandscapeScreen = false;
          this.isWideLayout = false;
        }
      });

      // 沉浸式：全屏一定沉浸；手机横屏（短边 < 600vp）也沉浸
      const shortSideVp = this.getUIContext().px2vp(Math.min(size.width, size.height));
      this.isImmersive = this.isFullLandscapeScreen || (isLandscape && shortSideVp < 600);
      if (this.isImmersive) {
        this.windowUtil.disableWindowSystemBar();
      } else {
        this.windowUtil.enableWindowSystemBar();
      }
      this.notifyFullScreenChange();
    });

    await this.onVideoChange();
    this.controller = session.controller;
    this.vm = session.controller.vm;

    // Register queue switch callback: when user clicks another video in the play queue,
    // PlayerPage reloads without going through AppStorage/Index.openVideoDetail.
    PlayQueueManager.getInstance().onSwitchVideo = async (v: VideoItem) => {
      logger.info(`${TAG} queue switch → ${v.videoId}`);
      // Set StorageProp to trigger @Watch('onVideoChange') — do NOT call onVideoChange()
      // explicitly to avoid double-trigger race condition.
      AppStorage.setOrCreate('selectedVideo', v);
      await PlayerSession.getInstance().play(v);
    };

    this.actionHub.on(ActionHubEvent.EXIT_FULLSCREEN, this.handleExitFullscreen);

    this.controller.onCastStateChange = (isCasting: boolean, deviceName: string) => {
      logger.info(`${TAG} Cast state changed: isCasting=${isCasting}, device=${deviceName}`);
      if (isCasting) {
        this.controller.syncPause();
      } else if (this.isPageShow && !this.vm.isCasting) {
        this.controller.syncPlay();
      }
    };

    // Set up stream refresh handler for automatic URL refresh on expiry
    this.controller.setRefreshHandler(async (videoId: string, _resumePos: number) => {
      try {
        const playService = YouTubePlayService.getInstance(context as common.UIAbilityContext);
        const result = await playService.refreshStreams(videoId);
        if (!result.success || !result.videoInfo) {
          return null;
        }
        const refreshVideoStream = result.videoInfo.streams?.find((s) => s.hasVideo && s.width && s.height);
        const refreshed: VideoData = {
          name: this.videoSource.name,
          description: result.videoInfo.title || '',
          time: this.videoSource.time,
          auto: this.videoSource.auto,
          head: this.videoSource.head,
          likeCount: this.videoSource.likeCount,
          commentCount: this.videoSource.commentCount,
          shareCount: this.videoSource.shareCount,
          author: result.videoInfo.author || this.videoSource.author || '',
          channelId: result.videoInfo.channelId || this.videoSource.channelId || '',
          videoDescription: result.videoInfo.description || '',
          play: true,
          videoId: videoId,
          index: this.videoSource.index,
          width: refreshVideoStream?.width || 0,
          height: refreshVideoStream?.height || 0,
          error: undefined,
          streams: result.playerStreams ?? [],
          subtitleTracks: result.subtitleTracks ?? [],
          isLive: result.videoInfo.isLive || false,
          thumbnailUrl: this.video?.thumbnailUrl || '',
          viewCount: result.videoInfo.viewCount || this.videoSource.viewCount || 0,
          publishDate: result.videoInfo.publishDate || this.videoSource.publishDate || '',
          tags: result.videoInfo.tags || this.videoSource.tags || []
        };
        return refreshed;
      } catch (e) {
        logger.error(`${TAG} refreshHandler error: ${e}`);
        return null;
      }
    });
  }

  aboutToDisappear(): void {
    // 恢复状态栏并恢复全局自动旋转
    this.windowUtil.enableWindowSystemBar();
    this.windowUtil.setMainWindowOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    this.windowUtil.registerOffWindowSizeChange();
    this.actionHub.off(ActionHubEvent.EXIT_FULLSCREEN, this.handleExitFullscreen);
    this.controller.onCastStateChange = undefined;

    // 退出播放页：关闭 PiP 自动启动（避免非播放页 home 键误启），注销生命周期回调
    PiPManager.getInstance().setAutoStart(false);
    PiPManager.getInstance().unregisterPipStateChangeListener();

    // 退出时清理 adhoc 队列
    const qm = PlayQueueManager.getInstance();
    if (qm.sourceType === QueueSourceType.ADHOC) {
      qm.clear();
      logger.info(`${TAG} cleared adhoc queue on exit`);
    }
  }

  // Guard against concurrent onVideoChange invocations (e.g. @Watch + explicit call)
  private isVideoChanging: boolean = false;

  private async onVideoChange(): Promise<void> {
    if (!this.video) return;
    if (this.isVideoChanging) {
      logger.info(`${TAG} onVideoChange skipped: already in progress`);
      return;
    }
    const session = PlayerSession.getInstance();
    this.isVideoChanging = true;

    // 同视频已就绪：直接同步，使用缓存数据
    if (session.currentVideo?.videoId === this.video?.videoId && session.controller.vm.isReady) {
      this.controller = session.controller;
      this.vm = session.controller.vm;
      if (session.cachedVideoSource) {
        this.videoSource = session.cachedVideoSource;
        this.syncDetailStateFromSource(session.cachedVideoSource);
      }
      this.isLoading = false;
      this.isVideoChanging = false;
      return;
    }

    // 切换视频：清空旧流数据以显示加载占位图，清空元数据避免残留
    try {
      const isSwitchingVideo = !!this.videoSource.videoId && this.videoSource.videoId !== this.video.videoId;
      if (isSwitchingVideo) {
        session.controller.syncPause();
      }
      this.isLoading = true;
      this.videoDescriptionError = null;
      this.errorInfo = null;
      this.detailLikeCount = '0';
      this.detailChannelId = this.video.channelId || '';
      this.detailChannelAvatarUrl = this.video.channelAvatarUrl || '';
      const newVideoSource = await session.play(this.video);

      this.controller = session.controller;
      this.vm = session.controller.vm;

      if (newVideoSource) {
        if (!this.videoSource.videoId || this.videoSource.videoId !== newVideoSource.videoId) {
          this.videoSource = newVideoSource;
          session.cachedVideoSource = newVideoSource;
          this.syncDetailStateFromSource(newVideoSource);
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
          this.videoDescriptionError = '加载视频失败';
          this.errorInfo = null;
        } else {
          this.errorInfo = err;
          this.videoDescriptionError = null;
        }
      }
    } catch (e) {
      logger.error(`${TAG} onVideoChange exception: ${e}`);
      this.videoDescriptionError = '加载视频失败';
    } finally {
      this.isLoading = false;
      this.isVideoChanging = false;
    }
  }

  onPageHide(): void {
    this.isPageShow = false;
    // 页面隐藏时关闭 PiP 自动启动（避免非播放页 home 键误启）
    PiPManager.getInstance().setAutoStart(false);
  }

  onPageShow(): void {
    this.isPageShow = true;

    // 页面可见时：若开启 pipOnReturn 且设备支持，允许 home 键自动启动 PiP
    const pip = PiPManager.getInstance();
    if (pip.isPiPSupported() && this.playbackConfig.pipOnReturn) {
      pip.setAutoStart(true);
    }

    const session = PlayerSession.getInstance();
    if (session.isReleased && this.video) {
      logger.info(`${TAG} Session was released while hidden, reloading video`);
      this.onVideoChange();
    }
  }

  private notifyFullScreenChange(): void {
    if (this.onFullScreenChange) {
      this.onFullScreenChange(this.isFullLandscapeScreen);
    }
  }

  handleFullScreenExit(): void {
    // 退出沉浸全屏：清掉 manual 标志，恢复系统栏，解除方向锁
    // 三种来源场景：
    //   - 物理横屏 + 横向视频沉浸：尺寸不变 → 这里直接切宽布局，由 .animation 驱动
    //   - 物理竖屏 + 竖向视频沉浸：尺寸不变 → 这里直接清状态，由 .animation 驱动
    //   - 物理竖屏 + 横向沉浸（之前手动旋转过来）：解锁后系统旋回竖屏，
    //     windowSizeChange 触发，由它接管
    this.isManualFullscreen = false;
    this.windowUtil.enableWindowSystemBar();
    this.windowUtil.setMainWindowOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);

    const isLandscape = this.deviceWidth > this.deviceHeight;
    if (isLandscape) {
      // 物理横屏：直接切宽布局
      const shortSideVp = this.getUIContext().px2vp(Math.min(this.deviceWidth, this.deviceHeight));
      this.isFullLandscapeScreen = false;
      this.isWideLayout = true;
      this.isImmersive = shortSideVp < 600;
      if (this.isImmersive) {
        this.windowUtil.disableWindowSystemBar();
      }
    } else {
      // 物理竖屏：直接清沉浸状态（竖向视频沉浸全屏退出走这里）
      this.isFullLandscapeScreen = false;
      this.isWideLayout = false;
      this.isImmersive = false;
    }
    this.notifyFullScreenChange();
  }

  @Builder
  tabBuilder(index: number, name: string | Resource) {
    Column() {
      Text(name)
        .fontColor(this.currentTabIndex === index ? $r('app.color.yourtube_theme_primary') : $r('app.color.yourtube_text_secondary'))
        .fontSize(16)
        .fontWeight(this.currentTabIndex === index ? FontWeight.Normal : FontWeight.Medium)
        .lineHeight(22)
        .margin({ top: 17, bottom: 7 })
      Divider()
        .width(48)
        .strokeWidth(Constants.STROKE_WIDTH)
        .color($r('app.color.yourtube_theme_primary'))
        .opacity(this.currentTabIndex === index ? 1 : 0)
    }
  }

  @Builder
  VideoPlaceholder() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.video && this.video.thumbnailUrl) {
        Image(this.video.thumbnailUrl)
          .id('thumb_' + this.video.id)
          .geometryTransition('thumb_' + this.video.id, { follow: true })
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
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
              .backgroundColor($r('app.color.yourtube_theme_primary'))
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
            .backgroundColor($r('app.color.yourtube_theme_primary'))
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
    .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
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
                    publishDate: this.videoSource.publishDate || '',
                    tags: this.videoSource.tags || [],
                    channelId: this.detailChannelId,
                    channelAvatarUrl: this.detailChannelAvatarUrl,
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
          // 进入沉浸全屏：根据视频比例选目标方向
          //   横向视频 → LANDSCAPE
          //   竖向视频（短视频）→ PORTRAIT（不旋转，竖向沉浸全屏）
          const isLandscapeVideo = this.videoSource.width && this.videoSource.height
            && this.videoSource.width > this.videoSource.height;
          const targetOrientation = isLandscapeVideo
            ? window.Orientation.LANDSCAPE
            : window.Orientation.PORTRAIT;
          const isCurrentLandscape = this.deviceWidth > this.deviceHeight;
          const willRotate = isLandscapeVideo !== isCurrentLandscape;

          this.isManualFullscreen = true;
          this.windowUtil.disableWindowSystemBar();
          this.windowUtil.setMainWindowOrientation(targetOrientation);

          // 不会发生旋转（窗口尺寸不变）：直接改状态，由容器 .animation() 驱动平滑过渡
          // 适用：竖屏+竖向视频、横屏宽布局+横向视频
          // 会旋转的路径交给 windowSizeChange 处理
          if (!willRotate) {
            this.isWideLayout = false;
            this.isFullLandscapeScreen = true;
            this.isImmersive = true;
            this.notifyFullScreenChange();
          }
        },
        onRetry: () => {
          this.retryLoadVideo();
        },
        onSurfaceReady: (xc: XComponentController) => {
          // 把播放页 XComponentController 注入 PiPManager 作为 PiP 的 componentController
          PiPManager.getInstance().setComponentController(xc);
        },
        curSource: $videoSource,
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
        Text('画中画播放中')
          .fontColor(Color.White)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
        Text('点击画中画窗口恢复')
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
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Column()
          .width(Const.WIDTH_FULL_PERCENT)
          .height(this.isImmersive ? 0 : this.statusBarHeight)
          .animation({ duration: 300, curve: Curve.EaseInOut })

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
          // 属性动画：宽布局 ↔ 沉浸全屏（同尺寸切换）需要 300ms 缓动；
          // 系统旋转路径下 windowSizeChange 用 animateTo({duration:0}) 主动禁用，
          // 让系统旋转动画独占，避免双动画打架。
          .animation({ duration: 300, curve: Curve.EaseInOut })

          this.InfoPanel()
        }
        .width(Const.WIDTH_FULL_PERCENT)
        .layoutWeight(1)
      }
    }
    .backgroundColor(Color.Black)
  }
}
