import {
  AuthSessionManager,
  ContentCountry,
  Localization,
  VideoItem,
  fetchBrowseContinuation,
  fetchBrowsePage
} from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { WatchHistoryItem } from '../../common/WatchHistoryStore';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';
import {
  buildHomeKioskVideoItems,
  getHomeFeedItemsFromTabContent
} from '../home/utils/HomeFeedUtils';
import { getTextFromRuns } from '../home/utils/TextUtils';

const logger = AppLog.getInstance('UserLibraryService');

export interface UserVideoPageResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
  visitorData: string;
}

export class UserLibraryService {
  private localization: Localization;
  private contentCountry: ContentCountry;
  private readonly HISTORY_BROWSE_ID: string = 'FEhistory';
  private readonly SUBSCRIPTIONS_BROWSE_ID: string = 'FEsubscriptions';
  private readonly CHANNELS_BROWSE_ID: string = 'FEchannels';
  private readonly LIBRARY_BROWSE_ID: string = 'FElibrary';

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  private requireSignedIn(): void {
    if (AuthSessionManager.getInstance()?.isSignedIn() !== true) {
      throw new Error('Sign-in required');
    }
  }

  async fetchWatchHistory(startId: number = 1): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowse(this.HISTORY_BROWSE_ID, startId);
  }

  async fetchWatchHistoryNext(
    nextPageToken: string,
    visitorData: string,
    startId: number
  ): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowseContinuation(nextPageToken, visitorData, startId);
  }

  async fetchSubscriptionsFeed(startId: number = 1): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowse(this.SUBSCRIPTIONS_BROWSE_ID, startId);
  }

  async fetchSubscriptionsFeedNext(
    nextPageToken: string,
    visitorData: string,
    startId: number
  ): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowseContinuation(nextPageToken, visitorData, startId);
  }

  async fetchLibrary(startId: number = 1): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowse(this.LIBRARY_BROWSE_ID, startId);
  }

  async fetchSubscribedChannels(): Promise<Array<SubscriptionUser>> {
    this.requireSignedIn();
    const response = await fetchBrowsePage(
      this.localization,
      this.contentCountry,
      this.CHANNELS_BROWSE_ID,
      '',
      undefined,
      true
    );
    if (!response) {
      throw new Error('Empty channels browse response');
    }
    return this.parseSubscribedChannels(response as Record<string, Object>);
  }

  /**
   * 云端历史没有可靠时间戳；这里只填元数据，时间由 WatchHistoryStore.mergeRemoteHistory 处理。
   */
  toWatchHistoryItems(videos: Array<VideoItem>): Array<WatchHistoryItem> {
    return videos
      .filter((v) => !!(v.videoId && v.videoId.trim().length > 0))
      .map((v) => {
        const item: WatchHistoryItem = {
          videoId: v.videoId.trim(),
          title: v.title || v.videoId,
          author: v.author || '',
          thumbnailUrl: v.thumbnailUrl || '',
          durationSec: 0,
          progressSec: 0,
          lastWatchedAt: 0,
          channelId: v.channelId || '',
          channelAvatarUrl: v.channelAvatarUrl || '',
          channelHandle: v.channelHandle || ''
        };
        return item;
      });
  }

  private async fetchAuthBrowse(browseId: string, startId: number): Promise<UserVideoPageResult> {
    const response = await fetchBrowsePage(
      this.localization,
      this.contentCountry,
      browseId,
      '',
      undefined,
      true
    );
    if (!response) {
      throw new Error(`Empty browse response: ${browseId}`);
    }
    return this.parseVideoBrowseInitial(response as Record<string, Object>, startId);
  }

  private async fetchAuthBrowseContinuation(
    nextPageToken: string,
    visitorData: string,
    startId: number
  ): Promise<UserVideoPageResult> {
    const response = await fetchBrowseContinuation(
      this.localization,
      this.contentCountry,
      nextPageToken,
      visitorData,
      true
    );
    if (!response) {
      throw new Error('Empty browse continuation response');
    }
    return this.parseVideoBrowseContinuation(response as Record<string, Object>, visitorData, startId);
  }

  private parseVideoBrowseInitial(response: Record<string, Object>, startId: number): UserVideoPageResult {
    const responseContext = response['responseContext'] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext['visitorData'] as string) : '') || '';
    const tabContent = this.extractTabContent(response);
    const rawItems = getHomeFeedItemsFromTabContent(tabContent);
    const built = buildHomeKioskVideoItems(rawItems, startId, '');
    return {
      items: built.items,
      nextPageToken: built.nextPageToken,
      visitorData
    };
  }

  private parseVideoBrowseContinuation(
    response: Record<string, Object>,
    visitorData: string,
    startId: number
  ): UserVideoPageResult {
    let items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;

    const actions = response['onResponseReceivedActions'] as Array<Record<string, Object>>;
    if (actions && actions.length > 0) {
      actions.forEach((action) => {
        const append = action['appendContinuationItemsAction'] as Record<string, Object>;
        const continuationItems = append
          ? (append['continuationItems'] as Array<Record<string, Object>>)
          : undefined;
        if (!continuationItems || continuationItems.length === 0) {
          return;
        }
        const built = buildHomeKioskVideoItems(continuationItems, startId + items.length, '');
        items = items.concat(built.items);
        nextPageToken = built.nextPageToken ?? nextPageToken;
      });
    }

    return { items, nextPageToken, visitorData };
  }

  private extractTabContent(response: Record<string, Object>): Record<string, Object> | undefined {
    const contents = response['contents'] as Record<string, Object>;
    if (!contents) {
      return undefined;
    }
    const twoColumn = contents['twoColumnBrowseResultsRenderer'] as Record<string, Object>;
    const tabs = twoColumn ? (twoColumn['tabs'] as Array<Record<string, Object>>) : undefined;
    const tab0 = tabs && tabs.length > 0 ? tabs[0] : undefined;
    const tabRenderer = tab0 ? (tab0['tabRenderer'] as Record<string, Object>) : undefined;
    const tabContent = tabRenderer ? (tabRenderer['content'] as Record<string, Object>) : undefined;
    return tabContent ?? contents;
  }

  private parseSubscribedChannels(response: Record<string, Object>): Array<SubscriptionUser> {
    const result: Array<SubscriptionUser> = [];
    const seen: Record<string, boolean> = {};

    const pushChannel = (
      channelId: string,
      displayName: string,
      avatarUrl: string,
      subscriberText: string
    ): void => {
      const id = (channelId || '').trim();
      if (!id || !id.startsWith('UC') || seen[id]) {
        return;
      }
      seen[id] = true;
      result.push(new SubscriptionUser(
        id,
        displayName || id,
        avatarUrl || '',
        subscriberText || '',
        '',
        '',
        ThumbnailPlaceholder.pickColor(id, result.length + 1)
      ));
    };

    // FEchannels 响应树很大；用有限深度的迭代扫描，避免递归栈溢出。
    this.scanChannelsIterative(response, pushChannel);

    logger.info(`parseSubscribedChannels count=${result.length}`);
    return result;
  }

  private unwrapRichContent(node: Record<string, Object>, key: string): Record<string, Object> | undefined {
    const rich = node['richItemRenderer'] as Record<string, Object>;
    const content = rich ? (rich['content'] as Record<string, Object>) : undefined;
    return content ? (content[key] as Record<string, Object>) : undefined;
  }

  private extractBrowseId(renderer: Record<string, Object>): string {
    const nav = renderer['navigationEndpoint'] as Record<string, Object>;
    const browse = nav ? (nav['browseEndpoint'] as Record<string, Object>) : undefined;
    return (browse ? (browse['browseId'] as string) : '') || '';
  }

  private extractThumbnailUrl(thumbnail: Record<string, Object> | undefined): string {
    if (!thumbnail) {
      return '';
    }
    const thumbs = thumbnail['thumbnails'] as Array<Record<string, Object>>;
    if (!thumbs || thumbs.length === 0) {
      return '';
    }
    const last = thumbs[thumbs.length - 1];
    return (last['url'] as string) || '';
  }

  private extractLockupChannelId(lockup: Record<string, Object>): string {
    const contentId = (lockup['contentId'] as string) || '';
    if (contentId.startsWith('UC')) {
      return contentId;
    }
    const rendererContext = lockup['rendererContext'] as Record<string, Object>;
    const commandContext = rendererContext ? (rendererContext['commandContext'] as Record<string, Object>) : undefined;
    const onTap = commandContext ? (commandContext['onTap'] as Record<string, Object>) : undefined;
    const innertubeCommand = onTap ? (onTap['innertubeCommand'] as Record<string, Object>) : undefined;
    const browse = innertubeCommand ? (innertubeCommand['browseEndpoint'] as Record<string, Object>) : undefined;
    return (browse ? (browse['browseId'] as string) : '') || contentId;
  }

  private extractLockupTitle(lockup: Record<string, Object>): string {
    const metadata = lockup['metadata'] as Record<string, Object>;
    const title = metadata ? (metadata['title'] as Record<string, Object>) : undefined;
    if (!title) {
      return 'Untitled';
    }
    return (title['content'] as string)
      || getTextFromRuns(title)
      || 'Untitled';
  }

  private extractLockupThumbnail(lockup: Record<string, Object>): string {
    const contentImage = lockup['contentImage'] as Record<string, Object>;
    if (!contentImage) {
      return '';
    }
    const image = (contentImage['image'] as Record<string, Object>)
      || (contentImage['decoratedAvatarViewModel'] as Record<string, Object>);
    if (!image) {
      return '';
    }
    let sources = image['sources'] as Array<Record<string, Object>>;
    if (!sources || sources.length === 0) {
      const avatar = image['avatar'] as Record<string, Object>;
      const avatarImage = avatar ? (avatar['image'] as Record<string, Object>) : undefined;
      const avatarSources = avatarImage
        ? (avatarImage['sources'] as Array<Record<string, Object>>)
        : undefined;
      if (avatarSources && avatarSources.length > 0) {
        sources = avatarSources;
      }
    }
    if (sources && sources.length > 0) {
      return (sources[sources.length - 1]['url'] as string) || '';
    }
    return this.extractThumbnailUrl(image);
  }

  /**
   * Iterative BFS over the browse JSON. Caps depth/nodes so huge FEchannels
   * payloads cannot blow the ArkTS stack (previous recursive walk did).
   */
  private scanChannelsIterative(
    root: Object,
    pushChannel: (channelId: string, displayName: string, avatarUrl: string, subscriberText: string) => void
  ): void {
    if (!root) {
      return;
    }
    const maxDepth = 24;
    const maxNodes = 8000;
    const queue: Array<Object> = [root];
    const depths: number[] = [0];
    let visited = 0;

    while (queue.length > 0 && visited < maxNodes) {
      const node = queue.shift();
      const depth = depths.shift() ?? 0;
      if (!node) {
        continue;
      }
      visited += 1;

      if (node instanceof Array) {
        const arr = node as Object[];
        if (depth >= maxDepth) {
          continue;
        }
        for (let i = 0; i < arr.length; i++) {
          const child = arr[i];
          if (child) {
            queue.push(child);
            depths.push(depth + 1);
          }
        }
        continue;
      }

      const obj = node as Record<string, Object>;
      if (this.tryPushChannelNode(obj, pushChannel)) {
        // Channel leaf — still allow siblings via queue, but do not descend into this leaf.
        continue;
      }

      if (depth >= maxDepth) {
        continue;
      }

      // Only descend known structural keys to keep the scan cheap and relevant.
      const structuralKeys: string[] = [
        'contents', 'content', 'items', 'tabs', 'header', 'sections',
        'sectionListRenderer', 'itemSectionRenderer', 'richGridRenderer',
        'richItemRenderer', 'shelfRenderer', 'gridRenderer',
        'expandedShelfContentsRenderer', 'horizontalListRenderer',
        'twoColumnBrowseResultsRenderer', 'tabRenderer',
        'continuationItemRenderer'
      ];
      for (let i = 0; i < structuralKeys.length; i++) {
        const key = structuralKeys[i];
        const child = obj[key];
        if (child) {
          queue.push(child);
          depths.push(depth + 1);
        }
      }

      // Also enqueue any array-valued unknown keys that look like collections.
      const keys = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        if (structuralKeys.indexOf(key) >= 0) {
          continue;
        }
        const child = obj[key];
        if (child instanceof Array) {
          queue.push(child);
          depths.push(depth + 1);
        }
      }
    }
  }

  private tryPushChannelNode(
    obj: Record<string, Object>,
    pushChannel: (channelId: string, displayName: string, avatarUrl: string, subscriberText: string) => void
  ): boolean {
    const channelRenderer = (obj['channelRenderer'] as Record<string, Object>)
      || this.unwrapRichContent(obj, 'channelRenderer');
    if (channelRenderer) {
      const channelId = (channelRenderer['channelId'] as string) || this.extractBrowseId(channelRenderer);
      const title = getTextFromRuns(channelRenderer['title']) || 'Untitled';
      const subscriberText = getTextFromRuns(channelRenderer['subscriberCountText']) || '';
      const avatarUrl = this.extractThumbnailUrl(channelRenderer['thumbnail'] as Record<string, Object>);
      pushChannel(channelId, title, avatarUrl, subscriberText);
      return true;
    }

    const gridChannel = (obj['gridChannelRenderer'] as Record<string, Object>)
      || this.unwrapRichContent(obj, 'gridChannelRenderer');
    if (gridChannel) {
      const channelId = (gridChannel['channelId'] as string) || this.extractBrowseId(gridChannel);
      const title = getTextFromRuns(gridChannel['title']) || 'Untitled';
      const subscriberText = getTextFromRuns(gridChannel['subscriberCountText']) || '';
      const avatarUrl = this.extractThumbnailUrl(gridChannel['thumbnail'] as Record<string, Object>);
      pushChannel(channelId, title, avatarUrl, subscriberText);
      return true;
    }

    const lockup = (obj['lockupViewModel'] as Record<string, Object>)
      || this.unwrapRichContent(obj, 'lockupViewModel');
    if (lockup) {
      const contentType = (lockup['contentType'] as string) || '';
      const channelId = this.extractLockupChannelId(lockup);
      if (channelId.startsWith('UC')
        || contentType === 'LOCKUP_CONTENT_TYPE_CHANNEL'
        || contentType.indexOf('CHANNEL') >= 0) {
        const title = this.extractLockupTitle(lockup);
        const avatarUrl = this.extractLockupThumbnail(lockup);
        pushChannel(channelId, title, avatarUrl, '');
        return true;
      }
    }
    return false;
  }
}
