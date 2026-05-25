import { AppLog } from '../../common/AppLog';
import { VideoItem } from 'youtube_core';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { SubscriptionFeedService } from '../../features/subscription/SubscriptionFeedService';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { UIConfig } from '../../common/AppState';

const logger = AppLog.getInstance('SubscriptionsPage');

@Component
export struct SubscriptionsPage {
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @State videoList: VideoItem[] = [];
  @State isRefreshing: boolean = false;
  @State errorMessage: string = '';
  private feedService: SubscriptionFeedService = new SubscriptionFeedService();
  private readonly GRID_SIDE_PADDING: number = 12;

  aboutToAppear() {
    this.loadFeed();
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

  private async loadFeed(): Promise<void> {
    if (!this.subscriptions || this.subscriptions.length === 0) {
      this.videoList = [];
      return;
    }
    this.isRefreshing = true;
    try {
      this.videoList = await this.feedService.fetchSubscriptionsFeed(this.subscriptions);
      this.errorMessage = '';
    } catch (err) {
      logger.error('loadFeed failed:', JSON.stringify(err));
      this.errorMessage = $r('app.string.yt_error_load_subs');
    } finally {
      this.isRefreshing = false;
    }
  }

  build() {
    Column() {
      if (this.subscriptions.length === 0) {
        Column() {
          Text($r('app.string.yt_empty_no_subs'))
            .fontSize(14)
            .fontColor($r('app.color.yourtube_text_secondary'))
            .margin({ top: 20 })
          Text($r('app.string.yt_empty_subs_hint'))
            .fontSize(12)
            .fontColor($r('app.color.yourtube_text_hint'))
            .margin({ top: 6 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      } else {
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(12)
            .fontColor($r('app.color.yourtube_theme_primary'))
            .margin({ left: 16, top: 8 })
        }
        Refresh({ refreshing: $$this.isRefreshing }) {
          if (this.uiConfig.homeLayoutMode === 'grid') {
            Scroll() {
              GridRow({
                columns: this.getVideoGridColumnCount(),
                gutter: { x: 8, y: 8 }
              }) {
                ForEach(this.videoList, (item: VideoItem) => {
                  GridCol({ span: 1 }) {
                    VideoCardGrid({
                      video: item,
                      actionLabel: $r('app.string.yt_action_favorite'),
                      actionType: 'favorite',
                      useFavoriteToggle: true
                    })
                  }
                }, (item: VideoItem) => item.id.toString())
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .edgeEffect(EdgeEffect.Spring)
          } else {
            List({ space: 4 }) {
              ForEach(this.videoList, (item: VideoItem) => {
                ListItem() {
                  VideoCard({
                    video: item,
                    actionLabel: $r('app.string.yt_action_favorite'),
                    actionType: 'favorite',
                    useFavoriteToggle: true
                  })
                }
              }, (item: VideoItem) => item.id.toString())
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .pullToRefresh(true)
        .refreshOffset(64)
        .onRefreshing(() => {
          this.loadFeed();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
