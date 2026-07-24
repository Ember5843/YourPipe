import { VideoItem } from 'youtube_core';
import { ThumbnailPlaceholder } from '../../../common/ThumbnailPlaceholder';
import { getTextFromRuns } from './TextUtils';
import {
  getThumbnailUrlFromThumbnailObject,
  getShortsLockupThumbnailUrl,
  getThumbnailUrl as getThumbFromRenderer
} from './ThumbnailUtils';
import { getLockupUploaderName, getLockupChannelId, getLockupViewCount, getLockupRequiresMembership } from './LockupViewModelParser';

export function buildVideoItemFromRenderer(
  renderer: Record<string, Object>,
  id: number,
  liveLabel: string
): VideoItem | null {
  const videoId = (renderer["videoId"] as string) || "";
  if (!videoId) return null;
  const title = getTextFromRuns(renderer["title"]) || "Untitled";
  const author = getTextFromRuns(renderer["ownerText"]) ||
    getTextFromRuns(renderer["longBylineText"]) ||
    getTextFromRuns(renderer["shortBylineText"]) ||
    "Unknown";
  let viewCount = getTextFromRuns(renderer["viewCountText"]) ||
    getTextFromRuns(renderer["shortViewCountText"]) ||
    "";
  if (!viewCount) {
    viewCount = getLockupViewCountFromRenderer(renderer);
  }
  const isLive = hasLiveBadge(renderer, liveLabel);
  const isPremium = hasPremiumBadge(renderer);
  const requiresMembership = hasMembershipBadge(renderer);
  const thumbnailUrl = getThumbFromRenderer(renderer);
  const channelId = getChannelId(renderer);
  const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, id);
  return new VideoItem(id, videoId, title, author, viewCount, thumbnailUrl, isLive, placeholderColor, channelId, "", "", "", null, isPremium, requiresMembership);
}

export function buildVideoItemFromReelRenderer(renderer: Record<string, Object>, id: number): VideoItem | null {
  const videoId = (renderer["videoId"] as string) || "";
  if (!videoId) return null;
  const title = getTextFromRuns(renderer["headline"]) || "Shorts";
  const viewCountText = getTextFromRuns(renderer["viewCountText"]);
  const thumbnail = renderer["thumbnail"] as Record<string, Object>;
  const thumbnailUrl = getThumbnailUrlFromThumbnailObject(thumbnail);
  const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, id);
  const ownerText = renderer["ownerText"] as Record<string, Object>;
  const longBylineText = renderer["longBylineText"] as Record<string, Object>;
  const shortBylineText = renderer["shortBylineText"] as Record<string, Object>;
  const author = getTextFromRuns(ownerText) ||
    getTextFromRuns(longBylineText) ||
    getTextFromRuns(shortBylineText) ||
    "";
  const channelId = getChannelId(renderer);
  return new VideoItem(id, videoId, title, author, viewCountText, thumbnailUrl, false, placeholderColor, channelId, "", "", "");
}

/**
 * SmartTube TV tileRenderer → VideoItem.
 * videoId: onSelectCommand.watchEndpoint / reelWatchEndpoint
 * title: metadata.tileMetadataRenderer.title
 * thumb: header.tileHeaderRenderer.thumbnail
 */
export function buildVideoItemFromTileRenderer(tile: Record<string, Object>, id: number): VideoItem | null {
  const onSelect = tile['onSelectCommand'] as Record<string, Object>;
  let videoId = '';
  if (onSelect) {
    const watch = onSelect['watchEndpoint'] as Record<string, Object>;
    const reel = onSelect['reelWatchEndpoint'] as Record<string, Object>;
    videoId = (watch ? (watch['videoId'] as string) : '')
      || (reel ? (reel['videoId'] as string) : '')
      || '';
    if (!videoId) {
      const executor = onSelect['commandExecutorCommand'] as Record<string, Object>;
      const commands = executor ? (executor['commands'] as Array<Record<string, Object>>) : undefined;
      if (commands) {
        for (let i = 0; i < commands.length; i++) {
          const cmd = commands[i];
          const w = cmd['watchEndpoint'] as Record<string, Object>;
          const r = cmd['reelWatchEndpoint'] as Record<string, Object>;
          videoId = (w ? (w['videoId'] as string) : '')
            || (r ? (r['videoId'] as string) : '')
            || videoId;
          if (videoId) {
            break;
          }
        }
      }
    }
  }
  if (!videoId) {
    return null;
  }

  const metadata = tile['metadata'] as Record<string, Object>;
  const tileMeta = metadata ? (metadata['tileMetadataRenderer'] as Record<string, Object>) : undefined;
  const titleObj = tileMeta ? (tileMeta['title'] as Record<string, Object>) : undefined;
  let title = getTextFromRuns(titleObj) || 'Untitled';
  if (title === 'Untitled') {
    // Shorts tiles often put title only on overlay
    const header = tile['header'] as Record<string, Object>;
    const tileHeader = header ? (header['tileHeaderRenderer'] as Record<string, Object>) : undefined;
    const overlays = tileHeader
      ? (tileHeader['thumbnailOverlays'] as Array<Record<string, Object>>)
      : undefined;
    if (overlays) {
      for (let i = 0; i < overlays.length; i++) {
        const tmd = overlays[i]['tileMetadataRenderer'] as Record<string, Object>;
        const t = tmd ? getTextFromRuns(tmd['title'] as Record<string, Object>) : '';
        if (t) {
          title = t;
          break;
        }
      }
    }
  }

  let author = '';
  let viewCount = '';
  const lines = tileMeta ? (tileMeta['lines'] as Array<Record<string, Object>>) : undefined;
  if (lines && lines.length > 0) {
    for (let li = 0; li < lines.length; li++) {
      const lineRenderer = lines[li]['lineRenderer'] as Record<string, Object>;
      const lineItems = lineRenderer
        ? (lineRenderer['items'] as Array<Record<string, Object>>)
        : undefined;
      if (!lineItems) {
        continue;
      }
      for (let j = 0; j < lineItems.length; j++) {
        const lineItem = lineItems[j]['lineItemRenderer'] as Record<string, Object>;
        if (!lineItem) {
          continue;
        }
        const badge = lineItem['badge'] as Record<string, Object>;
        const badgeRenderer = badge
          ? (badge['metadataBadgeRenderer'] as Record<string, Object>)
          : undefined;
        const label = badgeRenderer ? ((badgeRenderer['label'] as string) || '') : '';
        if (label && !author) {
          author = label;
        }
        const text = getTextFromRuns(lineItem['text'] as Record<string, Object>);
        if (text) {
          if (!author) {
            author = text;
          } else if (!viewCount) {
            viewCount = text;
          }
        }
      }
    }
  }

  let thumbnailUrl = '';
  const header = tile['header'] as Record<string, Object>;
  const tileHeader = header ? (header['tileHeaderRenderer'] as Record<string, Object>) : undefined;
  const trackHeader = header ? (header['trackTileHeaderRenderer'] as Record<string, Object>) : undefined;
  const thumbObj = (tileHeader ? (tileHeader['thumbnail'] as Record<string, Object>) : undefined)
    || (trackHeader ? (trackHeader['thumbnail'] as Record<string, Object>) : undefined);
  if (thumbObj) {
    thumbnailUrl = getThumbnailUrlFromThumbnailObject(thumbObj);
  }

  const style = ((tile['style'] as string) || '').toUpperCase();
  const contentType = ((tile['contentType'] as string) || '').toUpperCase();
  let isLive = false;
  if (tileHeader) {
    const overlays = tileHeader['thumbnailOverlays'] as Array<Record<string, Object>>;
    if (overlays) {
      for (let i = 0; i < overlays.length; i++) {
        const status = overlays[i]['thumbnailOverlayTimeStatusRenderer'] as Record<string, Object>;
        const st = status ? (((status['style'] as string) || '').toUpperCase()) : '';
        if (st.indexOf('LIVE') >= 0) {
          isLive = true;
          break;
        }
      }
    }
  }

  const channelId = '';
  const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, id);
  // Shorts: still a playable video id
  void style;
  void contentType;
  return new VideoItem(
    id, videoId, title, author, viewCount, thumbnailUrl, isLive, placeholderColor,
    channelId, '', '', '', null, false, false
  );
}

export function buildVideoItemFromShortsLockupViewModel(lockup: Record<string, Object>, id: number): VideoItem | null {
  const onTap = lockup["onTap"] as Record<string, Object>;
  const innertubeCommand = onTap ? (onTap["innertubeCommand"] as Record<string, Object>) : undefined;
  const reelWatchEndpoint = innertubeCommand ? (innertubeCommand["reelWatchEndpoint"] as Record<string, Object>) : undefined;
  let videoId = reelWatchEndpoint ? (reelWatchEndpoint["videoId"] as string) : "";
  if (!videoId) {
    const inlinePlayerData = lockup["inlinePlayerData"] as Record<string, Object>;
    const onVisible = inlinePlayerData ? (inlinePlayerData["onVisible"] as Record<string, Object>) : undefined;
    const visibleCommand = onVisible ? (onVisible["innertubeCommand"] as Record<string, Object>) : undefined;
    const watchEndpoint = visibleCommand ? (visibleCommand["watchEndpoint"] as Record<string, Object>) : undefined;
    videoId = watchEndpoint ? (watchEndpoint["videoId"] as string) : "";
  }
  if (!videoId) return null;

  const overlayMetadata = lockup["overlayMetadata"] as Record<string, Object>;
  const primaryText = overlayMetadata ? (overlayMetadata["primaryText"] as Record<string, Object>) : undefined;
  const title = primaryText ? (primaryText["content"] as string) : "Shorts";

  const secondaryText = overlayMetadata ? (overlayMetadata["secondaryText"] as Record<string, Object>) : undefined;
  const viewCount = secondaryText ? (secondaryText["content"] as string) : "";

  const thumbnailUrl = getShortsLockupThumbnailUrl(lockup);

  const placeholderColor = ThumbnailPlaceholder.pickColor(videoId || title, id);
  const author = getLockupUploaderName(lockup) || "";
  const channelId = getLockupChannelId(lockup);

  return new VideoItem(id, videoId, title, author, viewCount, thumbnailUrl, false, placeholderColor, channelId, "", "", "");
}

/**
 * Live detection aligned with NewPipe/PipePipe YoutubeStreamInfoItemExtractor:
 * 1) badges.metadataBadgeRenderer style/label
 * 2) thumbnailOverlays.thumbnailOverlayTimeStatusRenderer style === LIVE
 * 3) lockup contentImage overlays (badge / bottom badge)
 * 4) metadata "watching" fallback
 *
 * Important: do NOT early-return false when badges exist but are non-live
 * (e.g. Premium) — continue checking overlays.
 */
export function hasLiveBadge(video: Record<string, Object>, liveLabel: string): boolean {
  const badges = video["badges"] as Array<Record<string, Object>>;
  if (badges && badges.length > 0) {
    for (let i = 0; i < badges.length; i++) {
      const badgeRenderer = badges[i]
        ? (badges[i]["metadataBadgeRenderer"] as Record<string, Object>)
        : undefined;
      if (!badgeRenderer) {
        continue;
      }
      const style = ((badgeRenderer["style"] as string) || "").toUpperCase();
      if (style === "BADGE_STYLE_TYPE_LIVE_NOW" || style === "BADGE_STYLE_TYPE_LIVE"
        || style.indexOf("LIVE") >= 0) {
        return true;
      }
      const label = ((badgeRenderer["label"] as string) || "").trim();
      if (isLiveLabelText(label, liveLabel)) {
        return true;
      }
    }
  }

  const overlays = video["thumbnailOverlays"] as Array<Record<string, Object>>;
  if (overlays && overlays.length > 0) {
    for (let i = 0; i < overlays.length; i++) {
      const overlay = overlays[i];
      const timeStatus = overlay
        ? (overlay["thumbnailOverlayTimeStatusRenderer"] as Record<string, Object>)
        : undefined;
      if (timeStatus) {
        const style = ((timeStatus["style"] as string) || "").toUpperCase();
        // NewPipe: style.equalsIgnoreCase("LIVE") alone is enough.
        if (style === "LIVE") {
          return true;
        }
        const text = getTextFromRuns(timeStatus["text"]);
        if (isLiveLabelText(text, liveLabel)) {
          return true;
        }
      }
    }
  }

  // lockupViewModel path (contentImage.thumbnailViewModel.overlays)
  if (isLockupLiveFromOverlays(getLockupOverlays(video), liveLabel)) {
    return true;
  }

  // Fallback used by PipePipe lockup extractor: localized "watching" metadata.
  if (hasWatchingMetadata(video)) {
    return true;
  }

  return false;
}

function isLiveLabelText(text: string, liveLabel: string): boolean {
  const raw = (text || "").trim();
  if (raw.length === 0) {
    return false;
  }
  if (liveLabel && liveLabel.length > 0 && raw === liveLabel) {
    return true;
  }
  const lower = raw.toLowerCase();
  return lower === "live"
    || lower === "live now"
    || lower.indexOf("live") >= 0
    || lower.indexOf("bukhoma") >= 0
    || raw.indexOf("直播") >= 0
    || raw.indexOf("直播中") >= 0;
}

function isLiveBadgeViewModel(bvm: Record<string, Object>, liveLabel: string): boolean {
  const badgeStyle = ((bvm["badgeStyle"] as string) || "").toUpperCase();
  if (badgeStyle.indexOf("LIVE") >= 0) {
    return true;
  }
  const badgeText = (bvm["text"] as string) || "";
  if (isLiveLabelText(badgeText, liveLabel)) {
    return true;
  }
  // PipePipe: animatedText may be a plain string.
  const animatedRaw = bvm["animatedText"];
  if (typeof animatedRaw === "string" && isLiveLabelText(animatedRaw as string, liveLabel)) {
    return true;
  }
  if (animatedRaw && typeof animatedRaw === "object") {
    const animatedObj = animatedRaw as Record<string, Object>;
    const animatedContent = (animatedObj["content"] as string) || "";
    if (isLiveLabelText(animatedContent, liveLabel)) {
      return true;
    }
  }
  const imageName = (bvm["imageName"] as string) || "";
  if (imageName.toUpperCase() === "LIVE") {
    return true;
  }
  // PipePipe: icon.sources[].clientResource.imageName === "LIVE"
  const icon = bvm["icon"] as Record<string, Object>;
  const sources = icon ? (icon["sources"] as Array<Record<string, Object>>) : undefined;
  if (sources) {
    for (let s = 0; s < sources.length; s++) {
      const client = sources[s]
        ? (sources[s]["clientResource"] as Record<string, Object>)
        : undefined;
      const name = client ? ((client["imageName"] as string) || "") : "";
      if (name.toUpperCase() === "LIVE") {
        return true;
      }
    }
  }
  return false;
}

function isLockupLiveFromOverlays(
  overlays: Array<Record<string, Object>> | null,
  liveLabel: string
): boolean {
  if (!overlays) {
    return false;
  }
  for (let i = 0; i < overlays.length; i++) {
    const overlay = overlays[i];
    const badgeVm = overlay
      ? (overlay["thumbnailOverlayBadgeViewModel"] as Record<string, Object>)
      : undefined;
    if (badgeVm) {
      const lockupBadges = badgeVm["thumbnailBadges"] as Array<Record<string, Object>>;
      if (lockupBadges) {
        for (let b = 0; b < lockupBadges.length; b++) {
          const bvm = lockupBadges[b]
            ? (lockupBadges[b]["thumbnailBadgeViewModel"] as Record<string, Object>)
            : undefined;
          if (bvm && isLiveBadgeViewModel(bvm, liveLabel)) {
            return true;
          }
        }
      }
    }
    const bottomVm = overlay
      ? (overlay["thumbnailBottomOverlayViewModel"] as Record<string, Object>)
      : undefined;
    if (bottomVm) {
      const bottomBadges = bottomVm["badges"] as Array<Record<string, Object>>;
      if (bottomBadges) {
        for (let b = 0; b < bottomBadges.length; b++) {
          const bvm = bottomBadges[b]
            ? (bottomBadges[b]["thumbnailBadgeViewModel"] as Record<string, Object>)
            : undefined;
          if (bvm && isLiveBadgeViewModel(bvm, liveLabel)) {
            return true;
          }
        }
      }
    }
  }
  return false;
}

function hasWatchingMetadata(video: Record<string, Object>): boolean {
  // Classic renderer view count text for live often contains "watching".
  const viewCount = getTextFromRuns(video["viewCountText"])
    || getTextFromRuns(video["shortViewCountText"])
    || "";
  if (containsWatchingIndicator(viewCount)) {
    return true;
  }
  // lockup metadata rows
  const metadata = video["metadata"] as Record<string, Object>;
  const lmv = metadata
    ? (metadata["lockupMetadataViewModel"] as Record<string, Object>)
    : undefined;
  const meta = lmv ? (lmv["metadata"] as Record<string, Object>) : undefined;
  const cmv = meta
    ? (meta["contentMetadataViewModel"] as Record<string, Object>)
    : undefined;
  const rows = cmv
    ? (cmv["metadataRows"] as Array<Record<string, Object>>)
    : undefined;
  if (!rows) {
    return false;
  }
  for (let i = 0; i < rows.length; i++) {
    const parts = rows[i]
      ? (rows[i]["metadataParts"] as Array<Record<string, Object>>)
      : undefined;
    if (!parts) {
      continue;
    }
    for (let j = 0; j < parts.length; j++) {
      const text = parts[j] ? (parts[j]["text"] as Record<string, Object>) : undefined;
      const content = text ? ((text["content"] as string) || "") : "";
      if (containsWatchingIndicator(content)) {
        return true;
      }
    }
  }
  return false;
}

function containsWatchingIndicator(text: string): boolean {
  if (!text || text.trim().length === 0) {
    return false;
  }
  const lower = text.toLowerCase();
  return lower.indexOf("watching") >= 0
    || lower.indexOf("viewer") >= 0
    || lower.indexOf("ababukele") >= 0
    || lower.indexOf("babukele") >= 0
    || lower.indexOf("bukele") >= 0
    || text.indexOf("正在观看") >= 0
    || text.indexOf("人在看") >= 0
    || text.indexOf("观看中") >= 0
    || text.indexOf("位观众") >= 0
    || text.indexOf("名观众") >= 0;
}

function getLockupOverlays(video: Record<string, Object>): Array<Record<string, Object>> | null {
  const ci = video["contentImage"] as Record<string, Object>;
  const tvm = ci ? (ci["thumbnailViewModel"] as Record<string, Object>) : undefined;
  const overlayArr = tvm ? (tvm["overlays"] as Array<Record<string, Object>>) : undefined;
  return overlayArr ?? null;
}

export function hasPremiumBadge(video: Record<string, Object>): boolean {
  const badges = video["badges"] as Array<Record<string, Object>>;
  if (badges) {
    return badges.some((badge) => {
      const badgeRenderer = badge["metadataBadgeRenderer"] as Record<string, Object>;
      if (!badgeRenderer) return false;
      const label = (badgeRenderer["label"] as string) || "";
      return label === "Premium";
    });
  }
  return false;
}

export function hasMembershipBadge(video: Record<string, Object>): boolean {
  const badges = video["badges"] as Array<Record<string, Object>>;
  if (badges) {
    for (let i = 0; i < badges.length; i++) {
      const badgeRenderer = badges[i] ? (badges[i]["metadataBadgeRenderer"] as Record<string, Object>) : undefined;
      if (badgeRenderer) {
        const style = (badgeRenderer["style"] as string) || "";
        if (style === "BADGE_STYLE_TYPE_MEMBERS_ONLY") return true;
      }
    }
  }
  const lmkReq = getLockupRequiresMembership(video);
  if (lmkReq) return true;
  return false;
}

function getLockupViewCountFromRenderer(renderer: Record<string, Object>): string {
  const lockupMetadata = renderer["metadata"] as Record<string, Object>;
  if (!lockupMetadata) return "";
  const wrapped: Record<string, Object> = { "metadata": lockupMetadata };
  return getLockupViewCount(wrapped);
}

export function getChannelId(video: Record<string, Object>): string {
  const ownerText = video["ownerText"] as Record<string, Object>;
  const longBylineText = video["longBylineText"] as Record<string, Object>;
  const shortBylineText = video["shortBylineText"] as Record<string, Object>;
  const ownerRuns = ownerText ? (ownerText["runs"] as Array<Record<string, Object>>) : undefined;
  const bylineRuns = longBylineText ? (longBylineText["runs"] as Array<Record<string, Object>>) : undefined;
  const shortRuns = shortBylineText ? (shortBylineText["runs"] as Array<Record<string, Object>>) : undefined;
  const runs = (ownerRuns && ownerRuns.length > 0)
    ? ownerRuns
    : ((bylineRuns && bylineRuns.length > 0) ? bylineRuns : shortRuns);
  if (!runs || runs.length === 0) {
    return "";
  }
  const first = runs[0] as Record<string, Object>;
  const endpoint = first["navigationEndpoint"] as Record<string, Object>;
  const browse = endpoint ? (endpoint["browseEndpoint"] as Record<string, Object>) : undefined;
  const browseId = browse ? (browse["browseId"] as string) : "";
  return browseId || "";
}


