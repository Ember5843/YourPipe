import { SearchChannelItem, SearchInfoItem, SearchPageResult, SearchPlaylistItem, SearchStreamItem, VideoItem } from 'youtube_core';
import { ContentCountry, Localization, fetchSearchContinuation, fetchSearchPage } from 'youtube_core';
import { getLockupChannelId, getLockupPlaylistCoverUrl, getLockupPlaylistId, getLockupTitle, getLockupUploaderName, getLockupVideoId, getLockupVideoThumbnailUrl } from './utils/LockupViewModelParser';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';
import { getTextFromRuns } from './utils/TextUtils';
import { getThumbnailUrlFromThumbnailObject, pickBestThumbUrl } from './utils/ThumbnailUtils';
import { getContinuationToken } from './utils/ContinuationUtils';
import { buildVideoItemFromReelRenderer, buildVideoItemFromRenderer, buildVideoItemFromShortsLockupViewModel } from './utils/VideoItemBuilder';
import { MusicSearchService } from './MusicSearchService';
import { SearchBuildResult, VideoBuildResult } from './model/FeedResult';

export interface VideoSearchResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
}

export interface MixedSearchResult {
  items: Array<SearchInfoItem>;
  nextPageToken: string | null;
}

export class SearchService {
  private localization: Localization;
  private contentCountry: ContentCountry;
  private currentFilters: string[] = [];

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  setFilters(filters: string[]): void {
    this.currentFilters = filters ?? [];
  }

  async fetchInitial(query: string, startId: number): Promise<VideoSearchResult> {
    const trimmed = (query || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null };
    }
    const response = await fetchSearchPage(this.localization, this.contentCountry, trimmed, [], '');
    if (!response) {
      throw new Error('Empty search response');
    }
    return this.parseVideoInitialResponse(response as Record<string, Object>, startId);
  }

  async fetchNext(nextPageToken: string, startId: number): Promise<VideoSearchResult> {
    const trimmed = (nextPageToken || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null };
    }
    const response = await fetchSearchContinuation(this.localization, this.contentCountry, trimmed);
    if (!response) {
      throw new Error('Empty continuation response');
    }
    return this.parseVideoContinuationResponse(response as Record<string, Object>, startId);
  }

  async searchInitial(query: string, startId: number): Promise<MixedSearchResult> {
    const trimmed = (query || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null };
    }
    const filters = this.currentFilters;
    const response = await fetchSearchPage(this.localization, this.contentCountry, trimmed, filters, '');
    if (!response) {
      throw new Error('Empty search response');
    }
    if (MusicSearchService.isMusicSearch(filters)) {
      return MusicSearchService.parseInitialMusicSearchResponse(response as Record<string, Object>, startId, filters);
    }
    return this.parseMixedInitialResponse(response as Record<string, Object>, startId);
  }

  async searchNext(nextPageToken: string, startId: number): Promise<MixedSearchResult> {
    const trimmed = (nextPageToken || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null };
    }
    const filters = this.currentFilters;
    const response = await fetchSearchContinuation(this.localization, this.contentCountry, trimmed, filters);
    if (!response) {
      throw new Error('Empty continuation response');
    }
    if (MusicSearchService.isMusicSearch(filters)) {
      return MusicSearchService.parseMusicSearchContinuationResponse(response as Record<string, Object>, startId, filters);
    }
    return this.parseMixedContinuationResponse(response as Record<string, Object>, startId);
  }

  private parseVideoInitialResponse(response: Record<string, Object>, startId: number): VideoSearchResult {
    let items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;

    const contents = response["contents"] as Record<string, Object>;
    const twoColumn = contents ? (contents["twoColumnSearchResultsRenderer"] as Record<string, Object>) : undefined;
    const primaryContents = twoColumn ? (twoColumn["primaryContents"] as Record<string, Object>) : undefined;
    const sectionList = primaryContents ? (primaryContents["sectionListRenderer"] as Record<string, Object>) : undefined;
    const sectionContents = sectionList ? (sectionList["contents"] as Array<Record<string, Object>>) : undefined;

    if (sectionContents) {
      sectionContents.forEach((section) => {
        const itemSection = section["itemSectionRenderer"] as Record<string, Object>;
        const sectionItemContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
        if (sectionItemContents && sectionItemContents.length > 0) {
          const newItems = this.buildVideoItemsFromContents(sectionItemContents, startId + items.length);
          items = items.concat(newItems);
        }
        const tokenInSection = this.getContinuationTokenFromSection(section);
        const tokenInContents = this.getContinuationTokenFromContents(sectionItemContents);
        nextPageToken = tokenInSection || tokenInContents || nextPageToken;
      });
    }

    return { items, nextPageToken };
  }

  private parseVideoContinuationResponse(response: Record<string, Object>, startId: number): VideoSearchResult {
    let items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;

    const commands = response["onResponseReceivedCommands"] as Array<Record<string, Object>>;
    if (commands) {
      commands.forEach((command) => {
        const append = command["appendContinuationItemsAction"] as Record<string, Object>;
        const continuationItems = append ? (append["continuationItems"] as Array<Record<string, Object>>) : undefined;
        if (!continuationItems) {
          return;
        }
        continuationItems.forEach((continuationItem) => {
          const itemSection = continuationItem["itemSectionRenderer"] as Record<string, Object>;
          const sectionContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
          if (sectionContents && sectionContents.length > 0) {
            const newItems = this.buildVideoItemsFromContents(sectionContents, startId + items.length);
            items = items.concat(newItems);
          }
          const contRenderer = continuationItem["continuationItemRenderer"] as Record<string, Object>;
          if (contRenderer) {
            nextPageToken = getContinuationToken(contRenderer) ?? nextPageToken;
          }
        });
      });
    }

    return { items, nextPageToken };
  }

  private parseMixedInitialResponse(response: Record<string, Object>, startId: number): MixedSearchResult {
    let items: Array<SearchInfoItem> = [];
    let nextPageToken: string | null = null;

    const contents = response["contents"] as Record<string, Object>;
    const twoColumn = contents ? (contents["twoColumnSearchResultsRenderer"] as Record<string, Object>) : undefined;
    const primaryContents = twoColumn ? (twoColumn["primaryContents"] as Record<string, Object>) : undefined;
    const sectionList = primaryContents ? (primaryContents["sectionListRenderer"] as Record<string, Object>) : undefined;
    const sectionContents = sectionList ? (sectionList["contents"] as Array<Record<string, Object>>) : undefined;

    if (sectionContents) {
      sectionContents.forEach((section) => {
        const itemSection = section["itemSectionRenderer"] as Record<string, Object>;
        const sectionItemContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
        if (sectionItemContents && sectionItemContents.length > 0) {
          const built = this.buildSearchItemsFromContents(sectionItemContents, startId + items.length);
          items = items.concat(built.items);
          nextPageToken = built.nextPageToken ?? nextPageToken;
        }
        const tokenInSection = this.getContinuationTokenFromSection(section);
        nextPageToken = tokenInSection ?? nextPageToken;
      });
    }

    return { items, nextPageToken };
  }

  private parseMixedContinuationResponse(response: Record<string, Object>, startId: number): MixedSearchResult {
    const actions = response["onResponseReceivedCommands"] as Array<Record<string, Object>>;
    let items: Array<SearchInfoItem> = [];
    let nextPageToken: string | null = null;

    if (actions && actions.length > 0) {
      actions.forEach((action) => {
        const append = action["appendContinuationItemsAction"] as Record<string, Object>;
        const continuationItems = append ? (append["continuationItems"] as Array<Record<string, Object>>) : undefined;
        if (!continuationItems) {
          return;
        }
        continuationItems.forEach((continuationItem) => {
          const itemSection = continuationItem["itemSectionRenderer"] as Record<string, Object>;
          const sectionContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
          if (sectionContents && sectionContents.length > 0) {
            const built = this.buildSearchItemsFromContents(sectionContents, startId + items.length);
            items = items.concat(built.items);
          }
          const contRenderer = continuationItem["continuationItemRenderer"] as Record<string, Object>;
          if (contRenderer) {
            nextPageToken = getContinuationToken(contRenderer) ?? nextPageToken;
          }
        });
      });
    }

    return { items, nextPageToken };
  }

  private buildVideoItemsFromContents(sectionContents: Array<Record<string, Object>>, startId: number): Array<VideoItem> {
    let idCounter = startId;
    const items: Array<VideoItem> = [];
    sectionContents.forEach((entry) => {
      const promo = entry["backgroundPromoRenderer"] as Record<string, Object>;
      if (promo) {
        const message = getTextFromRuns(promo["bodyText"]) || getContext().resourceManager.getStringSync($r('app.string.yt_search_no_results').id);
        throw new Error(message);
      }

      const video = entry["videoRenderer"] as Record<string, Object>;
      if (video) {
        const videoId = (video["videoId"] as string) || "";
        const title = getTextFromRuns(video["title"]) || "Untitled";
        const author = getTextFromRuns(video["ownerText"]) ||
          getTextFromRuns(video["longBylineText"]) ||
          "Unknown";
        const viewCount = getTextFromRuns(video["viewCountText"]) || "";
        const isLive = this.hasLiveBadge(video);
        const thumbnailUrl = getThumbnailUrlFromThumbnailObject(video["thumbnail"] as Record<string, Object>);
        const channelId = this.getChannelId(video);
        const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, idCounter);
        items.push(new VideoItem(idCounter, videoId, title, author, viewCount, thumbnailUrl, isLive,
          placeholderColor, channelId, "", "", ""));
        idCounter += 1;
      }
    });
    return items;
  }

  private buildSearchItemsFromContents(
    contents: Array<Record<string, Object>>,
    startId: number
  ): SearchBuildResult {
    let idCounter = startId;
    const items: Array<SearchInfoItem> = [];
    let nextPageToken: string | null = null;

    contents.forEach((content) => {
      const videoRenderer = content["videoRenderer"] as Record<string, Object>;
      if (videoRenderer) {
        const videoItem = buildVideoItemFromRenderer(videoRenderer, idCounter, '');
        if (videoItem) {
          items.push(new SearchStreamItem(videoItem.id, videoItem));
          idCounter += 1;
        }
        return;
      }

      const reelRenderer = content["reelItemRenderer"] as Record<string, Object>;
      if (reelRenderer) {
        const videoItem = buildVideoItemFromReelRenderer(reelRenderer, idCounter);
        if (videoItem) {
          items.push(new SearchStreamItem(videoItem.id, videoItem));
          idCounter += 1;
        }
        return;
      }

      const shortsLockup = content["shortsLockupViewModel"] as Record<string, Object>;
      if (shortsLockup) {
        const videoItem = buildVideoItemFromShortsLockupViewModel(shortsLockup, idCounter);
        if (videoItem) {
          items.push(new SearchStreamItem(videoItem.id, videoItem));
          idCounter += 1;
        }
        return;
      }

      const channelRenderer = content["channelRenderer"] as Record<string, Object>;
      if (channelRenderer) {
        const channelItem = this.buildChannelItem(channelRenderer, idCounter);
        if (channelItem) {
          items.push(channelItem);
          idCounter += 1;
        }
        return;
      }

      const playlistRenderer = content["playlistRenderer"] as Record<string, Object>;
      if (playlistRenderer) {
        const playlistItem = this.buildPlaylistItem(playlistRenderer, idCounter);
        if (playlistItem) {
          items.push(playlistItem);
          idCounter += 1;
        }
        return;
      }

      const lockup = content["lockupViewModel"] as Record<string, Object>;
      if (lockup) {
        const contentType = (lockup["contentType"] as string) || "";

        if (contentType === "LOCKUP_CONTENT_TYPE_VIDEO") {
          const videoId = getLockupVideoId(lockup);
          const title = getLockupTitle(lockup) || "Untitled";
          const author = getLockupUploaderName(lockup) || "Unknown";
          const thumbnailUrl = getLockupVideoThumbnailUrl(lockup);
          const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, idCounter);
          const channelId = getLockupChannelId(lockup);
          const videoItem = new VideoItem(idCounter, videoId, title, author, "", thumbnailUrl, false, placeholderColor, channelId, "", "", "");
          items.push(new SearchStreamItem(videoItem.id, videoItem));
          idCounter += 1;
          return;
        }

        if (contentType === "LOCKUP_CONTENT_TYPE_SHORTS") {
          const videoId = getLockupVideoId(lockup);
          const title = getLockupTitle(lockup) || "Untitled";
          const thumbnailUrl = getLockupVideoThumbnailUrl(lockup);
          const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, idCounter);
          const author = getLockupUploaderName(lockup) || "";
          const channelId = getLockupChannelId(lockup);
          const videoItem = new VideoItem(idCounter, videoId, title, author, "", thumbnailUrl, false, placeholderColor, channelId, "", "", "");
          items.push(new SearchStreamItem(videoItem.id, videoItem));
          idCounter += 1;
          return;
        }

        if (contentType === "LOCKUP_CONTENT_TYPE_PLAYLIST" || contentType === "LOCKUP_CONTENT_TYPE_PODCAST") {
          const playlistId = getLockupPlaylistId(lockup);
          const name = getLockupTitle(lockup) || "Untitled";
          const uploaderName = getLockupUploaderName(lockup) || "";
          const coverUrl = getLockupPlaylistCoverUrl(lockup);
          const placeholderColor = ThumbnailPlaceholder.pickColor(playlistId || name, idCounter);
          items.push(new SearchPlaylistItem(idCounter, playlistId, name, uploaderName, "", coverUrl, "", placeholderColor));
          idCounter += 1;
          return;
        }

        if (contentType === "LOCKUP_CONTENT_TYPE_CHANNEL") {
          const channelId = getLockupChannelId(lockup);
          const title = getLockupTitle(lockup) || "Untitled";
          const thumbnailUrl = getThumbnailUrlFromThumbnailObject(lockup["thumbnail"] as Record<string, Object>);
          const subscriberCount = getLockupUploaderName(lockup) || "";
          const description = "";
          const placeholderColor = ThumbnailPlaceholder.pickColor(channelId || title, idCounter);
          items.push(new SearchChannelItem(idCounter, channelId, title, subscriberCount, "", thumbnailUrl, description, placeholderColor, ""));
          idCounter += 1;
          return;
        }
      }

      const continuation = content["continuationItemRenderer"] as Record<string, Object>;
      if (continuation) {
        nextPageToken = getContinuationToken(continuation) ?? nextPageToken;
      }
    });

    return { items, nextPageToken };
  }

  private buildChannelItem(channelRenderer: Record<string, Object>, idCounter: number): SearchChannelItem | null {
    const channelId = (channelRenderer["channelId"] as string) || "";
    const title = getTextFromRuns(channelRenderer["title"]) || "Untitled";
    const subscriberCount = this.getTextFromRuns(channelRenderer["subscriberCountText"]) || "";
    const videoCountText = this.getTextFromRuns(channelRenderer["videoCountText"]) || "";
    const descriptionSnippet = this.getTextFromRuns(channelRenderer["descriptionSnippet"]) || "";
    const thumbnail = channelRenderer["thumbnail"] as Record<string, Object>;
    const thumbnailUrl = getThumbnailUrlFromThumbnailObject(thumbnail);
    const placeholderColor = ThumbnailPlaceholder.pickColor(channelId || title, idCounter);
    return new SearchChannelItem(idCounter, channelId, title, subscriberCount, videoCountText, thumbnailUrl, descriptionSnippet, placeholderColor, "");
  }

  private buildPlaylistItem(playlistRenderer: Record<string, Object>, idCounter: number): SearchPlaylistItem | null {
    const playlistId = (playlistRenderer["playlistId"] as string) || "";
    const title = getTextFromRuns(playlistRenderer["title"]) || "Untitled";
    const shortBylineText = playlistRenderer["shortBylineText"] as Record<string, Object>;
    const uploaderName = getTextFromRuns(shortBylineText) || "Unknown";
    const videoCount = getTextFromRuns(playlistRenderer["videoCount"]) || "";
    const thumbnail = playlistRenderer["thumbnails"] as Array<Record<string, Object>>;
    let coverUrl = "";
    if (thumbnail && thumbnail.length > 0) {
      const firstThumbnail = thumbnail[0];
      const thumbnails = firstThumbnail ? (firstThumbnail["thumbnails"] as Array<Record<string, Object>>) : undefined;
      if (thumbnails && thumbnails.length > 0) {
        coverUrl = pickBestThumbUrl(thumbnails);
      }
    }
    const placeholderColor = ThumbnailPlaceholder.pickColor(playlistId || title, idCounter);
    return new SearchPlaylistItem(idCounter, playlistId, title, uploaderName, videoCount, coverUrl, "", placeholderColor);
  }

  private getContinuationTokenFromSection(section: Record<string, Object>): string | null {
    const cont = section["continuationItemRenderer"] as Record<string, Object>;
    if (!cont) return null;
    return getContinuationToken(cont);
  }

  private getContinuationTokenFromContents(contents: Array<Record<string, Object>> | undefined): string | null {
    if (!contents || contents.length === 0) return null;
    const last = contents[contents.length - 1];
    if (!last) return null;
    const cont = last["continuationItemRenderer"] as Record<string, Object>;
    if (!cont) return null;
    return getContinuationToken(cont);
  }

  private hasLiveBadge(video: Record<string, Object>): boolean {
    // Keep search in sync with feed/kiosk detection (NewPipe/PipePipe rules).
    const badges = video["badges"] as Array<Record<string, Object>>;
    if (badges) {
      for (const badge of badges) {
        const badgeRenderer = badge["metadataBadgeRenderer"] as Record<string, Object>;
        if (!badgeRenderer) {
          continue;
        }
        const style = ((badgeRenderer["style"] as string) || "").toUpperCase();
        if (style === "BADGE_STYLE_TYPE_LIVE_NOW" || style === "BADGE_STYLE_TYPE_LIVE"
          || style.indexOf("LIVE") >= 0) {
          return true;
        }
        const label = ((badgeRenderer["label"] as string) || "").toLowerCase();
        if (label === "live" || label === "live now" || label.indexOf("live") >= 0
          || ((badgeRenderer["label"] as string) || "").indexOf("直播") >= 0) {
          return true;
        }
      }
    }
    const thumbnailOverlays = video["thumbnailOverlays"] as Array<Record<string, Object>>;
    if (thumbnailOverlays) {
      for (const overlay of thumbnailOverlays) {
        const overlayRenderer = overlay["thumbnailOverlayTimeStatusRenderer"] as Record<string, Object>;
        if (overlayRenderer) {
          const style = ((overlayRenderer["style"] as string) || "").toUpperCase();
          if (style === "LIVE") {
            return true;
          }
        }
      }
    }
    // lockup-style overlays nested under contentImage
    const contentImage = video["contentImage"] as Record<string, Object>;
    const tvm = contentImage
      ? (contentImage["thumbnailViewModel"] as Record<string, Object>)
      : undefined;
    const overlays = tvm ? (tvm["overlays"] as Array<Record<string, Object>>) : undefined;
    if (overlays) {
      for (let i = 0; i < overlays.length; i++) {
        const overlay = overlays[i];
        const bottomVm = overlay
          ? (overlay["thumbnailBottomOverlayViewModel"] as Record<string, Object>)
          : undefined;
        const lockupBadges = bottomVm
          ? (bottomVm["badges"] as Array<Record<string, Object>>)
          : undefined;
        if (lockupBadges) {
          for (let b = 0; b < lockupBadges.length; b++) {
            const bvm = lockupBadges[b]
              ? (lockupBadges[b]["thumbnailBadgeViewModel"] as Record<string, Object>)
              : undefined;
            const badgeStyle = bvm ? (((bvm["badgeStyle"] as string) || "").toUpperCase()) : "";
            if (badgeStyle.indexOf("LIVE") >= 0) {
              return true;
            }
          }
        }
        const badgeVm = overlay
          ? (overlay["thumbnailOverlayBadgeViewModel"] as Record<string, Object>)
          : undefined;
        const thumbBadges = badgeVm
          ? (badgeVm["thumbnailBadges"] as Array<Record<string, Object>>)
          : undefined;
        if (thumbBadges) {
          for (let b = 0; b < thumbBadges.length; b++) {
            const bvm = thumbBadges[b]
              ? (thumbBadges[b]["thumbnailBadgeViewModel"] as Record<string, Object>)
              : undefined;
            const badgeStyle = bvm ? (((bvm["badgeStyle"] as string) || "").toUpperCase()) : "";
            if (badgeStyle.indexOf("LIVE") >= 0) {
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  private getChannelId(video: Record<string, Object>): string {
    const ownerText = video["ownerText"] as Record<string, Object>;
    const runs = ownerText ? (ownerText["runs"] as Array<Record<string, Object>>) : undefined;
    if (runs && runs.length > 0) {
      const firstRun = runs[0];
      const navigationEndpoint = firstRun ? (firstRun["navigationEndpoint"] as Record<string, Object>) : undefined;
      const browseEndpoint = navigationEndpoint ? (navigationEndpoint["browseEndpoint"] as Record<string, Object>) : undefined;
      if (browseEndpoint) {
        return (browseEndpoint["browseId"] as string) || "";
      }
    }
    const longBylineText = video["longBylineText"] as Record<string, Object>;
    const longRuns = longBylineText ? (longBylineText["runs"] as Array<Record<string, Object>>) : undefined;
    if (longRuns && longRuns.length > 0) {
      const firstRun = longRuns[0];
      const navigationEndpoint = firstRun ? (firstRun["navigationEndpoint"] as Record<string, Object>) : undefined;
      const browseEndpoint = navigationEndpoint ? (navigationEndpoint["browseEndpoint"] as Record<string, Object>) : undefined;
      if (browseEndpoint) {
        return (browseEndpoint["browseId"] as string) || "";
      }
    }
    return "";
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
