/**
 * Shared byte-size formatting (single implementation; previously copied in
 * DownloadManager / DownloadDialog / VideoDetails with drifted thresholds).
 * Returns '' for non-positive sizes so callers can fall back to 'Unknown'.
 */
export function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '';
  }
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

/**
 * Shared seconds → "h:mm:ss" / "m:ss" duration text (single implementation;
 * previously copied in PlayerSession / VideoDetails / LocalPage). Floors each
 * component. Callers that need '' for non-positive values (LocalPage) or a
 * clamp at 0 (PlayerSession) apply that at the call site.
 */
export function formatDurationHms(sec: number): string {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  const mm = m.toString().padStart(2, '0');
  const ss = s.toString().padStart(2, '0');
  return h > 0 ? `${h}:${mm}:${ss}` : `${m}:${ss}`;
}
