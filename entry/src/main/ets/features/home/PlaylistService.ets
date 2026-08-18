import { SearchPlaylistItem, VideoItem } from 'youtube_core';
import { VideoBuildResult } from './model/FeedResult';
import { ContentCountry, Localization, fetchBrowseContinuation, fetchBrowsePage } from 'youtube_core';
import { pickBestThumbUrl } from './utils/ThumbnailUtils';
import { getTextFromRuns } from './utils/TextUtils';
import { getPlaylistContinuationToken } from './utils/ContinuationUtils';
import {
  getLockupChannelAvatarUrl,
  getLockupChannelId,
  getLockupIsLive,
  getLockupIsPremium,
  getLockupRequiresMembership,
  getLockupTitle,
  getLockupUploaderName,
  getLockupVideoId,
  getLockupVideoThumbnailUrl,
  getLockupViewCount
} from './utils/LockupViewModelParser';
import {
  buildVideoItemFromRenderer,
  buildVideoItemFromShortsLockupViewModel
} from './utils/VideoItemBuilder';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';

/** PipePipe: show unavailable videos in playlist browse. */
const PLAYLIST_BROWSE_PARAMS = 'wgYCCAA%3D';

export interface VideoPageResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
  visitorData: string;
  totalCountText?: string;
}

export class PlaylistService {
  private localization: Localization;
  private contentCountry: ContentCountry;

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  async fetchPlaylistInitial(playlistId: string, startId: number): Promise<VideoPageResult> {
    const trimmed = (playlistId || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null, visitorData: '' };
    }
    // Align with PipePipe YoutubePlaylistExtractor: browseId VL+id + params wgYCCAA%3D
    const response = await fetchBrowsePage(this.localization, this.contentCountry,
      this.toPlaylistBrowseId(trimmed), PLAYLIST_BROWSE_PARAMS, undefined, true);
    if (!response) {
      throw new Error('Empty browse response');
    }
    const root = response as Record<string, Object>;
    const responseContext = root["responseContext"] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext["visitorData"] as string) : "") || "";

    const contents = root["contents"] as Record<string, Object>;
    const twoColumn = contents ? (contents["twoColumnBrowseResultsRenderer"] as Record<string, Object>) : undefined;
    const tabContent = this.getFirstTabContent(twoColumn);
    const rawItems = this.getPlaylistItemsFromTabContent(tabContent);

    let totalCountText = '';
    const playlistHeader = this.getPlaylistHeaderFromTwoColumn(twoColumn);
    if (playlistHeader) {
      totalCountText = this.getPlaylistTotalCountText(playlistHeader);
    }
    if (!totalCountText) {
      totalCountText = this.getPlaylistTotalCountFromSidebar(root);
    }

    const built = this.buildPlaylistVideoItems(rawItems, startId);
    return { items: built.items, nextPageToken: built.nextPageToken, visitorData, totalCountText };
  }

  async fetchPlaylistOverview(playlistId: string): Promise<SearchPlaylistItem | null> {
    const trimmed = (playlistId || '').trim();
    if (!trimmed) {
      return null;
    }
    const response = await fetchBrowsePage(this.localization, this.contentCountry,
      this.toPlaylistBrowseId(trimmed), PLAYLIST_BROWSE_PARAMS, undefined, true);
    if (!response) {
      return null;
    }
    const root = response as Record<string, Object>;

    const contents = root["contents"] as Record<string, Object>;
    const twoColumn = contents ? (contents["twoColumnBrowseResultsRenderer"] as Record<string, Object>) : undefined;
    const tabContent = this.getFirstTabContent(twoColumn);
    const playlistHeader = this.getPlaylistHeaderFromTwoColumn(twoColumn);

    // Prefer sidebar primary info (PipePipe getPlaylistInfo) when list header is missing.
    const sidebarPrimary = this.getSidebarPrimaryInfo(root);

    const title = getTextFromRuns(playlistHeader ? playlistHeader["title"] : undefined)
      || getTextFromRuns(sidebarPrimary ? sidebarPrimary["title"] : undefined)
      || this.getMicroformatTitle(root)
      || "Untitled";
    const shortBylineText = playlistHeader
      ? playlistHeader["shortBylineText"] as Record<string, Object>
      : undefined;
    const uploaderName = getTextFromRuns(shortBylineText) || "Unknown";
    let countText = this.getPlaylistTotalCountText(playlistHeader);
    if (!countText) {
      countText = this.getPlaylistTotalCountText(sidebarPrimary);
    }
    let coverUrl = "";
    if (playlistHeader) {
      coverUrl = this.getPlaylistCoverFromHeader(playlistHeader as Record<string, Object>);
    }
    if (!coverUrl) {
      coverUrl = this.getPlaylistCoverFromSidebar(root);
    }
    if (!coverUrl && playlistHeader) {
      const headerContents = playlistHeader["contents"] as Array<Record<string, Object>>;
      coverUrl = this.getCoverFromFirstPlaylistVideo(headerContents ?? []);
    }
    if (!coverUrl) {
      const rawItems = this.getPlaylistItemsFromTabContent(tabContent);
      coverUrl = this.getCoverFromFirstPlaylistVideo(rawItems);
    }

    const placeholderColor = ThumbnailPlaceholder.pickColor(playlistId || title, 0);
    return new SearchPlaylistItem(0, trimmed, title, uploaderName, countText, coverUrl, "", placeholderColor);
  }

  /**
   * Collect playlist item rows from tab content.
   * PipePipe YoutubePlaylistExtractor.getInitialPage:
   * 1) playlistVideoListRenderer.contents
   * 2) fallback: all itemSectionRenderer.contents
   * 3) richGridRenderer (Shorts playlists) → richItemRenderer.content rows
   */
  private getPlaylistItemsFromTabContent(tabContent: Record<string, Object> | undefined): Array<Record<string, Object>> {
    if (!tabContent) return [];
    const sectionList = tabContent["sectionListRenderer"] as Record<string, Object>;
    const sectionContents = sectionList ? (sectionList["contents"] as Array<Record<string, Object>>) : undefined;
    if (!sectionContents || sectionContents.length === 0) {
      // Some layouts put richGrid directly under tab content.
      const directRich = tabContent["richGridRenderer"] as Record<string, Object>;
      const directItems = directRich ? (directRich["contents"] as Array<Record<string, Object>>) : undefined;
      return directItems ?? [];
    }

    const collected: Array<Record<string, Object>> = [];

    // Prefer classic playlistVideoListRenderer when present.
    for (let i = 0; i < sectionContents.length; i++) {
      const section = sectionContents[i];
      const itemSection = section ? (section["itemSectionRenderer"] as Record<string, Object>) : undefined;
      const itemContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
      if (!itemContents) {
        continue;
      }
      for (let j = 0; j < itemContents.length; j++) {
        const firstItem = itemContents[j];
        const listRenderer = firstItem
          ? (firstItem["playlistVideoListRenderer"] as Record<string, Object>)
          : undefined;
        if (listRenderer) {
          const listContents = listRenderer["contents"] as Array<Record<string, Object>>;
          if (listContents && listContents.length > 0) {
            return listContents;
          }
        }
        const richGrid = firstItem ? (firstItem["richGridRenderer"] as Record<string, Object>) : undefined;
        if (richGrid) {
          const gridContents = richGrid["contents"] as Array<Record<string, Object>>;
          if (gridContents && gridContents.length > 0) {
            return gridContents;
          }
        }
      }
    }

    // Fallback: flatten all itemSection contents (playlistSegmentRenderer / lockups).
    for (let i = 0; i < sectionContents.length; i++) {
      const section = sectionContents[i];
      const itemSection = section ? (section["itemSectionRenderer"] as Record<string, Object>) : undefined;
      const itemContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
      if (itemContents && itemContents.length > 0) {
        for (let j = 0; j < itemContents.length; j++) {
          collected.push(itemContents[j]);
        }
      }
      // Continuation may sit at sectionList level.
      const cont = section ? (section["continuationItemRenderer"] as Record<string, Object>) : undefined;
      if (cont) {
        collected.push(section);
      }
      const contVm = section ? (section["continuationItemViewModel"] as Record<string, Object>) : undefined;
      if (contVm) {
        collected.push(section);
      }
    }
    return collected;
  }

  async fetchPlaylistNext(nextPageToken: string, visitorData: string, startId: number): Promise<VideoPageResult> {
    const trimmed = (nextPageToken || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null, visitorData };
    }
    const response = await fetchBrowseContinuation(this.localization, this.contentCountry, trimmed, visitorData);
    if (!response) {
      throw new Error('Empty browse continuation response');
    }
    const root = response as Record<string, Object>;
    const rawItems = this.getPlaylistItemsFromActions(root);
    const built = this.buildPlaylistVideoItems(rawItems, startId);
    return { items: built.items, nextPageToken: built.nextPageToken, visitorData };
  }

  /** Search lockups may expose the browse id (VLPL...) instead of the raw playlist id (PL...). */
  private toPlaylistBrowseId(playlistId: string): string {
    return playlistId.startsWith('VL') ? playlistId : 'VL' + playlistId;
  }

  private getPlaylistItemsFromActions(response: Record<string, Object>): Array<Record<string, Object>> {
    const actions = response["onResponseReceivedActions"] as Array<Record<string, Object>>;
    if (!actions || actions.length === 0) return [];
    for (const action of actions) {
      const append = action["appendContinuationItemsAction"] as Record<string, Object>;
      const items = append ? (append["continuationItems"] as Array<Record<string, Object>>) : undefined;
      if (items && items.length > 0) return items;
    }
    return [];
  }

  private buildPlaylistVideoItems(
    rawItems: Array<Record<string, Object>>,
    startId: number
  ): VideoBuildResult {
    let idCounter = startId;
    const items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;

    rawItems.forEach((content) => {
      // Traditional playlistVideoRenderer
      const playlistVideo = content["playlistVideoRenderer"] as Record<string, Object>;
      if (playlistVideo) {
        const videoItem = buildVideoItemFromRenderer(playlistVideo, idCounter, '');
        if (videoItem) {
          items.push(videoItem);
          idCounter += 1;
        }
        return;
      }

      // Modern lockupViewModel (PipePipe collectStreamsFrom)
      const lockup = content["lockupViewModel"] as Record<string, Object>;
      if (lockup) {
        const videoItem = this.buildVideoFromLockup(lockup, idCounter);
        if (videoItem) {
          items.push(videoItem);
          idCounter += 1;
        }
        return;
      }

      // richItemRenderer → shortsLockupViewModel / lockupViewModel
      const rich = content["richItemRenderer"] as Record<string, Object>;
      if (rich) {
        const richContent = rich["content"] as Record<string, Object>;
        if (richContent) {
          const shorts = richContent["shortsLockupViewModel"] as Record<string, Object>;
          if (shorts) {
            const videoItem = buildVideoItemFromShortsLockupViewModel(shorts, idCounter);
            if (videoItem) {
              items.push(videoItem);
              idCounter += 1;
            }
            return;
          }
          const nestedLockup = richContent["lockupViewModel"] as Record<string, Object>;
          if (nestedLockup) {
            const videoItem = this.buildVideoFromLockup(nestedLockup, idCounter);
            if (videoItem) {
              items.push(videoItem);
              idCounter += 1;
            }
            return;
          }
        }
      }

      // Continuations (classic + view-model)
      const continuation = content["continuationItemRenderer"] as Record<string, Object>;
      if (continuation) {
        nextPageToken = getPlaylistContinuationToken(continuation) ?? nextPageToken;
        return;
      }
      if (content["continuationItemViewModel"] || content["continuationCommand"]) {
        nextPageToken = getPlaylistContinuationToken(content) ?? nextPageToken;
      }
    });

    return { items, nextPageToken };
  }

  /** PipePipe commitLockupStreamIfSupported: VIDEO + EPISODE with non-empty title. */
  private buildVideoFromLockup(lockup: Record<string, Object>, id: number): VideoItem | null {
    const contentType = (lockup["contentType"] as string) || "";
    if (contentType !== "LOCKUP_CONTENT_TYPE_VIDEO"
      && contentType !== "LOCKUP_CONTENT_TYPE_EPISODE"
      && contentType !== "LOCKUP_CONTENT_TYPE_SHORTS") {
      // Some playlist lockups omit contentType; still try if videoId exists.
      if (contentType.length > 0) {
        return null;
      }
    }
    const title = getLockupTitle(lockup);
    if (!title && contentType.length > 0) {
      return null;
    }
    const videoId = getLockupVideoId(lockup);
    if (!videoId) {
      return null;
    }
    const author = getLockupUploaderName(lockup) || "";
    const thumbnailUrl = getLockupVideoThumbnailUrl(lockup);
    const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title || 'video', id);
    const channelId = getLockupChannelId(lockup);
    const channelAvatarUrl = getLockupChannelAvatarUrl(lockup);
    const viewCount = getLockupViewCount(lockup);
    const isLive = getLockupIsLive(lockup);
    const isPremium = getLockupIsPremium(lockup);
    const requiresMembership = getLockupRequiresMembership(lockup);
    return new VideoItem(
      id,
      videoId,
      title || "Untitled",
      author,
      viewCount,
      thumbnailUrl,
      isLive,
      placeholderColor,
      channelId,
      channelAvatarUrl,
      "",
      "",
      null,
      isPremium,
      requiresMembership
    );
  }

  private getPlaylistTotalCountText(playlistHeader: Record<string, Object> | undefined): string {
    if (!playlistHeader) return "";
    const stats = playlistHeader["stats"] as Array<Record<string, Object>>;
    if (!stats || stats.length === 0) return "";
    return getTextFromRuns(stats[0]) || "";
  }

  private getPlaylistTotalCountFromSidebar(root: Record<string, Object>): string {
    const sidebar = root["sidebar"] as Record<string, Object>;
    const playlistSidebar = sidebar ? (sidebar["playlistSidebarRenderer"] as Record<string, Object>) : undefined;
    const sidebarItems = playlistSidebar ? (playlistSidebar["items"] as Array<Record<string, Object>>) : undefined;
    const first = sidebarItems && sidebarItems.length > 0 ? sidebarItems[0] : undefined;
    const primary = first
      ? (first["playlistSidebarPrimaryInfoRenderer"] as Record<string, Object>)
      : undefined;
    if (!primary) return "";
    return this.getPlaylistTotalCountText(primary);
  }

  private getPlaylistCoverFromHeader(playlistHeader: Record<string, Object>): string {
    const thumbnail = playlistHeader["thumbnail"] as Record<string, Object>;
    if (!thumbnail) return "";
    const thumbnails = thumbnail["thumbnails"] as Array<Record<string, Object>>;
    if (!thumbnails || thumbnails.length === 0) return "";
    return pickBestThumbUrl(thumbnails);
  }

  private getSidebarPrimaryInfo(root: Record<string, Object>): Record<string, Object> | undefined {
    const sidebar = root["sidebar"] as Record<string, Object>;
    const playlistSidebar = sidebar ? (sidebar["playlistSidebarRenderer"] as Record<string, Object>) : undefined;
    const sidebarItems = playlistSidebar ? (playlistSidebar["items"] as Array<Record<string, Object>>) : undefined;
    const firstSidebarItem = sidebarItems && sidebarItems.length > 0 ? sidebarItems[0] : undefined;
    return firstSidebarItem
      ? (firstSidebarItem["playlistSidebarPrimaryInfoRenderer"] as Record<string, Object>)
      : undefined;
  }

  private getMicroformatTitle(root: Record<string, Object>): string {
    const micro = root["microformat"] as Record<string, Object>;
    const data = micro ? (micro["microformatDataRenderer"] as Record<string, Object>) : undefined;
    return data ? ((data["title"] as string) || "") : "";
  }

  private getPlaylistCoverFromSidebar(root: Record<string, Object>): string {
    const primaryRenderer = this.getSidebarPrimaryInfo(root);
    if (!primaryRenderer) return "";
    const thumbnail = primaryRenderer["thumbnailRenderer"] as Record<string, Object>;
    if (!thumbnail) return "";
    const videoThumbnail = thumbnail["playlistVideoThumbnailRenderer"] as Record<string, Object>;
    const customThumbnail = thumbnail["playlistCustomThumbnailRenderer"] as Record<string, Object>;
    const thumb = videoThumbnail
      ? (videoThumbnail["thumbnail"] as Record<string, Object>)
      : (customThumbnail ? (customThumbnail["thumbnail"] as Record<string, Object>) : undefined);
    const thumbnails = thumb ? (thumb["thumbnails"] as Array<Record<string, Object>>) : undefined;
    if (!thumbnails || thumbnails.length === 0) return "";
    return pickBestThumbUrl(thumbnails);
  }

  private getCoverFromFirstPlaylistVideo(rawItems: Array<Record<string, Object>>): string {
    for (let i = 0; i < rawItems.length; i++) {
      const first = rawItems[i];
      const video = first ? (first["playlistVideoRenderer"] as Record<string, Object>) : undefined;
      if (video) {
        const thumbnail = video["thumbnail"] as Record<string, Object>;
        const thumbnails = thumbnail ? (thumbnail["thumbnails"] as Array<Record<string, Object>>) : undefined;
        if (thumbnails && thumbnails.length > 0) {
          return pickBestThumbUrl(thumbnails);
        }
      }
      const lockup = first ? (first["lockupViewModel"] as Record<string, Object>) : undefined;
      if (lockup) {
        const url = getLockupVideoThumbnailUrl(lockup);
        if (url) return url;
      }
      const rich = first ? (first["richItemRenderer"] as Record<string, Object>) : undefined;
      if (rich) {
        const richContent = rich["content"] as Record<string, Object>;
        const nested = richContent ? (richContent["lockupViewModel"] as Record<string, Object>) : undefined;
        if (nested) {
          const url = getLockupVideoThumbnailUrl(nested);
          if (url) return url;
        }
      }
    }
    return "";
  }

  private getFirstTabContent(twoColumn: Record<string, Object> | undefined): Record<string, Object> | undefined {
    if (!twoColumn) return undefined;
    const tabs = twoColumn["tabs"] as Array<Record<string, Object>>;
    if (!tabs || tabs.length === 0) return undefined;
    const firstTabWrapper = tabs[0];
    const tabRenderer = firstTabWrapper ? (firstTabWrapper["tabRenderer"] as Record<string, Object>) : undefined;
    return tabRenderer ? (tabRenderer["content"] as Record<string, Object>) : undefined;
  }

  private getPlaylistHeaderFromTwoColumn(twoColumn: Record<string, Object> | undefined): Record<string, Object> | undefined {
    const tabContent = this.getFirstTabContent(twoColumn);
    if (!tabContent) return undefined;
    const sectionList = tabContent["sectionListRenderer"] as Record<string, Object>;
    const sectionContents = sectionList ? (sectionList["contents"] as Array<Record<string, Object>>) : undefined;
    if (!sectionContents) return undefined;
    for (let i = 0; i < sectionContents.length; i++) {
      const itemSection = sectionContents[i]
        ? (sectionContents[i]["itemSectionRenderer"] as Record<string, Object>)
        : undefined;
      const itemContents = itemSection
        ? (itemSection["contents"] as Array<Record<string, Object>>)
        : undefined;
      if (!itemContents) continue;
      for (let j = 0; j < itemContents.length; j++) {
        const list = itemContents[j]
          ? (itemContents[j]["playlistVideoListRenderer"] as Record<string, Object>)
          : undefined;
        if (list) return list;
      }
    }
    return undefined;
  }
}
