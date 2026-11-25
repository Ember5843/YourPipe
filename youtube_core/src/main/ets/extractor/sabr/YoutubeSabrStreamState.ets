import { SabrBufferedRange } from './SabrBufferedRange';
import {
  SabrContextSendingPolicy,
  SabrContextUpdate,
  SabrDecodedResponse,
  SabrFormatInitMeta,
  SabrLiveMetadata
} from './SabrDecodedResponse';
import { SabrMediaHeader } from './SabrMediaHeader';
import { SabrMediaSegment } from './SabrMediaSegment';
import { SabrServerEpoch } from './SabrServerEpoch';
import { YoutubeSabrFormatMeta } from './YoutubeSabrInfo';
import { parseMp4SegmentIndex, SabrSegmentIndex } from './SabrMp4SegmentIndex';
import { parseWebmSegmentIndex } from './SabrWebmSegmentIndex';

export const SABR_TRACK_BOTH = 0;
export const SABR_TRACK_AUDIO_ONLY = 1;
export const SABR_TRACK_VIDEO_ONLY = 2;

class FormatProgress {
  format: YoutubeSabrFormatMeta;
  private readonly isPostLive: boolean;
  initReceived: boolean = false;
  firstSequence: number = -1;
  /** Highest sequence received without a hole from startSequence. */
  lastSequence: number = 0;
  startTimeMs: number = 0;
  bufferedEndMs: number = 0;
  lastDurationMs: number = 0;
  endSegmentNumber: number = -1;
  endTimeMs: number = -1;
  averageDurationMs: number = 5000;
  private postLiveStartSequence: number = 0;
  private postLiveEndSequence: number = -1;
  private postLiveStartTimeMs: number = 0;
  private postLiveSegmentDurationMs: number = 0;
  private aheadSegments: Map<number, number> = new Map();
  private metadata?: SabrFormatInitMeta;
  private segmentIndex?: SabrSegmentIndex;

  constructor(format: YoutubeSabrFormatMeta, isPostLive: boolean = false) {
    this.format = format;
    this.isPostLive = isPostLive;
    this.lastSequence = isPostLive ? -1 : 0;
  }

  private minSequence(): number {
    return this.isPostLive ? Math.max(0, this.postLiveStartSequence) : 1;
  }

  syncPostLiveWindow(
    liveHeadSeq: number,
    liveHeadTimeMs: number,
    liveSeekableStartTimeMs: number,
    liveSeekableEndTimeMs: number
  ): void {
    if (!this.isPostLive) {
      return;
    }
    const dur = this.computeLiveSegmentDurationMs(liveHeadSeq, liveHeadTimeMs);
    if (dur > 0) {
      this.postLiveSegmentDurationMs = dur;
    }
    const endSeg = this.endSegmentNumber > 0 ? this.endSegmentNumber : liveHeadSeq;
    const endTime = this.endTimeMs > 0
      ? this.endTimeMs
      : (liveHeadTimeMs > 0 ? liveHeadTimeMs : liveSeekableEndTimeMs);
    let startSeq = 0;
    if (endSeg >= 0 && liveSeekableStartTimeMs > 0 && endTime > liveSeekableStartTimeMs && dur > 0) {
      const count = Math.ceil((endTime - liveSeekableStartTimeMs) / dur);
      startSeq = Math.max(0, endSeg - count + 1);
    }
    this.postLiveStartSequence = startSeq;
    this.postLiveStartTimeMs = Math.max(0, liveSeekableStartTimeMs);
    this.postLiveEndSequence = endSeg;
  }

  private computeLiveSegmentDurationMs(liveHeadSeq: number, liveHeadTimeMs: number): number {
    if (this.metadata && this.metadata.durationUnits > 0 && this.metadata.durationTimescale > 0) {
      return Math.max(1, Math.floor(this.metadata.durationUnits * 1000 / this.metadata.durationTimescale));
    }
    if (this.format.targetDurationSec && this.format.targetDurationSec > 0) {
      return Math.max(1, Math.floor(this.format.targetDurationSec * 1000));
    }
    if (liveHeadSeq > 0 && liveHeadTimeMs > 0) {
      return Math.max(1, Math.floor(liveHeadTimeMs / liveHeadSeq));
    }
    return -1;
  }

  observeHeader(header: SabrMediaHeader): boolean {
    if (header.initSegment) {
      this.initReceived = true;
      return true;
    }
    const minSeq = this.minSequence();
    if (header.sequenceNumber >= 0) {
      if (this.firstSequence < 0 || header.sequenceNumber < this.firstSequence) {
        this.firstSequence = header.sequenceNumber;
      }
      if (this.lastSequence < minSeq && header.sequenceNumber === minSeq) {
        this.lastSequence = header.sequenceNumber;
      } else if (header.sequenceNumber === this.lastSequence + 1) {
        this.lastSequence = header.sequenceNumber;
      } else if (header.sequenceNumber > Math.max(this.lastSequence + 1, minSeq)) {
        this.aheadSegments.set(header.sequenceNumber,
          header.startMs + Math.max(0, header.durationMs));
      }
      while (this.aheadSegments.has(this.lastSequence + 1)) {
        this.lastSequence++;
        const promotedEnd = this.aheadSegments.get(this.lastSequence) ?? 0;
        this.aheadSegments.delete(this.lastSequence);
        if (promotedEnd > this.bufferedEndMs) {
          this.bufferedEndMs = promotedEnd;
        }
      }
    }
    if (header.startMs >= 0) {
      if (this.bufferedEndMs <= 0 && header.startMs > 0) {
        this.startTimeMs = Math.min(this.startTimeMs || header.startMs, header.startMs);
      }
      const end = header.startMs + Math.max(0, header.durationMs);
      if (header.sequenceNumber <= this.lastSequence && end > this.bufferedEndMs) {
        this.bufferedEndMs = end;
      }
      if (header.durationMs > 0) {
        this.lastDurationMs = header.durationMs;
      }
      return true;
    }
    return false;
  }

  observeSegment(segment: SabrMediaSegment): boolean {
    const changed = this.observeHeader(segment.header);
    if (segment.header.initSegment && !this.segmentIndex) {
      const mime = (this.metadata?.mimeType ?? this.format.mimeType ?? '').toLowerCase();
      if (mime.indexOf('mp4') >= 0) {
        try {
          this.segmentIndex = parseMp4SegmentIndex(segment.data,
            this.metadata?.indexRangeStart ?? -1, this.metadata?.indexRangeEnd ?? -1);
          if (this.endSegmentNumber <= 0) {
            this.endSegmentNumber = this.segmentIndex.size();
          }
          return true;
        } catch (_) {
          // Keep the duration/count fallback for formats whose init data has no SIDX.
        }
      } else if (mime.indexOf('webm') >= 0) {
        try {
          const totalDurationMs = (this.metadata && this.metadata.durationUnits > 0
            && this.metadata.durationTimescale > 0)
            ? Math.floor((this.metadata.durationUnits * 1000 + this.metadata.durationTimescale / 2)
              / this.metadata.durationTimescale)
            : (this.format.approxDurationMs ?? -1);
          this.segmentIndex = parseWebmSegmentIndex(segment.data,
            this.metadata?.indexRangeStart ?? -1, this.metadata?.indexRangeEnd ?? -1,
            totalDurationMs);
          if (this.endSegmentNumber <= 0) {
            this.endSegmentNumber = this.segmentIndex.size();
          }
          return true;
        } catch (_) {
          // Keep the duration/count fallback for formats whose init data has no Cues.
        }
      }
    }
    return changed;
  }

  observeMetadata(meta: SabrFormatInitMeta): boolean {
    // This is the resource boundary, not download progress. Advertising it as buffered makes
    // YouTube correctly stop sending media after the first response.
    this.metadata = meta;
    this.endTimeMs = meta.endTimeMs;
    this.endSegmentNumber = meta.endSegmentNumber;
    if (meta.durationUnits > 0 && meta.durationTimescale > 0 && meta.endSegmentNumber > 0) {
      const totalMs = meta.durationUnits * 1000 / meta.durationTimescale;
      this.averageDurationMs = Math.max(1, Math.floor(totalMs / meta.endSegmentNumber));
    } else if (meta.endSegmentNumber > 0 && (this.format.approxDurationMs ?? 0) > 0) {
      this.averageDurationMs = Math.max(1,
        Math.floor((this.format.approxDurationMs ?? 0) / meta.endSegmentNumber));
    }
    return true;
  }

  addBufferedRange(ranges: SabrBufferedRange[]): void {
    const minSeq = this.minSequence();
    if (!this.initReceived || this.lastSequence < minSeq) {
      return;
    }
    const startSeq = this.firstSequence >= 0 ? this.firstSequence : minSeq;
    const endSeq = this.lastSequence;
    const duration = Math.max(0, this.bufferedEndMs - this.startTimeMs);
    ranges.push(SabrBufferedRange.fromProgress(
      this.format,
      this.startTimeMs,
      duration > 0 ? duration : 0,
      startSeq,
      endSeq
    ));
  }

  getBufferedEndMs(): number {
    return this.bufferedEndMs;
  }

  shrinkTo(targetMs: number): void {
    if (targetMs < this.bufferedEndMs) {
      this.bufferedEndMs = Math.max(0, targetMs);
    }
    const minSeq = this.minSequence();
    // Soft reset sequence tracking near seek target; next headers re-fill.
    this.firstSequence = -1;
    this.lastSequence = Math.max(minSeq - 1, this.getSegmentNumberAtOrAfterTimeMs(targetMs) - 1);
    this.aheadSegments.clear();
  }

  /**
   * Cold seek: claim everything before target as buffered so the server streams
   * from target instead of filling the skipped span (PipePipe jumpBufferedTo).
   */
  jumpTo(targetMs: number): void {
    const t = Math.max(0, targetMs);
    this.bufferedEndMs = t;
    this.startTimeMs = this.isPostLive ? this.postLiveStartTimeMs : 0;
    const minSeq = this.minSequence();
    const endSeq = Math.max(minSeq - 1, this.getSegmentNumberAtOrAfterTimeMs(t) - 1);
    this.firstSequence = endSeq >= minSeq ? minSeq : -1;
    this.lastSequence = endSeq;
    this.aheadSegments.clear();
  }

  /**
   * PipePipe SabrMediaBridge.track(): position this track's advertised bufferedThrough
   * immediately before an exact sequence number without relying on ms-to-sequence rounding.
   */
  jumpToSequence(sequenceNumber: number): void {
    const minSeq = this.minSequence();
    const endSeq = Math.max(minSeq - 1, sequenceNumber - 1);
    this.startTimeMs = this.isPostLive ? this.postLiveStartTimeMs : 0;
    this.firstSequence = endSeq >= minSeq ? minSeq : -1;
    this.lastSequence = endSeq;
    if (endSeq >= minSeq) {
      const endMs = this.getSegmentEndMs(endSeq);
      this.bufferedEndMs = endMs >= 0 ? endMs : Math.max(0, this.getSegmentStartMs(sequenceNumber));
    } else {
      this.bufferedEndMs = this.startTimeMs;
    }
    this.aheadSegments.clear();
  }

  getLastSequence(): number {
    return this.lastSequence;
  }

  getStartSequence(): number {
    return this.isPostLive ? Math.max(0, this.postLiveStartSequence) : 1;
  }

  getEndSegmentNumber(): number {
    if (this.endSegmentNumber >= 0) {
      return this.endSegmentNumber;
    }
    return this.isPostLive ? this.postLiveEndSequence : -1;
  }

  hasSegmentIndex(): boolean {
    return !!this.segmentIndex;
  }

  getEffectiveSegmentDurationMs(): number {
    return this.postLiveSegmentDurationMs > 0 ? this.postLiveSegmentDurationMs : this.averageDurationMs;
  }

  getSegmentStartMs(sequenceNumber: number): number {
    if (this.segmentIndex) {
      if (sequenceNumber <= 1) {
        return 0;
      }
      const indexed = this.segmentIndex.getEntry(sequenceNumber);
      return indexed ? indexed.startMs : -1;
    }
    if (this.isPostLive) {
      const startSeq = Math.max(0, this.postLiveStartSequence);
      if (sequenceNumber <= startSeq) {
        return this.postLiveStartTimeMs;
      }
      const dur = this.getEffectiveSegmentDurationMs();
      return this.postLiveStartTimeMs + (sequenceNumber - startSeq) * dur;
    }
    if (sequenceNumber <= 1) {
      return 0;
    }
    return Math.max(0, sequenceNumber - 1) * this.averageDurationMs;
  }

  getSegmentEndMs(sequenceNumber: number): number {
    const indexed = this.segmentIndex?.getEntry(sequenceNumber);
    if (indexed) {
      return indexed.getEndMs();
    }
    if (this.isPostLive) {
      if (sequenceNumber < 0) {
        return -1;
      }
      return this.getSegmentStartMs(sequenceNumber) + this.getEffectiveSegmentDurationMs();
    }
    if (sequenceNumber <= 0) {
      return -1;
    }
    return sequenceNumber * this.averageDurationMs;
  }

  getSegmentNumberAtOrAfterTimeMs(timeMs: number): number {
    if (this.segmentIndex) {
      if (timeMs <= 0) {
        return 1;
      }
      for (let sequence = 1; sequence <= this.segmentIndex.size(); sequence++) {
        const entry = this.segmentIndex.getEntry(sequence);
        if (entry && entry.getEndMs() > timeMs) {
          return sequence;
        }
      }
      return Math.max(1, this.segmentIndex.size() + 1);
    }
    if (this.isPostLive) {
      const startSeq = Math.max(0, this.postLiveStartSequence);
      if (timeMs <= this.postLiveStartTimeMs) {
        return startSeq;
      }
      const dur = Math.max(1, this.getEffectiveSegmentDurationMs());
      return startSeq + Math.floor((timeMs - this.postLiveStartTimeMs) / dur);
    }
    if (timeMs <= 0) {
      return 1;
    }
    return Math.max(1, Math.floor(timeMs / Math.max(1, this.averageDurationMs)) + 1);
  }

  getPlaybackInitializationData(data: Uint8Array): Uint8Array {
    const start = this.metadata?.initRangeStart ?? -1;
    const end = this.metadata?.initRangeEnd ?? -1;
    // UMP initialization media may contain both the decoder initialization bytes and the
    // following SIDX index range. DASH already owns the segment timeline, so expose only the
    // initialization byte range to the player. This also keeps hierarchical SIDX boxes away
    // from FFmpeg builds that reject reference_type=1 while opening the track.
    if (start >= 0 && end >= start && end < data.length) {
      return data.subarray(start, end + 1);
    }
    return data;
  }

  isComplete(): boolean {
    const endSeg = this.getEndSegmentNumber();
    return this.initReceived && endSeg >= 0 && this.lastSequence >= endSeg;
  }
}

/**
 * Per-session track progress + seek/player-time state (PipePipe
 * YoutubeSabrStreamState subset). Server-epoch state (playbackCookie,
 * sabrContexts, poToken) lives in SabrServerEpoch; the public accessors
 * below keep their signatures and delegate to it.
 */
export class YoutubeSabrStreamState {
  private audio: FormatProgress;
  private video: FormatProgress;
  private epoch: SabrServerEpoch;
  private readonly isPostLive: boolean;
  private live: boolean = false;
  private postLiveDvr: boolean = false;
  private liveHeadSequenceNumber: number = -1;
  private liveHeadTimeMs: number = -1;
  private liveSeekableStartTimeMs: number = -1;
  private liveSeekableEndTimeMs: number = -1;
  private playerTimeMsOverride: number = -1;
  private enabledTrackTypesBitfield: number = SABR_TRACK_BOTH;
  private selectAudioFormat: boolean = true;
  private selectVideoFormat: boolean = true;
  private writeTopLevelPlayerTimeMs: boolean = true;
  private playbackRate: number = 1.0;
  /**
   * Measured downlink throughput in bits/s (PipePipe updateBandwidthEstimate).
   * -1 = not measured yet; the UMP request then falls back to the static
   * bitrate estimate (PipePipe activeBitrateEstimate).
   */
  private bandwidthEstimateBps: number = -1;

  constructor(audioFormat: YoutubeSabrFormatMeta, videoFormat: YoutubeSabrFormatMeta,
    epoch: SabrServerEpoch, isPostLive: boolean = false) {
    this.isPostLive = isPostLive;
    this.audio = new FormatProgress(audioFormat, isPostLive);
    this.video = new FormatProgress(videoFormat, isPostLive);
    this.epoch = epoch;
  }

  getEpoch(): SabrServerEpoch {
    return this.epoch;
  }

  isPostLiveStream(): boolean {
    return this.isPostLive;
  }

  observeLiveMetadata(meta: SabrLiveMetadata): void {
    this.live = true;
    this.postLiveDvr = this.postLiveDvr || meta.isPostLiveDvr;
    if (meta.liveHeadSequenceNumber >= 0) {
      this.liveHeadSequenceNumber = Math.max(this.liveHeadSequenceNumber, meta.liveHeadSequenceNumber);
    }
    if (meta.liveHeadTimeMs >= 0) {
      this.liveHeadTimeMs = Math.max(this.liveHeadTimeMs, meta.liveHeadTimeMs);
    }
    const minSeekMs = scaleToMilliseconds(meta.minSeekableTimeTicks, meta.minSeekableTimescale);
    if (minSeekMs >= 0) {
      this.liveSeekableStartTimeMs = Math.max(this.liveSeekableStartTimeMs, minSeekMs);
    }
    const maxSeekMs = scaleToMilliseconds(meta.maxSeekableTimeTicks, meta.maxSeekableTimescale);
    if (maxSeekMs >= 0) {
      this.liveSeekableEndTimeMs = Math.max(this.liveSeekableEndTimeMs, maxSeekMs);
    }
    this.syncPostLiveWindows();
  }

  private syncPostLiveWindows(): void {
    if (!this.isPostLive) {
      return;
    }
    this.audio.syncPostLiveWindow(
      this.liveHeadSequenceNumber, this.liveHeadTimeMs,
      this.liveSeekableStartTimeMs, this.liveSeekableEndTimeMs);
    this.video.syncPostLiveWindow(
      this.liveHeadSequenceNumber, this.liveHeadTimeMs,
      this.liveSeekableStartTimeMs, this.liveSeekableEndTimeMs);
  }

  ingest(response: SabrDecodedResponse): boolean {
    let progressed = false;
    if (response.nextRequestPolicy) {
      if (response.nextRequestPolicy.playbackCookie) {
        this.epoch.playbackCookie = response.nextRequestPolicy.playbackCookie;
      }
    }
    for (const liveMeta of response.liveMetadata) {
      this.observeLiveMetadata(liveMeta);
    }
    for (const meta of response.formatInitializationMetadata) {
      const progress = this.findProgressForItag(meta.itag);
      if (progress) {
        progressed = progress.observeMetadata(meta) || progressed;
      }
    }
    this.syncPostLiveWindows();
    for (const header of response.mediaHeaders) {
      const progress = this.findProgressForItag(header.itag);
      if (progress) {
        progressed = progress.observeHeader(header) || progressed;
      }
    }
    for (const segment of response.segments) {
      progressed = this.ingestSegment(segment) || progressed;
    }
    for (const update of response.sabrContextUpdates) {
      this.ingestContextUpdate(update);
    }
    if (response.sabrContextSendingPolicy) {
      this.ingestContextSendingPolicy(response.sabrContextSendingPolicy);
    }
    return progressed;
  }

  ingestSegment(segment: SabrMediaSegment): boolean {
    const progress = this.findProgressForItag(segment.header.itag);
    return progress ? progress.observeSegment(segment) : false;
  }

  /**
   * Deliver the format initialization metadata as soon as its UMP part shows
   * up. The metadata carries the index range the init segment's SIDX parse
   * needs, so in the streaming path it must be known BEFORE the init segment
   * arrives — waiting for the end of the response would drop the segment
   * index and fall back to the duration/count estimate.
   */
  observeFormatInitMeta(meta: SabrFormatInitMeta): void {
    const progress = this.findProgressForItag(meta.itag);
    if (progress) {
      progress.observeMetadata(meta);
      this.syncPostLiveWindows();
    }
  }

  private ingestContextUpdate(update: SabrContextUpdate): void {
    if (update.type < 0) {
      return;
    }
    // writePolicy 2 = KEEP_EXISTING
    if (update.writePolicy === 2 && this.epoch.sabrContexts.has(update.type)) {
      return;
    }
    this.epoch.sabrContexts.set(update.type, update);
    if (update.sendByDefault) {
      this.epoch.activeSabrContextTypes.add(update.type);
    }
  }

  private ingestContextSendingPolicy(policy: SabrContextSendingPolicy): void {
    for (const type of policy.activateTypes) {
      this.epoch.activeSabrContextTypes.add(type);
    }
    for (const type of policy.deactivateTypes) {
      this.epoch.activeSabrContextTypes.delete(type);
    }
    for (const type of policy.disposeTypes) {
      this.epoch.activeSabrContextTypes.delete(type);
      this.epoch.sabrContexts.delete(type);
    }
  }

  getBufferedRanges(): SabrBufferedRange[] {
    const ranges: SabrBufferedRange[] = [];
    if (this.isAudioEnabled()) {
      this.audio.addBufferedRange(ranges);
    }
    if (this.isVideoEnabled()) {
      this.video.addBufferedRange(ranges);
    }
    return ranges;
  }

  getPlayerTimeMs(): number {
    if (this.playerTimeMsOverride >= 0) {
      return this.playerTimeMsOverride;
    }
    return Math.max(this.audio.getBufferedEndMs(), this.video.getBufferedEndMs());
  }

  getRequestPlayerTimeMs(): number {
    if (this.playerTimeMsOverride >= 0) {
      return this.playerTimeMsOverride;
    }
    if ((this.isAudioEnabled() && !this.audio.initReceived)
      || (this.isVideoEnabled() && !this.video.initReceived)) {
      return 0;
    }
    return this.getPlayerTimeMs();
  }

  setPlayerTimeMsOverride(ms: number): void {
    this.playerTimeMsOverride = ms;
  }

  getMinBufferedEndMs(): number {
    if (!this.isVideoEnabled()) {
      return this.audio.getBufferedEndMs();
    }
    if (!this.isAudioEnabled()) {
      return this.video.getBufferedEndMs();
    }
    return Math.min(this.audio.getBufferedEndMs(), this.video.getBufferedEndMs());
  }

  getBufferedEndMs(format: YoutubeSabrFormatMeta): number {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getBufferedEndMs() : 0;
  }

  getLastSequence(format: YoutubeSabrFormatMeta): number {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getLastSequence() : (this.isPostLive ? -1 : 0);
  }

  getStartSegment(format: YoutubeSabrFormatMeta): number {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getStartSequence() : (this.isPostLive ? 0 : 1);
  }

  getEndSegment(format: YoutubeSabrFormatMeta): number {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getEndSegmentNumber() : -1;
  }

  hasSegmentIndex(format: YoutubeSabrFormatMeta): boolean {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.hasSegmentIndex() : false;
  }

  getLiveSegmentDurationMs(format: YoutubeSabrFormatMeta): number {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getEffectiveSegmentDurationMs() : 5000;
  }

  getPresentationTimeOffsetMs(): number {
    return this.isPostLive ? Math.max(0, this.liveSeekableStartTimeMs) : 0;
  }

  getPostLiveDurationMs(): number {
    if (!this.isPostLive || !this.live) {
      return 0;
    }
    const windowStart = Math.max(0, this.liveSeekableStartTimeMs);
    const windowEnd = Math.max(this.liveSeekableEndTimeMs, Math.max(this.liveHeadTimeMs, windowStart));
    return windowEnd > windowStart ? Math.max(1, windowEnd - windowStart) : 0;
  }

  getSegmentStartMs(format: YoutubeSabrFormatMeta, sequenceNumber: number): number {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getSegmentStartMs(sequenceNumber) : 0;
  }

  getSegmentEndMs(format: YoutubeSabrFormatMeta, sequenceNumber: number): number {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getSegmentEndMs(sequenceNumber) : -1;
  }

  getSegmentNumberAtOrAfterTimeMs(format: YoutubeSabrFormatMeta, timeMs: number): number {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getSegmentNumberAtOrAfterTimeMs(timeMs) : 1;
  }

  getPlaybackInitializationData(format: YoutubeSabrFormatMeta, data: Uint8Array): Uint8Array {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getPlaybackInitializationData(data) : data;
  }

  isComplete(format?: YoutubeSabrFormatMeta): boolean {
    if (format) {
      const progress = this.findProgressForItag(format.itag);
      return !!progress && progress.isComplete();
    }
    return (!this.isAudioEnabled() || this.audio.isComplete())
      && (!this.isVideoEnabled() || this.video.isComplete());
  }

  isInitialized(format: YoutubeSabrFormatMeta): boolean {
    const progress = this.findProgressForItag(format.itag);
    return !!progress && progress.initReceived;
  }

  markInitReceived(itag: number): void {
    const progress = this.findProgressForItag(itag);
    if (progress) {
      progress.initReceived = true;
    }
  }

  shouldSelectAudioFormat(): boolean {
    return this.selectAudioFormat && this.isAudioEnabled();
  }

  shouldSelectVideoFormat(): boolean {
    return this.selectVideoFormat && this.isVideoEnabled();
  }

  shouldWriteTopLevelPlayerTimeMs(): boolean {
    return this.writeTopLevelPlayerTimeMs;
  }

  getEnabledTrackTypesBitfield(): number {
    return this.enabledTrackTypesBitfield;
  }

  getPlaybackRate(): number {
    return this.playbackRate;
  }

  /**
   * Last measured downlink throughput in bits/s, or -1 when nothing was measured yet.
   * PipePipe YoutubeSabrSession.getBandwidthEstimate — the UMP request prefers this
   * over the static bitrate estimate so the server can pick a matching ABR level.
   */
  getBandwidthEstimateBps(): number {
    return this.bandwidthEstimateBps;
  }

  /**
   * Fold one measured response into the bandwidth estimate.
   * PipePipe updateBandwidthEstimate: sample = bytes*8000/elapsedMs (bits/s),
   * smoothed as (estimate*3 + sample)/4 so one slow response cannot collapse the hint.
   */
  updateBandwidthEstimate(responseBytes: number, elapsedMs: number): void {
    if (responseBytes <= 0 || elapsedMs <= 0) {
      return;
    }
    const sample = Math.floor((responseBytes * 8000) / elapsedMs);
    if (sample <= 0) {
      return;
    }
    this.bandwidthEstimateBps = this.bandwidthEstimateBps <= 0
      ? sample
      : Math.floor((this.bandwidthEstimateBps * 3 + sample) / 4);
  }

  // DORMANT: 全仓零调用——倍速不下发到 UMP 请求（builder 读到的恒为 1.0）；
  // 启用条件：对齐 PipePipe 倍速行为后由播放引擎接线调用。
  setPlaybackRate(rate: number): void {
    this.playbackRate = rate > 0 ? rate : 1.0;
  }

  getRawPlaybackCookie(): Uint8Array | undefined {
    return this.epoch.playbackCookie;
  }

  getRawPoToken(): Uint8Array | undefined {
    return this.epoch.poToken;
  }

  setPoToken(token?: Uint8Array): void {
    this.epoch.poToken = token;
  }

  clearPlaybackCookie(): void {
    this.epoch.playbackCookie = undefined;
  }

  getActiveSabrContexts(): SabrContextUpdate[] {
    const out: SabrContextUpdate[] = [];
    this.epoch.activeSabrContextTypes.forEach((type: number) => {
      const ctx = this.epoch.sabrContexts.get(type);
      if (ctx) {
        out.push(ctx);
      }
    });
    return out;
  }

  getUnsentSabrContextTypes(): number[] {
    // PipePipe getUnsentSabrContextTypes: the context types the server sent that
    // are not in the active set yet. They are echoed in streamerContext field 6
    // so the server knows the client is holding them — without that the server
    // cannot tell whether the context was received, and a later
    // SABR_CONTEXT_SENDING_POLICY (activate) would never turn it into an
    // echoed context.
    const unsent: number[] = [];
    this.epoch.sabrContexts.forEach((_value: SabrContextUpdate, type: number) => {
      if (!this.epoch.activeSabrContextTypes.has(type)) {
        unsent.push(type);
      }
    });
    return unsent;
  }

  prepareForSeek(targetMs: number): void {
    const t = Math.max(0, targetMs);
    this.setPlayerTimeMsOverride(t);
    this.clearPlaybackCookie();
    const edge = this.getMinBufferedEndMs();
    if (t + 500 < edge) {
      this.audio.shrinkTo(t);
      this.video.shrinkTo(t);
    } else {
      this.audio.jumpTo(t);
      this.video.jumpTo(t);
    }
  }

  /** Re-advertise one track immediately before an observed cache hole or behind-edge demand. */
  prepareForMissingSegment(format: YoutubeSabrFormatMeta, sequenceNumber: number): void {
    const progress = this.findProgressForItag(format.itag);
    const minSeq = progress ? progress.getStartSequence() : 1;
    if (!progress || sequenceNumber < minSeq) {
      return;
    }
    const targetMs = Math.max(0, progress.getSegmentStartMs(sequenceNumber));
    progress.jumpToSequence(sequenceNumber);
    this.setPlayerTimeMsOverride(targetMs);
    this.clearPlaybackCookie();
  }

  private isAudioEnabled(): boolean {
    return this.enabledTrackTypesBitfield !== SABR_TRACK_VIDEO_ONLY;
  }

  private isVideoEnabled(): boolean {
    return this.enabledTrackTypesBitfield !== SABR_TRACK_AUDIO_ONLY;
  }

  private findProgressForItag(itag: number): FormatProgress | undefined {
    if (this.audio.format.itag === itag) {
      return this.audio;
    }
    if (this.video.format.itag === itag) {
      return this.video;
    }
    return undefined;
  }
}

function scaleToMilliseconds(ticks: number, timescale: number): number {
  if (ticks < 0 || timescale <= 0) {
    return -1;
  }
  return Math.floor(ticks * 1000 / timescale);
}
