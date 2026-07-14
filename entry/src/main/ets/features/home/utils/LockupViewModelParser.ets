import { pickBestThumbUrl } from './ThumbnailUtils';

export function getLockupTitle(lockup: Record<string, Object>): string {
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const title = lmv ? (lmv["title"] as Record<string, Object>) : undefined;
  const content = title ? (title["content"] as string) : "";
  return content || "";
}

export function getLockupVideoId(lockup: Record<string, Object>): string {
  const contentId = lockup["contentId"] as string;
  if (contentId) return contentId;
  const rendererContext = lockup["rendererContext"] as Record<string, Object>;
  const commandContext = rendererContext ? (rendererContext["commandContext"] as Record<string, Object>) : undefined;
  const onTap = commandContext ? (commandContext["onTap"] as Record<string, Object>) : undefined;
  const cmd = onTap ? (onTap["innertubeCommand"] as Record<string, Object>) : undefined;
  const watch = cmd ? (cmd["watchEndpoint"] as Record<string, Object>) : undefined;
  const videoId = watch ? (watch["videoId"] as string) : "";
  return videoId || "";
}

export function getLockupPlaylistId(lockup: Record<string, Object>): string {
  const contentId = lockup["contentId"] as string;
  if (contentId) return contentId;

  const rendererContext = lockup["rendererContext"] as Record<string, Object>;
  const commandContext = rendererContext ? (rendererContext["commandContext"] as Record<string, Object>) : undefined;

  // Some lockupViewModels have watchEndpoint directly under commandContext
  const directWatch = commandContext ? (commandContext["watchEndpoint"] as Record<string, Object>) : undefined;
  const directPlaylistId = directWatch ? (directWatch["playlistId"] as string) : "";
  if (directPlaylistId) return directPlaylistId;

  // Most lockupViewModels nest the endpoint under onTap.innertubeCommand
  const onTap = commandContext ? (commandContext["onTap"] as Record<string, Object>) : undefined;
  const innertubeCommand = onTap ? (onTap["innertubeCommand"] as Record<string, Object>) : undefined;

  const watchEndpoint = innertubeCommand ? (innertubeCommand["watchEndpoint"] as Record<string, Object>) : undefined;
  const watchPlaylistId = watchEndpoint ? (watchEndpoint["playlistId"] as string) : "";
  if (watchPlaylistId) return watchPlaylistId;

  // Playlists often use browseEndpoint with browseId like "VLPLxxxx"
  // Keep the "VL" prefix — YouTube browse API needs it for playlists
  const browseEndpoint = innertubeCommand ? (innertubeCommand["browseEndpoint"] as Record<string, Object>) : undefined;
  const browseId = browseEndpoint ? (browseEndpoint["browseId"] as string) : "";
  if (browseId) {
    // App models store raw list ids; browse requests add the VL prefix at the service boundary.
    return browseId.startsWith("VL") ? browseId.substring(2) : browseId;
  }

  return "";
}

function getLockupMetadataRows(lockup: Record<string, Object>): Array<Record<string, Object>> | undefined {
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const meta = lmv ? (lmv["metadata"] as Record<string, Object>) : undefined;
  const cmv = meta ? (meta["contentMetadataViewModel"] as Record<string, Object>) : undefined;
  return cmv ? (cmv["metadataRows"] as Array<Record<string, Object>>) : undefined;
}

function getPartTextContent(part: Record<string, Object> | undefined): string {
  if (!part) {
    return "";
  }
  const text = part["text"] as Record<string, Object>;
  return (text ? (text["content"] as string) : "") || "";
}

function getPartBrowseId(part: Record<string, Object> | undefined): string {
  if (!part) {
    return "";
  }
  const text = part["text"] as Record<string, Object>;
  const commandRuns = text ? (text["commandRuns"] as Array<Record<string, Object>>) : undefined;
  if (!commandRuns || commandRuns.length === 0) {
    return "";
  }
  for (let i = 0; i < commandRuns.length; i++) {
    const run = commandRuns[i];
    const onTap = run ? (run["onTap"] as Record<string, Object>) : undefined;
    const innertubeCommand = onTap ? (onTap["innertubeCommand"] as Record<string, Object>) : undefined;
    const browseEndpoint = innertubeCommand
      ? (innertubeCommand["browseEndpoint"] as Record<string, Object>)
      : undefined;
    const browseId = browseEndpoint ? (browseEndpoint["browseId"] as string) : "";
    if (browseId && browseId.length > 0) {
      return browseId;
    }
  }
  return "";
}

function isRelativeTimeText(content: string): boolean {
  const lower = content.toLowerCase().trim();
  if (lower.length === 0) {
    return false;
  }
  return lower.includes("ago")
    || lower.includes("hour")
    || lower.includes("minute")
    || lower.includes("day")
    || lower.includes("week")
    || lower.includes("month")
    || lower.includes("year")
    || lower.includes("streamed")
    || lower.includes("premiered")
    || content.includes("前")
    || content.includes("小时")
    || content.includes("分钟")
    || content.includes("天")
    || content.includes("周")
    || content.includes("月")
    || content.includes("年")
    || content.includes("昨天")
    || content.includes("剛剛")
    || content.includes("刚刚");
}

function isUploaderCandidateText(content: string): boolean {
  if (!content || content.trim().length === 0) {
    return false;
  }
  if (isViewCountText(content) || isRelativeTimeText(content)) {
    return false;
  }
  // Duration-like tokens should not be treated as channel names.
  if (/^\d{1,2}:\d{2}(:\d{2})?$/.test(content.trim())) {
    return false;
  }
  return true;
}

/**
 * Channel / uploader name from lockup metadata.
 * History shelves often put views/date first; prefer parts with browseEndpoint,
 * then first non-stats text.
 */
export function getLockupUploaderName(lockup: Record<string, Object>): string {
  const rows = getLockupMetadataRows(lockup);
  if (!rows || rows.length === 0) {
    return "";
  }

  // Prefer metadata parts that actually navigate to a channel.
  for (let i = 0; i < rows.length; i++) {
    const parts = rows[i] ? (rows[i]["metadataParts"] as Array<Record<string, Object>>) : undefined;
    if (!parts) {
      continue;
    }
    for (let j = 0; j < parts.length; j++) {
      const part = parts[j];
      const content = getPartTextContent(part);
      if (!isUploaderCandidateText(content)) {
        continue;
      }
      if (getPartBrowseId(part).length > 0) {
        return content;
      }
    }
  }

  // Fallback: first non-view / non-time text.
  for (let i = 0; i < rows.length; i++) {
    const parts = rows[i] ? (rows[i]["metadataParts"] as Array<Record<string, Object>>) : undefined;
    if (!parts) {
      continue;
    }
    for (let j = 0; j < parts.length; j++) {
      const content = getPartTextContent(parts[j]);
      if (isUploaderCandidateText(content)) {
        return content;
      }
    }
  }
  return "";
}

export function getLockupChannelId(lockup: Record<string, Object>): string {
  const rows = getLockupMetadataRows(lockup);
  if (rows) {
    for (let i = 0; i < rows.length; i++) {
      const parts = rows[i] ? (rows[i]["metadataParts"] as Array<Record<string, Object>>) : undefined;
      if (!parts) {
        continue;
      }
      for (let j = 0; j < parts.length; j++) {
        const browseId = getPartBrowseId(parts[j]);
        if (browseId.startsWith("UC") || browseId.length > 0) {
          return browseId;
        }
      }
    }
  }

  // History lockups often only expose channel on the avatar image endpoint.
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const image = lmv ? (lmv["image"] as Record<string, Object>) : undefined;
  if (image) {
    const decorated = image["decoratedAvatarViewModel"] as Record<string, Object>;
    const avatar = decorated
      ? (decorated["avatar"] as Record<string, Object>)
      : (image["avatarViewModel"] as Record<string, Object>);
    const endpoint = avatar
      ? (avatar["endpoint"] as Record<string, Object>)
      : (decorated ? (decorated["rendererContext"] as Record<string, Object>) : undefined);
    const onTap = endpoint
      ? ((endpoint["onTap"] as Record<string, Object>) || endpoint)
      : undefined;
    const commandContext = endpoint ? (endpoint["commandContext"] as Record<string, Object>) : undefined;
    const cmdOnTap = commandContext ? (commandContext["onTap"] as Record<string, Object>) : onTap;
    const innertubeCommand = cmdOnTap
      ? ((cmdOnTap["innertubeCommand"] as Record<string, Object>)
        || (endpoint ? (endpoint["innertubeCommand"] as Record<string, Object>) : undefined))
      : undefined;
    const browseEndpoint = innertubeCommand
      ? (innertubeCommand["browseEndpoint"] as Record<string, Object>)
      : undefined;
    const browseId = browseEndpoint ? (browseEndpoint["browseId"] as string) : "";
    if (browseId && browseId.length > 0) {
      return browseId;
    }
  }
  return "";
}

/** Channel avatar URL when lockup embeds a channel image (common on FEhistory). */
export function getLockupChannelAvatarUrl(lockup: Record<string, Object>): string {
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const image = lmv ? (lmv["image"] as Record<string, Object>) : undefined;
  if (!image) {
    return "";
  }
  const decorated = image["decoratedAvatarViewModel"] as Record<string, Object>;
  const avatar = decorated
    ? (decorated["avatar"] as Record<string, Object>)
    : (image["avatarViewModel"] as Record<string, Object>);
  const avatarImage = avatar
    ? (avatar["image"] as Record<string, Object>)
    : (image["image"] as Record<string, Object>);
  const sources = avatarImage
    ? (avatarImage["sources"] as Array<Record<string, Object>>)
    : undefined;
  if (sources && sources.length > 0) {
    return pickBestThumbUrl(sources);
  }
  return "";
}

/** Duration seconds from thumbnail overlay badges (e.g. "12:34"). */
export function getLockupDurationSec(lockup: Record<string, Object>): number {
  const ci = lockup["contentImage"] as Record<string, Object>;
  const tvm = ci ? (ci["thumbnailViewModel"] as Record<string, Object>) : undefined;
  const overlays = tvm ? (tvm["overlays"] as Array<Record<string, Object>>) : undefined;
  if (!overlays) {
    return 0;
  }
  for (let i = 0; i < overlays.length; i++) {
    const overlay = overlays[i];
    const bottomVm = overlay ? (overlay["thumbnailBottomOverlayViewModel"] as Record<string, Object>) : undefined;
    const badges = bottomVm ? (bottomVm["badges"] as Array<Record<string, Object>>) : undefined;
    if (!badges) {
      continue;
    }
    for (let b = 0; b < badges.length; b++) {
      const bvm = badges[b] ? (badges[b]["thumbnailBadgeViewModel"] as Record<string, Object>) : undefined;
      const text = bvm ? ((bvm["text"] as string) || "") : "";
      const sec = parseDurationBadge(text);
      if (sec > 0) {
        return sec;
      }
    }
  }
  return 0;
}

function parseDurationBadge(text: string): number {
  const raw = (text || "").trim();
  if (!raw || raw.indexOf(":") < 0) {
    return 0;
  }
  const parts = raw.split(":");
  if (parts.length < 2 || parts.length > 3) {
    return 0;
  }
  let total = 0;
  for (let i = 0; i < parts.length; i++) {
    const n = parseInt(parts[i], 10);
    if (!Number.isFinite(n) || n < 0) {
      return 0;
    }
    total = total * 60 + n;
  }
  return total;
}

export function getLockupVideoThumbnailUrl(lockup: Record<string, Object>): string {
  const ci = lockup["contentImage"] as Record<string, Object>;
  const tvm = ci ? (ci["thumbnailViewModel"] as Record<string, Object>) : undefined;
  const image = tvm ? (tvm["image"] as Record<string, Object>) : undefined;
  const sources = image ? (image["sources"] as Array<Record<string, Object>>) : undefined;
  if (!sources || sources.length === 0) return "";
  return pickBestThumbUrl(sources);
}

export function getLockupViewCount(lockup: Record<string, Object>): string {
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const meta = lmv ? (lmv["metadata"] as Record<string, Object>) : undefined;
  const cmv = meta ? (meta["contentMetadataViewModel"] as Record<string, Object>) : undefined;
  const rows = cmv ? (cmv["metadataRows"] as Array<Record<string, Object>>) : undefined;
  if (!rows) return "";

  for (let i = 0; i < rows.length; i++) {
    const parts = rows[i] ? (rows[i]["metadataParts"] as Array<Record<string, Object>>) : undefined;
    if (!parts) continue;
    for (let j = 0; j < parts.length; j++) {
      const part = parts[j] ? parts[j] as Record<string, Object> : undefined;
      if (!part) continue;
      const text = part["text"] as Record<string, Object>;
      const content = text ? (text["content"] as string) : "";
      if (!content) continue;

      if (isViewCountText(content)) {
        return content;
      }

      if (isViewCountPart(part)) {
        return content;
      }
    }
  }
  return "";
}

function isViewCountText(content: string): boolean {
  const lower = content.toLowerCase();
  return lower.includes("view")
    || lower.includes("watching")
    || lower.includes("ukubukwa")
    || lower.includes("akukho")
    || lower.includes("no views")
    || lower.includes("viewer")
    || lower.includes("ababukele")
    || lower.includes("babukele")
    || lower.includes("bukele")
    || content.includes("观看")
    || content.includes("次观看")
    || content.includes("正在观看")
    || content.includes("視")
    || content.includes("視聴")
    || content.includes("回再生")
    || content.includes("visualizaciones")
    || content.includes("vues")
    || content.includes("aufrufe")
    || content.includes("visualiza")
    || content.includes("vizionari")
    || content.includes("wy")
    || content.includes("görüntüleme")
    || content.includes("lượt xem")
    || content.includes("tontonan")
    || content.includes("просмотр");
}

function isViewCountPart(part: Record<string, Object>): boolean {
  const accessibilityLabel = (part["accessibilityLabel"] as string) || "";
  if (accessibilityLabel && isViewCountText(accessibilityLabel)) {
    return true;
  }
  const leadingIcon = part["leadingIcon"] as Record<string, Object>;
  if (leadingIcon) {
    const name = (leadingIcon["name"] as string) || "";
    if (name === "PLAY_ARROW_OUTLINED") {
      return true;
    }
  }
  return false;
}

/**
 * Live detection for lockupViewModel (PipePipe YoutubeLockupStreamInfoItemExtractor).
 */
export function getLockupIsLive(lockup: Record<string, Object>): boolean {
  const ci = lockup["contentImage"] as Record<string, Object>;
  const tvm = ci ? (ci["thumbnailViewModel"] as Record<string, Object>) : undefined;
  const overlays = tvm ? (tvm["overlays"] as Array<Record<string, Object>>) : undefined;
  if (overlays) {
    for (let i = 0; i < overlays.length; i++) {
      const overlay = overlays[i];
      const badgeVm = overlay
        ? (overlay["thumbnailOverlayBadgeViewModel"] as Record<string, Object>)
        : undefined;
      if (badgeVm) {
        const badges = badgeVm["thumbnailBadges"] as Array<Record<string, Object>>;
        if (badges) {
          for (let b = 0; b < badges.length; b++) {
            const bvm = badges[b]
              ? (badges[b]["thumbnailBadgeViewModel"] as Record<string, Object>)
              : undefined;
            if (bvm && isLockupLiveBadge(bvm)) {
              return true;
            }
          }
        }
      }
      const bottomVm = overlay
        ? (overlay["thumbnailBottomOverlayViewModel"] as Record<string, Object>)
        : undefined;
      if (bottomVm) {
        const badges = bottomVm["badges"] as Array<Record<string, Object>>;
        if (badges) {
          for (let b = 0; b < badges.length; b++) {
            const bvm = badges[b]
              ? (badges[b]["thumbnailBadgeViewModel"] as Record<string, Object>)
              : undefined;
            if (bvm && isLockupLiveBadge(bvm)) {
              return true;
            }
          }
        }
      }
    }
  }

  // Fallback: localized watching indicators in metadata rows.
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const meta = lmv ? (lmv["metadata"] as Record<string, Object>) : undefined;
  const cmv = meta ? (meta["contentMetadataViewModel"] as Record<string, Object>) : undefined;
  const rows = cmv ? (cmv["metadataRows"] as Array<Record<string, Object>>) : undefined;
  if (rows) {
    for (let i = 0; i < rows.length; i++) {
      const parts = rows[i] ? (rows[i]["metadataParts"] as Array<Record<string, Object>>) : undefined;
      if (!parts) {
        continue;
      }
      for (let j = 0; j < parts.length; j++) {
        const text = parts[j] ? (parts[j]["text"] as Record<string, Object>) : undefined;
        const content = text ? ((text["content"] as string) || "") : "";
        if (containsLockupWatchingIndicator(content)) {
          return true;
        }
      }
    }
  }
  return false;
}

function isLockupLiveBadge(bvm: Record<string, Object>): boolean {
  const style = ((bvm["badgeStyle"] as string) || "").toUpperCase();
  if (style.indexOf("LIVE") >= 0) {
    return true;
  }
  const text = ((bvm["text"] as string) || "").toLowerCase();
  if (text.indexOf("live") >= 0 || text.indexOf("bukhoma") >= 0
    || ((bvm["text"] as string) || "").indexOf("直播") >= 0) {
    return true;
  }
  // PipePipe treats animatedText as string; also accept {content}.
  const animatedRaw = bvm["animatedText"];
  if (typeof animatedRaw === "string") {
    const a = (animatedRaw as string).toLowerCase();
    if (a.indexOf("live") >= 0 || (animatedRaw as string).indexOf("直播") >= 0) {
      return true;
    }
  } else if (animatedRaw && typeof animatedRaw === "object") {
    const content = (((animatedRaw as Record<string, Object>)["content"] as string) || "");
    if (content.toLowerCase().indexOf("live") >= 0 || content.indexOf("直播") >= 0) {
      return true;
    }
  }
  const imageName = ((bvm["imageName"] as string) || "").toUpperCase();
  if (imageName === "LIVE") {
    return true;
  }
  const icon = bvm["icon"] as Record<string, Object>;
  const sources = icon ? (icon["sources"] as Array<Record<string, Object>>) : undefined;
  if (sources) {
    for (let s = 0; s < sources.length; s++) {
      const client = sources[s]
        ? (sources[s]["clientResource"] as Record<string, Object>)
        : undefined;
      const name = client ? (((client["imageName"] as string) || "").toUpperCase()) : "";
      if (name === "LIVE") {
        return true;
      }
    }
  }
  return false;
}

function containsLockupWatchingIndicator(text: string): boolean {
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

export function getLockupIsPremium(lockup: Record<string, Object>): boolean {
  const badges = lockup["badges"] as Array<Record<string, Object>>;
  if (badges) {
    for (let i = 0; i < badges.length; i++) {
      const badgeRenderer = badges[i] ? (badges[i]["metadataBadgeRenderer"] as Record<string, Object>) : undefined;
      if (badgeRenderer) {
        const label = (badgeRenderer["label"] as string) || "";
        if (label === "Premium" || label === "Free") return true;
        const style = (badgeRenderer["style"] as string) || "";
        if (style === "BADGE_STYLE_TYPE_PREMIUM") return true;
      }
    }
  }
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const meta = lmv ? (lmv["metadata"] as Record<string, Object>) : undefined;
  const cmv = meta ? (meta["contentMetadataViewModel"] as Record<string, Object>) : undefined;
  const rows = cmv ? (cmv["metadataRows"] as Array<Record<string, Object>>) : undefined;
  if (rows) {
    for (let i = 0; i < rows.length; i++) {
      const rowBadges = rows[i] ? (rows[i]["badges"] as Array<Record<string, Object>>) : undefined;
      if (!rowBadges) continue;
      for (let b = 0; b < rowBadges.length; b++) {
        const bvm = rowBadges[b] ? (rowBadges[b]["badgeViewModel"] as Record<string, Object>) : undefined;
        if (bvm) {
          const style = (bvm["badgeStyle"] as string) || "";
          if (style === "BADGE_PREMIUM" || style === "BADGE_STYLE_TYPE_PREMIUM") return true;
          const text = (bvm["text"] as string) || "";
          if (text.toLowerCase() === "premium") return true;
        }
      }
    }
  }
  return false;
}

export function getLockupRequiresMembership(lockup: Record<string, Object>): boolean {
  const badges = lockup["badges"] as Array<Record<string, Object>>;
  if (badges) {
    for (let i = 0; i < badges.length; i++) {
      const badgeRenderer = badges[i] ? (badges[i]["metadataBadgeRenderer"] as Record<string, Object>) : undefined;
      if (badgeRenderer) {
        const style = (badgeRenderer["style"] as string) || "";
        if (style === "BADGE_STYLE_TYPE_MEMBERS_ONLY") return true;
      }
    }
  }
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const meta = lmv ? (lmv["metadata"] as Record<string, Object>) : undefined;
  const cmv = meta ? (meta["contentMetadataViewModel"] as Record<string, Object>) : undefined;
  const rows = cmv ? (cmv["metadataRows"] as Array<Record<string, Object>>) : undefined;
  if (rows) {
    for (let i = 0; i < rows.length; i++) {
      const rowBadges = rows[i] ? (rows[i]["badges"] as Array<Record<string, Object>>) : undefined;
      if (!rowBadges) continue;
      for (let b = 0; b < rowBadges.length; b++) {
        const bvm = rowBadges[b] ? (rowBadges[b]["badgeViewModel"] as Record<string, Object>) : undefined;
        if (bvm) {
          const style = (bvm["badgeStyle"] as string) || "";
          if (style === "BADGE_MEMBERS_ONLY") return true;
        }
      }
    }
  }
  return false;
}

export function getLockupPlaylistCoverUrl(lockup: Record<string, Object>): string {
  const ci = lockup["contentImage"] as Record<string, Object>;
  const ctv = ci ? (ci["collectionThumbnailViewModel"] as Record<string, Object>) : undefined;
  const primary = ctv ? (ctv["primaryThumbnail"] as Record<string, Object>) : undefined;
  const tvm = primary ? (primary["thumbnailViewModel"] as Record<string, Object>) : undefined;
  const image = tvm ? (tvm["image"] as Record<string, Object>) : undefined;
  const sources = image ? (image["sources"] as Array<Record<string, Object>>) : undefined;
  if (!sources || sources.length === 0) return "";
  return pickBestThumbUrl(sources);
}
