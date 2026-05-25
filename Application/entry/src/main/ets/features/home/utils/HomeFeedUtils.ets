import { VideoItem } from 'youtube_core';
import { VideoBuildResult } from '../model/FeedResult';
import { ThumbnailPlaceholder } from '../../../common/ThumbnailPlaceholder';
import { getContinuationToken } from './ContinuationUtils';
import { getLockupChannelId, getLockupIsLive, getLockupTitle, getLockupUploaderName, getLockupVideoId, getLockupVideoThumbnailUrl, getLockupViewCount } from './LockupViewModelParser';
import { buildVideoItemFromReelRenderer, buildVideoItemFromRenderer, buildVideoItemFromShortsLockupViewModel } from './VideoItemBuilder';

export function getHomeKioskItemsFromTabContent(tabContent: Record<string, Object> | undefined): Array<Record<string, Object>> {
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

export function buildHomeKioskVideoItems(
  rawItems: Array<Record<string, Object>>,
  startId: number,
  liveLabel: string
): VideoBuildResult {
  let idCounter = startId;
  const items: Array<VideoItem> = [];
  let nextPageToken: string | null = null;

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

      const lockupInRich = richContent ? (richContent["lockupViewModel"] as Record<string, Object>) : undefined;
      if (lockupInRich) {
        const lockupContentType = (lockupInRich["contentType"] as string) || "";
        if (lockupContentType === "LOCKUP_CONTENT_TYPE_VIDEO") {
          const videoId = getLockupVideoId(lockupInRich);
          const title = getLockupTitle(lockupInRich) || "Untitled";
          const author = getLockupUploaderName(lockupInRich) || "Unknown";
          const thumbnailUrl = getLockupVideoThumbnailUrl(lockupInRich);
          const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, idCounter);
          const channelId = getLockupChannelId(lockupInRich);
          const viewCount = getLockupViewCount(lockupInRich);
          const isLive = getLockupIsLive(lockupInRich);
          items.push(new VideoItem(idCounter, videoId, title, author, viewCount, thumbnailUrl, isLive, placeholderColor, channelId, "", "", ""));
          idCounter += 1;
          return;
        }
        if (lockupContentType === "LOCKUP_CONTENT_TYPE_SHORTS") {
          const videoId = getLockupVideoId(lockupInRich);
          const title = getLockupTitle(lockupInRich) || "Untitled";
          const thumbnailUrl = getLockupVideoThumbnailUrl(lockupInRich);
          const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, idCounter);
          const author = getLockupUploaderName(lockupInRich) || "";
          const channelId = getLockupChannelId(lockupInRich);
          const viewCount = getLockupViewCount(lockupInRich);
          items.push(new VideoItem(idCounter, videoId, title, author, viewCount, thumbnailUrl, false, placeholderColor, channelId, "", "", ""));
          idCounter += 1;
          return;
        }
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
        const viewCount = getLockupViewCount(lockup);
        const isLive = getLockupIsLive(lockup);
        items.push(new VideoItem(idCounter, videoId, title, author, viewCount, thumbnailUrl, isLive, placeholderColor, channelId, "", "", ""));
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
        const viewCount = getLockupViewCount(lockup);
        items.push(new VideoItem(idCounter, videoId, title, author, viewCount, thumbnailUrl, false, placeholderColor, channelId, "", "", ""));
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
