import { AppLog } from './AppLog';
import { SubscriptionUser } from './SubscriptionModel';
import { VideoItem } from 'youtube_core';
import { PlaylistItem } from './PlaylistModel';

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

  private static asString(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }
}
