import { AppLog } from '../../common/AppLog';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { SearchChannelItem } from 'youtube_core';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';
import { ChannelCard } from '../../features/user/components/ChannelCard';
import { ChannelInfoService, ChannelProfile } from '../../features/user/ChannelInfoService';
import { PreferencesStore } from '../../common/PreferencesStore';
import { LocalStore } from '../../common/LocalStore';

const logger = AppLog.getInstance('SubscriptionManagePage');

@Component
export struct SubscriptionManagePage {
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @State channelMap: Record<string, SearchChannelItem> = {};
  private channelInfoService: ChannelInfoService = new ChannelInfoService();

  aboutToAppear(): void {
    this.loadProfiles();
  }

  private buildPlaceholder(item: SubscriptionUser, index: number): SearchChannelItem {
    const channelId = (item.channelId || '').trim();
    const name = item.displayName && item.displayName.length > 0 ? item.displayName : (channelId || 'Unknown');
    const placeholder = item.thumbnailColor && item.thumbnailColor.length > 0
      ? item.thumbnailColor
      : ThumbnailPlaceholder.pickColor(channelId || name, index);
    return new SearchChannelItem(
      index,
      channelId,
      name,
      item.subscriberText || '',
      item.videoCountText || '',
      item.avatarUrl || '',
      item.description || '',
      placeholder
    );
  }

  private buildFromProfile(item: SubscriptionUser, index: number, profile: ChannelProfile): SearchChannelItem {
    const channelId = (item.channelId || '').trim();
    const name = profile.name && profile.name.length > 0
      ? profile.name
      : (item.displayName && item.displayName.length > 0 ? item.displayName : channelId || 'Unknown');
    const placeholder = item.thumbnailColor && item.thumbnailColor.length > 0
      ? item.thumbnailColor
      : ThumbnailPlaceholder.pickColor(channelId || name, index);
    return new SearchChannelItem(
      index,
      channelId,
      name,
      this.resolveSubscriberText(item.subscriberText || '', profile.subscriberText || ''),
      this.resolveVideoCountText(item.videoCountText || '', profile.videoCountText || ''),
      profile.avatarUrl || item.avatarUrl || '',
      item.description || profile.description || '',
      placeholder
    );
  }

  private resolveSubscriberText(stored: string, latest: string): string {
    const trimmed = (latest || '').trim();
    if (trimmed.length > 0 && !trimmed.startsWith('@')) {
      return trimmed;
    }
    return (stored || '').trim();
  }

  private resolveVideoCountText(stored: string, latest: string): string {
    const storedTrim = (stored || '').trim();
    if (storedTrim.startsWith('@')) {
      return storedTrim;
    }
    const latestTrim = (latest || '').trim();
    if (latestTrim.length > 0) {
      return latestTrim;
    }
    return storedTrim;
  }

  private async loadProfiles(): Promise<void> {
    const nextMap: Record<string, SearchChannelItem> = {};
    const tasks = this.subscriptions.map(async (item, index) => {
      const channelId = (item.channelId || '').trim();
      if (!channelId) {
        return;
      }
      try {
        const profile = await this.channelInfoService.fetchChannelProfile(channelId);
        nextMap[channelId] = this.buildFromProfile(item, index, profile);
        this.updateSubscriptionProfile(channelId, item.displayName, profile);
      } catch (err) {
        logger.error('loadProfile failed:', JSON.stringify(err));
        nextMap[channelId] = this.buildPlaceholder(item, index);
      }
    });
    await Promise.all(tasks);
    this.channelMap = nextMap;
  }

  private updateSubscriptionProfile(channelId: string, displayName: string, profile: ChannelProfile): void {
    if (!channelId) {
      return;
    }
    const next = this.subscriptions.map((item) => {
      if (item.channelId !== channelId) {
        return item;
      }
      const name = displayName || item.displayName || channelId;
      const subscriberText = this.resolveSubscriberText(item.subscriberText || '', profile.subscriberText || '');
      const videoCountText = this.resolveVideoCountText(item.videoCountText || '', profile.videoCountText || '');
      return new SubscriptionUser(
        channelId,
        name,
        profile.avatarUrl || item.avatarUrl || '',
        subscriberText,
        videoCountText,
        item.description || profile.description || '',
        item.thumbnailColor || ''
      );
    });
    this.subscriptions = next;
    PreferencesStore.setString('subscriptionsJson', LocalStore.saveSubscriptions(this.subscriptions));
  }

  build() {
    List({ space: 4 }) {
      ListItem() {
        Text($r('app.string.yt_sub_manage_title'))
          .fontSize(20)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ top: 16, bottom: 12 })
          .padding({ left: 16, right: 16 })
          .width('100%')
      }

      if (this.subscriptions.length === 0) {
        ListItem() {
          Column() {
            Text($r('app.string.yt_empty_no_subs'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .margin({ top: 20 })
            Text($r('app.string.yt_empty_subs_hint_alt'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 24 })
        }
      } else {
        ForEach(this.subscriptions, (item: SubscriptionUser, index: number) => {
          ListItem() {
            ChannelCard({
              channel: this.channelMap[item.channelId]
                ? this.channelMap[item.channelId]
                : this.buildPlaceholder(item, index),
              typeLabel: $r('app.string.yt_label_user'),
              showDescription: true,
              forceActionLabel: $r('app.string.yt_action_unsubscribe')
            })
          }
        }, (item: SubscriptionUser) => item.channelId)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: this.safeAreaTop + 56, bottom: this.safeAreaBottom + 72 })
    .edgeEffect(EdgeEffect.Spring)
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
