import { VideoItem } from 'youtube_core';
import { ContentCountry, Localization, fetchBrowseContinuation, fetchBrowsePage } from 'youtube_core';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';
import { getContinuationToken } from './utils/ContinuationUtils';
import { getLockupChannelId, getLockupTitle, getLockupUploaderName, getLockupVideoId, getLockupVideoThumbnailUrl } from './utils/LockupViewModelParser';
import { buildVideoItemFromReelRenderer, buildVideoItemFromRenderer, buildVideoItemFromShortsLockupViewModel } from './utils/VideoItemBuilder';
import { getShortsLockupThumbnailUrl } from './utils/ThumbnailUtils';

export interface KioskPageResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
  visitorData: string;
}

interface HomeKioskBuildResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
}

export class HomeFeedService {
  private localization: Localization;
  private contentCountry: ContentCountry;
  private readonly HOME_BROWSE_ID: string = 'UC4R8DWoMoI7CAwX8_LjQHig';
  private readonly HOME_PARAMS: string = 'EgdsaXZldGFikgEDCKEK';

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  async fetchHomeKioskInitial(startId: number): Promise<KioskPageResult> {
    const response = await fetchBrowsePage(this.localization, this.contentCountry, this.HOME_BROWSE_ID, this.HOME_PARAMS);
    if (!response) {
      throw new Error('Empty browse response');
    }
    return this.parseHomeBrowseInitialResponse(response as Record<string, Object>, startId);
  }

  async fetchHomeKioskNext(nextPageToken: string, visitorData: string, startId: number): Promise<KioskPageResult> {
    const response = await fetchBrowseContinuation(this.localization, this.contentCountry, nextPageToken, visitorData);
    if (!response) {
      throw new Error('Empty browse continuation response');
    }
    return this.parseHomeBrowseContinuationResponse(response as Record<string, Object>, visitorData, startId);
  }

  private parseHomeBrowseInitialResponse(response: Record<string, Object>, startId: number): KioskPageResult {
    let items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;

    const responseContext = response["responseContext"] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext["visitorData"] as string) : "") || "";

    const contents = response["contents"] as Record<string, Object>;
    const twoColumn = contents ? (contents["twoColumnBrowseResultsRenderer"] as Record<string, Object>) : undefined;
    const tabs = twoColumn ? (twoColumn["tabs"] as Array<Record<string, Object>>) : undefined;
    const tab0 = tabs && tabs.length > 0 ? tabs[0] : undefined;
    const tabRenderer = tab0 ? (tab0["tabRenderer"] as Record<string, Object>) : undefined;
    const tabContent = tabRenderer ? (tabRenderer["content"] as Record<string, Object>) : undefined;

    const rawItems: Array<Record<string, Object>> = this.getHomeKioskItemsFromTabContent(tabContent);
    const built = this.buildHomeKioskVideoItems(rawItems, startId);
    items = built.items;
    nextPageToken = built.nextPageToken;

    return { items, nextPageToken, visitorData };
  }

  private parseHomeBrowseContinuationResponse(
    response: Record<string, Object>,
    visitorData: string,
    startId: number
  ): KioskPageResult {
    let items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;

    const actions = response["onResponseReceivedActions"] as Array<Record<string, Object>>;
    if (actions && actions.length > 0) {
      actions.forEach((action) => {
        const append = action["appendContinuationItemsAction"] as Record<string, Object>;
        const continuationItems = append ? (append["continuationItems"] as Array<Record<string, Object>>) : undefined;
        if (!continuationItems || continuationItems.length === 0) {
          return;
        }
        const built = this.buildHomeKioskVideoItems(continuationItems, startId + items.length);
        items = items.concat(built.items);
        nextPageToken = built.nextPageToken ?? nextPageToken;
      });
    }

    return { items, nextPageToken, visitorData };
  }

  private getHomeKioskItemsFromTabContent(tabContent: Record<string, Object> | undefined): Array<Record<string, Object>> {
    if (!tabContent) return [];
    const sectionList = tabContent["sectionListRenderer"] as Record<string, Object>;
    if (sectionList) {
      const contents = sectionList["contents"] as Array<Record<string, Object>>;
      const first = contents && contents.length > 0 ? contents[0] : undefined;
      const itemSection = first ? (first["itemSectionRenderer"] as Record<string, Object>) : undefined;
      const sectionContents = itemSection ? (itemSection["contents"] as Array<Record<string, Object>>) : undefined;
      const firstSection = sectionContents && sectionContents.length > 0 ? sectionContents[0] : undefined;
      const grid = firstSection ? (firstSection["gridRenderer"] as Record<string, Object>) : undefined;
      const items = grid ? (grid["items"] as Array<Record<string, Object>>) : undefined;
      if (items && items.length > 0) return items;
      const shelfWrapper = sectionContents && sectionContents.length > 0 ? sectionContents[0] : undefined;
      const shelf = shelfWrapper ? (shelfWrapper["shelfRenderer"] as Record<string, Object>) : undefined;
      const shelfContent = shelf ? (shelf["content"] as Record<string, Object>) : undefined;
      const shelfGrid = shelfContent ? (shelfContent["gridRenderer"] as Record<string, Object>) : undefined;
      const shelfItems = shelfGrid ? (shelfGrid["items"] as Array<Record<string, Object>>) : undefined;
      if (shelfItems && shelfItems.length > 0) return shelfItems;
    }
    const richGrid = tabContent["richGridRenderer"] as Record<string, Object>;
    if (richGrid) {
      const contents = richGrid["contents"] as Array<Record<string, Object>>;
      if (contents && contents.length > 0) {
        return contents;
      }
    }
    if (sectionList) {
      const contents = sectionList["contents"] as Array<Record<string, Object>>;
      return contents ?? [];
    }
    return [];
  }

  private buildHomeKioskVideoItems(
    rawItems: Array<Record<string, Object>>,
    startId: number
  ): HomeKioskBuildResult {
    let idCounter = startId;
    const items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;
    const liveLabel = '';

    rawItems.forEach((content) => {
      const rich = content["richItemRenderer"] as Record<string, Object>;
      if (rich) {
        const richContent = rich["content"] as Record<string, Object>;

        const videoRenderer = richContent ? (richContent["videoRenderer"] as Record<string, Object>) : undefined;
        if (videoRenderer) {
          const videoItem = buildVideoItemFromRenderer(videoRenderer, idCounter, liveLabel);
          if (videoItem) {
            items.push(videoItem);
            idCounter += 1;
          }
          return;
        }

        const reelRenderer = richContent ? (richContent["reelItemRenderer"] as Record<string, Object>) : undefined;
        if (reelRenderer) {
          const videoItem = buildVideoItemFromReelRenderer(reelRenderer, idCounter);
          if (videoItem) {
            items.push(videoItem);
            idCounter += 1;
          }
          return;
        }

        const shortsLockup = richContent ? (richContent["shortsLockupViewModel"] as Record<string, Object>) : undefined;
        if (shortsLockup) {
          const videoItem = buildVideoItemFromShortsLockupViewModel(shortsLockup, idCounter);
          if (videoItem) {
            items.push(videoItem);
            idCounter += 1;
          }
          return;
        }
      }

      const gridVideo = content["gridVideoRenderer"] as Record<string, Object>;
      if (gridVideo) {
        const videoItem = buildVideoItemFromRenderer(gridVideo, idCounter, liveLabel);
        if (videoItem) {
          items.push(videoItem);
          idCounter += 1;
        }
        return;
      }

      const reelRenderer = content["reelItemRenderer"] as Record<string, Object>;
      if (reelRenderer) {
        const videoItem = buildVideoItemFromReelRenderer(reelRenderer, idCounter);
        if (videoItem) {
          items.push(videoItem);
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
          items.push(new VideoItem(idCounter, videoId, title, author, "", thumbnailUrl, false, placeholderColor, channelId, "", "", ""));
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
          items.push(new VideoItem(idCounter, videoId, title, author, "", thumbnailUrl, false, placeholderColor, channelId, "", "", ""));
          idCounter += 1;
          return;
        }
      }

      const shortsLockup = content["shortsLockupViewModel"] as Record<string, Object>;
      if (shortsLockup) {
        const videoItem = buildVideoItemFromShortsLockupViewModel(shortsLockup, idCounter);
        if (videoItem) {
          items.push(videoItem);
          idCounter += 1;
        }
        return;
      }

      const continuation = content["continuationItemRenderer"] as Record<string, Object>;
      if (continuation) {
        nextPageToken = getContinuationToken(continuation) ?? nextPageToken;
      }
    });

    return { items, nextPageToken };
  }
}
