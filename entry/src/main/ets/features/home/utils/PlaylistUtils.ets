import { getTextFromRuns } from './TextUtils';
import { getThumbnailUrlFromThumbnailObject, pickBestThumbUrl } from './ThumbnailUtils';

export function getPlaylistCoverUrl(playlist: Record<string, Object>): string {
  const wrappers = playlist["thumbnails"] as Array<Record<string, Object>>;
  if (wrappers && wrappers.length > 0) {
    const first = wrappers[0] as Record<string, Object>;
    const nested = first ? (first["thumbnails"] as Array<Record<string, Object>>) : undefined;
    if (nested && nested.length > 0) {
      const url = pickBestThumbUrl(nested);
      if (url) return url;
    }
  }
  const thumbnail = playlist["thumbnail"] as Record<string, Object>;
  return getThumbnailUrlFromThumbnailObject(thumbnail);
}

export function getPlaylistVideoCountText(playlist: Record<string, Object>): string {
  const rawCount = playlist["videoCount"] as string;
  if (rawCount && rawCount.length > 0) {
    return rawCount;
  }
  const countText = getTextFromRuns(playlist["videoCountText"]);
  if (countText && countText.length > 0) {
    return countText;
  }
  const shortText = getTextFromRuns(playlist["videoCountShortText"]);
  return shortText || "";
}

export function getShowCoverUrl(show: Record<string, Object>): string {
  const thumbnailRenderer = show["thumbnailRenderer"] as Record<string, Object>;
  const showThumbRenderer = thumbnailRenderer ? (thumbnailRenderer["showCustomThumbnailRenderer"] as Record<string, Object>) : undefined;
  if (showThumbRenderer) {
    const thumbnail = showThumbRenderer["thumbnail"] as Record<string, Object>;
    const url = getThumbnailUrlFromThumbnailObject(thumbnail);
    if (url) return url;
  }
  const thumbnail = show["thumbnail"] as Record<string, Object>;
  return getThumbnailUrlFromThumbnailObject(thumbnail);
}

export function getShowVideoCountText(show: Record<string, Object>): string {
  const overlays = show["thumbnailOverlays"] as Record<string, Object>;
  const bottom = overlays ? (overlays["thumbnailOverlayBottomPanelRenderer"] as Record<string, Object>) : undefined;
  const text = bottom ? bottom["text"] as Object : undefined;
  return getTextFromRuns(text) || "";
}

export function getPlaylistIdFromNavigationEndpoint(endpointObj: Record<string, Object> | undefined): string {
  if (!endpointObj) return "";
  const watchEndpoint = endpointObj["watchEndpoint"] as Record<string, Object>;
  const playlistId = watchEndpoint ? (watchEndpoint["playlistId"] as string) : "";
  if (playlistId) return playlistId;
  const commandMetadata = endpointObj["commandMetadata"] as Record<string, Object>;
  const web = commandMetadata ? (commandMetadata["webCommandMetadata"] as Record<string, Object>) : undefined;
  const url = web ? (web["url"] as string) : "";
  return url || "";
}
