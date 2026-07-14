import { SabrMediaSegment, SabrSegmentRequest } from 'youtube_core';
import Logger from '../utils/Logger';
import { SabrLease, sabrSessionStore } from './SabrSessionStore';

const TAG = '[SabrTrackBuffer]';

/**
 * Linear progressive view of SABR init + media segments for one track.
 * Maps HTTP Range offsets → segment bytes; pumps session when missing.
 * Cold seek: byte offset → time → SABR prepareSeek, then refill from target.
 */
export class SabrTrackBuffer {
  private lease: SabrLease;
  private isAudio: boolean;
  private durationMs: number;
  private estimatedTotalBytes: number;
  private init?: SabrMediaSegment;
  private mediaBySeq: Map<number, SabrMediaSegment> = new Map();
  private orderedSeq: number[] = [];
  private totalKnownBytes: number = 0;
  private nextExpectedSeq: number = 0;
  private fullyBuffered: boolean = false;
  private pumpPromise?: Promise<void>;
  /** Stop free-pump after protected no-media until session backoff clears. */
  private stalledProtected: boolean = false;
  private emptyPumpStreak: number = 0;
  /** After cold seek, media is placed from this virtual file offset. */
  private mediaBaseByte: number = 0;
  private mediaBaseMs: number = 0;

  constructor(lease: SabrLease, isAudio: boolean, durationMs: number = 0) {
    this.lease = lease;
    this.isAudio = isAudio;
    this.durationMs = Math.max(0, durationMs);
    this.estimatedTotalBytes = this.computeEstimatedTotal();
  }

  getItag(): number {
    return this.isAudio ? this.lease.audioFormat.itag : this.lease.videoFormat.itag;
  }

  getEndSegment(): number {
    const format = this.isAudio ? this.lease.audioFormat : this.lease.videoFormat;
    return this.lease.session.getStreamState().getEndSegment(format);
  }

  getSegmentStartMs(sequenceNumber: number): number {
    const format = this.isAudio ? this.lease.audioFormat : this.lease.videoFormat;
    return this.lease.session.getStreamState().getSegmentStartMs(format, sequenceNumber);
  }

  getSegmentEndMs(sequenceNumber: number): number {
    const format = this.isAudio ? this.lease.audioFormat : this.lease.videoFormat;
    return this.lease.session.getStreamState().getSegmentEndMs(format, sequenceNumber);
  }

  /** Exact segment access used by the local DASH facade. Undefined means proven EOF. */
  async readSegment(initSegment: boolean, sequenceNumber: number = -1): Promise<Uint8Array | undefined> {
    await this.ensureReady();
    const request = initSegment
      ? SabrSegmentRequest.init(this.getItag())
      : SabrSegmentRequest.media(this.getItag(), sequenceNumber);
    if (this.lease.session.isBeyondEnd(request)) {
      return undefined;
    }
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const segment = await this.lease.session.fetchSegment(request);
        if (initSegment) {
          const format = this.isAudio ? this.lease.audioFormat : this.lease.videoFormat;
          const playbackData = this.lease.session.getStreamState()
            .getPlaybackInitializationData(format, segment.data);
          if (playbackData.length !== segment.data.length) {
            Logger.info(TAG, `trim init itag=${this.getItag()} `
              + `bytes=${segment.data.length}->${playbackData.length}`);
          }
          return playbackData;
        }
        return segment.data;
      } catch (e) {
        if (this.lease.session.isBeyondEnd(request)
          || String(e).indexOf('segment beyond end') >= 0) {
          return undefined;
        }
        const message = String(e);
        const transient = message.indexOf('policy-only') >= 0
          || message.indexOf('protected no-media') >= 0
          || message.indexOf('repeated no-media') >= 0;
        if (!transient || attempt >= 3) {
          throw e instanceof Error ? e : new Error(message);
        }
        const waitMs = Math.max(250, this.lease.session.getBackoffRemainingMs());
        Logger.warn(TAG, `wait transient itag=${this.getItag()} seq=${sequenceNumber} `
          + `attempt=${attempt + 1} waitMs=${waitMs}`);
        await sleepMs(waitMs);
      }
    }
    return undefined;
  }

  /**
   * Prefer fixed estimated length (bitrate×duration) so MPV can seek; never shrink below known.
   */
  getContentLength(): number {
    if (this.estimatedTotalBytes > 0) {
      return Math.max(this.estimatedTotalBytes, this.totalKnownBytes, this.mediaBaseByte + 1);
    }
    return this.totalKnownBytes > 0 ? this.totalKnownBytes : -1;
  }

  async ensureReady(): Promise<void> {
    if (!this.init) {
      this.init = await sabrSessionStore.ensureInit(this.lease, this.isAudio);
      this.totalKnownBytes = this.init.getLength();
      this.mediaBaseByte = this.init.getLength();
      this.mediaBaseMs = 0;
      if (this.estimatedTotalBytes <= 0) {
        this.estimatedTotalBytes = this.computeEstimatedTotal();
      }
      Logger.info(TAG, `init ready itag=${this.getItag()} bytes=${this.init.getLength()} `
        + `estTotal=${this.estimatedTotalBytes} durMs=${this.durationMs}`);
    }
  }

  /**
   * Read [start, end] inclusive into a new Uint8Array. Pumps as needed.
   */
  async readRange(start: number, end: number): Promise<Uint8Array> {
    await this.ensureReady();
    if (start < 0) {
      start = 0;
    }
    if (end < start) {
      return new Uint8Array(0);
    }

    // lavf progressive seeks often compute absurd byte offsets (>> estTotal).
    // Map any far/out-of-range start onto a timeline seek before serving.
    if (this.shouldColdSeek(start)) {
      await this.coldSeekToByte(start);
      // After cold seek, serve from the virtual base (init + media from target time).
      // Remap the request into the new contiguous window so demuxer still gets media.
      const windowStart = this.mediaBaseByte;
      const span = Math.max(1, end - start);
      start = windowStart;
      end = windowStart + Math.min(span, 2 * 1024 * 1024 - 1);
    }

    const needEnd = end + 1;
    await this.ensureBytes(needEnd);

    const outLen = end - start + 1;
    const out = new Uint8Array(outLen);
    let written = 0;

    // init always lives at [0, initLen)
    if (this.init) {
      const initLen = this.init.getLength();
      if (start < initLen) {
        const from = start;
        const to = Math.min(end + 1, initLen);
        out.set(this.init.data.subarray(from, to), written);
        written += to - from;
      }
    }

    // Media placed from mediaBaseByte using startMs relative to mediaBaseMs when possible.
    for (const seq of this.orderedSeq) {
      if (written >= outLen) {
        break;
      }
      const seg = this.mediaBySeq.get(seq);
      if (!seg) {
        continue;
      }
      const segStart = this.byteOffsetOf(seg);
      const segLen = seg.getLength();
      const segEnd = segStart + segLen;
      if (end >= segStart && start < segEnd) {
        const from = Math.max(start, segStart) - segStart;
        const to = Math.min(end + 1, segEnd) - segStart;
        out.set(seg.data.subarray(from, to), written);
        written += to - from;
      }
    }

    if (written < outLen) {
      return out.subarray(0, written);
    }
    return out;
  }

  private shouldColdSeek(start: number): boolean {
    if (!this.init || start <= 0) {
      return false;
    }
    const initLen = this.init.getLength();
    if (start < initLen) {
      return false;
    }
    if (this.durationMs <= 0) {
      return false;
    }
    const est = this.estimatedTotalBytes > initLen
      ? this.estimatedTotalBytes
      : Math.max(this.extentEnd() * 4, initLen + 1);
    const windowEnd = Math.max(this.totalKnownBytes, this.mediaBaseByte, this.extentEnd());
    // Still inside/near the known progressive window: keep pumping, never cold-seek.
    if (start <= windowEnd + 256 * 1024) {
      return false;
    }
    // Past advertised Content-Length: lavf often probes with absurd offsets (>> est).
    // Mapping those to ratio=1 seeks to the *end* of the video (start-from-last-frame bug).
    // Treat as EOF instead — serve empty range, do not prepareSeek(duration).
    if (start >= est) {
      return false;
    }
    // Legitimate mid-file jump far past the contiguous window.
    return start > windowEnd + 256 * 1024;
  }

  private async coldSeekToByte(start: number): Promise<void> {
    const initLen = this.init ? this.init.getLength() : 0;
    const est = this.estimatedTotalBytes > initLen
      ? this.estimatedTotalBytes
      : Math.max(this.extentEnd() * 4, initLen + 1024 * 1024);
    // Only called for start < est (see shouldColdSeek). Keep ratio strictly in [0, 1).
    const ratio = Math.min(0.999, Math.max(0, start / Math.max(est, 1)));
    let targetMs = ratio * this.durationMs;
    // Never land on exact duration (mpv would open at EOF and look "stuck at end").
    if (this.durationMs > 2000) {
      targetMs = Math.min(targetMs, this.durationMs - 1000);
    }
    Logger.info(TAG, `cold seek itag=${this.getItag()} byte=${start} est=${est} `
      + `ratio=${ratio.toFixed(3)} → ${Math.floor(targetMs)}ms`);
    this.resetForSeek(targetMs);
    // Rebuild a contiguous progressive window from init: demuxers handle this better
    // than sparse placement at huge offsets.
    this.mediaBaseByte = initLen;
    this.mediaBaseMs = targetMs;
    this.stalledProtected = false;
    this.emptyPumpStreak = 0;
    this.backoffUntilClearedAllowRetry();
    for (let i = 0; i < 8; i++) {
      const before = this.mediaBySeq.size;
      await this.pumpMore();
      if (this.mediaBySeq.size > before) {
        this.emptyPumpStreak = 0;
        continue;
      }
      if (this.stalledProtected && this.lease.session.isInBackoff()) {
        break;
      }
      if (this.emptyPumpStreak >= 2) {
        break;
      }
    }
  }

  private backoffUntilClearedAllowRetry(): void {
    // Drop sticky stall so seek can POST after prepareSeek cleared session backoff.
    this.stalledProtected = false;
    this.emptyPumpStreak = 0;
  }

  private byteOffsetOf(seg: SabrMediaSegment): number {
    const initLen = this.init ? this.init.getLength() : 0;
    // A byte-range resource must be contiguous. Mapping each fragment from its timestamp and
    // average bitrate creates holes; HTTP then returns a short body and lavf treats it as EOF.
    // Seeking is handled by prepareSeek/resetForSeek, so pack the current playback window by seq.
    let offset = this.mediaBaseByte > 0 ? this.mediaBaseByte : initLen;
    for (const seq of this.orderedSeq) {
      if (seq === seg.header.sequenceNumber) {
        return offset;
      }
      const s = this.mediaBySeq.get(seq);
      if (s) {
        offset += s.getLength();
      }
    }
    return offset;
  }

  private computeEstimatedTotal(): number {
    const fmt = this.isAudio ? this.lease.audioFormat : this.lease.videoFormat;
    if (fmt.contentLength && fmt.contentLength > 0) {
      return fmt.contentLength;
    }
    const bitrate = fmt.bitrate ?? 0;
    const dur = this.durationMs > 0 ? this.durationMs : (fmt.approxDurationMs ?? 0);
    if (bitrate > 0 && dur > 0) {
      // bitrate is typically bps; +512KB pad for init/moof overhead
      return Math.floor((bitrate / 8) * (dur / 1000)) + 512 * 1024;
    }
    return 0;
  }

  private async ensureBytes(needEnd: number): Promise<void> {
    let guard = 0;
    while (this.extentEnd() < needEnd && !this.fullyBuffered && guard < 32) {
      // After server backoff expires, always allow another attempt (don't stick forever).
      if (this.stalledProtected && !this.lease.session.isInBackoff()) {
        this.stalledProtected = false;
        this.emptyPumpStreak = 0;
      }
      if (this.stalledProtected && this.lease.session.isInBackoff()) {
        break;
      }
      guard++;
      const before = this.extentEnd();
      await this.pumpMore();
      if (this.extentEnd() <= before) {
        this.emptyPumpStreak++;
        // One empty is enough while protected; otherwise allow a couple.
        if (this.stalledProtected || this.emptyPumpStreak >= 2) {
          break;
        }
      } else {
        this.emptyPumpStreak = 0;
      }
    }
  }

  private extentEnd(): number {
    let end = this.init ? this.init.getLength() : 0;
    for (const seq of this.orderedSeq) {
      const seg = this.mediaBySeq.get(seq);
      if (!seg) {
        continue;
      }
      const s = this.byteOffsetOf(seg);
      end = Math.max(end, s + seg.getLength());
    }
    return Math.max(end, this.totalKnownBytes, this.mediaBaseByte);
  }

  private async pumpMore(): Promise<void> {
    if (this.pumpPromise) {
      await this.pumpPromise;
      return;
    }
    this.pumpPromise = this.doPump();
    try {
      await this.pumpPromise;
    } finally {
      this.pumpPromise = undefined;
    }
  }

  private async doPump(): Promise<void> {
    const itag = this.getItag();
    const synced = this.syncFromSessionCache(itag);
    if (synced > 0) {
      this.emptyPumpStreak = 0;
      this.stalledProtected = false;
      return;
    }

    if (this.stalledProtected && this.lease.session.isInBackoff()) {
      return;
    }

    if (this.orderedSeq.length > 0) {
      const last = this.orderedSeq[this.orderedSeq.length - 1];
      const next = last + 1;
      try {
        const seg = await this.lease.session.fetchSegment(SabrSegmentRequest.media(itag, next));
        this.ingestMedia(seg);
        this.stalledProtected = false;
        this.emptyPumpStreak = 0;
        return;
      } catch (e) {
        const msg = String(e);
        if (msg.indexOf('protected no-media') >= 0 || msg.indexOf('policy-only') >= 0
          || msg.indexOf('repeated no-media') >= 0) {
          this.stalledProtected = true;
          Logger.warn(TAG, `fetch next seq=${next} stalled (no free-pump): ${e}`);
          return;
        }
        Logger.warn(TAG, `fetch next seq=${next} failed, free pump once: ${e}`);
      }
    }

    if (this.stalledProtected) {
      return;
    }
    const decoded = await this.lease.session.pumpOnce();
    let got = 0;
    for (const seg of decoded.segments) {
      if (seg.header.itag === itag) {
        if (seg.header.initSegment) {
          if (!this.init) {
            this.init = seg;
            this.totalKnownBytes = Math.max(this.totalKnownBytes, seg.getLength());
            got++;
          }
        } else {
          const before = this.mediaBySeq.size;
          this.ingestMedia(seg);
          if (this.mediaBySeq.size > before) {
            got++;
          }
        }
      }
    }
    got += this.syncFromSessionCache(itag);
    if (got === 0 && decoded.isProtectionBoundaryNoMediaResponse()) {
      this.stalledProtected = true;
      Logger.warn(TAG, `free pump protected no-media, stall itag=${itag}`);
    }
  }

  private syncFromSessionCache(itag: number): number {
    let added = 0;
    for (const key of this.lease.session.listCachedKeys()) {
      if (!key.startsWith(`${itag}:`) || key.endsWith(':init')) {
        continue;
      }
      const seqStr = key.substring(key.indexOf(':') + 1);
      const seq = parseInt(seqStr, 10);
      if (!Number.isFinite(seq) || this.mediaBySeq.has(seq)) {
        continue;
      }
      const cached = this.lease.session.getCachedSegment(SabrSegmentRequest.media(itag, seq));
      if (cached) {
        const before = this.mediaBySeq.size;
        this.ingestMedia(cached);
        if (this.mediaBySeq.size > before) {
          added++;
        }
      }
    }
    return added;
  }

  private ingestMedia(seg: SabrMediaSegment): void {
    if (seg.header.initSegment) {
      return;
    }
    const seq = seg.header.sequenceNumber;
    if (seq < 0 || this.mediaBySeq.has(seq)) {
      return;
    }
    this.mediaBySeq.set(seq, seg);
    this.orderedSeq.push(seq);
    this.orderedSeq.sort((a, b) => a - b);
    const end = this.byteOffsetOf(seg) + seg.getLength();
    if (end > this.totalKnownBytes) {
      this.totalKnownBytes = end;
    }
    if (this.nextExpectedSeq <= seq) {
      this.nextExpectedSeq = seq + 1;
    }
    Logger.debug(TAG, `media itag=${this.getItag()} seq=${seq} startMs=${seg.header.startMs} `
      + `bytes=${seg.getLength()} total=${this.totalKnownBytes}`);
  }

  resetForSeek(targetMs: number): void {
    sabrSessionStore.prepareSeek(this.lease.key, targetMs);
    this.mediaBySeq.clear();
    this.orderedSeq = [];
    this.totalKnownBytes = this.init ? this.init.getLength() : 0;
    this.nextExpectedSeq = 0;
    this.fullyBuffered = false;
    this.stalledProtected = false;
    this.emptyPumpStreak = 0;
    this.mediaBaseMs = Math.max(0, targetMs);
    this.mediaBaseByte = this.init ? this.init.getLength() : 0;
  }
}

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), ms);
  });
}
