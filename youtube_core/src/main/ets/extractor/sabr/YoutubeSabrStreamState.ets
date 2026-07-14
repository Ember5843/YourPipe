import { SabrBufferedRange } from './SabrBufferedRange';
import {
  SabrContextSendingPolicy,
  SabrContextUpdate,
  SabrDecodedResponse,
  SabrFormatInitMeta
} from './SabrDecodedResponse';
import { SabrMediaHeader } from './SabrMediaHeader';
import { SabrMediaSegment } from './SabrMediaSegment';
import { YoutubeSabrFormatMeta } from './YoutubeSabrInfo';
import { parseMp4SegmentIndex, SabrSegmentIndex } from './SabrMp4SegmentIndex';

export const SABR_TRACK_BOTH = 0;
export const SABR_TRACK_AUDIO_ONLY = 1;
export const SABR_TRACK_VIDEO_ONLY = 2;

class FormatProgress {
  format: YoutubeSabrFormatMeta;
  initReceived: boolean = false;
  firstSequence: number = -1;
  /** Highest sequence received without a hole from sequence 1. */
  lastSequence: number = 0;
  startTimeMs: number = 0;
  bufferedEndMs: number = 0;
  lastDurationMs: number = 0;
  endSegmentNumber: number = -1;
  endTimeMs: number = -1;
  averageDurationMs: number = 5000;
  private aheadSegments: Map<number, number> = new Map();
  private metadata?: SabrFormatInitMeta;
  private segmentIndex?: SabrSegmentIndex;

  constructor(format: YoutubeSabrFormatMeta) {
    this.format = format;
  }

  observeHeader(header: SabrMediaHeader): boolean {
    if (header.initSegment) {
      this.initReceived = true;
      return true;
    }
    if (header.sequenceNumber >= 0) {
      if (this.firstSequence < 0 || header.sequenceNumber < this.firstSequence) {
        this.firstSequence = header.sequenceNumber;
      }
      if (header.sequenceNumber === this.lastSequence + 1) {
        this.lastSequence = header.sequenceNumber;
      } else if (header.sequenceNumber > this.lastSequence + 1) {
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
      const mime = this.metadata?.mimeType ?? this.format.mimeType ?? '';
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
    if (!this.initReceived || this.lastSequence <= 0) {
      return;
    }
    const startSeq = this.firstSequence >= 0 ? this.firstSequence : 0;
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
    // Soft reset sequence tracking near seek target; next headers re-fill.
    this.firstSequence = -1;
    this.lastSequence = Math.max(0, this.getSegmentNumberAtOrAfterTimeMs(targetMs) - 1);
    this.aheadSegments.clear();
  }

  /**
   * Cold seek: claim everything before target as buffered so the server streams
   * from target instead of filling the skipped span (PipePipe jumpBufferedTo).
   */
  jumpTo(targetMs: number): void {
    const t = Math.max(0, targetMs);
    if (t > this.bufferedEndMs) {
      this.bufferedEndMs = t;
    } else {
      this.bufferedEndMs = t;
    }
    this.startTimeMs = 0;
    const endSeq = Math.max(0, this.getSegmentNumberAtOrAfterTimeMs(t) - 1);
    this.firstSequence = endSeq > 0 ? 1 : -1;
    this.lastSequence = endSeq;
    this.aheadSegments.clear();
  }

  getEndSegmentNumber(): number {
    return this.endSegmentNumber;
  }

  getSegmentStartMs(sequenceNumber: number): number {
    if (sequenceNumber <= 1) {
      return 0;
    }
    const indexed = this.segmentIndex?.getEntry(sequenceNumber);
    if (indexed) {
      return indexed.startMs;
    }
    return Math.max(0, sequenceNumber - 1) * this.averageDurationMs;
  }

  getSegmentEndMs(sequenceNumber: number): number {
    const indexed = this.segmentIndex?.getEntry(sequenceNumber);
    if (indexed) {
      return indexed.getEndMs();
    }
    if (sequenceNumber <= 0) {
      return -1;
    }
    return sequenceNumber * this.averageDurationMs;
  }

  getSegmentNumberAtOrAfterTimeMs(timeMs: number): number {
    if (timeMs <= 0) {
      return 1;
    }
    if (this.segmentIndex) {
      for (let sequence = 1; sequence <= this.segmentIndex.size(); sequence++) {
        const entry = this.segmentIndex.getEntry(sequence);
        if (entry && entry.getEndMs() > timeMs) {
          return sequence;
        }
      }
      return Math.max(1, this.segmentIndex.size() + 1);
    }
    return Math.max(1, Math.floor(timeMs / Math.max(1, this.averageDurationMs)) + 1);
  }

  isComplete(): boolean {
    return this.initReceived && this.endSegmentNumber >= 0
      && this.lastSequence >= this.endSegmentNumber;
  }
}

/**
 * Per-session track progress + cookie/context state (PipePipe YoutubeSabrStreamState subset).
 */
export class YoutubeSabrStreamState {
  private audio: FormatProgress;
  private video: FormatProgress;
  private playbackCookie?: Uint8Array;
  private poToken?: Uint8Array;
  private sabrContexts: Map<number, SabrContextUpdate> = new Map();
  private activeSabrContextTypes: Set<number> = new Set();
  private playerTimeMsOverride: number = -1;
  private enabledTrackTypesBitfield: number = SABR_TRACK_BOTH;
  private selectAudioFormat: boolean = true;
  private selectVideoFormat: boolean = true;
  private writeTopLevelPlayerTimeMs: boolean = true;
  private playbackRate: number = 1.0;

  constructor(audioFormat: YoutubeSabrFormatMeta, videoFormat: YoutubeSabrFormatMeta) {
    this.audio = new FormatProgress(audioFormat);
    this.video = new FormatProgress(videoFormat);
  }

  ingest(response: SabrDecodedResponse): boolean {
    let progressed = false;
    if (response.nextRequestPolicy) {
      if (response.nextRequestPolicy.playbackCookie) {
        this.playbackCookie = response.nextRequestPolicy.playbackCookie;
      }
    }
    for (const meta of response.formatInitializationMetadata) {
      const progress = this.findProgressForItag(meta.itag);
      if (progress) {
        progressed = progress.observeMetadata(meta) || progressed;
      }
    }
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

  private ingestContextUpdate(update: SabrContextUpdate): void {
    if (update.type < 0) {
      return;
    }
    // writePolicy 2 = KEEP_EXISTING
    if (update.writePolicy === 2 && this.sabrContexts.has(update.type)) {
      return;
    }
    this.sabrContexts.set(update.type, update);
    if (update.sendByDefault) {
      this.activeSabrContextTypes.add(update.type);
    }
  }

  private ingestContextSendingPolicy(policy: SabrContextSendingPolicy): void {
    for (const type of policy.types) {
      this.activeSabrContextTypes.add(type);
    }
    for (const type of policy.disposeTypes) {
      this.activeSabrContextTypes.delete(type);
      this.sabrContexts.delete(type);
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

  clearPlayerTimeMsOverride(): void {
    this.playerTimeMsOverride = -1;
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

  getEndSegment(format: YoutubeSabrFormatMeta): number {
    const progress = this.findProgressForItag(format.itag);
    return progress ? progress.getEndSegmentNumber() : -1;
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

  setEnabledTrackTypesBitfield(value: number): void {
    this.enabledTrackTypesBitfield = value;
  }

  setTrackModeAudioOnly(): void {
    this.enabledTrackTypesBitfield = SABR_TRACK_AUDIO_ONLY;
    this.selectAudioFormat = true;
    this.selectVideoFormat = false;
  }

  setTrackModeVideoOnly(): void {
    this.enabledTrackTypesBitfield = SABR_TRACK_VIDEO_ONLY;
    this.selectAudioFormat = false;
    this.selectVideoFormat = true;
  }

  setTrackModeBoth(): void {
    this.enabledTrackTypesBitfield = SABR_TRACK_BOTH;
    this.selectAudioFormat = true;
    this.selectVideoFormat = true;
  }

  getPlaybackRate(): number {
    return this.playbackRate;
  }

  setPlaybackRate(rate: number): void {
    this.playbackRate = rate > 0 ? rate : 1.0;
  }

  getRawPlaybackCookie(): Uint8Array | undefined {
    return this.playbackCookie;
  }

  getRawPoToken(): Uint8Array | undefined {
    return this.poToken;
  }

  setPoToken(token?: Uint8Array): void {
    this.poToken = token;
  }

  clearPlaybackCookie(): void {
    this.playbackCookie = undefined;
  }

  getActiveSabrContexts(): SabrContextUpdate[] {
    const out: SabrContextUpdate[] = [];
    this.activeSabrContextTypes.forEach((type: number) => {
      const ctx = this.sabrContexts.get(type);
      if (ctx) {
        out.push(ctx);
      }
    });
    return out;
  }

  getUnsentSabrContextTypes(): number[] {
    // PipePipe echoes types that server asked but are not yet in active set.
    // MVP: empty (contexts with sendByDefault already active).
    return [];
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

  /** Re-advertise one track immediately before an observed cache hole. */
  prepareForMissingSegment(format: YoutubeSabrFormatMeta, sequenceNumber: number): void {
    const progress = this.findProgressForItag(format.itag);
    if (!progress || sequenceNumber <= 0) {
      return;
    }
    const targetMs = progress.getSegmentStartMs(sequenceNumber);
    progress.jumpTo(targetMs);
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
