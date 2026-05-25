import { AppLog } from '../../common/AppLog';
import { fetchRssFeed } from 'youtube_core';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { VideoItem } from 'youtube_core';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';

const logger = AppLog.getInstance('SubscriptionFeedService');

interface FeedEntry {
  videoId: string;
  title: string;
  author: string;
  thumbnailUrl: string;
}

export class SubscriptionFeedService {

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
      entries.push({ videoId, title, author, thumbnailUrl });
    }
    return entries;
  }

  private matchTag(text: string, tag: string): string {
    const regex = new RegExp(`<${tag}>([\\s\\S]*?)<\\/${tag}>`, 'i');
    const match = regex.exec(text);
    return match ? match[1] : '';
  }

  private matchThumbnail(text: string): string {
    const regex = /<media:thumbnail[^>]*url="([^"]+)"/i;
    const match = regex.exec(text);
    return match ? match[1] : '';
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
