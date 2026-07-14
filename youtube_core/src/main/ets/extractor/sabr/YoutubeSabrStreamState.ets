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

export const SABR_TRACK_BOTH = 0;
export const SABR_TRACK_AUDIO_ONLY = 1;
export const SABR_TRACK_VIDEO_ONLY = 2;

class FormatProgress {
  format: YoutubeSabrFormatMeta;
  initReceived: boolean = false;
  firstSequence: number = -1;
  lastSequence: number = -1;
  startTimeMs: number = 0;
  bufferedEndMs: number = 0;
  lastDurationMs: number = 0;

  constructor(format: YoutubeSabrFormatMeta) {
    this.format = format;
  }

  observeHeader(header: SabrMediaHeader): boolean {
    if (header.initSegment) {
      this.initReceived = true;
      return true;
    }
    if (header.sequenceNumber >= 0) {
      if (this.firstSequence < 0) {
        this.firstSequence = header.sequenceNumber;
      }
      if (header.sequenceNumber > this.lastSequence) {
        this.lastSequence = header.sequenceNumber;
      }
    }
    if (header.startMs >= 0) {
      if (this.bufferedEndMs <= 0 && header.startMs > 0) {
        this.startTimeMs = Math.min(this.startTimeMs || header.startMs, header.startMs);
      }
      const end = header.startMs + Math.max(0, header.durationMs);
      if (end > this.bufferedEndMs) {
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
    return this.observeHeader(segment.header);
  }

  observeMetadata(meta: SabrFormatInitMeta): boolean {
    if (meta.endTimeMs > this.bufferedEndMs) {
      this.bufferedEndMs = meta.endTimeMs;
    }
    if (meta.endSegmentNumber > this.lastSequence) {
      this.lastSequence = meta.endSegmentNumber;
    }
    return true;
  }

  addBufferedRange(ranges: SabrBufferedRange[]): void {
    if (!this.initReceived && this.lastSequence < 0) {
      return;
    }
    const startSeq = this.firstSequence >= 0 ? this.firstSequence : 0;
    const endSeq = this.lastSequence >= 0 ? this.lastSequence : 0;
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
    this.lastSequence = -1;
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
    this.setPlayerTimeMsOverride(targetMs);
    this.clearPlaybackCookie();
    this.audio.shrinkTo(targetMs);
    this.video.shrinkTo(targetMs);
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
