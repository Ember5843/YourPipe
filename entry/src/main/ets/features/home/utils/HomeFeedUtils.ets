import { VideoItem } from 'youtube_core';
import { HomeFeedChip, HomeFeedSection, VideoBuildResult } from '../model/FeedResult';
import { getTextFromRuns } from './TextUtils';
import { ThumbnailPlaceholder } from '../../../common/ThumbnailPlaceholder';
import { getContinuationToken } from './ContinuationUtils';
import {
  getLockupChannelAvatarUrl,
  getLockupChannelId,
  getLockupDurationText,
  getLockupIsLive,
  getLockupIsPremium,
  getLockupPublishedTimeText,
  getLockupRequiresMembership,
  getLockupTitle,
  getLockupUploaderName,
  getLockupUploaderVerified,
  getLockupVideoId,
  getLockupVideoThumbnailUrl,
  getLockupViewCount,
  getLockupViewCountExact
} from './LockupViewModelParser';
import {
  buildVideoItemFromReelRenderer,
  buildVideoItemFromRenderer,
  buildVideoItemFromShortsLockupViewModel,
  buildVideoItemFromTileRenderer
} from './VideoItemBuilder';

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

/**
 * Flatten personalized home / multi-shelf browse responses into leaf item nodes.
 * Falls back to the kiosk-oriented extractor when no multi-section structure is found.
 */
export function getHomeFeedItemsFromTabContent(tabContent: Record<string, Object> | undefined): Array<Record<string, Object>> {
  if (!tabContent) return [];

  const richGrid = tabContent["richGridRenderer"] as Record<string, Object>;
  if (richGrid) {
    const contents = richGrid["contents"] as Array<Record<string, Object>>;
    if (contents && contents.length > 0) {
      return expandHomeFeedNodes(contents);
    }
  }

  const sectionList = tabContent["sectionListRenderer"] as Record<string, Object>;
  if (sectionList) {
    const sections = sectionList["contents"] as Array<Record<string, Object>>;
    if (sections && sections.length > 0) {
      const expanded = expandHomeFeedNodes(sections);
      if (expanded.length > 0) {
        return expanded;
      }
    }
  }

  return getHomeKioskItemsFromTabContent(tabContent);
}

function expandHomeFeedNodes(nodes: Array<Record<string, Object>>): Array<Record<string, Object>> {
  const result: Array<Record<string, Object>> = [];
  nodes.forEach((node) => {
    collectHomeFeedLeaves(node, result);
  });
  return result;
}

function collectHomeFeedLeaves(node: Record<string, Object>, out: Array<Record<string, Object>>): void {
  if (!node) {
    return;
  }

  if (node["richItemRenderer"] || node["gridVideoRenderer"] || node["reelItemRenderer"]
    || node["lockupViewModel"] || node["shortsLockupViewModel"] || node["videoRenderer"]
    || node["compactVideoRenderer"] || node["videoWithContextRenderer"]
    || node["continuationItemRenderer"]) {
    out.push(node);
    return;
  }

  const itemSection = node["itemSectionRenderer"] as Record<string, Object>;
  if (itemSection) {
    const contents = itemSection["contents"] as Array<Record<string, Object>>;
    if (contents) {
      contents.forEach((c) => collectHomeFeedLeaves(c, out));
    }
    return;
  }

  const richSection = node["richSectionRenderer"] as Record<string, Object>;
  if (richSection) {
    const content = richSection["content"] as Record<string, Object>;
    if (content) {
      const richShelf = content["richShelfRenderer"] as Record<string, Object>;
      if (richShelf) {
        const shelfContents = richShelf["contents"] as Array<Record<string, Object>>;
        if (shelfContents) {
          shelfContents.forEach((c) => collectHomeFeedLeaves(c, out));
        }
        return;
      }
      collectHomeFeedLeaves(content, out);
    }
    return;
  }

  const shelf = node["shelfRenderer"] as Record<string, Object>;
  if (shelf) {
    const shelfContent = shelf["content"] as Record<string, Object>;
    if (shelfContent) {
      const grid = shelfContent["gridRenderer"] as Record<string, Object>;
      if (grid) {
        const items = grid["items"] as Array<Record<string, Object>>;
        if (items) {
          items.forEach((c) => collectHomeFeedLeaves(c, out));
        }
        return;
      }
      const expanded = shelfContent["expandedShelfContentsRenderer"] as Record<string, Object>;
      if (expanded) {
        const items = expanded["items"] as Array<Record<string, Object>>;
        if (items) {
          items.forEach((c) => collectHomeFeedLeaves(c, out));
        }
        return;
      }
      const horizontal = shelfContent["horizontalListRenderer"] as Record<string, Object>;
      if (horizontal) {
        const items = horizontal["items"] as Array<Record<string, Object>>;
        if (items) {
          items.forEach((c) => collectHomeFeedLeaves(c, out));
        }
        return;
      }
    }
    return;
  }

  const grid = node["gridRenderer"] as Record<string, Object>;
  if (grid) {
    const items = grid["items"] as Array<Record<string, Object>>;
    if (items) {
      items.forEach((c) => collectHomeFeedLeaves(c, out));
    }
    return;
  }

  const richGrid = node["richGridRenderer"] as Record<string, Object>;
  if (richGrid) {
    const contents = richGrid["contents"] as Array<Record<string, Object>>;
    if (contents) {
      contents.forEach((c) => collectHomeFeedLeaves(c, out));
    }
  }
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
          // Prefer empty over "Unknown" so history merge/enrich can fill real author later.
          const author = getLockupUploaderName(lockupInRich) || "";
          const thumbnailUrl = getLockupVideoThumbnailUrl(lockupInRich);
          const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, idCounter);
          const channelId = getLockupChannelId(lockupInRich);
          const channelAvatarUrl = getLockupChannelAvatarUrl(lockupInRich);
          const viewCount = getLockupViewCount(lockupInRich);
          const isLive = getLockupIsLive(lockupInRich);
          const isPremium = getLockupIsPremium(lockupInRich);
          const requiresMembership = getLockupRequiresMembership(lockupInRich);
          const item = new VideoItem(
            idCounter, videoId, title, author, viewCount, thumbnailUrl, isLive, placeholderColor,
            channelId, channelAvatarUrl, "", "", null, isPremium, requiresMembership
          );
          item.publishedTimeText = getLockupPublishedTimeText(lockupInRich);
          item.durationText = getLockupDurationText(lockupInRich);
          item.viewCountExact = getLockupViewCountExact(lockupInRich);
          item.uploaderVerified = getLockupUploaderVerified(lockupInRich);
          items.push(item);
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
          const channelAvatarUrl = getLockupChannelAvatarUrl(lockupInRich);
          const viewCount = getLockupViewCount(lockupInRich);
          const shortsItem = new VideoItem(
            idCounter, videoId, title, author, viewCount, thumbnailUrl, false, placeholderColor,
            channelId, channelAvatarUrl, "", "", ""
          );
          shortsItem.isShort = true;
          items.push(shortsItem);
          idCounter += 1;
          return;
        }
      }
    }

    const videoRenderer = content["videoRenderer"] as Record<string, Object>;
    if (videoRenderer) {
      const videoItem = buildVideoItemFromRenderer(videoRenderer, idCounter, liveLabel);
      if (videoItem) {
        items.push(videoItem);
        idCounter += 1;
      }
      return;
    }

    const compactVideo = content["compactVideoRenderer"] as Record<string, Object>;
    if (compactVideo) {
      const videoItem = buildVideoItemFromRenderer(compactVideo, idCounter, liveLabel);
      if (videoItem) {
        items.push(videoItem);
        idCounter += 1;
      }
      return;
    }

    // FEhistory sometimes nests classic video fields under videoWithContextRenderer.
    const videoWithContext = content["videoWithContextRenderer"] as Record<string, Object>;
    if (videoWithContext) {
      const nested = (videoWithContext["videoRenderer"] as Record<string, Object>)
        || (videoWithContext["headline"] as Record<string, Object>)
        || videoWithContext;
      const videoItem = buildVideoItemFromRenderer(nested, idCounter, liveLabel);
      if (videoItem) {
        items.push(videoItem);
        idCounter += 1;
      } else {
        // Some payloads put videoId/title on the outer node itself.
        const outerItem = buildVideoItemFromRenderer(videoWithContext, idCounter, liveLabel);
        if (outerItem) {
          items.push(outerItem);
          idCounter += 1;
        }
      }
      return;
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
        const author = getLockupUploaderName(lockup) || "";
        const thumbnailUrl = getLockupVideoThumbnailUrl(lockup);
        const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, idCounter);
        const channelId = getLockupChannelId(lockup);
        const channelAvatarUrl = getLockupChannelAvatarUrl(lockup);
        const viewCount = getLockupViewCount(lockup);
        const isLive = getLockupIsLive(lockup);
        const isPremium = getLockupIsPremium(lockup);
        const requiresMembership = getLockupRequiresMembership(lockup);
        const item = new VideoItem(
          idCounter, videoId, title, author, viewCount, thumbnailUrl, isLive, placeholderColor,
          channelId, channelAvatarUrl, "", "", null, isPremium, requiresMembership
        );
        item.publishedTimeText = getLockupPublishedTimeText(lockup);
        item.durationText = getLockupDurationText(lockup);
        item.viewCountExact = getLockupViewCountExact(lockup);
        item.uploaderVerified = getLockupUploaderVerified(lockup);
        items.push(item);
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
        const channelAvatarUrl = getLockupChannelAvatarUrl(lockup);
        const viewCount = getLockupViewCount(lockup);
        const shortsItem = new VideoItem(
          idCounter, videoId, title, author, viewCount, thumbnailUrl, false, placeholderColor,
          channelId, channelAvatarUrl, "", "", ""
        );
        shortsItem.isShort = true;
        items.push(shortsItem);
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

    // SmartTube TV home/subs: horizontalList items are tileRenderer
    const tile = content['tileRenderer'] as Record<string, Object>;
    if (tile) {
      const videoItem = buildVideoItemFromTileRenderer(tile, idCounter);
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


function extractTokenFromEndpoint(endpoint: Record<string, Object> | undefined): string {
  if (!endpoint) return '';
  const contCmd = endpoint['continuationCommand'] as Record<string, Object>;
  if (contCmd && typeof contCmd['token'] === 'string' && (contCmd['token'] as string).length > 0) {
    return contCmd['token'] as string;
  }
  const reloadData = endpoint['reloadContinuationData'] as Record<string, Object>;
  if (reloadData && typeof reloadData['continuation'] === 'string' && (reloadData['continuation'] as string).length > 0) {
    return reloadData['continuation'] as string;
  }
  const execCmd = endpoint['commandExecutorCommand'] as Record<string, Object>;
  const cmds = execCmd ? (execCmd['commands'] as Array<Record<string, Object>>) : undefined;
  if (cmds) {
    for (let i = 0; i < cmds.length; i++) {
      const inner = cmds[i]['continuationCommand'] as Record<string, Object>;
      if (inner && typeof inner['token'] === 'string' && (inner['token'] as string).length > 0) {
        return inner['token'] as string;
      }
    }
  }
  const innertubeCmd = endpoint['innertubeCommand'] as Record<string, Object>;
  if (innertubeCmd) {
    return extractTokenFromEndpoint(innertubeCmd);
  }
  return '';
}

function extractChipText(textNode: Object | undefined): string {
  if (!textNode) return '';
  if (typeof textNode === 'string') return textNode.trim();
  const obj = textNode as Record<string, Object>;
  if (typeof obj['content'] === 'string') {
    return (obj['content'] as string).trim();
  }
  return getTextFromRuns(textNode).trim();
}

function collectChipEntries(entries: Array<Record<string, Object>> | undefined, out: Array<HomeFeedChip>, seen: Set<string>): void {
  if (!entries || entries.length === 0) return;
  entries.forEach((entry) => {
    const chip = entry['chipCloudChipRenderer'] as Record<string, Object>;
    if (chip) {
      const label = extractChipText(chip['text']);
      if (!label || seen.has(label)) return;
      const isSelected = chip['isSelected'] === true;
      const token = extractTokenFromEndpoint(chip['navigationEndpoint'] as Record<string, Object>);
      seen.add(label);
      out.push({
        label,
        continuationToken: token,
        isSelected,
        searchQuery: label
      });
      return;
    }
    const vm = entry['chipViewModel'] as Record<string, Object>;
    if (vm) {
      const label = extractChipText(vm['text']);
      if (!label || seen.has(label)) return;
      const isSelected = vm['selected'] === true || vm['isSelected'] === true;
      const token = extractTokenFromEndpoint(vm['tapCommand'] as Record<string, Object>);
      seen.add(label);
      out.push({
        label,
        continuationToken: token,
        isSelected,
        searchQuery: label
      });
    }
  });
}

function collectShelfTitleChips(node: Record<string, Object> | undefined, out: Array<HomeFeedChip>, seen: Set<string>): void {
  if (!node) return;
  const richShelf = node['richShelfRenderer'] as Record<string, Object>;
  if (richShelf) {
    const title = extractChipText(richShelf['title']);
    if (title && title.length <= 18 && title.toLowerCase() !== 'shorts' && !seen.has(title)) {
      seen.add(title);
      out.push({ label: title, continuationToken: '', isSelected: false, searchQuery: title });
    }
  }
  const shelf = node['shelfRenderer'] as Record<string, Object>;
  if (shelf) {
    let title = extractChipText(shelf['title']);
    if (!title) {
      const headerRenderer = shelf['headerRenderer'] as Record<string, Object>;
      const shelfHeader = headerRenderer ? (headerRenderer['shelfHeaderRenderer'] as Record<string, Object>) : undefined;
      if (shelfHeader) {
        title = extractChipText(shelfHeader['title']);
      }
    }
    if (title && title.length <= 18 && title.toLowerCase() !== 'shorts' && !seen.has(title)) {
      seen.add(title);
      out.push({ label: title, continuationToken: '', isSelected: false, searchQuery: title });
    }
  }
  const richSection = node['richSectionRenderer'] as Record<string, Object>;
  if (richSection && richSection['content']) {
    collectShelfTitleChips(richSection['content'] as Record<string, Object>, out, seen);
  }
  const itemSection = node['itemSectionRenderer'] as Record<string, Object>;
  if (itemSection) {
    const contents = itemSection['contents'] as Array<Record<string, Object>>;
    if (contents) {
      contents.forEach((c) => collectShelfTitleChips(c, out, seen));
    }
  }
}

/**
 * Extract home feed filter chips and shelf category titles from browse response.
 */
export function getHomeFeedChipsFromTabContent(
  tabContent: Record<string, Object> | undefined,
  response?: Record<string, Object>
): Array<HomeFeedChip> {
  const chips: Array<HomeFeedChip> = [];
  const seen = new Set<string>();

  if (tabContent) {
    const richGrid = tabContent['richGridRenderer'] as Record<string, Object>;
    const header = richGrid ? (richGrid['header'] as Record<string, Object>) : undefined;
    const chipBar = header ? (header['feedFilterChipBarRenderer'] as Record<string, Object>) : undefined;
    if (chipBar) {
      collectChipEntries(chipBar['contents'] as Array<Record<string, Object>>, chips, seen);
    }
    const chipCloud = header ? (header['chipCloudRenderer'] as Record<string, Object>) : undefined;
    if (chipCloud) {
      collectChipEntries(chipCloud['chips'] as Array<Record<string, Object>>, chips, seen);
    }

    const sectionList = tabContent['sectionListRenderer'] as Record<string, Object>;
    const subMenu = sectionList ? (sectionList['subMenu'] as Record<string, Object>) : undefined;
    const subChipBar = subMenu ? (subMenu['feedFilterChipBarRenderer'] as Record<string, Object>) : undefined;
    if (subChipBar) {
      collectChipEntries(subChipBar['contents'] as Array<Record<string, Object>>, chips, seen);
    }
  }

  if (response) {
    const rootHeader = response['header'] as Record<string, Object>;
    if (rootHeader) {
      const rootChipBar = rootHeader['feedFilterChipBarRenderer'] as Record<string, Object>;
      if (rootChipBar) {
        collectChipEntries(rootChipBar['contents'] as Array<Record<string, Object>>, chips, seen);
      }
      const rootChipCloud = rootHeader['chipCloudRenderer'] as Record<string, Object>;
      if (rootChipCloud) {
        collectChipEntries(rootChipCloud['chips'] as Array<Record<string, Object>>, chips, seen);
      }
    }
  }

  if (tabContent) {
    const richGrid = tabContent['richGridRenderer'] as Record<string, Object>;
    const richContents = richGrid ? (richGrid['contents'] as Array<Record<string, Object>>) : undefined;
    if (richContents) {
      richContents.forEach((c) => collectShelfTitleChips(c, chips, seen));
    }
    const sectionList = tabContent['sectionListRenderer'] as Record<string, Object>;
    const sectionContents = sectionList ? (sectionList['contents'] as Array<Record<string, Object>>) : undefined;
    if (sectionContents) {
      sectionContents.forEach((c) => collectShelfTitleChips(c, chips, seen));
    }
  }

  return chips;
}

/**
 * Extract titled video shelves from an array of item/section nodes as grouped sections (Header + Videos).
 */
export function getHomeFeedSectionsFromNodes(
  nodes: Array<Record<string, Object>> | undefined,
  startId: number,
  liveLabel: string
): Array<HomeFeedSection> {
  if (!nodes || nodes.length === 0) return [];
  const sections: Array<HomeFeedSection> = [];
  const seenTitles = new Set<string>();
  let nextId = startId;

  const pushShelfSection = (title: string, rawNodes: Array<Record<string, Object>>): void => {
    const cleanTitle = (title || '').trim();
    if (!cleanTitle || cleanTitle.toLowerCase() === 'shorts' || seenTitles.has(cleanTitle)) {
      return;
    }
    const leaves = expandHomeFeedNodes(rawNodes);
    if (leaves.length === 0) {
      return;
    }
    const built = buildHomeKioskVideoItems(leaves, nextId, liveLabel);
    const nonShort = built.items.filter((it: VideoItem) => !it.isShort);
    if (nonShort.length === 0) {
      return;
    }
    nextId += built.items.length;
    seenTitles.add(cleanTitle);
    sections.push({
      title: cleanTitle,
      items: nonShort
    });
  };

  const inspectNode = (node: Record<string, Object> | undefined): void => {
    if (!node) return;
    const richShelf = node['richShelfRenderer'] as Record<string, Object>;
    if (richShelf) {
      const title = extractChipText(richShelf['title']);
      const contents = richShelf['contents'] as Array<Record<string, Object>>;
      if (title && contents && contents.length > 0) {
        pushShelfSection(title, contents);
      }
      return;
    }
    const shelf = node['shelfRenderer'] as Record<string, Object>;
    if (shelf) {
      let title = extractChipText(shelf['title']);
      if (!title) {
        const headerRenderer = shelf['headerRenderer'] as Record<string, Object>;
        const shelfHeader = headerRenderer ? (headerRenderer['shelfHeaderRenderer'] as Record<string, Object>) : undefined;
        if (shelfHeader) {
          title = extractChipText(shelfHeader['title']);
        }
      }
      if (title) {
        pushShelfSection(title, [node]);
      }
      return;
    }
    const richSection = node['richSectionRenderer'] as Record<string, Object>;
    if (richSection && richSection['content']) {
      inspectNode(richSection['content'] as Record<string, Object>);
      return;
    }
    const itemSection = node['itemSectionRenderer'] as Record<string, Object>;
    if (itemSection) {
      const contents = itemSection['contents'] as Array<Record<string, Object>>;
      if (contents) {
        contents.forEach((c) => inspectNode(c));
      }
    }
  };

  nodes.forEach((c) => inspectNode(c));
  return sections;
}

/**
 * Extract titled video shelves from browse tabContent as grouped sections (Header + Videos).
 */
export function getHomeFeedSectionsFromTabContent(
  tabContent: Record<string, Object> | undefined,
  startId: number,
  liveLabel: string
): Array<HomeFeedSection> {
  if (!tabContent) return [];
  const allNodes: Array<Record<string, Object>> = [];

  const richGrid = tabContent['richGridRenderer'] as Record<string, Object>;
  if (richGrid) {
    const contents = richGrid['contents'] as Array<Record<string, Object>>;
    if (contents) {
      contents.forEach((c) => allNodes.push(c));
    }
  }

  const sectionList = tabContent['sectionListRenderer'] as Record<string, Object>;
  if (sectionList) {
    const contents = sectionList['contents'] as Array<Record<string, Object>>;
    if (contents) {
      contents.forEach((c) => allNodes.push(c));
    }
  }

  return getHomeFeedSectionsFromNodes(allNodes, startId, liveLabel);
}