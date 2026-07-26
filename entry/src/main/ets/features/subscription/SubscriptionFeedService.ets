import { AppLog } from '../../common/AppLog';
import { AuthSessionManager, fetchRssFeed } from 'youtube_core';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { VideoItem } from 'youtube_core';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { PreferencesStore } from '../../common/PreferencesStore';
import { SubscriptionFeedItem, SubscriptionFeedStore } from '../../common/SubscriptionFeedStore';
import { RelativeTimeParser } from '../../common/utils/RelativeTimeParser';

const logger = AppLog.getInstance('SubscriptionFeedService');

interface FeedEntry {
  videoId: string;
  title: string;
  author: string;
  thumbnailUrl: string;
  publishedMs: number;
}

export type FeedRefreshSource = 'official' | 'channels' | 'none';

export interface FeedRefreshResult {
  source: FeedRefreshSource;
  addedCount: number;
  failedChannels: string[];
  /** 因未过期而跳过的频道数 */
  skippedFresh: number;
}

export class SubscriptionFeedService {
  /** 频道刷新阈值：5 分钟（对齐 NewPipe feed_update_threshold 默认 300s） */
  private static readonly STALE_THRESHOLD_MS: number = 5 * 60 * 1000;
  private static readonly PARALLEL_FETCHES: number = 3;
  /** 逐频道模式每个频道取的最新条目数上限 */
  private static readonly PER_CHANNEL_LIMIT: number = 10;
  private static readonly FAST_MODE_PREF: string = 'cfg_feed_fast_mode';

  /**
   * 刷新订阅动态缓存。
   * 登录态优先走官方聚合 feed（FEsubscriptions，一次请求）；失败或未登录时
   * 逐频道抓取（默认 InnerTube browse，cfg_feed_fast_mode 开启时用 RSS）。
   */
  async refreshFeed(subscriptions: SubscriptionUser[], force: boolean = false): Promise<FeedRefreshResult> {
    const startedAt = Date.now();
    if (this.isSignedIn()) {
      const official = await this.tryOfficialFeed();
      if (official !== null) {
        logger.info(`refreshFeed source=official added=${official} elapsed=${Date.now() - startedAt}ms`);
        return { source: 'official', addedCount: official, failedChannels: [], skippedFresh: 0 };
      }
      logger.warn('refreshFeed official feed unavailable, fallback to per-channel');
    }
    const result = await this.refreshPerChannel(subscriptions, force);
    logger.info(`refreshFeed source=channels added=${result.addedCount} failed=${result.failedChannels.length} `
      + `skipped=${result.skippedFresh} elapsed=${Date.now() - startedAt}ms`);
    return result;
  }

  /** 缓存是否过期（页面打开时决定是否自动后台刷新） */
  isStale(): boolean {
    const items = SubscriptionFeedStore.getItems();
    if (items.length === 0) {
      return true;
    }
    const newest = items.reduce((acc: number, it: SubscriptionFeedItem) => Math.max(acc, it.firstSeenMs), 0);
    return Date.now() - newest > SubscriptionFeedService.STALE_THRESHOLD_MS;
  }

  private isSignedIn(): boolean {
    return AuthSessionManager.getInstance()?.hasAuthForUserData() === true;
  }

  /** 官方聚合 feed。返回新增数；不可用（未登录/异常/空）返回 null 触发降级。 */
  private async tryOfficialFeed(): Promise<number | null> {
    try {
      const library = FeedServiceProvider.getInstance().getUserLibraryService();
      const page = await library.fetchSubscriptionsFeed(1);
      if (!page.items || page.items.length === 0) {
        return null;
      }
      const now = Date.now();
      const byChannel: Record<string, SubscriptionFeedItem[]> = {};
      for (const v of page.items) {
        if (!v.videoId) {
          continue;
        }
        const channelId = v.channelId || '';
        const item: SubscriptionFeedItem = {
          videoId: v.videoId,
          title: v.title || '',
          channelId: channelId,
          channelName: v.author || '',
          channelAvatarUrl: v.channelAvatarUrl || '',
          thumbnailUrl: v.thumbnailUrl || '',
          viewCountText: v.viewCount || '',
          isLive: v.isLive,
          uploadDateMs: 0,
          firstSeenMs: now
        };
        const bucket = byChannel[channelId] ?? [];
        bucket.push(item);
        byChannel[channelId] = bucket;
      }
      let added = 0;
      for (const channelId of Object.keys(byChannel)) {
        added += SubscriptionFeedStore.upsertChannelItems(channelId, byChannel[channelId], now);
      }
      return added;
    } catch (err) {
      logger.warn(`official feed failed: ${JSON.stringify(err)}`);
      return null;
    }
  }

  private async refreshPerChannel(subscriptions: SubscriptionUser[], force: boolean): Promise<FeedRefreshResult> {
    if (!subscriptions || subscriptions.length === 0) {
      return { source: 'none', addedCount: 0, failedChannels: [], skippedFresh: 0 };
    }
    const now = Date.now();
    const stale: SubscriptionUser[] = [];
    let skippedFresh = 0;
    for (const sub of subscriptions) {
      const channelId = (sub.channelId || '').trim();
      if (!channelId) {
        continue;
      }
      const last = SubscriptionFeedStore.getChannelLastUpdated(channelId);
      if (force || last <= 0 || now - last > SubscriptionFeedService.STALE_THRESHOLD_MS) {
        stale.push(sub);
      } else {
        skippedFresh++;
      }
    }
    const fastMode = PreferencesStore.getString(SubscriptionFeedService.FAST_MODE_PREF, 'false') === 'true';
    let added = 0;
    const failedChannels: string[] = [];
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < stale.length) {
        const sub = stale[cursor++];
        const channelId = sub.channelId.trim();
        try {
          const items = fastMode
            ? await this.fetchChannelItemsViaRss(sub)
            : await this.fetchChannelItemsViaBrowse(sub);
          added += SubscriptionFeedStore.upsertChannelItems(channelId, items, Date.now());
        } catch (err) {
          SubscriptionFeedStore.markChannelFailed(channelId);
          failedChannels.push(channelId);
          logger.warn(`channel fetch failed id=${channelId} fast=${fastMode}: ${JSON.stringify(err)}`);
        }
      }
    };
    const workers: Promise<void>[] = [];
    for (let i = 0; i < SubscriptionFeedService.PARALLEL_FETCHES; i++) {
      workers.push(worker());
    }
    await Promise.all(workers);
    return { source: stale.length > 0 ? 'channels' : 'none', addedCount: added, failedChannels, skippedFresh };
  }

  /** InnerTube browse（默认）：信息全（时长/观看数/直播标），日期由 publishedTimeText 解析 */
  private async fetchChannelItemsViaBrowse(sub: SubscriptionUser): Promise<SubscriptionFeedItem[]> {
    const service = FeedServiceProvider.getInstance().getChannelService();
    const page = await service.fetchChannelVideosInitial(sub.channelId, 1);
    const now = Date.now();
    return page.items
      .slice(0, SubscriptionFeedService.PER_CHANNEL_LIMIT)
      .filter((v: VideoItem) => !!v.videoId)
      .map((v: VideoItem): SubscriptionFeedItem => ({
        videoId: v.videoId,
        title: v.title || '',
        channelId: sub.channelId,
        channelName: v.author || sub.displayName || '',
        channelAvatarUrl: sub.avatarUrl || '',
        thumbnailUrl: v.thumbnailUrl || '',
        viewCountText: v.viewCount || '',
        isLive: v.isLive,
        uploadDateMs: RelativeTimeParser.parse(v.publishedTimeText, now),
        firstSeenMs: now
      }));
  }

  /** RSS（快速模式）：轻量，带精确 published 日期，但无时长/观看数 */
  private async fetchChannelItemsViaRss(sub: SubscriptionUser): Promise<SubscriptionFeedItem[]> {
    const entries = await this.fetchChannelFeed(sub);
    const now = Date.now();
    return entries
      .slice(0, SubscriptionFeedService.PER_CHANNEL_LIMIT)
      .map((entry): SubscriptionFeedItem => ({
        videoId: entry.videoId,
        title: entry.title,
        channelId: sub.channelId,
        channelName: entry.author || sub.displayName || '',
        channelAvatarUrl: sub.avatarUrl || '',
        thumbnailUrl: entry.thumbnailUrl,
        viewCountText: '',
        isLive: false,
        uploadDateMs: entry.publishedMs,
        firstSeenMs: now
      }));
  }

  async fetchSubscriptionsFeed(subscriptions: SubscriptionUser[]): Promise<VideoItem[]> {
    const results: VideoItem[] = [];
    let idCounter = 1;
    if (!subscriptions || subscriptions.length === 0) {
      return results;
    }

    const feeds = await Promise.all(subscriptions.map(async (sub) => {
      try {
        const entries = await this.fetchChannelFeed(sub);
        return entries.map((entry) => {
          const itemId = idCounter++;
          const item = new VideoItem(
            itemId,
            entry.videoId,
            entry.title,
            entry.author,
            '',
            entry.thumbnailUrl,
            false,
            ThumbnailPlaceholder.pickColor(entry.videoId, itemId),
            sub.channelId,
            '',
            '',
            ''
          );
          return item;
        });
      } catch (err) {
        logger.error('fetchChannelFeed failed:', JSON.stringify(err));
        return [];
      }
    }));

    feeds.forEach((list) => {
      list.forEach((item) => results.push(item));
    });

    return results;
  }

  async fetchChannelVideos(channelId: string, displayName: string = ''): Promise<VideoItem[]> {
    const trimmed = (channelId || '').trim();
    if (!trimmed) {
      return [];
    }
    const sub = new SubscriptionUser(trimmed, displayName || trimmed);
    const entries = await this.fetchChannelFeed(sub);
    let idCounter = 1;
    return entries.map((entry) => {
      const itemId = idCounter++;
      return new VideoItem(
        itemId,
        entry.videoId,
        entry.title,
        entry.author,
        '',
        entry.thumbnailUrl,
        false,
        ThumbnailPlaceholder.pickColor(entry.videoId, itemId),
        sub.channelId,
        '',
        '',
        ''
      );
    });
  }

  async fetchPlaylistVideos(playlistId: string, displayName: string = ''): Promise<VideoItem[]> {
    const trimmed = (playlistId || '').trim();
    if (!trimmed) {
      return [];
    }
    const entries = await this.fetchPlaylistFeed(trimmed, displayName || trimmed);
    let idCounter = 1;
    return entries.map((entry) => {
      const itemId = idCounter++;
      return new VideoItem(
        itemId,
        entry.videoId,
        entry.title,
        entry.author,
        '',
        entry.thumbnailUrl,
        false,
        ThumbnailPlaceholder.pickColor(entry.videoId, itemId),
        '',
        '',
        '',
        ''
      );
    });
  }

  private async fetchChannelFeed(sub: SubscriptionUser): Promise<FeedEntry[]> {
    const url = `https://www.youtube.com/feeds/videos.xml?channel_id=${encodeURIComponent(sub.channelId)}`;
    const xml = await fetchRssFeed(url);
    return this.parseFeed(xml, sub.displayName);
  }

  private async fetchPlaylistFeed(playlistId: string, fallbackAuthor: string): Promise<FeedEntry[]> {
    const url = `https://www.youtube.com/feeds/videos.xml?playlist_id=${encodeURIComponent(playlistId)}`;
    const xml = await fetchRssFeed(url);
    return this.parseFeed(xml, fallbackAuthor);
  }

  private parseFeed(xml: string, fallbackAuthor: string): FeedEntry[] {
    const entries: FeedEntry[] = [];
    const entryRegex = /<entry>([\s\S]*?)<\/entry>/g;
    let match: RegExpExecArray | null;
    while ((match = entryRegex.exec(xml)) !== null) {
      const entryText = match[1];
      const videoId = this.matchTag(entryText, 'yt:videoId');
      if (!videoId) {
        continue;
      }
      const title = this.decodeXml(this.matchTag(entryText, 'title') || 'Untitled');
      const author = this.decodeXml(this.matchTag(entryText, 'name') || fallbackAuthor);
      const thumbnailUrl = this.matchThumbnail(entryText);
      const publishedMs = this.matchPublishedMs(entryText);
      entries.push({ videoId, title, author, thumbnailUrl, publishedMs });
    }
    return entries;
  }

  private matchTag(text: string, tag: string): string {
    const regex = new RegExp(`<${tag}>([\\s\\S]*?)<\\/${tag}>`, 'i');
    const match = regex.exec(text);
    return match ? match[1] : '';
  }

  private matchPublishedMs(text: string): number {
    const raw = this.matchTag(text, 'published') || this.matchTag(text, 'updated');
    if (!raw) {
      return 0;
    }
    const ms = Date.parse(raw);
    return Number.isFinite(ms) ? ms : 0;
  }

  private matchThumbnail(text: string): string {
    const regex = /<media:thumbnail[^>]*url="([^"]+)"/i;
    const match = regex.exec(text);
    const url = match ? match[1] : '';
    if (!url) {
      return '';
    }
    // Always upgrade RSS stills (usually hqdefault) to maxres.
    const idMatch = /\/vi\/([^/]+)\//.exec(url);
    if (idMatch && idMatch[1]) {
      return `https://i.ytimg.com/vi/${idMatch[1]}/maxresdefault.jpg`;
    }
    return url;
  }

  private decodeXml(input: string): string {
    return input
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'");
  }
}
