import { AppLog } from '../../common/AppLog';
import { AuthAccountStatus, AuthSessionManager, VideoItem } from 'youtube_core';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { SubscriptionFeedService } from '../../features/subscription/SubscriptionFeedService';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { UIConfig } from '../../common/AppState';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { LocalStore } from '../../common/LocalStore';
import { PreferencesStore } from '../../common/PreferencesStore';
import { customAnimationUtil } from '../../common/AnimationUtil';

const logger = AppLog.getInstance('SubscriptionsPage');

@Component
export struct SubscriptionsPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @StorageLink('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();
  @State videoList: VideoItem[] = [];
  @State isRefreshing: boolean = false;
  @State errorMessage: string = '';
  @State feedSourceLabel: string = '';
  private feedService: SubscriptionFeedService = new SubscriptionFeedService();
  private readonly GRID_SIDE_PADDING: number = 12;

  aboutToAppear() {
    this.loadFeed();
  }

  private isSignedIn(): boolean {
    return AuthSessionManager.getInstance()?.isAuthEnabledForUserData() === true;
  }

  private syncSubscriptionsToStorage(list: SubscriptionUser[]): void {
    this.subscriptions = list;
    PreferencesStore.setString('subscriptionsJson', LocalStore.saveSubscriptions(list));
  }

  private mergeSubscribedChannels(remote: SubscriptionUser[]): void {
    if (!remote || remote.length === 0) {
      return;
    }
    const map: Record<string, SubscriptionUser> = {};
    this.subscriptions.forEach((item) => {
      map[item.channelId] = item;
    });
    remote.forEach((item) => {
      const id = (item.channelId || '').trim();
      if (!id) {
        return;
      }
      const prev = map[id];
      if (prev) {
        map[id] = new SubscriptionUser(
          id,
          item.displayName || prev.displayName,
          item.avatarUrl || prev.avatarUrl,
          item.subscriberText || prev.subscriberText,
          item.videoCountText || prev.videoCountText,
          item.description || prev.description,
          item.thumbnailColor || prev.thumbnailColor
        );
      } else {
        map[id] = item;
      }
    });
    const merged: SubscriptionUser[] = [];
    Object.keys(map).forEach((key) => {
      merged.push(map[key]);
    });
    this.syncSubscriptionsToStorage(merged);
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
    this.isRefreshing = true;
    this.errorMessage = '';
    try {
      if (this.isSignedIn()) {
        const library = FeedServiceProvider.getInstance().getUserLibraryService();
        try {
          const channels = await library.fetchSubscribedChannels();
          this.mergeSubscribedChannels(channels);
        } catch (channelErr) {
          logger.error('fetchSubscribedChannels failed:', JSON.stringify(channelErr));
        }

        try {
          const page = await library.fetchSubscriptionsFeed(1);
          if (page.items.length > 0) {
            this.videoList = page.items;
            this.feedSourceLabel = getContext().resourceManager.getStringSync($r('app.string.yt_sub_feed_youtube').id);
            return;
          }
        } catch (feedErr) {
          logger.error('fetchSubscriptionsFeed failed:', JSON.stringify(feedErr));
        }
      }

      if (!this.subscriptions || this.subscriptions.length === 0) {
        this.videoList = [];
        this.feedSourceLabel = '';
        return;
      }
      this.videoList = await this.feedService.fetchSubscriptionsFeed(this.subscriptions);
      this.feedSourceLabel = this.isSignedIn() ? $r('app.string.yt_subscriptions_feed_local') : '';
    } catch (err) {
      logger.error('loadFeed failed:', JSON.stringify(err));
      this.errorMessage = $r('app.string.yt_error_load_subs');
    } finally {
      this.isRefreshing = false;
    }
  }

  private isEmpty(): boolean {
    return this.subscriptions.length === 0 && this.videoList.length === 0;
  }

  build() {
    Column() {
      if (this.feedSourceLabel.length > 0) {
        Text(this.feedSourceLabel)
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_hint'))
          .margin({ left: 16, top: 8, bottom: 4 })
      }
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor(this.themePrimary)
          .margin({ left: 16, top: 8, bottom: 4 })
      }

      Refresh({ refreshing: $$this.isRefreshing }) {
        if (this.isEmpty()) {
          Scroll() {
            Column() {
              Text($r('app.string.yt_empty_no_subs'))
                .fontSize(14)
                .fontColor($r('app.color.yourtube_text_secondary'))
                .margin({ top: 80 })
              Text(this.isSignedIn()
                ? $r('app.string.yt_subs_sync_signed_in_hint')
                : $r('app.string.yt_empty_subs_hint'))
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .margin({ top: 6 })
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
              ForEach(this.videoList, (item: VideoItem) => {
                GridCol({ span: 1 }) {
                  VideoCardGrid({
                    video: item,
                    actionLabel: $r('app.string.yt_action_favorite'),
                    actionType: 'favorite',
                    useFavoriteToggle: true
                  })
                }
                .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
              }, (item: VideoItem) => item.id.toString())
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
            ForEach(this.videoList, (item: VideoItem) => {
              ListItem() {
                VideoCard({
                  video: item,
                  actionLabel: $r('app.string.yt_action_favorite'),
                  actionType: 'favorite',
                  useFavoriteToggle: true
                })
              }
              .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
            }, (item: VideoItem) => item.id.toString())
          }
          .width('100%')
          .height('100%')
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .pullToRefresh(true)
      .refreshOffset(64)
      .onRefreshing(() => {
        this.loadFeed();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
