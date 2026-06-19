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

export function getThumbnailUrlFromThumbnailObject(thumbnail: Record<string, Object> | undefined): string {
  if (!thumbnail) return "";
  const thumbnails = thumbnail["thumbnails"] as Array<Record<string, Object>>;
  if (!thumbnails || thumbnails.length === 0) return "";
  const last = thumbnails[thumbnails.length - 1];
  const url = last ? (last["url"] as string) : "";
  return normalizeUrl(url || "");
}

export function getThumbnailUrl(video: Record<string, Object>): string {
  const thumbnail = video["thumbnail"] as Record<string, Object>;
  if (!thumbnail) return "";
  const thumbnails = thumbnail["thumbnails"] as Array<Record<string, Object>>;
  if (!thumbnails || thumbnails.length === 0) return "";
  const last = thumbnails[thumbnails.length - 1];
  const url = last ? (last["url"] as string) : "";
  return normalizeUrl(url || "");
}

export function getRendererThumbnailUrl(renderer: Record<string, Object>): string {
  const thumbnail = renderer["thumbnail"] as Record<string, Object>;
  const thumbnailUrl = getThumbnailUrlFromThumbnailObject(thumbnail);
  if (thumbnailUrl) {
    return thumbnailUrl;
  }
  const wrappers = renderer["thumbnails"] as Array<Record<string, Object>>;
  if (wrappers && wrappers.length > 0) {
    const first = wrappers[0] as Record<string, Object>;
    const nestedThumb = first ? (first["thumbnails"] as Array<Record<string, Object>>) : undefined;
    if (nestedThumb && nestedThumb.length > 0) {
      const last = nestedThumb[nestedThumb.length - 1];
      const url = last ? (last["url"] as string) : "";
      return normalizeUrl(url || "");
    }
  }
  return "";
}

export function getShortsLockupThumbnailUrl(lockup: Record<string, Object>): string {
  const thumbnail = lockup["thumbnail"] as Record<string, Object>;
  const sources = thumbnail ? (thumbnail["sources"] as Array<Record<string, Object>>) : undefined;
  if (sources && sources.length > 0) {
    const url = sources[sources.length - 1]["url"] as string;
    return normalizeUrl(url || "");
  }
  const thumbnailViewModel = lockup["thumbnailViewModel"] as Record<string, Object>;
  const inner = thumbnailViewModel ? (thumbnailViewModel["thumbnailViewModel"] as Record<string, Object>) : undefined;
  const image = inner ? (inner["image"] as Record<string, Object>) : undefined;
  const imageSources = image ? (image["sources"] as Array<Record<string, Object>>) : undefined;
  if (imageSources && imageSources.length > 0) {
    const url = imageSources[imageSources.length - 1]["url"] as string;
    return normalizeUrl(url || "");
  }
  return "";
}
