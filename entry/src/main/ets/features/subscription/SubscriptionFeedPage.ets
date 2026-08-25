import { AppLog } from '../../common/AppLog';
import { TITLE_BAR_HEIGHT } from '../../common/components/MediaCardTokens';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { SubscriptionFeedItem, SubscriptionFeedStore } from '../../common/SubscriptionFeedStore';
import { SubscriptionFeedService } from './SubscriptionFeedService';
import { ActionHub } from '../../common/ActionHub';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { UIConfig } from '../../common/AppState';
import { MediaFeedItemSlot, MediaVideoFeed } from '../../common/components/MediaVideoFeed';
import { FeedDataSource } from '../../common/model/FeedDataSource';
import { getFeedContentWidthVp, getVideoGridColumnCount, getWideListColumnCount } from '../../common/utils/ListLayoutUtils';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildYourTubeTitleBar } from '../../common/components/HdsTitleBar';

const logger = AppLog.getInstance('SubscriptionFeedPage');

@Component
export struct SubscriptionFeedPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageLink('subscriptionFeed') @Watch('syncFeedSource') feedItems: SubscriptionFeedItem[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @State isRefreshing: boolean = false;
  @State newItemsCount: number = 0;
  /** 内部重入守卫：不能用 isRefreshing——Refresh 组件下拉时会经 $$ 双向绑定自行置 true */
  private refreshRunning: boolean = false;
  private feedService: SubscriptionFeedService = new SubscriptionFeedService();
  private scrollerForScroll: Scroller = new Scroller();
  /** 订阅流的 LazyForEach 数据源（feedItems 重赋值经 @Watch 同步） */
  private feedSource: FeedDataSource = new FeedDataSource();

  aboutToAppear(): void {
    this.syncFeedSource();
    this.computeNewItemsCount();
    if (this.feedService.isStale()) {
      this.refreshFeed(false);
    }
  }

  private computeNewItemsCount(): void {
    const anchor = SubscriptionFeedStore.getLastRefreshAnchorMs();
    if (anchor <= 0) {
      this.newItemsCount = 0;
    } else {
      this.newItemsCount = this.feedItems.filter((it) =>
        (it.uploadDateMs > 0 ? it.uploadDateMs : it.firstSeenMs) > anchor).length;
    }
    SubscriptionFeedStore.markRefreshAnchor();
  }

  private async refreshFeed(force: boolean): Promise<void> {
    if (this.refreshRunning) {
      return;
    }
    this.refreshRunning = true;
    this.isRefreshing = true;
    try {
      const result = await this.feedService.refreshFeed(this.subscriptions, force);
      logger.info(`refresh done source=${result.source} added=${result.addedCount} failed=${result.failedChannels.length}`);
    } catch (err) {
      logger.error('refreshFeed failed:', JSON.stringify(err));
    } finally {
      this.isRefreshing = false;
      this.refreshRunning = false;
    }
  }

  private syncFeedSource(): void {
    this.feedSource.setData(this.feedItems, SubscriptionFeedPage.keyOfFeedItem);
  }

  private static keyOfFeedItem(item: Object): string {
    return (item as SubscriptionFeedItem).videoId;
  }

  private gridColumns(): number {
    return getVideoGridColumnCount(getFeedContentWidthVp(this.getUIContext(), this.deviceWidth));
  }

  /** 条式列表在宽屏（平板展开/2in1/电视）下的列数 */
  private getWideListColumns(): number {
    return getWideListColumnCount(getFeedContentWidthVp(this.getUIContext(), this.deviceWidth));
  }

  @LocalBuilder
  private FeedGridCard(slot: MediaFeedItemSlot) {
    VideoCardGrid({
      video: SubscriptionFeedStore.toVideoItem(slot.item as SubscriptionFeedItem),
      actionLabel: $r('app.string.yt_action_favorite'),
      actionType: 'favorite',
      useFavoriteToggle: true
    })
  }

  @LocalBuilder
  private FeedListCard(slot: MediaFeedItemSlot) {
    VideoCard({
      video: SubscriptionFeedStore.toVideoItem(slot.item as SubscriptionFeedItem),
      actionLabel: $r('app.string.yt_action_favorite'),
      actionType: 'favorite',
      useFavoriteToggle: true
    })
  }

  @LocalBuilder
  private FeedEmpty() {
    Text(this.subscriptions.length === 0
      ? $r('app.string.yt_empty_no_subs')
      : $r('app.string.yt_sub_feed_empty_hint'))
      .fontSize(14)
      .fontColor($r('app.color.yourtube_text_secondary'))
      .margin({ top: 80 })
  }

  /**
   * 骨架收敛进 MediaVideoFeed（Grid / 宽列 / 单列 List + LazyForEach）。
   * 订阅流无分页（无 onReachEnd / 加载更多）；空态保持可滚动以支持下拉刷新。
   */
  @Builder
  private FeedContent() {
    MediaVideoFeed({
      dataSource: this.feedSource,
      gridScroller: this.scrollerForScroll,
      listScroller: this.scrollerForScroll,
      itemKey: SubscriptionFeedPage.keyOfFeedItem,
      gridItemBuilder: this.FeedGridCard,
      itemBuilder: this.FeedListCard,
      emptyBuilder: this.FeedEmpty,
      params: {
        layoutPreference: this.uiConfig.homeLayoutMode,
        gridColumns: this.gridColumns(),
        listColumns: this.getWideListColumns(),
        isLoading: false,
        isLoadingMore: false,
        errorMessage: '',
        emptyText: '',
        hasHeader: false,
        headerHorizontalBleed: 0,
        gridContentPadding: { left: 12, right: 12, top: 4, bottom: 4 },
        listContentPadding: { left: 12, right: 12, top: 4, bottom: 4 },
        listContentEndOffset: 0,
        stateScrollable: true,
        useLayoutWeight: false
      }
    })
  }

  build() {
    HdsNavDestination() {
      Column() {
        Row().width('100%').height(this.safeAreaTop + TITLE_BAR_HEIGHT)
        if (this.newItemsCount > 0) {
          Text(getContext().resourceManager.getStringSync($r('app.string.yt_sub_feed_new_items').id, this.newItemsCount))
            .fontSize(12)
            .fontColor(this.themePrimary)
            .margin({ left: 16, bottom: 4 })
        }
        Refresh({ refreshing: $$this.isRefreshing }) {
          this.FeedContent()
        }
        .layoutWeight(1)
        .width('100%')
        .pullToRefresh(true)
        .refreshOffset(64)
        .onRefreshing(() => {
          this.refreshFeed(true);
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.yourtube_bg_page'))
      .padding({ bottom: this.safeAreaBottom })
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar(buildYourTubeTitleBar({
      title: $r('app.string.yt_sub_feed_title'),
      onBack: () => {
        this.actionHub.closePage();
      },
      immersiveShadow: true,
      avoidLayoutSafeArea: true,
      menus: []
    }))
    .bindToScrollable([this.scrollerForScroll])
    .onBackPressed(() => {
      this.actionHub.closePage();
      return true;
    })
  }
}
