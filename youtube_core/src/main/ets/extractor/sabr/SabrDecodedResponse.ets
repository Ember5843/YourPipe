import { SabrMediaHeader } from './SabrMediaHeader';
import { SabrMediaSegment } from './SabrMediaSegment';

export class SabrNextRequestPolicy {
  targetAudioReadaheadMs: number = -1;
  targetVideoReadaheadMs: number = -1;
  maxTimeSinceLastRequestMs: number = -1;
  backoffTimeMs: number = -1;
  minAudioReadaheadMs: number = -1;
  minVideoReadaheadMs: number = -1;
  playbackCookie?: Uint8Array;
  videoId?: string;

  summarize(): string {
    return `backoff=${this.backoffTimeMs} cookie=${this.playbackCookie?.length ?? 0}`;
  }
}

export class SabrRedirectInfo {
  url?: string;
}

export class SabrContextUpdate {
  type: number = -1;
  scope: number = -1;
  value: Uint8Array = new Uint8Array(0);
  sendByDefault: boolean = false;
  writePolicy: number = -1;

  toStreamerContextProtoBytes(writeMessage: (type: number, value: Uint8Array) => Uint8Array): Uint8Array {
    return writeMessage(this.type, this.value);
  }
}

export class SabrContextSendingPolicy {
  /** field 1: context types to add to the active set. */
  activateTypes: number[] = [];
  /** field 2: context types to remove from the active set. */
  deactivateTypes: number[] = [];
  /** field 3: context types to dispose (drop from active set and stored contexts). */
  disposeTypes: number[] = [];
}

export class SabrFormatInitMeta {
  videoId?: string;
  itag: number = -1;
  lastModified: number = -1;
  xtags?: string;
  endTimeMs: number = -1;
  endSegmentNumber: number = -1;
  mimeType?: string;
  initRangeStart: number = -1;
  initRangeEnd: number = -1;
  indexRangeStart: number = -1;
  indexRangeEnd: number = -1;
  field8: number = -1;
  durationUnits: number = -1;
  durationTimescale: number = -1;
}

export class SabrDecodedResponse {
  mediaHeaders: SabrMediaHeader[] = [];
  mediaEndHeaderIds: number[] = [];
  nextRequestPolicy?: SabrNextRequestPolicy;
  redirectUrl?: string;
  sabrError?: string;
  reloadRequested: boolean = false;
  streamProtectionStatus: number = -1;
  streamProtectionMaxRetries: number = -1;
  /** SABR_SEEK part reason (-1 = no seek part). Decoded for diagnostics only. */
  sabrSeekReason: number = -1;
  sabrContextUpdates: SabrContextUpdate[] = [];
  sabrContextSendingPolicy?: SabrContextSendingPolicy;
  formatInitializationMetadata: SabrFormatInitMeta[] = [];
  backoffTimeMs: number = -1;
  unknownPartTypes: number[] = [];
  segments: SabrMediaSegment[] = [];
  /** PipePipe YoutubeSabrResponse.getIntegrityIssues — empty means media-complete. */
  integrityIssues: string[] = [];

  hasMedia(): boolean {
    return this.mediaHeaders.length > 0 || this.segments.length > 0;
  }

  isNoMediaResponse(): boolean {
    return !this.hasMedia();
  }

  isPolicyOnlyResponse(): boolean {
    return this.isNoMediaResponse() && !!this.nextRequestPolicy;
  }

  isProtectionBoundaryNoMediaResponse(): boolean {
    return this.isNoMediaResponse() && this.streamProtectionStatus >= 2;
  }

  /** Stream protection pending (status==2): server asks for attestation progress. */
  isAttestationPending(): boolean {
    return this.streamProtectionStatus === 2;
  }

  /** Stream protection required (status>=3): hard boundary, no local retry helps. */
  isAttestationRequired(): boolean {
    return this.streamProtectionStatus >= 3;
  }

  summarizeNoMediaResponse(): string {
    return `protection=${this.streamProtectionStatus}/${this.streamProtectionMaxRetries} `
      + `reload=${this.reloadRequested} seek=${this.sabrSeekReason} redirect=${!!this.redirectUrl} `
      + `error=${this.sabrError || 'none'} policy=${this.nextRequestPolicy?.summarize() || 'none'}`;
  }
}
