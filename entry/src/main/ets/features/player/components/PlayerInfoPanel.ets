import { CommonConstants as Const, PlayerUiViewModel, StreamInfo } from 'mediaservice';
import { VideoItem } from 'youtube_core';
import { initTabData } from '../../../common/model/TabViewModel';
import { TabItem } from '../../../common/model/TabItem';
import { SubTabBarItem } from '../../../common/components/SubTabBar';
import { VideoDetails } from './VideoDetails';
import { CommentNavWrapper } from './CommentNavWrapper';
import { PlayQueueList } from './PlayQueueList';

/**
 * 播放器信息面板（简介 / 评论 / 播放列表三 Tab）。
 * 两处复用：PlayerPage 内联（竖屏下方 / 横屏侧栏）与全屏态的信息 sheet。
 */
@Component
export struct PlayerInfoPanel {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop video: VideoItem | null = null;
  @Prop videoDescription: string = '';
  @Prop streams: StreamInfo[] = [];
  /** True only for currently live broadcasts (not VOD of past lives). */
  @Prop isLiveNow: boolean = false;
  @Prop viewCount: number = 0;
  @Prop likeCount: string = '0';
  @Prop dislikeCount: string = '';
  @Prop publishDate: string = '';
  @Prop tags: string[] = [];
  @Prop channelId: string = '';
  @Prop channelAvatarUrl: string = '';
  // 与 AVPlayer / VideoDetails 同一范式：vm 必须由组件自己 @Link（PlayerSession 单例）
  @Link vm: PlayerUiViewModel;
  @State tabArray: Array<TabItem> = initTabData();
  @State currentTabIndex: number = 0;

  @Builder
  tabBuilder(index: number, name: string | Resource) {
    SubTabBarItem({ label: name, selected: this.currentTabIndex === index, themePrimary: this.themePrimary })
  }

  build() {
    Column() {
      Tabs({ barPosition: BarPosition.Start }) {
        ForEach(this.tabArray, (item: TabItem) => {
          TabContent() {
            Column() {
              if (item.id === 0) {
                if (this.video) {
                  VideoDetails({
                    item: this.video,
                    videoDescription: this.videoDescription,
                    streams: this.streams,
                    // Extractor sets videoInfo.isLive from isLiveNow only (not isLiveContent).
                    // List badge item.isLive must not hide download on 直播回放.
                    isLiveNow: this.isLiveNow,
                    viewCount: this.viewCount,
                    likeCount: this.likeCount,
                    dislikeCount: this.dislikeCount,
                    publishDate: this.publishDate,
                    tags: this.tags,
                    channelId: this.channelId,
                    channelAvatarUrl: this.channelAvatarUrl,
                    vm: $vm,
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
      .barHeight(48)
      .onAnimationStart((index: number, targetIndex: number) => {
        this.currentTabIndex = targetIndex;
      })
      .backgroundColor($r('app.color.yourtube_bg_page'))
    }
    .width(Const.WIDTH_FULL_PERCENT)
    .height(Const.HEIGHT_FULL_PERCENT)
  }
}
