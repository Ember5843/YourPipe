import { CommonConstants as Const, PlayerUiViewModel, StreamInfo } from 'mediaservice';
import { VideoItem } from 'youtube_core';
import { initTabData } from '../../../common/model/TabViewModel';
import { TabItem } from '../../../common/model/TabItem';
import { SubTabBarItem } from '../../../common/components/SubTabBar';
import { VideoDetails } from './VideoDetails';
import { CommentNavWrapper } from './CommentNavWrapper';
import { PlayQueueList } from './PlayQueueList';
import { LiveChatPanel } from './LiveChatPanel';

const LIVE_CHAT_TAB: TabItem = new TabItem(3, $r('app.string.yt_tab_live_chat'));

/**
 * 播放器信息面板（简介 / 评论 / 播放列表三 Tab）。
 * 两处复用：PlayerPage 内联（竖屏下方 / 横屏侧栏）与全屏态的信息 sheet。
 */
@Component
export struct PlayerInfoPanel {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop @Watch('onTabSetChanged') video: VideoItem | null = null;
  @Prop videoDescription: string = '';
  @Prop streams: StreamInfo[] = [];
  /** True only for currently live broadcasts (not VOD of past lives). */
  @Prop @Watch('onTabSetChanged') isLiveNow: boolean = false;
  /** Past live broadcast: show chat replay tab synced to playback position. */
  @Prop @Watch('onTabSetChanged') isLiveReplay: boolean = false;
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
  @StorageLink('isLocalMode') @Watch('onTabSetChanged') isLocalMode: boolean = false;

  private lastTabSetKey: string = '';

  /**
   * Rebuild Tabs as a whole when the tab set or video changes (stale TabBar items otherwise).
   */
  private tabSetKey(): string {
    const ids = this.visibleTabs().map((item: TabItem) => item.id).join('_');
    return `${this.video?.videoId || ''}|${ids}`;
  }

  /**
   * 换视频 / 进入本地模式 / 直播状态变化后 Tab 集合可能变短：
   * 当前索引越界会显示空白内容，统一收回「简介」。
   */
  private onTabSetChanged(): void {
    const key = this.tabSetKey();
    if (key !== this.lastTabSetKey) {
      this.lastTabSetKey = key;
      this.currentTabIndex = 0;
    }
    const count = this.visibleTabs().length;
    if (this.currentTabIndex >= count) {
      this.currentTabIndex = 0;
    }
  }

  /**
   * 本地文件没有评论 / 聊天 Tab；播放队列保留（下载库整份入队，可顺放）。
   * 正在直播的视频追加只读「聊天」Tab（点播 / 回放不显示）。
   */
  private visibleTabs(): Array<TabItem> {
    if (this.isLocalMode) {
      return this.tabArray.filter((item: TabItem) => item.id !== 1);
    }
    if (this.isLiveNow || this.isLiveReplay) {
      const tabs = this.tabArray.filter((item: TabItem) => item.id !== LIVE_CHAT_TAB.id);
      tabs.push(LIVE_CHAT_TAB);
      return tabs;
    }
    return this.tabArray;
  }

  @Builder
  tabBuilder(index: number, name: string | Resource) {
    SubTabBarItem({ label: name, selected: this.currentTabIndex === index, themePrimary: this.themePrimary })
  }

  build() {
    Column() {
      ForEach([this.tabSetKey()], (_key: string) => {
      Tabs({ barPosition: BarPosition.Start }) {
        ForEach(this.visibleTabs(), (item: TabItem, index: number) => {
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
              } else if (item.id === 3) {
                LiveChatPanel({
                  videoId: this.video?.videoId || '',
                  active: this.currentTabIndex === index, replay: !this.isLiveNow && this.isLiveReplay, vm: $vm
                })
              } else {
                PlayQueueList()
              }
            }
            .width(Const.WIDTH_FULL_PERCENT)
            .height(Const.HEIGHT_FULL_PERCENT)
          // tabBar 的高亮按「位置索引」比较，TabContent 的内容按 tab id 分派 ——
          // 本地模式过滤掉评论 tab 后 id≠位置，必须用 index，否则选中态错位。
          }.tabBar(this.tabBuilder(index, item.name))
        }, (item: TabItem) => `tab_${item.id}`)
      }
      .borderRadius({ topLeft: 16, topRight: 16 })
      .barMode(BarMode.Fixed)
      .barWidth(Const.WIDTH_FULL_PERCENT)
      .barHeight(48)
      .onAnimationStart((_index: number, targetIndex: number) => {
        this.currentTabIndex = targetIndex;
      })
      .backgroundColor($r('app.color.yourtube_bg_page'))
      }, (key: string) => key)
    }
    .width(Const.WIDTH_FULL_PERCENT)
    .height(Const.HEIGHT_FULL_PERCENT)
  }
}
