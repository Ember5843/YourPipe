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

export function hasLiveBadge(video: Record<string, Object>, liveLabel: string): boolean {
  const badges = video["badges"] as Array<Record<string, Object>>;
  if (badges && badges.length > 0) {
    return badges.some((badge) => {
      const badgeRenderer = badge["metadataBadgeRenderer"] as Record<string, Object>;
      if (!badgeRenderer) return false;
      const label = badgeRenderer["label"] as string;
      if (label === "LIVE" || label === "LIVE NOW" || label === liveLabel) return true;
      const style = badgeRenderer["style"] as string;
      if (style === "BADGE_STYLE_TYPE_LIVE_NOW" || style === "BADGE_STYLE_TYPE_LIVE") return true;
      return false;
    });
  }

  const overlays = video["thumbnailOverlays"] as Array<Record<string, Object>>;
  if (overlays && overlays.length > 0) {
    return overlays.some((overlay) => {
      const timeStatus = overlay["thumbnailOverlayTimeStatusRenderer"] as Record<string, Object>;
      if (timeStatus) {
        const style = timeStatus["style"] as string;
        if (style === "LIVE" || style === "DEFAULT") {
          const text = getTextFromRuns(timeStatus["text"]);
          if (text === "LIVE" || text === "LIVE NOW" || text === liveLabel) return true;
        }
      }
      return false;
    });
  }

  const lockupOverlays = getLockupOverlays(video);
  if (lockupOverlays) {
    for (let i = 0; i < lockupOverlays.length; i++) {
      const overlay = lockupOverlays[i];
      const badgeVm = overlay ? (overlay["thumbnailOverlayBadgeViewModel"] as Record<string, Object>) : undefined;
      if (badgeVm) {
        const lockupBadges = badgeVm["thumbnailBadges"] as Array<Record<string, Object>>;
        if (lockupBadges) {
          for (let b = 0; b < lockupBadges.length; b++) {
            const bvm = lockupBadges[b] ? (lockupBadges[b]["thumbnailBadgeViewModel"] as Record<string, Object>) : undefined;
            if (!bvm) continue;
            const badgeStyle = (bvm["badgeStyle"] as string) || "";
            if (badgeStyle.toUpperCase().includes("LIVE")) return true;
            const badgeText = (bvm["text"] as string) || "";
            if (badgeText.toLowerCase().includes("live") || badgeText.toLowerCase().includes("bukhoma")) return true;
            const imageName = (bvm["imageName"] as string) || "";
            if (imageName === "LIVE") return true;
          }
        }
      }
      const bottomVm = overlay ? (overlay["thumbnailBottomOverlayViewModel"] as Record<string, Object>) : undefined;
      if (bottomVm) {
        const bottomBadges = bottomVm["badges"] as Array<Record<string, Object>>;
        if (bottomBadges) {
          for (let b = 0; b < bottomBadges.length; b++) {
            const bvm = bottomBadges[b] ? (bottomBadges[b]["thumbnailBadgeViewModel"] as Record<string, Object>) : undefined;
            if (!bvm) continue;
            const badgeStyle = (bvm["badgeStyle"] as string) || "";
            if (badgeStyle.toUpperCase().includes("LIVE")) return true;
            const badgeText = (bvm["text"] as string) || "";
            if (badgeText.toLowerCase().includes("live") || badgeText.toLowerCase().includes("bukhoma")) return true;
            const imageName = (bvm["imageName"] as string) || "";
            if (imageName === "LIVE") return true;
          }
        }
      }
    }
  }

  return false;
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


