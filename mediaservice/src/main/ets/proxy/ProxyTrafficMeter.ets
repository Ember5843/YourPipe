/**
 * Proxy-layer inbound network traffic meter.
 *
 * Playback media reaches MPV through the loopback proxy, so MPV's own
 * cache-speed property collapses to 0 once the demuxer cache is full.
 * This meter instead samples real network bytes at the point they arrive
 * (RangeProxy upstream chunks; SABR UMP POST responses via the
 * `setSabrNetworkTrafficSink` hook in youtube_core), giving the stats UI a
 * meaningful connection-speed figure. Loopback write-back to MPV is never
 * counted.
 *
 * High-frequency path: no logging here.
 */

/**
 * Sliding rate window reported by getRateBps(). Media downloads are bursty
 * (SABR POST every few seconds; MPV range bursts when its cache drains), so
 * the window is a 5s moving average — a short fixed window would read 0 at
 * most poll instants even though the average throughput is healthy. This
 * mirrors the smoothed connection speed in YouTube's stats-for-nerds.
 */
const RATE_WINDOW_MS = 5000;
/** Samples older than this are pruned (covers gaps so a stale burst cannot inflate a later window). */
const RETAIN_MS = 10000;

interface TrafficSample {
  timeMs: number;
  bytes: number;
}

export class ProxyTrafficMeter {
  private samples: TrafficSample[] = [];

  /** Record inbound network bytes; also prunes samples older than RETAIN_MS. */
  recordBytes(byteCount: number): void {
    if (byteCount <= 0) {
      return;
    }
    const now = Date.now();
    this.samples.push({ timeMs: now, bytes: byteCount });
    this.prune(now);
  }

  /** Bytes received within the last RATE_WINDOW_MS, normalized to bytes/sec. 0 when no samples. */
  getRateBps(): number {
    const now = Date.now();
    this.prune(now);
    const windowStart = now - RATE_WINDOW_MS;
    let total = 0;
    for (const sample of this.samples) {
      if (sample.timeMs >= windowStart) {
        total += sample.bytes;
      }
    }
    return total * (1000 / RATE_WINDOW_MS);
  }

  private prune(now: number): void {
    const cutoff = now - RETAIN_MS;
    while (this.samples.length > 0 && this.samples[0].timeMs < cutoff) {
      this.samples.shift();
    }
  }
}

export const proxyTrafficMeter = new ProxyTrafficMeter();
