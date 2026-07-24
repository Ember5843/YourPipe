import {
  AuthSessionManager,
  ContentCountry,
  Localization,
  VideoItem,
  fetchBrowseContinuation,
  fetchBrowsePage,
  fetchTvBrowseContinuation,
  fetchTvBrowsePage
} from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { WatchHistoryItem } from '../../common/WatchHistoryStore';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';
import {
  buildHomeKioskVideoItems,
  getHomeFeedItemsFromTabContent
} from '../home/utils/HomeFeedUtils';
import { buildTvBrowseVideoItems, getTvVisitorData } from '../home/utils/TvBrowseUtils';
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
    const session = AuthSessionManager.getInstance();
    if (!session || !session.hasAuthForUserData()) {
      throw new Error('Sign-in required');
    }
  }

  /** Prefer WEB cookie rail; OAuth-only uses TV browse. */
  private useTvRail(): boolean {
    const session = AuthSessionManager.getInstance();
    return session?.preferredUserDataRail() === 'tv';
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
    if (this.useTvRail()) {
      // TV has no clean FEchannels WEB tree; channel list lives on FEsubscriptions nav tabs.
      logger.info('[UserLibrary] stage=channels rail=tv browseId=FEsubscriptions');
      const response = await fetchTvBrowsePage(
        this.localization,
        this.contentCountry,
        this.SUBSCRIPTIONS_BROWSE_ID,
        '',
        undefined,
        true
      );
      if (!response) {
        throw new Error('Empty TV channels browse response');
      }
      const tvChannels = this.parseTvSubscribedChannels(response as Record<string, Object>);
      if (tvChannels.length > 0) {
        return tvChannels;
      }
      // Fallback: generic UC scan (may be empty for pure TV payloads)
      return this.parseSubscribedChannels(response as Record<string, Object>);
    }
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
    if (this.useTvRail()) {
      logger.info(`[UserLibrary] stage=browse rail=tv browseId=${browseId}`);
      const response = await fetchTvBrowsePage(
        this.localization,
        this.contentCountry,
        browseId,
        '',
        undefined,
        true
      );
      if (!response) {
        throw new Error(`Empty TV browse response: ${browseId}`);
      }
      return this.parseTvVideoBrowse(response as Record<string, Object>, startId);
    }
    logger.info(`[UserLibrary] stage=browse rail=web browseId=${browseId}`);
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
    if (this.useTvRail()) {
      const response = await fetchTvBrowseContinuation(
        this.localization,
        this.contentCountry,
        nextPageToken,
        visitorData,
        true
      );
      if (!response) {
        throw new Error('Empty TV browse continuation response');
      }
      return this.parseTvVideoBrowse(response as Record<string, Object>, startId, visitorData);
    }
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

  private parseTvVideoBrowse(
    response: Record<string, Object>,
    startId: number,
    fallbackVisitor: string = ''
  ): UserVideoPageResult {
    const built = buildTvBrowseVideoItems(response, startId);
    return {
      items: built.items,
      nextPageToken: built.nextPageToken,
      visitorData: getTvVisitorData(response) || fallbackVisitor
    };
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

  /**
   * TV FEsubscriptions secondary-nav tabs after "All" are per-channel entries.
   * Channel id is embedded in browseEndpoint.params (base64-ish with UC…).
   */
  private parseTvSubscribedChannels(response: Record<string, Object>): Array<SubscriptionUser> {
    const result: Array<SubscriptionUser> = [];
    const seen: Record<string, boolean> = {};
    const contents = response['contents'] as Record<string, Object>;
    const tvBrowse = contents ? (contents['tvBrowseRenderer'] as Record<string, Object>) : undefined;
    const content = tvBrowse ? (tvBrowse['content'] as Record<string, Object>) : undefined;
    const secondary = content ? (content['tvSecondaryNavRenderer'] as Record<string, Object>) : undefined;
    const sections = secondary ? (secondary['sections'] as Array<Record<string, Object>>) : undefined;
    const section0 = sections && sections.length > 0
      ? (sections[0]['tvSecondaryNavSectionRenderer'] as Record<string, Object>)
      : undefined;
    const tabs = section0 ? (section0['tabs'] as Array<Record<string, Object>>) : undefined;
    if (!tabs || tabs.length === 0) {
      logger.info('parseTvSubscribedChannels tabs=0');
      return result;
    }

    for (let i = 0; i < tabs.length; i++) {
      const tab = tabs[i];
      const tabRenderer = (tab['tabRenderer'] as Record<string, Object>)
        || (tab['expandableTabRenderer'] as Record<string, Object>);
      if (!tabRenderer) {
        continue;
      }
      const title = ((tabRenderer['title'] as string) || '').trim();
      if (!title || title.toLowerCase() === 'all') {
        continue;
      }
      const endpoint = tabRenderer['endpoint'] as Record<string, Object>;
      const browse = endpoint ? (endpoint['browseEndpoint'] as Record<string, Object>) : undefined;
      const params = browse ? ((browse['params'] as string) || '') : '';
      const channelId = this.extractChannelIdFromTvParams(params);
      if (!channelId || seen[channelId]) {
        continue;
      }
      seen[channelId] = true;
      result.push(new SubscriptionUser(
        channelId,
        title,
        '',
        '',
        '',
        '',
        ThumbnailPlaceholder.pickColor(channelId, result.length + 1)
      ));
    }
    logger.info(`parseTvSubscribedChannels count=${result.length}`);
    return result;
  }

  private extractChannelIdFromTvParams(params: string): string {
    if (!params || params.length === 0) {
      return '';
    }
    // 1) plain UC… in raw/url-decoded string
    try {
      const pct = decodeURIComponent(params.replace(/\+/g, ' '));
      const mPlain = pct.match(/UC[\w-]{22}/);
      if (mPlain && mPlain[0]) {
        return mPlain[0];
      }
    } catch (_e) {
      // ignore
    }
    const m0 = params.match(/UC[\w-]{22}/);
    if (m0 && m0[0]) {
      return m0[0];
    }
    // 2) URL-safe base64 → binary; UC channel id is embedded as ASCII
    try {
      let b64 = params.replace(/%3D/gi, '=').replace(/%2B/gi, '+').replace(/%2F/gi, '/');
      try {
        b64 = decodeURIComponent(b64);
      } catch (_e) {
        // keep b64
      }
      b64 = b64.replace(/-/g, '+').replace(/_/g, '/');
      while (b64.length % 4 !== 0) {
        b64 += '=';
      }
      const ascii = this.base64ToAscii(b64);
      const m = ascii.match(/UC[\w-]{22}/);
      if (m && m[0]) {
        return m[0];
      }
    } catch (_e) {
      // ignore
    }
    return '';
  }

  private base64ToAscii(b64: string): string {
    const table =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out = '';
    let buffer = 0;
    let bits = 0;
    for (let i = 0; i < b64.length; i++) {
      const ch = b64.charAt(i);
      if (ch === '=') {
        break;
      }
      const val = table.indexOf(ch);
      if (val < 0) {
        continue;
      }
      buffer = (buffer << 6) | val;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        const byte = (buffer >> bits) & 0xff;
        out += String.fromCharCode(byte);
      }
    }
    return out;
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
