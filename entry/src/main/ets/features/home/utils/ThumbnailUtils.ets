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
 * Primary key: width * height (PipePipe/NewPipe style: largest listed source).
 * If dimensions missing: known YouTube name order (maxres > hq720 > sd > hq > mq > default).
 * Equal scores: prefer later array index (YouTube arrays are usually low → high).
 * After selection, upgrade standard /vi/ stills to maxresdefault.
 */
export function pickBestThumbUrl(candidates: Array<Record<string, Object>>): string {
  if (!candidates || candidates.length === 0) {
    return "";
  }
  let bestUrl = "";
  let bestScore = -1;
  for (let i = 0; i < candidates.length; i++) {
    const item = candidates[i];
    if (!item) {
      continue;
    }
    const url = normalizeUrl((item["url"] as string) || "");
    if (url.length === 0) {
      continue;
    }
    const width = Number(item["width"] ?? 0);
    const height = Number(item["height"] ?? 0);
    let score = 0;
    if (width > 0 && height > 0) {
      score = width * height;
    } else if (width > 0) {
      score = width * 1000;
    } else if (height > 0) {
      score = height * 1000;
    } else {
      const lower = url.toLowerCase();
      if (lower.indexOf('maxresdefault') >= 0) {
        score = 100000;
      } else if (lower.indexOf('hq720') >= 0) {
        score = 90000;
      } else if (lower.indexOf('sddefault') >= 0) {
        score = 80000;
      } else if (lower.indexOf('hqdefault') >= 0) {
        score = 70000;
      } else if (lower.indexOf('mqdefault') >= 0) {
        score = 60000;
      } else if (lower.indexOf('default.jpg') >= 0 || lower.indexOf('/default.') >= 0) {
        score = 50000;
      } else {
        // Prefer later unnamed entries slightly so size-less arrays still pick last
        score = i;
      }
    }
    if (score >= bestScore) {
      bestScore = score;
      bestUrl = url;
    }
  }
  return upgradeYoutubeStillToMaxRes(bestUrl);
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
