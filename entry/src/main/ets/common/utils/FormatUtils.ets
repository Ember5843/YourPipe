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
