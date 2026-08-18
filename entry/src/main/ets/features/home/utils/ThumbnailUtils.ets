import { pickHighestThumbnailUrl } from 'youtube_core';

export function normalizeUrl(input: string): string {
  if (!input) return "";
  const url = input.trim();
  if (url.length === 0) return "";
  if (url.startsWith('//')) {
    return `https:${url}`;
  }
  if (url.startsWith('http://')) {
    return `https://${url.slice('http://'.length)}`;
  }
  return url;
}

/**
 * YouTube static stills: always prefer maxresdefault when we can extract a video id.
 * Do not apply to ggpht/yt3 avatars or other hosts.
 */
export function upgradeYoutubeStillToMaxRes(url: string): string {
  const fixed = normalizeUrl(url);
  if (fixed.length === 0) {
    return '';
  }
  // i.ytimg.com/vi/<id>/xxx.jpg  or  i.ytimg.com/vi_webp/<id>/xxx.webp
  const match = /(?:^https?:\/\/)?(?:i\d*\.)?ytimg\.com\/vi(?:_webp)?\/([^/]+)\//i.exec(fixed);
  if (match && match[1] && match[1].length > 0) {
    return `https://i.ytimg.com/vi/${match[1]}/maxresdefault.jpg`;
  }
  return fixed;
}

/**
 * Always pick the highest-resolution thumbnail from candidates.
 * Single implementation lives in youtube_core (pickHighestThumbnailUrl);
 * this wrapper keeps the entry-side name and call sites unchanged.
 */
export function pickBestThumbUrl(candidates: Array<Record<string, Object>>): string {
  return pickHighestThumbnailUrl(candidates);
}

export function getThumbnailUrlFromThumbnailObject(thumbnail: Record<string, Object> | undefined): string {
  if (!thumbnail) return "";
  const thumbnails = thumbnail["thumbnails"] as Array<Record<string, Object>>;
  if (thumbnails && thumbnails.length > 0) {
    return pickBestThumbUrl(thumbnails);
  }
  const sources = thumbnail["sources"] as Array<Record<string, Object>>;
  if (sources && sources.length > 0) {
    return pickBestThumbUrl(sources);
  }
  return "";
}

/**
 * From a video/renderer object that has a nested "thumbnail" field.
 */
export function getThumbnailUrl(video: Record<string, Object>): string {
  if (!video) return "";
  if (video["thumbnails"] || video["sources"]) {
    return getThumbnailUrlFromThumbnailObject(video);
  }
  const thumbnail = video["thumbnail"] as Record<string, Object>;
  return getThumbnailUrlFromThumbnailObject(thumbnail);
}

export function getRendererThumbnailUrl(renderer: Record<string, Object>): string {
  const fromThumbnail = getThumbnailUrlFromThumbnailObject(
    renderer ? (renderer["thumbnail"] as Record<string, Object>) : undefined
  );
  if (fromThumbnail) {
    return fromThumbnail;
  }
  const wrappers = renderer["thumbnails"] as Array<Record<string, Object>>;
  if (wrappers && wrappers.length > 0) {
    const first = wrappers[0] as Record<string, Object>;
    const nestedThumb = first ? (first["thumbnails"] as Array<Record<string, Object>>) : undefined;
    if (nestedThumb && nestedThumb.length > 0) {
      return pickBestThumbUrl(nestedThumb);
    }
  }
  return "";
}

export function getShortsLockupThumbnailUrl(lockup: Record<string, Object>): string {
  const thumbnail = lockup["thumbnail"] as Record<string, Object>;
  const sources = thumbnail ? (thumbnail["sources"] as Array<Record<string, Object>>) : undefined;
  if (sources && sources.length > 0) {
    return pickBestThumbUrl(sources);
  }
  const thumbnailViewModel = lockup["thumbnailViewModel"] as Record<string, Object>;
  const inner = thumbnailViewModel ? (thumbnailViewModel["thumbnailViewModel"] as Record<string, Object>) : undefined;
  const image = inner ? (inner["image"] as Record<string, Object>) : undefined;
  const imageSources = image ? (image["sources"] as Array<Record<string, Object>>) : undefined;
  if (imageSources && imageSources.length > 0) {
    return pickBestThumbUrl(imageSources);
  }
  return "";
}

/** Highest-quality static fallback when only videoId is known. */
export function getMaxResFallbackThumbnailUrl(videoId: string): string {
  const id = (videoId || '').trim();
  if (id.length === 0) {
    return '';
  }
  return `https://i.ytimg.com/vi/${id}/maxresdefault.jpg`;
}
