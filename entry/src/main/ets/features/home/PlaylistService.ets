import { SearchPlaylistItem, VideoItem } from 'youtube_core';
import { VideoBuildResult } from './model/FeedResult';
import { ContentCountry, Localization, fetchBrowseContinuation, fetchBrowsePage } from 'youtube_core';
import { getThumbnailUrl, normalizeUrl } from './utils/ThumbnailUtils';
import { getContinuationToken, getPlaylistContinuationToken } from './utils/ContinuationUtils';
import { buildVideoItemFromRenderer } from './utils/VideoItemBuilder';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';


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
    const response = await fetchBrowsePage(this.localization, this.contentCountry, 'VL' + trimmed, '');
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

    const built = this.buildPlaylistVideoItems(rawItems, startId);
    return { items: built.items, nextPageToken: built.nextPageToken, visitorData, totalCountText };
  }

  async fetchPlaylistOverview(playlistId: string): Promise<SearchPlaylistItem | null> {
    const trimmed = (playlistId || '').trim();
    if (!trimmed) {
      return null;
    }
    const response = await fetchBrowsePage(this.localization, this.contentCountry, 'VL' + trimmed, '');
    if (!response) {
      return null;
    }
    const root = response as Record<string, Object>;

    const contents = root["contents"] as Record<string, Object>;
    const twoColumn = contents ? (contents["twoColumnBrowseResultsRenderer"] as Record<string, Object>) : undefined;
    const tabs = twoColumn ? (twoColumn["tabs"] as Array<Record<string, Object>>) : undefined;
    const firstTabWrapper = tabs && tabs.length > 0 ? tabs[0] : undefined;
    const firstTab = firstTabWrapper ? (firstTabWrapper["tabRenderer"] as Record<string, Object>) : undefined;
    const tabContent = firstTab ? (firstTab["content"] as Record<string, Object>) : undefined;

    const sectionList = tabContent ? (tabContent["sectionListRenderer"] as Record<string, Object>) : undefined;
    const sectionContents = sectionList ? (sectionList["contents"] as Array<Record<string, Object>>) : undefined;
    const firstSection = sectionContents && sectionContents.length > 0 ? sectionContents[0] : undefined;
    const itemSection = firstSection ? (firstSection["itemSectionRenderer"] as Record<string, Object>) : undefined;
    const itemContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
    const firstItem = itemContents && itemContents.length > 0 ? itemContents[0] : undefined;
    const playlistHeader = firstItem ? (firstItem["playlistVideoListRenderer"] as Record<string, Object>) : undefined;

    const title = this.getTextFromRuns(playlistHeader ? playlistHeader["title"] : undefined) || "Untitled";
    const shortBylineText = playlistHeader ? playlistHeader["shortBylineText"] as Record<string, Object> : undefined;
    const uploaderName = this.getTextFromRuns(shortBylineText) || "Unknown";
    const countText = this.getPlaylistTotalCountText(playlistHeader);
    let coverUrl = "";
    if (playlistHeader) {
      coverUrl = this.getPlaylistCoverFromHeader(playlistHeader as Record<string, Object>);
      if (!coverUrl) {
        coverUrl = this.getPlaylistCoverFromSidebar(root);
      }
      if (!coverUrl && playlistHeader) {
        const headerContents = playlistHeader["contents"] as Array<Record<string, Object>>;
        coverUrl = this.getCoverFromFirstPlaylistVideo(headerContents ?? []);
      }
    }

    const placeholderColor = ThumbnailPlaceholder.pickColor(playlistId || title, 0);
    return new SearchPlaylistItem(0, trimmed, title, uploaderName, countText, coverUrl, "", placeholderColor);
  }

  private getPlaylistItemsFromTabContent(tabContent: Record<string, Object> | undefined): Array<Record<string, Object>> {
    if (!tabContent) return [];
    const sectionList = tabContent["sectionListRenderer"] as Record<string, Object>;
    const sectionContents = sectionList ? (sectionList["contents"] as Array<Record<string, Object>>) : undefined;
    const firstSection = sectionContents && sectionContents.length > 0 ? sectionContents[0] : undefined;
    const itemSection = firstSection ? (firstSection["itemSectionRenderer"] as Record<string, Object>) : undefined;
    const itemContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
    const firstItem = itemContents && itemContents.length > 0 ? itemContents[0] : undefined;
    const playlistHeader = firstItem ? (firstItem["playlistVideoListRenderer"] as Record<string, Object>) : undefined;
    if (!playlistHeader) return [];
    const contents = playlistHeader["contents"] as Array<Record<string, Object>>;
    return contents ?? [];
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
      const playlistVideo = content["playlistVideoRenderer"] as Record<string, Object>;
      if (playlistVideo) {
        const videoItem = buildVideoItemFromRenderer(playlistVideo, idCounter, '');
        if (videoItem) {
          items.push(videoItem);
          idCounter += 1;
        }
        return;
      }

      const continuation = content["continuationItemRenderer"] as Record<string, Object>;
      if (continuation) {
        nextPageToken = getPlaylistContinuationToken(continuation) ?? nextPageToken;
      }
    });

    return { items, nextPageToken };
  }

  private getPlaylistTotalCountText(playlistHeader: Record<string, Object> | undefined): string {
    if (!playlistHeader) return "";
    const stats = playlistHeader["stats"] as Array<Record<string, Object>>;
    if (!stats || stats.length === 0) return "";
    return this.getTextFromRuns(stats[0]) || "";
  }

  private getPlaylistCoverFromHeader(playlistHeader: Record<string, Object>): string {
    const thumbnail = playlistHeader["thumbnail"] as Record<string, Object>;
    if (!thumbnail) return "";
    const thumbnails = thumbnail["thumbnails"] as Array<Record<string, Object>>;
    if (!thumbnails || thumbnails.length === 0) return "";
    const last = thumbnails[thumbnails.length - 1];
    const url = last ? (last["url"] as string) : "";
    return normalizeUrl(url || "");
  }

  private getPlaylistCoverFromSidebar(root: Record<string, Object>): string {
    const sidebar = root["sidebar"] as Record<string, Object>;
    const playlistSidebar = sidebar ? (sidebar["playlistSidebarRenderer"] as Record<string, Object>) : undefined;
    const sidebarItems = playlistSidebar ? (playlistSidebar["items"] as Array<Record<string, Object>>) : undefined;
    const firstSidebarItem = sidebarItems && sidebarItems.length > 0 ? sidebarItems[0] : undefined;
    const primaryRenderer = firstSidebarItem ? (firstSidebarItem["playlistSidebarPrimaryInfoRenderer"] as Record<string, Object>) : undefined;
    const thumbnail = primaryRenderer ? (primaryRenderer["thumbnailRenderer"] as Record<string, Object>) : undefined;
    const videoThumbnail = thumbnail ? (thumbnail["playlistVideoThumbnailRenderer"] as Record<string, Object>) : undefined;
    const thumb = videoThumbnail ? (videoThumbnail["thumbnail"] as Record<string, Object>) : undefined;
    const thumbnails = thumb ? (thumb["thumbnails"] as Array<Record<string, Object>>) : undefined;
    if (!thumbnails || thumbnails.length === 0) return "";
    const last = thumbnails[thumbnails.length - 1];
    const url = last ? (last["url"] as string) : "";
    return normalizeUrl(url || "");
  }

  private getCoverFromFirstPlaylistVideo(rawItems: Array<Record<string, Object>>): string {
    const first = rawItems.length > 0 ? rawItems[0] : undefined;
    const video = first ? (first["playlistVideoRenderer"] as Record<string, Object>) : undefined;
    if (!video) return "";
    const thumbnail = video["thumbnail"] as Record<string, Object>;
    if (!thumbnail) return "";
    const thumbnails = thumbnail["thumbnails"] as Array<Record<string, Object>>;
    if (!thumbnails || thumbnails.length === 0) return "";
    const last = thumbnails[thumbnails.length - 1];
    const url = last ? (last["url"] as string) : "";
    return normalizeUrl(url || "");
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
    const firstSection = sectionContents && sectionContents.length > 0 ? sectionContents[0] : undefined;
    const itemSection = firstSection ? (firstSection["itemSectionRenderer"] as Record<string, Object>) : undefined;
    const itemContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
    const firstItem = itemContents && itemContents.length > 0 ? itemContents[0] : undefined;
    return firstItem ? (firstItem["playlistVideoListRenderer"] as Record<string, Object>) : undefined;
  }

  private getTextFromRuns(source: Object | undefined): string {
    if (!source) return "";
    const anySource = source as Record<string, Object>;
    const simpleText = anySource["simpleText"] as string;
    if (simpleText) return simpleText;
    const runs = anySource["runs"] as Array<Record<string, Object>>;
    if (!runs || runs.length === 0) return "";
    return runs.map((run) => (run["text"] as string) || "").join("");
  }
}
