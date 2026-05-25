import { VideoItem, SearchInfoItem, SearchPageResult, SearchStreamItem, SearchPlaylistItem } from 'youtube_core';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';
import { getTextFromRuns } from './utils/TextUtils';
import { getThumbnailUrlFromThumbnailObject } from './utils/ThumbnailUtils';
import { getMusicContinuationToken } from './utils/ContinuationUtils';

export class MusicSearchService {
  static isMusicSearch(contentFilters: string[] | undefined): boolean {
    return !!(contentFilters && contentFilters.length > 0 && contentFilters[0].startsWith('music_'));
  }

  static parseInitialMusicSearchResponse(
    response: Record<string, Object>,
    startId: number,
    contentFilters: string[]
  ): SearchPageResult {
    let items: Array<SearchInfoItem> = [];
    let nextPageToken: string | null = null;

    const contents = response["contents"] as Record<string, Object>;
    const tabbed = contents ? (contents["tabbedSearchResultsRenderer"] as Record<string, Object>) : undefined;
    const tabs = tabbed ? (tabbed["tabs"] as Array<Record<string, Object>>) : undefined;
    const tab0 = tabs && tabs.length > 0 ? tabs[0] : undefined;
    const tabRenderer = tab0 ? (tab0["tabRenderer"] as Record<string, Object>) : undefined;
    const tabContent = tabRenderer ? (tabRenderer["content"] as Record<string, Object>) : undefined;
    const sectionList = tabContent ? (tabContent["sectionListRenderer"] as Record<string, Object>) : undefined;
    const sections = sectionList ? (sectionList["contents"] as Array<Record<string, Object>>) : [];

    for (const section of sections) {
      const musicShelf = section["musicShelfRenderer"] as Record<string, Object>;
      if (!musicShelf) {
        continue;
      }
      const shelfContents = musicShelf["contents"] as Array<Record<string, Object>>;
      if (shelfContents && shelfContents.length > 0) {
        const built = MusicSearchService.buildMusicSearchItemsFromContents(shelfContents, startId + items.length, contentFilters);
        items = items.concat(built);
      }
      const continuations = musicShelf["continuations"] as Array<Record<string, Object>>;
      const token = getMusicContinuationToken(continuations);
      if (token) {
        nextPageToken = token;
      }
    }

    return { items, nextPageToken };
  }

  static parseMusicSearchContinuationResponse(
    response: Record<string, Object>,
    startId: number,
    contentFilters: string[]
  ): SearchPageResult {
    let items: Array<SearchInfoItem> = [];
    let nextPageToken: string | null = null;

    const continuationContents = response["continuationContents"] as Record<string, Object>;
    const musicShelf = continuationContents
      ? (continuationContents["musicShelfContinuation"] as Record<string, Object>)
      : undefined;
    if (musicShelf) {
      const shelfContents = musicShelf["contents"] as Array<Record<string, Object>>;
      if (shelfContents && shelfContents.length > 0) {
        items = MusicSearchService.buildMusicSearchItemsFromContents(shelfContents, startId, contentFilters);
      }
      const continuations = musicShelf["continuations"] as Array<Record<string, Object>>;
      const token = getMusicContinuationToken(continuations);
      if (token) {
        nextPageToken = token;
      }
    }

    return { items, nextPageToken };
  }

  private static buildMusicSearchItemsFromContents(
    contents: Array<Record<string, Object>>,
    startId: number,
    contentFilters: string[]
  ): Array<SearchInfoItem> {
    let idCounter = startId;
    const items: Array<SearchInfoItem> = [];
    const searchType = contentFilters && contentFilters.length > 0 ? contentFilters[0] : "";

    contents.forEach((entry) => {
      const renderer = entry["musicResponsiveListItemRenderer"] as Record<string, Object>;
      if (!renderer) return;
      const displayPolicy = (renderer["musicItemRendererDisplayPolicy"] as string) || "";
      if (displayPolicy === "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT") {
        return;
      }

      const flexColumns = renderer["flexColumns"] as Array<Record<string, Object>>;
      const title = MusicSearchService.getMusicTextFromFlexColumn(flexColumns, 0) || "Untitled";
      const descriptionRuns = MusicSearchService.getMusicDescriptionRuns(renderer);

      if (searchType === "music_songs" || searchType === "music_videos") {
        const videoId = MusicSearchService.getMusicVideoId(renderer);
        if (!videoId) return;
        const author = MusicSearchService.getMusicAuthorFromRuns(descriptionRuns) || "Unknown";
        const viewCount = searchType === "music_videos"
          ? MusicSearchService.getMusicViewCountFromRuns(descriptionRuns)
          : "";
        const thumbnailUrl = MusicSearchService.getMusicThumbnailUrl(renderer);
        const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, idCounter);
        const videoItem = new VideoItem(idCounter, videoId, title, author, viewCount, thumbnailUrl,
          false, placeholderColor, "", "", "", "");
        items.push(new SearchStreamItem(idCounter, videoItem));
        idCounter += 1;
        return;
      }

      if (searchType === "music_albums" || searchType === "music_playlists") {
        const playlistId = MusicSearchService.getMusicPlaylistId(renderer);
        const uploaderName = MusicSearchService.getMusicUploaderFromRuns(descriptionRuns, searchType);
        const coverUrl = MusicSearchService.getMusicThumbnailUrl(renderer);
        const placeholderColor = ThumbnailPlaceholder.pickColor(playlistId || title, idCounter);
        items.push(new SearchPlaylistItem(idCounter, playlistId, title, uploaderName, "", coverUrl, "",
          placeholderColor));
        idCounter += 1;
      }
    });

    return items;
  }

  private static getMusicTextFromFlexColumn(
    flexColumns: Array<Record<string, Object>> | undefined,
    index: number
  ): string {
    if (!flexColumns || flexColumns.length <= index) return "";
    const column = flexColumns[index] as Record<string, Object>;
    const renderer = column ? (column["musicResponsiveListItemFlexColumnRenderer"] as Record<string, Object>) : undefined;
    const text = renderer ? (renderer["text"] as Record<string, Object>) : undefined;
    return getTextFromRuns(text);
  }

  private static getMusicDescriptionRuns(renderer: Record<string, Object>): Array<Record<string, Object>> {
    const flexColumns = renderer["flexColumns"] as Array<Record<string, Object>>;
    if (!flexColumns || flexColumns.length < 2) return [];
    const column = flexColumns[1] as Record<string, Object>;
    const rendererColumn = column ? (column["musicResponsiveListItemFlexColumnRenderer"] as Record<string, Object>) : undefined;
    const text = rendererColumn ? (rendererColumn["text"] as Record<string, Object>) : undefined;
    const runs = text ? (text["runs"] as Array<Record<string, Object>>) : undefined;
    return runs ?? [];
  }

  private static getMusicAuthorFromRuns(runs: Array<Record<string, Object>>): string {
    const first = runs && runs.length > 0 ? runs[0] : undefined;
    return first ? ((first["text"] as string) || "") : "";
  }

  private static getMusicUploaderFromRuns(runs: Array<Record<string, Object>>, searchType: string): string {
    if (!runs || runs.length === 0) return "";
    if (searchType === "music_albums") {
      const candidate = runs.length > 2 ? runs[2] : runs[0];
      return candidate ? ((candidate["text"] as string) || "") : "";
    }
    const first = runs[0];
    return first ? ((first["text"] as string) || "") : "";
  }

  private static getMusicViewCountFromRuns(runs: Array<Record<string, Object>>): string {
    if (!runs || runs.length === 0) return "";
    const candidate = runs.length >= 3 ? runs[runs.length - 3] : runs[runs.length - 1];
    return candidate ? ((candidate["text"] as string) || "") : "";
  }

  private static getMusicVideoId(renderer: Record<string, Object>): string {
    const playlistItemData = renderer["playlistItemData"] as Record<string, Object>;
    return playlistItemData ? ((playlistItemData["videoId"] as string) || "") : "";
  }

  private static getMusicPlaylistId(renderer: Record<string, Object>): string {
    const menu = renderer["menu"] as Record<string, Object>;
    const menuRenderer = menu ? (menu["menuRenderer"] as Record<string, Object>) : undefined;
    const items = menuRenderer ? (menuRenderer["items"] as Array<Record<string, Object>>) : undefined;
    if (items) {
      for (const item of items) {
        const toggle = item["toggleMenuServiceItemRenderer"] as Record<string, Object>;
        const toggled = toggle ? (toggle["toggledServiceEndpoint"] as Record<string, Object>) : undefined;
        const likeEndpoint = toggled ? (toggled["likeEndpoint"] as Record<string, Object>) : undefined;
        const target = likeEndpoint ? (likeEndpoint["target"] as Record<string, Object>) : undefined;
        const playlistId = target ? (target["playlistId"] as string) : "";
        if (playlistId) return playlistId;
      }
    }
    const overlay = renderer["overlay"] as Record<string, Object>;
    const thumbOverlay = overlay ? (overlay["musicItemThumbnailOverlayRenderer"] as Record<string, Object>) : undefined;
    const content = thumbOverlay ? (thumbOverlay["content"] as Record<string, Object>) : undefined;
    const playButton = content ? (content["musicPlayButtonRenderer"] as Record<string, Object>) : undefined;
    const endpoint = playButton ? (playButton["playNavigationEndpoint"] as Record<string, Object>) : undefined;
    const watchPlaylist = endpoint ? (endpoint["watchPlaylistEndpoint"] as Record<string, Object>) : undefined;
    return watchPlaylist ? ((watchPlaylist["playlistId"] as string) || "") : "";
  }

  private static getMusicThumbnailUrl(renderer: Record<string, Object>): string {
    const thumbnail = renderer["thumbnail"] as Record<string, Object>;
    const musicThumbnail = thumbnail ? (thumbnail["musicThumbnailRenderer"] as Record<string, Object>) : undefined;
    const inner = musicThumbnail ? (musicThumbnail["thumbnail"] as Record<string, Object>) : undefined;
    return getThumbnailUrlFromThumbnailObject(inner);
  }
}
