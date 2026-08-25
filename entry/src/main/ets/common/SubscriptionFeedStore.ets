import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';
import { VideoItem } from 'youtube_core';
import { ThumbnailPlaceholder } from './ThumbnailPlaceholder';

const logger = AppLog.getInstance('SubscriptionFeedStore');
const APP_STORAGE_KEY = 'subscriptionFeed';

export interface SubscriptionFeedItem {
  videoId: string;
  title: string;
  channelId: string;
  channelName: string;
  channelAvatarUrl: string;
  thumbnailUrl: string;
  viewCountText: string;
  isLive: boolean;
  /** 发布时间的本地化相对文本（browse 路径）或 ISO 日期（RSS 路径）；无则空串 */
  publishedTimeText: string;
  /** 时长文本（browse 路径的 overlay badge）；RSS 无，空串 */
  durationText: string;
  /** 精确播放数文本（lockup accessibilityLabel / RSS media:statistics）；无则空串 */
  viewCountExact: string;
  /** 精确发布时间（ms），0 = 未知（browse/官方 feed 路径无时间戳） */
  uploadDateMs: number;
  /** 首次进入缓存的时间（ms），未知发布时间的排序兜底 */
  firstSeenMs: number;
}

interface FeedCachePayload {
  items: SubscriptionFeedItem[];
  /** channelId -> lastUpdated(ms)；缺失或 0 视为过期需重抓 */
  channelLastUpdated: Record<string, number>;
  /** 上次成功刷新的锚点时间，用于“N 个新视频”提示 */
  lastRefreshAnchorMs: number;
}

export class SubscriptionFeedStore {
  private static readonly KEY: string = 'subscription_feed';
  private static readonly MAX_ITEMS: number = 500;
  /** 保留窗口：13 周（对齐 PipePipe FEED_OLDEST_ALLOWED_DATE） */
  private static readonly RETENTION_MS: number = 13 * 7 * 24 * 60 * 60 * 1000;

  static getItems(): SubscriptionFeedItem[] {
    return SubscriptionFeedStore.load().items;
  }

  static getChannelLastUpdated(channelId: string): number {
    const meta = SubscriptionFeedStore.load().channelLastUpdated;
    return meta[channelId] ?? 0;
  }

  static getLastRefreshAnchorMs(): number {
    return SubscriptionFeedStore.load().lastRefreshAnchorMs;
  }

  /** 把本次刷新设为“已读锚点”，下次新增条目据此计数 */
  static markRefreshAnchor(): void {
    const payload = SubscriptionFeedStore.load();
    payload.lastRefreshAnchorMs = Date.now();
    SubscriptionFeedStore.save(payload);
  }

  /**
   * 合并某频道抓到的最新条目（按 videoId 去重 upsert），并记录刷新时间。
   * incoming 顺序视为从新到旧。返回新增条目数。
   */
  static upsertChannelItems(channelId: string, incoming: SubscriptionFeedItem[], fetchedAtMs: number): number {
    if (!channelId) {
      return 0;
    }
    const payload = SubscriptionFeedStore.load();
    const known: Set<string> = new Set(payload.items.map((it) => it.videoId));
    let added = 0;
    for (const item of incoming) {
      if (!item.videoId) {
        continue;
      }
      if (known.has(item.videoId)) {
        // 已存在的条目若缺发布日期而新数据带日期，回填以修正排序
        if (item.uploadDateMs > 0) {
          const existing = payload.items.find((it) => it.videoId === item.videoId);
          if (existing && existing.uploadDateMs <= 0) {
            existing.uploadDateMs = item.uploadDateMs;
          }
        }
        continue;
      }
      known.add(item.videoId);
      payload.items.push(item);
      added++;
    }
    payload.channelLastUpdated[channelId] = fetchedAtMs;
    payload.items = SubscriptionFeedStore.prune(payload.items);
    SubscriptionFeedStore.sortItems(payload.items);
    SubscriptionFeedStore.save(payload);
    return added;
  }

  static markChannelFailed(channelId: string): void {
    if (!channelId) {
      return;
    }
    const payload = SubscriptionFeedStore.load();
    payload.channelLastUpdated[channelId] = 0;
    SubscriptionFeedStore.save(payload);
  }

  static clear(): void {
    SubscriptionFeedStore.save({ items: [], channelLastUpdated: {}, lastRefreshAnchorMs: 0 });
  }

  /** 完全替换（备份恢复用） */
  static replaceAll(items: SubscriptionFeedItem[]): void {
    const payload = SubscriptionFeedStore.load();
    payload.items = SubscriptionFeedStore.prune(items);
    SubscriptionFeedStore.sortItems(payload.items);
    SubscriptionFeedStore.save(payload);
  }

  static toVideoItem(item: SubscriptionFeedItem): VideoItem {
    const video = new VideoItem(
      SubscriptionFeedStore.stableId(item.videoId),
      item.videoId,
      item.title,
      item.channelName,
      item.viewCountText,
      item.thumbnailUrl,
      item.isLive,
      ThumbnailPlaceholder.pickColor(item.videoId, 0),
      item.channelId,
      item.channelAvatarUrl,
      '',
      ''
    );
    video.publishedTimeText = item.publishedTimeText || '';
    video.durationText = item.durationText || '';
    video.viewCountExact = item.viewCountExact || '';
    return video;
  }

  /** 已排序条目直接转 VideoItem 列表（卡片渲染用） */
  static toVideoItems(items: SubscriptionFeedItem[]): VideoItem[] {
    return items.map((item) => SubscriptionFeedStore.toVideoItem(item));
  }

  private static stableId(videoId: string): number {
    let hash = 0;
    for (let i = 0; i < videoId.length; i++) {
      hash = (hash * 31 + videoId.charCodeAt(i)) & 0x7fffffff;
    }
    return hash;
  }

  /** 发布时间未知时退化为 firstSeen，语义上“新出现的排前面” */
  private static sortItems(items: SubscriptionFeedItem[]): void {
    items.sort((a, b) => {
      const ka = a.uploadDateMs > 0 ? a.uploadDateMs : a.firstSeenMs;
      const kb = b.uploadDateMs > 0 ? b.uploadDateMs : b.firstSeenMs;
      return kb - ka;
    });
  }

  /** 超窗口剪枝（每频道保底 1 条作为新视频判据），再按容量截断 */
  private static prune(items: SubscriptionFeedItem[]): SubscriptionFeedItem[] {
    const cutoff = Date.now() - SubscriptionFeedStore.RETENTION_MS;
    const keptPerChannel: Record<string, number> = {};
    const kept: SubscriptionFeedItem[] = [];
    // 输入按新旧排序时遍历可保证保底条目是该频道最新的一条
    const sorted = items.slice();
    SubscriptionFeedStore.sortItems(sorted);
    for (const item of sorted) {
      const count = keptPerChannel[item.channelId] ?? 0;
      const dated = item.uploadDateMs > 0;
      if (dated && item.uploadDateMs < cutoff && count >= 1) {
        continue;
      }
      keptPerChannel[item.channelId] = count + 1;
      kept.push(item);
    }
    return kept.slice(0, SubscriptionFeedStore.MAX_ITEMS);
  }

  private static load(): FeedCachePayload {
    const json = PreferencesStore.getString(SubscriptionFeedStore.KEY, '');
    if (!json) {
      return { items: [], channelLastUpdated: {}, lastRefreshAnchorMs: 0 };
    }
    try {
      const raw = JSON.parse(json) as FeedCachePayload;
      return {
        items: Array.isArray(raw.items) ? raw.items : [],
        channelLastUpdated: raw.channelLastUpdated ?? {},
        lastRefreshAnchorMs: raw.lastRefreshAnchorMs ?? 0
      };
    } catch (err) {
      logger.error('Failed to parse subscription feed cache:', JSON.stringify(err));
      return { items: [], channelLastUpdated: {}, lastRefreshAnchorMs: 0 };
    }
  }

  private static save(payload: FeedCachePayload): void {
    try {
      PreferencesStore.setString(SubscriptionFeedStore.KEY, JSON.stringify(payload));
    } catch (err) {
      logger.error('Failed to save subscription feed cache:', JSON.stringify(err));
    }
    AppStorage.setOrCreate(APP_STORAGE_KEY, payload.items);
  }
}
