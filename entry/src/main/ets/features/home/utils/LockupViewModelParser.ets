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
    return browseId;
  }

  return "";
}

export function getLockupUploaderName(lockup: Record<string, Object>): string {
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const meta = lmv ? (lmv["metadata"] as Record<string, Object>) : undefined;
  const cmv = meta ? (meta["contentMetadataViewModel"] as Record<string, Object>) : undefined;
  const rows = cmv ? (cmv["metadataRows"] as Array<Record<string, Object>>) : undefined;
  const firstRow = rows && rows.length > 0 ? rows[0] : undefined;
  const parts = firstRow ? (firstRow["metadataParts"] as Array<Record<string, Object>>) : undefined;
  const firstPart = parts && parts.length > 0 ? parts[0] : undefined;
  const text = firstPart ? (firstPart["text"] as Record<string, Object>) : undefined;
  const content = text ? (text["content"] as string) : "";
  return content || "";
}

export function getLockupChannelId(lockup: Record<string, Object>): string {
  const metadata = lockup["metadata"] as Record<string, Object>;
  const lmv = metadata ? (metadata["lockupMetadataViewModel"] as Record<string, Object>) : undefined;
  const meta = lmv ? (lmv["metadata"] as Record<string, Object>) : undefined;
  const cmv = meta ? (meta["contentMetadataViewModel"] as Record<string, Object>) : undefined;
  const rows = cmv ? (cmv["metadataRows"] as Array<Record<string, Object>>) : undefined;
  const firstRow = rows && rows.length > 0 ? rows[0] : undefined;
  const parts = firstRow ? (firstRow["metadataParts"] as Array<Record<string, Object>>) : undefined;
  const firstPart = parts && parts.length > 0 ? parts[0] : undefined;
  const text = firstPart ? (firstPart["text"] as Record<string, Object>) : undefined;
  const commandRuns = text ? (text["commandRuns"] as Array<Record<string, Object>>) : undefined;
  const firstRun = commandRuns && commandRuns.length > 0 ? commandRuns[0] : undefined;
  const onTap = firstRun ? (firstRun["onTap"] as Record<string, Object>) : undefined;
  const innertubeCommand = onTap ? (onTap["innertubeCommand"] as Record<string, Object>) : undefined;
  const browseEndpoint = innertubeCommand ? (innertubeCommand["browseEndpoint"] as Record<string, Object>) : undefined;
  const browseId = browseEndpoint ? (browseEndpoint["browseId"] as string) : "";
  return browseId || "";
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

export function getLockupIsLive(lockup: Record<string, Object>): boolean {
  const ci = lockup["contentImage"] as Record<string, Object>;
  const tvm = ci ? (ci["thumbnailViewModel"] as Record<string, Object>) : undefined;
  const overlays = tvm ? (tvm["overlays"] as Array<Record<string, Object>>) : undefined;
  if (overlays) {
    for (let i = 0; i < overlays.length; i++) {
      const overlay = overlays[i];
      const badgeVm = overlay ? (overlay["thumbnailOverlayBadgeViewModel"] as Record<string, Object>) : undefined;
      if (badgeVm) {
        const badges = badgeVm["thumbnailBadges"] as Array<Record<string, Object>>;
        if (badges) {
          for (let b = 0; b < badges.length; b++) {
            const bvm = badges[b] ? (badges[b]["thumbnailBadgeViewModel"] as Record<string, Object>) : undefined;
            if (!bvm) continue;
            const style = (bvm["badgeStyle"] as string) || "";
            if (style.toUpperCase().includes("LIVE")) return true;
            const text = (bvm["text"] as string) || "";
            if (text.toLowerCase().includes("live") || text.toLowerCase().includes("bukhoma")) return true;
            const animatedText = (bvm["animatedText"] as Record<string, Object>);
            const animatedContent = animatedText ? (animatedText["content"] as string) : "";
            if (animatedContent.toLowerCase().includes("live")) return true;
            const imageName = (bvm["imageName"] as string) || "";
            if (imageName === "LIVE") return true;
          }
        }
      }
      const bottomVm = overlay ? (overlay["thumbnailBottomOverlayViewModel"] as Record<string, Object>) : undefined;
      if (bottomVm) {
        const badges = bottomVm["badges"] as Array<Record<string, Object>>;
        if (badges) {
          for (let b = 0; b < badges.length; b++) {
            const bvm = badges[b] ? (badges[b]["thumbnailBadgeViewModel"] as Record<string, Object>) : undefined;
            if (!bvm) continue;
            const style = (bvm["badgeStyle"] as string) || "";
            if (style.toUpperCase().includes("LIVE")) return true;
            const text = (bvm["text"] as string) || "";
            if (text.toLowerCase().includes("live") || text.toLowerCase().includes("bukhoma")) return true;
            const imageName = (bvm["imageName"] as string) || "";
            if (imageName === "LIVE") return true;
          }
        }
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
      const parts = rows[i] ? (rows[i]["metadataParts"] as Array<Record<string, Object>>) : undefined;
      if (!parts) continue;
      for (let j = 0; j < parts.length; j++) {
        const text = parts[j] ? (parts[j]["text"] as Record<string, Object>) : undefined;
        const content = text ? (text["content"] as string) : "";
        if (content && (content.toLowerCase().includes("watching") || content.toLowerCase().includes("bukele"))) return true;
      }
    }
  }
  return false;
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
