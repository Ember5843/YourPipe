import { AppLog } from './AppLog';
import { SubscriptionUser } from './SubscriptionModel';
import { VideoItem } from 'youtube_core';
import { PlaylistItem, StoredLocalQueue } from './PlaylistModel';
import { PreferencesStore } from './PreferencesStore';
import { SubscriptionFeedStore } from './SubscriptionFeedStore';

const logger = AppLog.getInstance('LocalStore');

export class LocalStore {
  static loadSubscriptions(json: string): SubscriptionUser[] {
    if (!json || json.length === 0) {
      return [];
    }
    try {
      const raw = JSON.parse(json) as Array<Record<string, Object>>;
      return raw.map((item) => new SubscriptionUser(
        LocalStore.asString(item['channelId']),
        LocalStore.asString(item['displayName']),
        LocalStore.asString(item['avatarUrl']),
        LocalStore.asString(item['subscriberText']),
        LocalStore.asString(item['videoCountText']),
        LocalStore.asString(item['description']),
        LocalStore.asString(item['thumbnailColor'])
      ));
    } catch (err) {
      logger.error('Failed to parse subscriptions:', JSON.stringify(err));
      return [];
    }
  }

  static saveSubscriptions(subscriptions: SubscriptionUser[]): string {
    return JSON.stringify(subscriptions);
  }

  static loadFavorites(json: string): VideoItem[] {
    if (!json || json.length === 0) {
      return [];
    }
    try {
      const raw: VideoItem[] = JSON.parse(json);
      return raw.map((item) => new VideoItem(
        item.id || 0,
        item.videoId || '',
        item.title || '',
        item.author || '',
        item.viewCount || '',
        item.thumbnailUrl || '',
        typeof item.isLive === 'boolean' ? item.isLive : false,
        item.thumbnailColor || '#CCCCCC',
        item.channelId || '',
        item.channelAvatarUrl || '',
        item.channelHandle || '',
        item.videoDescription || ''
      ));
    } catch (err) {
      logger.error('Failed to parse favorites:', JSON.stringify(err));
      return [];
    }
  }

  static saveFavorites(favorites: VideoItem[]): string {
    return JSON.stringify(favorites);
  }

  static loadPlaylists(json: string): PlaylistItem[] {
    if (!json || json.length === 0) {
      return [];
    }
    try {
      const raw = JSON.parse(json) as Array<Record<string, Object>>;
      return raw.map((item) => {
        const playlistId = LocalStore.asString(item['playlistId']);
        const title = LocalStore.asString(item['title']) || LocalStore.asString(item['name']);
        const coverUrl = LocalStore.asString(item['coverUrl']);
        return new PlaylistItem(playlistId, title, coverUrl);
      });
    } catch (err) {
      logger.error('Failed to parse playlists:', JSON.stringify(err));
      return [];
    }
  }

  static savePlaylists(playlists: PlaylistItem[]): string {
    return JSON.stringify(playlists);
  }

  static loadLocalQueues(json: string): StoredLocalQueue[] {
    if (!json || json.length === 0) {
      return [];
    }
    try {
      const raw = JSON.parse(json) as Array<Record<string, Object>>;
      return raw.map((item: Record<string, Object>): StoredLocalQueue => ({
        id: LocalStore.asString(item['id']),
        name: LocalStore.asString(item['name']),
        videos: (item['videos'] as Array<Record<string, Object>> || []).map((v) =>
          new VideoItem(
            v['id'] as number || 0,
            LocalStore.asString(v['videoId']),
            LocalStore.asString(v['title']),
            LocalStore.asString(v['author']),
            LocalStore.asString(v['viewCount']),
            LocalStore.asString(v['thumbnailUrl']),
            typeof v['isLive'] === 'boolean' ? v['isLive'] as boolean : false,
            LocalStore.asString(v['thumbnailColor']) || '#CCCCCC',
            LocalStore.asString(v['channelId']),
            LocalStore.asString(v['channelAvatarUrl']),
            LocalStore.asString(v['channelHandle']),
            LocalStore.asString(v['videoDescription']),
            (v['videoDescriptionError'] as string) || null
          )
        ),
        createdAt: item['createdAt'] as number || 0,
      }));
    } catch (err) {
      logger.error('Failed to parse local queues:', JSON.stringify(err));
      return [];
    }
  }

  static saveLocalQueues(queues: StoredLocalQueue[]): string {
    return JSON.stringify(queues);
  }

  /** Preferences → AppStorage('subscriptions')；@StorageLink 消费方随 AppStorage 写入自动刷新 */
  static loadSubscriptionsToAppStorage(): void {
    const stored = PreferencesStore.getString('subscriptionsJson', '[]');
    AppStorage.setOrCreate('subscriptions', LocalStore.loadSubscriptions(stored));
  }

  /** AppStorage('subscriptions') → Preferences；调用前需已通过 @StorageLink 写入新值 */
  static persistSubscriptions(): void {
    const subscriptions = AppStorage.get<SubscriptionUser[]>('subscriptions') ?? [];
    PreferencesStore.setString('subscriptionsJson', LocalStore.saveSubscriptions(subscriptions));
    // 订阅列表变化（增/删/云端合并）→ 动态缓存清零，下次进入动态页重新拉取
    SubscriptionFeedStore.clear();
  }

  /** Preferences → AppStorage('favorites') */
  static loadFavoritesToAppStorage(): void {
    const stored = PreferencesStore.getString('favoritesJson', '[]');
    AppStorage.setOrCreate('favorites', LocalStore.loadFavorites(stored));
  }

  /** AppStorage('favorites') → Preferences */
  static persistFavorites(): void {
    const favorites = AppStorage.get<VideoItem[]>('favorites') ?? [];
    PreferencesStore.setString('favoritesJson', LocalStore.saveFavorites(favorites));
  }

  /** Preferences → AppStorage('playlists') */
  static loadPlaylistsToAppStorage(): void {
    const stored = PreferencesStore.getString('playlistsJson', '[]');
    AppStorage.setOrCreate('playlists', LocalStore.loadPlaylists(stored));
  }

  /** AppStorage('playlists') → Preferences */
  static persistPlaylists(): void {
    const playlists = AppStorage.get<PlaylistItem[]>('playlists') ?? [];
    PreferencesStore.setString('playlistsJson', LocalStore.savePlaylists(playlists));
  }

  /** Preferences → AppStorage('localQueues') */
  static loadLocalQueuesToAppStorage(): void {
    const stored = PreferencesStore.getString('localQueuesJson', '[]');
    AppStorage.setOrCreate('localQueues', LocalStore.loadLocalQueues(stored));
  }

  /** AppStorage('localQueues') → Preferences */
  static persistLocalQueues(): void {
    const queues = AppStorage.get<StoredLocalQueue[]>('localQueues') ?? [];
    PreferencesStore.setString('localQueuesJson', LocalStore.saveLocalQueues(queues));
  }

  private static asString(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }
}
