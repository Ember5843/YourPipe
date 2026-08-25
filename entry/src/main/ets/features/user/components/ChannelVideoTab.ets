import { UIConfig } from '../../../common/AppState';
import { VideoItem } from 'youtube_core';
import { VideoCard } from '../../../common/components/VideoCard';
import { VideoCardGrid } from '../../../common/components/VideoCardGrid';
import { MediaFeedItemSlot, MediaVideoFeed } from '../../../common/components/MediaVideoFeed';
import { FeedDataSource } from '../../../common/model/FeedDataSource';
import {
  getFeedContentWidthVp,
  getVideoGridColumnCount,
  getWideListColumnCount
} from '../../../common/utils/ListLayoutUtils';

/**
 * 频道页视频类 Tab（视频 / Shorts / 直播共用）。
 * loading / error / empty / grid / 宽列 / 单列骨架收敛进 MediaVideoFeed
 * （Grid / List + LazyForEach，触底加载更多）；状态由父级 UserPage 通过
 * @Prop 单向注入，list 每次整体重赋值经 @Watch 同步进 feedSource。
 */
@Component
export struct ChannelVideoTab {
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;

  @Prop @Watch('syncFeedSource') list: VideoItem[] = [];
  @Prop isLoading: boolean = false;
  @Prop isLoadingMore: boolean = false;
  @Prop errorMessage: ResourceStr = '';
  @Prop emptyText: Resource = $r('app.string.yt_empty_no_videos');
  scroller: Scroller = new Scroller();
  onLoadMore: () => void = () => {};

  private feedSource: FeedDataSource = new FeedDataSource();

  aboutToAppear(): void {
    this.syncFeedSource();
  }

  private syncFeedSource(): void {
    this.feedSource.setData(this.list, ChannelVideoTab.keyOfVideo);
  }

  private static keyOfVideo(item: Object): string {
    const video = item as VideoItem;
    return video.videoId || video.id.toString();
  }

  private gridColumns(): number {
    return getVideoGridColumnCount(getFeedContentWidthVp(this.getUIContext(), this.deviceWidth));
  }

  /** 条式列表在宽屏（平板展开/2in1/电视）下的列数 */
  private wideListColumns(): number {
    return getWideListColumnCount(getFeedContentWidthVp(this.getUIContext(), this.deviceWidth));
  }

  @LocalBuilder
  VideoGridCard(slot: MediaFeedItemSlot) {
    VideoCardGrid({
      video: slot.item as VideoItem,
      actionLabel: $r('app.string.yt_action_favorite'),
      actionType: 'favorite',
      showAuthor: false,
      useFavoriteToggle: true
    })
  }

  @LocalBuilder
  VideoListCard(slot: MediaFeedItemSlot) {
    VideoCard({
      video: slot.item as VideoItem,
      actionLabel: $r('app.string.yt_action_favorite'),
      actionType: 'favorite',
      showAuthor: false,
      useFavoriteToggle: true
    })
  }

  build() {
    MediaVideoFeed({
      dataSource: this.feedSource,
      gridScroller: this.scroller,
      listScroller: this.scroller,
      nestedScrollParentFirst: true,
      itemKey: ChannelVideoTab.keyOfVideo,
      gridItemBuilder: this.VideoGridCard,
      itemBuilder: this.VideoListCard,
      onReachEnd: () => {
        this.onLoadMore();
      },
      params: {
        layoutPreference: this.uiConfig.homeLayoutMode,
        gridColumns: this.gridColumns(),
        listColumns: this.wideListColumns(),
        isLoading: this.isLoading,
        isLoadingMore: this.isLoadingMore,
        errorMessage: this.errorMessage,
        emptyText: this.emptyText,
        hasHeader: false,
        headerHorizontalBleed: 0,
        gridContentPadding: { left: 12, right: 12, top: 8, bottom: 12 },
        listContentPadding: { left: 12, right: 12, top: 8, bottom: 12 },
        listContentEndOffset: 0,
        stateScrollable: false,
        useLayoutWeight: false
      }
    })
  }
}
