import { VideoItem } from 'youtube_core';
import { SearchPlaylistItem } from 'youtube_core';
import { ContentCountry, Localization, fetchBrowseContinuation, fetchBrowsePage } from 'youtube_core';
import { getPlaylistContinuationToken } from './utils/ContinuationUtils';
import { buildHomeKioskVideoItems, getHomeKioskItemsFromTabContent } from './utils/HomeFeedUtils';
import { pickBestThumbUrl } from './utils/ThumbnailUtils';
import { getTextFromRuns } from './utils/TextUtils';
import { buildVideoItemFromReelRenderer, buildVideoItemFromRenderer } from './utils/VideoItemBuilder';
import { getLockupPlaylistCoverUrl, getLockupPlaylistId, getLockupTitle, getLockupUploaderName } from './utils/LockupViewModelParser';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';

export interface KioskPageResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
  visitorData: string;
}

export interface PlaylistPageResult {
  items: Array<SearchPlaylistItem>;
  nextPageToken: string | null;
  visitorData: string;
}

export class ChannelTabParams {
  static readonly VIDEOS: string = 'EgZ2aWRlb3PyBgQKAjoA';
  static readonly SHORTS: string = 'EgZzaG9ydHPyBgUKA5oBAA%3D%3D';
  static readonly LIVESTREAMS: string = 'EgdzdHJlYW1z8gYECgJ6AA%3D%3D';
  static readonly PLAYLISTS: string = 'EglwbGF5bGlzdHPyBgQKAkIA';
}

export class ChannelService {
  private localization: Localization;
  private contentCountry: ContentCountry;

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  async fetchChannelVideosInitial(channelId: string, startId: number): Promise<KioskPageResult> {
    return this.fetchChannelTabInitial(channelId, startId, ChannelTabParams.VIDEOS, '/videos');
  }

  async fetchChannelShortsInitial(channelId: string, startId: number): Promise<KioskPageResult> {
    return this.fetchChannelTabInitial(channelId, startId, ChannelTabParams.SHORTS, '/shorts');
  }

  async fetchChannelLiveInitial(channelId: string, startId: number): Promise<KioskPageResult> {
    return this.fetchChannelTabInitial(channelId, startId, ChannelTabParams.LIVESTREAMS, '/streams');
  }

  async fetchChannelPlaylistsInitial(channelId: string, startId: number): Promise<PlaylistPageResult> {
    const trimmed = (channelId || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null, visitorData: '' };
    }
    const response = await fetchBrowsePage(this.localization, this.contentCountry, trimmed, ChannelTabParams.PLAYLISTS);
    if (!response) {
      throw new Error('Empty browse response');
    }
    const root = response as Record<string, Object>;
    const responseContext = root["responseContext"] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext["visitorData"] as string) : "") || "";

    const contents = root["contents"] as Record<string, Object>;
    const twoColumn = contents ? (contents["twoColumnBrowseResultsRenderer"] as Record<string, Object>) : undefined;

    const tabContent = this.pickBrowseTabContent(twoColumn, '/playlists');
    const rawItems = getHomeKioskItemsFromTabContent(tabContent);

    const built = this.buildPlaylistItems(rawItems, startId);
    return { items: built.items, nextPageToken: built.nextPageToken, visitorData };
  }

  async fetchChannelVideosNext(nextPageToken: string, visitorData: string, startId: number): Promise<KioskPageResult> {
    return this.fetchChannelTabNext(nextPageToken, visitorData, startId);
  }

  async fetchChannelShortsNext(nextPageToken: string, visitorData: string, startId: number): Promise<KioskPageResult> {
    return this.fetchChannelTabNext(nextPageToken, visitorData, startId);
  }

  async fetchChannelLiveNext(nextPageToken: string, visitorData: string, startId: number): Promise<KioskPageResult> {
    return this.fetchChannelTabNext(nextPageToken, visitorData, startId);
  }

  async fetchChannelPlaylistsNext(nextPageToken: string, visitorData: string, startId: number): Promise<PlaylistPageResult> {
    const trimmed = (nextPageToken || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null, visitorData };
    }
    const response = await fetchBrowseContinuation(this.localization, this.contentCountry, trimmed, visitorData);
    if (!response) {
      throw new Error('Empty browse continuation response');
    }
    return this.parsePlaylistContinuationResponse(response as Record<string, Object>, visitorData, startId);
  }

  private async fetchChannelTabInitial(
    channelId: string,
    startId: number,
    params: string,
    urlSuffix: string
  ): Promise<KioskPageResult> {
    const trimmed = (channelId || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null, visitorData: '' };
    }
    const response = await fetchBrowsePage(this.localization, this.contentCountry, trimmed, params);
    if (!response) {
      throw new Error('Empty browse response');
    }
    const root = response as Record<string, Object>;
    const responseContext = root["responseContext"] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext["visitorData"] as string) : "") || "";

    const contents = root["contents"] as Record<string, Object>;
    const twoColumn = contents ? (contents["twoColumnBrowseResultsRenderer"] as Record<string, Object>) : undefined;

    const tabContent = this.pickBrowseTabContent(twoColumn, urlSuffix);
    const rawItems = getHomeKioskItemsFromTabContent(tabContent);

    const built = buildHomeKioskVideoItems(rawItems, startId, 'LIVE');
    return { items: built.items, nextPageToken: built.nextPageToken, visitorData };
  }

  private async fetchChannelTabNext(nextPageToken: string, visitorData: string, startId: number): Promise<KioskPageResult> {
    const trimmed = (nextPageToken || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null, visitorData };
    }
    const response = await fetchBrowseContinuation(this.localization, this.contentCountry, trimmed, visitorData);
    if (!response) {
      throw new Error('Empty browse continuation response');
    }
    const root = response as Record<string, Object>;
    const actions = root["onResponseReceivedActions"] as Array<Record<string, Object>>;
    let items: Array<VideoItem> = [];
    let token: string | null = null;
    if (actions && actions.length > 0) {
      actions.forEach((action) => {
        const append = action["appendContinuationItemsAction"] as Record<string, Object>;
        const continuationItems = append ? (append["continuationItems"] as Array<Record<string, Object>>) : undefined;
        if (!continuationItems || continuationItems.length === 0) {
          return;
        }
        const built = buildHomeKioskVideoItems(continuationItems, startId + items.length, 'LIVE');
        items = items.concat(built.items);
        token = built.nextPageToken ?? token;
      });
    }
    return { items, nextPageToken: token, visitorData };
  }

  private pickBrowseTabContent(
    twoColumn: Record<string, Object> | undefined,
    preferredUrlSuffix: string
  ): Record<string, Object> | undefined {
    const tabs = twoColumn ? (twoColumn["tabs"] as Array<Record<string, Object>>) : undefined;
    if (!tabs || tabs.length === 0) {
      return undefined;
    }

    for (const tabWrapper of tabs) {
      const tabRenderer = tabWrapper ? (tabWrapper["tabRenderer"] as Record<string, Object>) : undefined;
      if (!tabRenderer) {
        continue;
      }
      if (!preferredUrlSuffix || preferredUrlSuffix.length === 0) continue;
      const endpoint = tabRenderer["endpoint"] as Record<string, Object>;
      const commandMetadata = endpoint ? (endpoint["commandMetadata"] as Record<string, Object>) : undefined;
      const web = commandMetadata ? (commandMetadata["webCommandMetadata"] as Record<string, Object>) : undefined;
      const url = web ? ((web["url"] as string) || "") : "";
      if (!url || !url.endsWith(preferredUrlSuffix)) {
        continue;
      }
      const content = tabRenderer["content"] as Record<string, Object>;
      if (!content) {
        return undefined;
      }
      if (this.isMessageOnlyTab(content)) {
        return undefined;
      }
      return content;
    }

    return undefined;
  }

  private isMessageOnlyTab(tabContent: Record<string, Object>): boolean {
    const sectionList = tabContent["sectionListRenderer"] as Record<string, Object>;
    if (!sectionList) return false;
    const contents = sectionList["contents"] as Array<Record<string, Object>>;
    const first = contents && contents.length > 0 ? contents[0] : undefined;
    const itemSection = first ? (first["itemSectionRenderer"] as Record<string, Object>) : undefined;
    const sectionContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
    if (!sectionContents || sectionContents.length !== 1) return false;
    const only = sectionContents[0];
    return !!(only && (only["messageRenderer"] as Record<string, Object>));
  }

  private parsePlaylistContinuationResponse(
    response: Record<string, Object>,
    visitorData: string,
    startId: number
  ): PlaylistPageResult {
    let items: Array<SearchPlaylistItem> = [];
    let nextPageToken: string | null = null;

    const actions = response["onResponseReceivedActions"] as Array<Record<string, Object>>;
    if (actions && actions.length > 0) {
      actions.forEach((action) => {
        const append = action["appendContinuationItemsAction"] as Record<string, Object>;
        const continuationItems = append ? (append["continuationItems"] as Array<Record<string, Object>>) : undefined;
        if (!continuationItems || continuationItems.length === 0) {
          return;
        }
        const built = this.buildPlaylistItems(continuationItems, startId + items.length);
        items = items.concat(built.items);
        nextPageToken = built.nextPageToken ?? nextPageToken;
      });
    }

    return { items, nextPageToken, visitorData };
  }

  private buildPlaylistItems(
    rawItems: Array<Record<string, Object>>,
    startId: number
  ): PlaylistPageResult {
    let idCounter = startId;
    const items: Array<SearchPlaylistItem> = [];
    let nextPageToken: string | null = null;

    rawItems.forEach((content) => {
      const gridPlaylist = content["gridPlaylistRenderer"] as Record<string, Object>;
      if (gridPlaylist) {
        const playlistId = (gridPlaylist["playlistId"] as string) || "";
        const title = getTextFromRuns(gridPlaylist["title"]) || "Untitled";
        const videoCount = getTextFromRuns(gridPlaylist["videoCountText"]) || "";
        const thumbnail = gridPlaylist["thumbnail"] as Record<string, Object>;
        const coverUrl = this.getThumbnailUrlFromThumbnailObject(thumbnail);
        const shortBylineText = gridPlaylist["shortBylineText"] as Record<string, Object>;
        const uploaderName = getTextFromRuns(shortBylineText) || "Unknown";
        const placeholderColor = ThumbnailPlaceholder.pickColor(playlistId || title, idCounter);
        items.push(new SearchPlaylistItem(
          idCounter,
          playlistId,
          title,
          uploaderName,
          videoCount,
          coverUrl,
          "",
          placeholderColor
        ));
        idCounter += 1;
        return;
      }

      const lockup = content["lockupViewModel"] as Record<string, Object>;
      if (lockup) {
        const contentType = (lockup["contentType"] as string) || "";
        if (contentType === "LOCKUP_CONTENT_TYPE_PLAYLIST" || contentType === "LOCKUP_CONTENT_TYPE_PODCAST") {
          const playlistId = getLockupPlaylistId(lockup);
          const name = getLockupTitle(lockup) || "Untitled";
          const uploaderName = getLockupUploaderName(lockup) || "";
          const coverUrl = getLockupPlaylistCoverUrl(lockup);
          const placeholderColor = ThumbnailPlaceholder.pickColor(playlistId || name, idCounter);
          items.push(new SearchPlaylistItem(idCounter, playlistId, name, uploaderName, "", coverUrl, "",
            placeholderColor));
          idCounter += 1;
          return;
        }
      }

      const continuation = content["continuationItemRenderer"] as Record<string, Object>;
      if (continuation) {
        nextPageToken = getPlaylistContinuationToken(continuation) ?? nextPageToken;
      }
    });

    return { items, nextPageToken, visitorData: "" };
  }

  private getThumbnailUrlFromThumbnailObject(thumbnail: Record<string, Object> | undefined): string {
    if (!thumbnail) return "";
    const thumbnails = thumbnail["thumbnails"] as Array<Record<string, Object>>;
    if (!thumbnails || thumbnails.length === 0) return "";
    return pickBestThumbUrl(thumbnails);
  }

  private normalizeUrl(input: string): string {
    if (!input) return "";
    const url = input.trim();
    if (url.length === 0) return "";
    if (url.startsWith('//')) {
      return `https:${url}`;
    }
    if (url.startsWith('http://')) {
      return `https://${url.slice('http://'.length)}`;
    }
    return url;
  }
}
