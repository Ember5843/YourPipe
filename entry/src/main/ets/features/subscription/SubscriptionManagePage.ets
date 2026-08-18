import { AppLog } from '../../common/AppLog';
import { TITLE_BAR_HEIGHT } from '../../common/components/MediaCardTokens';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { UIConfig } from '../../common/AppState';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { SubscriptionScrollCoordinator } from './SubscriptionScrollCoordinator';
import { AuthAccountStatus, AuthSessionManager, SearchChannelItem } from 'youtube_core';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';
import { ChannelCard } from '../../features/user/components/ChannelCard';
import { ChannelInfoService, ChannelProfile } from '../../features/user/ChannelInfoService';
import { PreferencesStore } from '../../common/PreferencesStore';
import { LocalStore } from '../../common/LocalStore';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';

const logger = AppLog.getInstance('SubscriptionManagePage');

@Component
export struct SubscriptionManagePage {
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageLink('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @State channelMap: Record<string, SearchChannelItem> = {};
  @State isRefreshing: boolean = false;
  @State syncMessage: string = '';
  /** Bumps after profile load so ChannelCard ForEach keys change and cards rebuild. */
  @State profileEpoch: number = 0;
  private channelInfoService: ChannelInfoService = new ChannelInfoService();

  private tr(res: Resource): string {
    return getContext().resourceManager.getStringSync(res.id);
  }

  aboutToAppear(): void {
    this.loadProfiles();
  }

  private isSignedIn(): boolean {
    return AuthSessionManager.getInstance()?.hasAuthForUserData() === true;
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

  private persistSubscriptions(list: SubscriptionUser[]): void {
    this.subscriptions = list;
    PreferencesStore.setString('subscriptionsJson', LocalStore.saveSubscriptions(list));
  }

  private mergeRemoteChannels(remote: SubscriptionUser[]): number {
    if (!remote || remote.length === 0) {
      return 0;
    }
    const map: Record<string, SubscriptionUser> = {};
    this.subscriptions.forEach((item) => {
      map[item.channelId] = item;
    });
    let added = 0;
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
        added += 1;
      }
    });
    const merged: SubscriptionUser[] = [];
    Object.keys(map).forEach((key) => {
      merged.push(map[key]);
    });
    this.persistSubscriptions(merged);
    return added;
  }

  private async syncCloudSubscriptions(): Promise<void> {
    if (!this.isSignedIn()) {
      this.syncMessage = this.tr($r('app.string.yt_sub_sync_sign_in_first'));
      return;
    }
    try {
      const library = FeedServiceProvider.getInstance().getUserLibraryService();
      const channels = await library.fetchSubscribedChannels();
      if (channels.length === 0) {
        this.syncMessage = this.tr($r('app.string.yt_sub_sync_cloud_empty'));
        return;
      }
      const added = this.mergeRemoteChannels(channels);
      this.syncMessage = added > 0
        ? getContext().resourceManager.getStringSync($r('app.string.yt_sub_sync_result_added').id, channels.length, added)
        : getContext().resourceManager.getStringSync($r('app.string.yt_sub_sync_result').id, channels.length);
    } catch (err) {
      logger.error('syncCloudSubscriptions failed:', JSON.stringify(err));
      this.syncMessage = this.tr($r('app.string.yt_sub_sync_failed'));
    }
  }

  private async loadProfiles(): Promise<void> {
    const nextMap: Record<string, SearchChannelItem> = {};
    const profiles: Record<string, ChannelProfile> = {};
    const names: Record<string, string> = {};
    const tasks = this.subscriptions.map(async (item, index) => {
      const channelId = (item.channelId || '').trim();
      if (!channelId) {
        return;
      }
      try {
        const profile = await this.channelInfoService.fetchChannelProfile(channelId);
        nextMap[channelId] = this.buildFromProfile(item, index, profile);
        profiles[channelId] = profile;
        names[channelId] = item.displayName;
      } catch (err) {
        logger.error('loadProfile failed:', JSON.stringify(err));
        nextMap[channelId] = this.buildPlaceholder(item, index);
      }
    });
    await Promise.all(tasks);
    this.channelMap = nextMap;
    this.profileEpoch += 1;
    // 批量合并 + 单次持久化；原先每个频道一次全量 map + JSON 序列化 + 写盘。
    this.applyProfilesToSubscriptions(profiles, names);
  }

  private async onPullRefresh(): Promise<void> {
    // Refresh($$isRefreshing) 已把 isRefreshing 置 true，这里只干活并在 finally 复位。
    this.syncMessage = '';
    const startedAt = Date.now();
    const prevCount = this.subscriptions.length;
    try {
      await this.syncCloudSubscriptions();
      await this.loadProfiles();
      logger.info(`[SubRefresh] stage=complete elapsed=${Date.now() - startedAt}ms channels=${this.subscriptions.length} prev=${prevCount}`);
    } catch (err) {
      logger.error('onPullRefresh failed:', JSON.stringify(err));
      if (this.syncMessage.length === 0) {
        this.syncMessage = this.tr($r('app.string.yt_refresh_failed'));
      }
    } finally {
      this.isRefreshing = false;
    }
  }

  private applyProfilesToSubscriptions(
    profiles: Record<string, ChannelProfile>,
    names: Record<string, string>
  ): void {
    if (Object.keys(profiles).length === 0) {
      return;
    }
    let changed = false;
    const next = this.subscriptions.map((item) => {
      const profile = profiles[item.channelId];
      if (!profile) {
        return item;
      }
      const name = names[item.channelId] || item.displayName || item.channelId;
      const subscriberText = this.resolveSubscriberText(item.subscriberText || '', profile.subscriberText || '');
      const videoCountText = this.resolveVideoCountText(item.videoCountText || '', profile.videoCountText || '');
      const merged = new SubscriptionUser(
        item.channelId,
        name,
        profile.avatarUrl || item.avatarUrl || '',
        subscriberText,
        videoCountText,
        item.description || profile.description || '',
        item.thumbnailColor || ''
      );
      if (!changed
        && (merged.displayName !== item.displayName || merged.avatarUrl !== item.avatarUrl
          || merged.subscriberText !== item.subscriberText || merged.videoCountText !== item.videoCountText
          || merged.description !== item.description)) {
        changed = true;
      }
      return merged;
    });
    // 无实际变化时不触发全量持久化和 @StorageLink 刷新
    if (changed) {
      this.persistSubscriptions(next);
    }
  }

  build() {
    // 顶栏避让放在 Refresh 外侧，加载圈从标题栏下方出现（与内容区对齐）。
    Column() {
      Refresh({ refreshing: $$this.isRefreshing }) {
        List({ scroller: SubscriptionScrollCoordinator.scroller, space: 4 }) {
          ListItem() {
            Column() {
              if (this.syncMessage.length > 0) {
                Text(this.syncMessage)
                  .fontSize(12)
                  .fontColor($r('app.color.yourtube_text_hint'))
                  .width('100%')
              } else if (this.isSignedIn()) {
                Text($r('app.string.yt_sub_pull_to_sync'))
                  .fontSize(12)
                  .fontColor($r('app.color.yourtube_text_hint'))
                  .width('100%')
              }
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ top: 8, bottom: 12 })
            .padding({ left: 16, right: 16 })
            .width('100%')
          }

          if (this.subscriptions.length === 0) {
            ListItem() {
              Column() {
                Text($r('app.string.yt_empty_no_subs'))
                  .fontSize(14)
                  .fontColor($r('app.color.yourtube_text_secondary'))
                  .margin({ top: 40 })
                Text(this.isSignedIn()
                  ? $r('app.string.yt_sub_signed_in_pull_hint')
                  : $r('app.string.yt_empty_subs_hint_alt'))
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
              .transition(customAnimationUtil.isScaleTran(`${this.profileEpoch}_${item.channelId}`, this.uiConfig))
            }, (item: SubscriptionUser) => `${this.profileEpoch}_${item.channelId}`)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 12, right: 12, bottom: this.safeAreaBottom + 72 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
      .layoutWeight(1)
      .width('100%')
      .pullToRefresh(true)
      .refreshOffset(64)
      .onRefreshing(() => {
        this.onPullRefresh();
      })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeAreaTop + TITLE_BAR_HEIGHT })
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
