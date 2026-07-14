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

  summarize(): string {
    return `urlLen=${this.url?.length ?? 0}`;
  }
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

  summarize(): string {
    return `type=${this.type} scope=${this.scope} valueLen=${this.value.length} send=${this.sendByDefault}`;
  }
}

export class SabrContextSendingPolicy {
  startTimeMs: number = -1;
  durationMs: number = -1;
  types: number[] = [];
  disposeTypes: number[] = [];

  summarize(): string {
    return `types=${this.types.join(',')} dispose=${this.disposeTypes.join(',')}`;
  }
}

export class SabrFormatInitMeta {
  itag: number = -1;
  lastModified: number = -1;
  xtags?: string;
  endTimeMs: number = -1;
  endSegmentNumber: number = -1;
  mimeType?: string;

  summarize(): string {
    return `itag=${this.itag} endMs=${this.endTimeMs} endSeq=${this.endSegmentNumber}`;
  }
}

export class SabrDecodedResponse {
  mediaHeaders: SabrMediaHeader[] = [];
  mediaEndHeaderIds: number[] = [];
  mediaBytesByHeaderId: Map<number, number> = new Map();
  nextRequestPolicy?: SabrNextRequestPolicy;
  redirectUrl?: string;
  sabrError?: string;
  reloadRequested: boolean = false;
  streamProtectionStatus: number = -1;
  streamProtectionMaxRetries: number = -1;
  sabrContextUpdates: SabrContextUpdate[] = [];
  sabrContextSendingPolicy?: SabrContextSendingPolicy;
  formatInitializationMetadata: SabrFormatInitMeta[] = [];
  backoffTimeMs: number = -1;
  unknownPartTypes: number[] = [];
  integrityIssues: string[] = [];
  segments: SabrMediaSegment[] = [];

  hasMedia(): boolean {
    return this.mediaHeaders.length > 0 || this.mediaBytesByHeaderId.size > 0
      || this.segments.length > 0;
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

  isProtectedNoMediaResponse(): boolean {
    return this.isNoMediaResponse() && this.streamProtectionStatus >= 3;
  }

  getIntegrityIssues(): string[] {
    const issues: string[] = [];
    for (const header of this.mediaHeaders) {
      const bytes = this.mediaBytesByHeaderId.get(header.headerId) ?? 0;
      if (bytes <= 0 && !this.mediaEndHeaderIds.includes(header.headerId)) {
        // header observed without media end is ok if segment assembled separately
        continue;
      }
      if (header.contentLength > 0 && bytes > 0 && bytes < header.contentLength) {
        issues.push(`incomplete-media headerId=${header.headerId} got=${bytes} want=${header.contentLength}`);
      }
    }
    return issues.concat(this.integrityIssues);
  }

  summarizeNoMediaResponse(): string {
    return `protection=${this.streamProtectionStatus}/${this.streamProtectionMaxRetries} `
      + `reload=${this.reloadRequested} redirect=${!!this.redirectUrl} `
      + `error=${this.sabrError || 'none'} policy=${this.nextRequestPolicy?.summarize() || 'none'}`;
  }
}
