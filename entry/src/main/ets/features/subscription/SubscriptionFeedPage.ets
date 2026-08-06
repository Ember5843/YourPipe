import { AppLog } from '../../common/AppLog';
import { TITLE_BAR_HEIGHT } from '../../common/components/MediaCardTokens';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { SubscriptionFeedItem, SubscriptionFeedStore } from '../../common/SubscriptionFeedStore';
import { SubscriptionFeedService } from './SubscriptionFeedService';
import { ActionHub } from '../../common/ActionHub';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { getWideListColumnCount } from '../../common/utils/ListLayoutUtils';
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
  @StorageLink('subscriptionFeed') feedItems: SubscriptionFeedItem[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @State isRefreshing: boolean = false;
  @State newItemsCount: number = 0;
  /** 内部重入守卫：不能用 isRefreshing——Refresh 组件下拉时会经 $$ 双向绑定自行置 true */
  private refreshRunning: boolean = false;
  private feedService: SubscriptionFeedService = new SubscriptionFeedService();
  private scrollerForScroll: Scroller = new Scroller();
  private readonly GRID_SIDE_PADDING: number = 12;

  aboutToAppear(): void {
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

  private getVideoGridColumnCount(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - this.GRID_SIDE_PADDING * 2);
    if (contentWidth >= 1440) {
      return 5;
    }
    if (contentWidth >= 1080) {
      return 4;
    }
    if (contentWidth >= 760) {
      return 3;
    }
    if (contentWidth >= 520) {
      return 2;
    }
    return 1;
  }

  /** 条式列表在宽屏（平板展开/2in1/电视）下的列数 */
  private getWideListColumns(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - this.GRID_SIDE_PADDING * 2);
    return getWideListColumnCount(contentWidth);
  }

  @Builder
  private FeedContent() {
    if (this.feedItems.length === 0) {
      Scroll() {
        Column() {
          Text(this.subscriptions.length === 0
            ? $r('app.string.yt_empty_no_subs')
            : $r('app.string.yt_sub_feed_empty_hint'))
            .fontSize(14)
            .fontColor($r('app.color.yourtube_text_secondary'))
            .margin({ top: 80 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    } else if (this.uiConfig.homeLayoutMode === 'grid') {
      Scroll() {
        GridRow({
          columns: this.getVideoGridColumnCount(),
          gutter: { x: 8, y: 8 }
        }) {
          ForEach(this.feedItems, (item: SubscriptionFeedItem) => {
            GridCol({ span: 1 }) {
              VideoCardGrid({
                video: SubscriptionFeedStore.toVideoItem(item),
                actionLabel: $r('app.string.yt_action_favorite'),
                actionType: 'favorite',
                useFavoriteToggle: true
              })
            }
            .transition(customAnimationUtil.isScaleTran(item.videoId, this.uiConfig))
          }, (item: SubscriptionFeedItem) => item.videoId)
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    } else if (this.getWideListColumns() > 1) {
      Scroll() {
        GridRow({
          columns: this.getWideListColumns(),
          gutter: { x: 8, y: 4 }
        }) {
          ForEach(this.feedItems, (item: SubscriptionFeedItem) => {
            GridCol({ span: 1 }) {
              VideoCard({
                video: SubscriptionFeedStore.toVideoItem(item),
                actionLabel: $r('app.string.yt_action_favorite'),
                actionType: 'favorite',
                useFavoriteToggle: true
              })
            }
            .transition(customAnimationUtil.isScaleTran(item.videoId, this.uiConfig))
          }, (item: SubscriptionFeedItem) => item.videoId)
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    } else {
      List({ space: 4 }) {
        ForEach(this.feedItems, (item: SubscriptionFeedItem) => {
          ListItem() {
            VideoCard({
              video: SubscriptionFeedStore.toVideoItem(item),
              actionLabel: $r('app.string.yt_action_favorite'),
              actionType: 'favorite',
              useFavoriteToggle: true
            })
          }
          .transition(customAnimationUtil.isScaleTran(item.videoId, this.uiConfig))
        }, (item: SubscriptionFeedItem) => item.videoId)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .edgeEffect(EdgeEffect.Spring)
    }
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
