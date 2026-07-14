import { SabrMediaSegment, SabrSegmentRequest } from 'youtube_core';
import Logger from '../utils/Logger';
import { SabrLease, sabrSessionStore } from './SabrSessionStore';

const TAG = '[SabrTrackBuffer]';

/**
 * Linear progressive view of SABR init + media segments for one track.
 * Maps HTTP Range offsets → segment bytes; pumps session when missing.
 */
export class SabrTrackBuffer {
  private lease: SabrLease;
  private isAudio: boolean;
  private init?: SabrMediaSegment;
  private mediaBySeq: Map<number, SabrMediaSegment> = new Map();
  private orderedSeq: number[] = [];
  private totalKnownBytes: number = 0;
  private nextExpectedSeq: number = 0;
  private fullyBuffered: boolean = false;
  private pumpPromise?: Promise<void>;

  constructor(lease: SabrLease, isAudio: boolean) {
    this.lease = lease;
    this.isAudio = isAudio;
  }

  getItag(): number {
    return this.isAudio ? this.lease.audioFormat.itag : this.lease.videoFormat.itag;
  }

  /**
   * Approximate content length: sum of known segments. Grows as more media arrives.
   * When unknown, return -1 (proxy may use chunked / open-ended 206).
   */
  getContentLength(): number {
    return this.totalKnownBytes > 0 ? this.totalKnownBytes : -1;
  }

  async ensureReady(): Promise<void> {
    if (!this.init) {
      this.init = await sabrSessionStore.ensureInit(this.lease, this.isAudio);
      this.totalKnownBytes = this.init.getLength();
      Logger.info(TAG, `init ready itag=${this.getItag()} bytes=${this.init.getLength()}`);
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
    const needEnd = end + 1;
    await this.ensureBytes(needEnd);

    const outLen = end - start + 1;
    const out = new Uint8Array(outLen);
    let written = 0;
    let offset = 0;

    // init
    if (this.init) {
      const initLen = this.init.getLength();
      if (start < initLen) {
        const from = start;
        const to = Math.min(end + 1, initLen);
        out.set(this.init.data.subarray(from, to), written);
        written += to - from;
      }
      offset = initLen;
    }

    for (const seq of this.orderedSeq) {
      if (written >= outLen) {
        break;
      }
      const seg = this.mediaBySeq.get(seq);
      if (!seg) {
        continue;
      }
      const segLen = seg.getLength();
      const segStart = offset;
      const segEnd = offset + segLen;
      if (end >= segStart && start < segEnd) {
        const from = Math.max(start, segStart) - segStart;
        const to = Math.min(end + 1, segEnd) - segStart;
        out.set(seg.data.subarray(from, to), written);
        written += to - from;
      }
      offset = segEnd;
    }

    if (written < outLen) {
      // Partial — return what we have
      return out.subarray(0, written);
    }
    return out;
  }

  private async ensureBytes(needEnd: number): Promise<void> {
    let guard = 0;
    while (this.totalKnownBytes < needEnd && !this.fullyBuffered && guard < 64) {
      guard++;
      await this.pumpMore();
    }
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
    // Prefer next sequence if we already have some media; else free pump.
    if (this.orderedSeq.length > 0) {
      const last = this.orderedSeq[this.orderedSeq.length - 1];
      const next = last + 1;
      try {
        const seg = await this.lease.session.fetchSegment(SabrSegmentRequest.media(itag, next));
        this.ingestMedia(seg);
        return;
      } catch (e) {
        Logger.warn(TAG, `fetch next seq=${next} failed, free pump: ${e}`);
      }
    }
    const decoded = await this.lease.session.pumpOnce();
    for (const seg of decoded.segments) {
      if (seg.header.itag === itag) {
        if (seg.header.initSegment) {
          if (!this.init) {
            this.init = seg;
            this.totalKnownBytes += seg.getLength();
          }
        } else {
          this.ingestMedia(seg);
        }
      }
    }
    // Also pull from cache any new segments for this itag
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
        this.ingestMedia(cached);
      }
    }
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
    this.totalKnownBytes += seg.getLength();
    if (this.nextExpectedSeq <= seq) {
      this.nextExpectedSeq = seq + 1;
    }
    Logger.debug(TAG, `media itag=${this.getItag()} seq=${seq} bytes=${seg.getLength()} total=${this.totalKnownBytes}`);
  }

  resetForSeek(targetMs: number): void {
    sabrSessionStore.prepareSeek(this.lease.key, targetMs);
    // Keep init; drop media timeline (session cache also window-evicted).
    this.mediaBySeq.clear();
    this.orderedSeq = [];
    this.totalKnownBytes = this.init ? this.init.getLength() : 0;
    this.nextExpectedSeq = 0;
    this.fullyBuffered = false;
  }
}
