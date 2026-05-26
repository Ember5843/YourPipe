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
import { CommonConstants as Const, Logger, VideoData } from 'mediaservice';
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
import { CommentList } from './components/CommentList';
import { CommentReplyPage } from './components/CommentReplyPage';
import { CommentNavWrapper } from './components/CommentNavWrapper';
import { WatchHistoryStore } from '../../common/WatchHistoryStore';
import { AvPlayerController, PlayerState } from 'mediaservice';
import { PlayerSession } from '../../common/PlayerSession';

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
  // 全屏横屏状态，由 windowSizeChange 回调驱动以保证布局和旋转动画同步
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
  @State isPageShow: boolean = false;
  @State tabArray: Array<TabItem> = initTabData();
  @State currentTabIndex: number = 0;
  @State videoDescriptionError: string | null = null;
  @State isRetrying: boolean = false;
  @State isLoading: boolean = false;
  @State isManualRotated: boolean = false;
  private windowUtil: WindowUtil = WindowUtil.getInstance();
  /** 当前播放视频的 videoId，用于历史记录 */
  private watchVideoId: string = '';
  /** 10 秒定时保存历史进度的 Timer ID */
  private watchSaveTimerId: number = -1;

  private getVideoHeightVp(): number {
    const shortSide = Math.min(this.deviceWidth, this.deviceHeight);
    const aspectRatio = this.videoSource.width && this.videoSource.height
      ? this.videoSource.width / this.videoSource.height : Const.ASPECT;
    return this.getUIContext().px2vp(shortSide / aspectRatio);
  }

  /**
   * 重试加载视频信息（从获取视频详细信息和流开始）
   */
  private resourceToString(res: ResourceStr | null): string {
    if (res === null) return '';
    if (typeof res === 'string') return res;
    try {
      return getContext().resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private async retryLoadVideo(): Promise<void> {
    if (this.isRetrying) return;
    this.isRetrying = true;
    await this.onVideoChange();
    this.isRetrying = false;
  }

  async aboutToAppear(): Promise<void> {
    const session = PlayerSession.getInstance();
    this.controller = session.controller;

    let context: Context = this.getUIContext().getHostContext() as Context;
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

    this.windowUtil.registerOnWindowSizeChange((size) => {
      const isLandscape = size.width > size.height;

      if (!this.isManualFullscreen) {
        animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
          this.isFullLandscapeScreen = false;
          this.isWideLayout = isLandscape;
        });
      }

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

    this.actionHub.on(ActionHubEvent.EXIT_FULLSCREEN, () => {
      this.handleFullScreenExit();
    });

    // 监听投屏状态变化 —— 连接时暂停本地播放，断开后恢复
    this.controller.onCastStateChange = (isCasting: boolean, deviceName: string) => {
      logger.info(`${TAG} Cast state changed: isCasting=${isCasting}, device=${deviceName}`);
      if (isCasting) {
        this.controller.syncPause();
      } else {
        if (this.isPageShow && !this.controller.isCasting) {
          this.controller.syncPlay();
        }
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
          width: result.videoInfo.streams?.[0]?.width || 1280,
          height: result.videoInfo.streams?.[0]?.height || 720,
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
    // 退出播放页面时，保存最终进度到历史记录
    this.saveWatchHistory();
    this.stopWatchSaveTimer();
    // 恢复状态栏并恢复全局自动旋转
    this.windowUtil.enableWindowSystemBar();
    this.windowUtil.setMainWindowOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    this.windowUtil.registerOffWindowSizeChange();
    this.actionHub.off(ActionHubEvent.EXIT_FULLSCREEN);
    this.controller.onCastStateChange = undefined;
  }

  private async onVideoChange(): Promise<void> {
    if (!this.video) return;

    const session = PlayerSession.getInstance();

    // PiP 恢复期间：session 仍在播放，只需同步 controller 引用，不触发 play
    if (session.isRestoringFromPip) {
      logger.info(`${TAG} onVideoChange skipped: PiP restore in progress (state=${session.playerState})`);
      this.controller = session.controller;
      if (session.cachedVideoSource) {
        this.videoSource = session.cachedVideoSource;
      }
      this.isLoading = false;
      return;
    }

    // 同视频已就绪：直接同步，使用缓存数据
    if (session.currentVideo?.videoId === this.video?.videoId && session.controller.isReady) {
      this.controller = session.controller;
      if (session.cachedVideoSource) {
        this.videoSource = session.cachedVideoSource;
      }
      this.isLoading = false;
      return;
    }

    this.isLoading = true;
    this.videoDescriptionError = null;
    const videoSource = await session.play(this.video);

    this.controller = session.controller;

    if (videoSource) {
      if (!this.videoSource.videoId || this.videoSource.videoId !== videoSource.videoId) {
        this.videoSource = videoSource;
        session.cachedVideoSource = videoSource;
      }
    } else {
      const err = session.lastPlayError;
      if (err === null) {
        this.videoDescriptionError = '加载视频失败';
      } else if (typeof err === 'string') {
        this.videoDescriptionError = err;
      } else {
        try {
          const ctx = getContext(this);
          this.videoDescriptionError = ctx.resourceManager.getStringSync((err as Resource).id);
        } catch (_e) {
          this.videoDescriptionError = '加载视频失败';
        }
      }
    }

    this.isLoading = false;
  }

  onPageHide(): void {
    this.isPageShow = false;
  }

  onPageShow(): void {
    this.isPageShow = true;

    const session = PlayerSession.getInstance();
    const pipActive = session.playerState === PlayerState.PIP_ACTIVE
      || session.playerState === PlayerState.PIP_ENTERING
      || session.playerState === PlayerState.PIP_RESTORING;

    if (session.isReleased && this.video && !pipActive) {
      logger.info(`${TAG} Session was released while hidden, reloading video`);
      this.onVideoChange();
    }
  }

  private notifyFullScreenChange(): void {
    if (this.onFullScreenChange) {
      this.onFullScreenChange(this.isFullLandscapeScreen);
    }
  }

  /** 保存当前播放位置到历史记录 */
  private saveWatchHistory(): void {
    if (!this.watchVideoId) return;
    try {
      const controller = this.controller;
      const progressSec = controller.currentTime;
      const durationSec = controller.durationTime;
      WatchHistoryStore.record(
        this.watchVideoId,
        this.video?.title || this.videoSource.description as string || '',
        this.video?.author || this.videoSource.author || '',
        this.video?.thumbnailUrl || this.videoSource.thumbnailUrl || '',
        durationSec,
        progressSec,
        this.video?.channelId || this.videoSource.channelId || '',
        this.video?.channelAvatarUrl || '',
        this.video?.channelHandle || ''
      );
      logger.info(`${TAG} Saved history: ${this.watchVideoId} at ${progressSec.toFixed(1)}s / ${durationSec.toFixed(1)}s`);
    } catch (e) {
      logger.warn(`${TAG} saveWatchHistory failed: ${e}`);
    }
  }

  /** 启动 10 秒定时保存 */
  private startWatchSaveTimer(): void {
    this.stopWatchSaveTimer();
    this.watchSaveTimerId = setInterval(() => {
      this.saveWatchHistory();
    }, 10000);
  }

  /** 清除定时保存 */
  private stopWatchSaveTimer(): void {
    if (this.watchSaveTimerId !== -1) {
      clearInterval(this.watchSaveTimerId);
      this.watchSaveTimerId = -1;
    }
  }

  handleFullScreenExit(): void {
    this.isManualFullscreen = false;
    const shortSideVp = this.getUIContext().px2vp(Math.min(this.deviceWidth, this.deviceHeight));
    const isLandscape = this.deviceWidth > this.deviceHeight;
    this.isImmersive = isLandscape && shortSideVp < 600;

    if (this.isImmersive) {
      this.windowUtil.disableWindowSystemBar();
    } else {
      this.windowUtil.enableWindowSystemBar();
    }

    animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
      this.isFullLandscapeScreen = false;
      if (isLandscape) {
        this.isWideLayout = true;
      }
    });
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

      if (this.videoDescriptionError) {
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
    .aspectRatio(16 / 9)
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
                    likeCount: this.videoSource.likeCount,
                    publishDate: this.videoSource.publishDate || '',
                    tags: this.videoSource.tags || [],
                  })
                }
              } else if (item.id === 1) {
                CommentNavWrapper({ videoId: this.video?.videoId || '' })
              } else {
                Row() {
                  Text($r('app.string.yt_empty_no_content'))
                    .fontSize(16)
                    .fontColor($r('app.color.yourtube_text_hint'))
                }
                .width(Const.WIDTH_FULL_PERCENT)
                .justifyContent(FlexAlign.Center)
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
    if (!this.videoSource.streams || this.videoSource.streams.length === 0) {
      this.VideoPlaceholder()
    } else {
      VideoPlayer({
        controller: $controller,
        isFullLandscapeScreen: this.isFullLandscapeScreen,
        onFullScreenClick: (isLandscape?: boolean) => {
          if (isLandscape) {
            this.isImmersive = true;
            this.windowUtil.disableWindowSystemBar();
            animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
              this.isManualFullscreen = true;
              this.isWideLayout = false;
              this.isFullLandscapeScreen = true;
            });
          } else {
            this.handleFullScreenExit();
          }
        },
        onRotateClick: () => {
          if (this.isManualRotated) {
            this.windowUtil.setMainWindowOrientation(window.Orientation.PORTRAIT);
          } else {
            this.windowUtil.setMainWindowOrientation(window.Orientation.LANDSCAPE);
          }
          this.isManualRotated = !this.isManualRotated;
        },
        onRetry: () => {
          this.retryLoadVideo();
        },
        curSource: $videoSource,
        curIndex: 0,
        index: 0,
      })
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Column()
          .width(Const.WIDTH_FULL_PERCENT)
          .height(this.statusBarHeight)
          .visibility(this.isImmersive ? Visibility.None : Visibility.Visible)

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
          .animation(null)

          this.InfoPanel()
        }
        .width(Const.WIDTH_FULL_PERCENT)
        .layoutWeight(1)
      }
    }
    .backgroundColor(Color.Black)
  }
}
