import { SabrProtocolException } from './SabrProtocolException';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import {
  SabrContextSendingPolicy,
  SabrContextUpdate,
  SabrDecodedResponse,
  SabrFormatInitMeta,
  SabrNextRequestPolicy,
  SabrRedirectInfo
} from './SabrDecodedResponse';
import { SabrMediaHeader } from './SabrMediaHeader';
import { SabrMediaSegment } from './SabrMediaSegment';
import { sabrReadFields, WIRE_LENGTH_DELIMITED, WIRE_VARINT } from './SabrProto';
import { readProtoVarint } from '../../common/ProtoUtil';
import { UmpPart, umpReadAll } from './UmpReader';

export const PART_MEDIA_HEADER = 20;
export const PART_MEDIA = 21;
export const PART_MEDIA_END = 22;
export const PART_NEXT_REQUEST_POLICY = 35;
export const PART_FORMAT_INITIALIZATION_METADATA = 42;
export const PART_SABR_REDIRECT = 43;
export const PART_SABR_ERROR = 44;
export const PART_SABR_SEEK = 45;
export const PART_RELOAD_PLAYER_RESPONSE = 46;
export const PART_STREAM_PROTECTION_STATUS = 58;
export const PART_SABR_CONTEXT_UPDATE = 57;
export const PART_SABR_CONTEXT_SENDING_POLICY = 59;

const logger = YTCoreLogger.getInstance('SabrResponseDecoder');

class OpenMediaAssembly {
  header: SabrMediaHeader;
  chunks: Uint8Array[] = [];

  constructor(header: SabrMediaHeader) {
    this.header = header;
  }
}

class StreamProtectionResult {
  status: number = -1;
  maxRetries: number = -1;
}

class FormatByteRange {
  start: number = -1;
  end: number = -1;
}

/**
 * Decode buffered UMP body into control fields + assembled media segments.
 * Whole-body path — kept for the offline downloader and tests. The playback
 * path uses {@link SabrPartProcessor} over a streamed response instead.
 */
export function sabrDecodeBody(data: Uint8Array): SabrDecodedResponse {
  const parts = umpReadAll(data);
  return sabrDecodeParts(parts);
}

export function sabrDecodeParts(parts: UmpPart[]): SabrDecodedResponse {
  const processor = new SabrPartProcessor();
  for (const part of parts) {
    processor.acceptPart(part);
  }
  return processor.finish();
}

/**
 * Incremental UMP part processor (PipePipe SabrStreamingResponseReader parity).
 *
 * <p>Parts are fed one at a time as the response arrives. Control parts are
 * decoded into the {@link SabrDecodedResponse}; media parts are assembled into
 * a segment and handed to {@code segmentSink} the moment the segment is
 * complete, so the player can start on the first segment instead of waiting
 * for the whole response.
 *
 * <p>Two invariants are preserved from the buffered path:
 * <ul>
 *   <li>a segment whose byte count disagrees with its header's contentLength
 *       is never delivered — the response-level integrity check then re-POSTs
 *       for a clean batch (a truncated segment must not reach the player);</li>
 *   <li>the media byte accounting is kept per header id, so the integrity
 *       check reports the same issues as the buffered decoder.</li>
 * </ul>
 */
export class SabrPartProcessor {
  private decoded: SabrDecodedResponse = new SabrDecodedResponse();
  private open: Map<number, OpenMediaAssembly> = new Map();
  /** Bytes per headerId across ALL media parts (PipePipe mediaBytesByHeaderId). */
  private mediaBytesByHeaderId: Map<number, number> = new Map();
  private segmentSink?: (segment: SabrMediaSegment) => void;
  private formatMetaSink?: (meta: SabrFormatInitMeta) => void;
  /** Segments retained only when no sink is attached. */
  private retainedSegments: SabrMediaSegment[] = [];
  private segmentCountValue: number = 0;

  constructor(
    segmentSink?: (segment: SabrMediaSegment) => void,
    formatMetaSink?: (meta: SabrFormatInitMeta) => void
  ) {
    this.segmentSink = segmentSink;
    this.formatMetaSink = formatMetaSink;
  }

  /** Process one UMP part. Never throws — a malformed part is logged and skipped. */
  acceptPart(part: UmpPart): void {
    try {
      switch (part.type) {
        case PART_MEDIA_HEADER: {
          const header = SabrMediaHeader.decode(part.data);
          this.decoded.mediaHeaders.push(header);
          this.open.set(header.headerId, new OpenMediaAssembly(header));
          break;
        }
        case PART_MEDIA: {
          if (part.data.length > 0) {
            const headerId = part.data[0];
            const media = part.data.subarray(1);
            this.mediaBytesByHeaderId.set(headerId,
              (this.mediaBytesByHeaderId.get(headerId) ?? 0) + media.length);
            const entry = this.open.get(headerId);
            if (entry) {
              entry.chunks.push(media);
            }
          }
          break;
        }
        case PART_MEDIA_END: {
          if (part.data.length > 0) {
            const headerId = part.data[0];
            this.decoded.mediaEndHeaderIds.push(headerId);
            const entry = this.open.get(headerId);
            if (entry) {
              const segmentData = concatChunks(entry.chunks);
              this.open.delete(headerId);
              this.deliverSegment(new SabrMediaSegment(entry.header, segmentData));
            }
          }
          break;
        }
        case PART_NEXT_REQUEST_POLICY: {
          const policy = decodeNextRequestPolicy(part.data);
          this.decoded.nextRequestPolicy = policy;
          if (policy.backoffTimeMs > 0) {
            this.decoded.backoffTimeMs = policy.backoffTimeMs;
          }
          break;
        }
        case PART_SABR_REDIRECT: {
          const redirect = decodeRedirect(part.data);
          this.decoded.redirectUrl = redirect.url;
          break;
        }
        case PART_SABR_ERROR: {
          this.decoded.sabrError = summarizeOpaque(part.data, 'error');
          break;
        }
        case PART_RELOAD_PLAYER_RESPONSE: {
          this.decoded.reloadRequested = true;
          this.decoded.reloadToken = decodeReloadToken(part.data);
          break;
        }
        case PART_STREAM_PROTECTION_STATUS: {
          const prot = decodeStreamProtection(part.data);
          this.decoded.streamProtectionStatus = prot.status;
          this.decoded.streamProtectionMaxRetries = prot.maxRetries;
          break;
        }
        case PART_SABR_CONTEXT_UPDATE: {
          this.decoded.sabrContextUpdates.push(decodeContextUpdate(part.data));
          break;
        }
        case PART_SABR_CONTEXT_SENDING_POLICY: {
          this.decoded.sabrContextSendingPolicy = decodeContextSendingPolicy(part.data);
          break;
        }
        case PART_FORMAT_INITIALIZATION_METADATA: {
          const meta = decodeFormatInitMeta(part.data);
          this.decoded.formatInitializationMetadata.push(meta);
          // The init metadata carries the index range the init segment's SIDX
          // parse needs, so it must reach the stream state before the init
          // segment arrives — not when the response ends.
          this.formatMetaSink?.(meta);
          break;
        }
        case PART_SABR_SEEK: {
          // Minimal handling: decode the reason for diagnostics. We do not execute the
          // server-demanded reposition (PipePipe doesn't either); the response is still
          // counted as no-media by the pump, so repeated seeks hit the existing budgets.
          this.decoded.sabrSeekReason = decodeSabrSeekReason(part.data);
          break;
        }
        default:
          if (part.type !== PART_MEDIA && part.type !== PART_MEDIA_END
            && part.type !== PART_MEDIA_HEADER) {
            // keep quiet for known optional parts
            if (part.type < 10 || part.type > 70) {
              this.decoded.unknownPartTypes.push(part.type);
            }
          }
          break;
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.warn(`[SABR-DECODE] part=${part.type} decode-failed: ${msg}`);
    }
  }

  /** Finalize the response (integrity issues) after the last part arrived. */
  finish(): SabrDecodedResponse {
    this.decoded.segmentCount = this.segmentCountValue;
    if (!this.segmentSink) {
      this.decoded.segments = this.retainedSegments;
    }
    this.decoded.integrityIssues = computeIntegrityIssues(
      this.decoded.mediaHeaders, this.mediaBytesByHeaderId, this.decoded.mediaEndHeaderIds);
    return this.decoded;
  }

  /**
   * Hand a finished segment to the consumer. A segment shorter (or longer)
   * than its header announces is withheld: the response-level integrity check
   * reports the mismatch and the session re-POSTs for a clean batch, so a
   * truncated segment never reaches the player.
   */
  private deliverSegment(segment: SabrMediaSegment): void {
    const expected = segment.header.contentLength;
    if (expected >= 0 && segment.getLength() !== expected) {
      logger.warn(`[SABR-DECODE] withhold incomplete segment itag=${segment.header.itag} `
        + `seq=${segment.header.sequenceNumber} expected=${expected} actual=${segment.getLength()}`);
      return;
    }
    this.segmentCountValue++;
    if (this.segmentSink) {
      try {
        this.segmentSink(segment);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        logger.warn(`[SABR-DECODE] segment sink failed itag=${segment.header.itag}: ${msg}`);
      }
      return;
    }
    this.retainedSegments.push(segment);
  }
}

/** PipePipe YoutubeSabrResponse.getIntegrityIssues. */
function computeIntegrityIssues(
  mediaHeaders: SabrMediaHeader[],
  mediaBytesByHeaderId: Map<number, number>,
  mediaEndHeaderIds: number[]
): string[] {
  const issues: string[] = [];
  const headerIds: number[] = [];
  for (const header of mediaHeaders) {
    if (headerIds.indexOf(header.headerId) >= 0) {
      issues.push(`duplicate-media-header:${header.headerId}`);
    }
    headerIds.push(header.headerId);
    const bytes = mediaBytesByHeaderId.get(header.headerId);
    if (bytes === undefined) {
      issues.push(`missing-media:${header.headerId}`);
    } else if (header.contentLength >= 0 && bytes !== header.contentLength) {
      issues.push(`length-mismatch:${header.headerId}:expected=${header.contentLength}:actual=${bytes}`);
    }
    if (mediaEndHeaderIds.indexOf(header.headerId) < 0) {
      issues.push(`missing-media-end:${header.headerId}`);
    }
  }
  for (const id of mediaBytesByHeaderId.keys()) {
    if (headerIds.indexOf(id) < 0) {
      issues.push(`media-without-header:${id}`);
    }
  }
  for (const id of mediaEndHeaderIds) {
    if (headerIds.indexOf(id) < 0) {
      issues.push(`media-end-without-header:${id}`);
    }
  }
  return issues;
}

/** PipePipe isRecoverableIncompleteMediaResponse. */
export function isRecoverableIntegrityIssues(issues: string[]): boolean {
  if (issues.length === 0) {
    return false;
  }
  for (const issue of issues) {
    if (!issue.startsWith('length-mismatch:')
      && !issue.startsWith('missing-media-end:')
      && !issue.startsWith('missing-media:')
      && !issue.startsWith('media-without-header:')
      && !issue.startsWith('media-end-without-header:')
      // Streaming path: the reply ended in the middle of a UMP part.
      && !issue.startsWith('truncated-ump-response:')) {
      return false;
    }
  }
  return true;
}

function concatChunks(chunks: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const c of chunks) {
    total += c.length;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.length;
  }
  return out;
}

function decodeNextRequestPolicy(data: Uint8Array): SabrNextRequestPolicy {
  const policy = new SabrNextRequestPolicy();
  for (const field of sabrReadFields(data)) {
    switch (field.number) {
      case 1:
        policy.targetAudioReadaheadMs = field.varint | 0;
        break;
      case 2:
        policy.targetVideoReadaheadMs = field.varint | 0;
        break;
      case 3:
        policy.maxTimeSinceLastRequestMs = field.varint | 0;
        break;
      case 4:
        policy.backoffTimeMs = field.varint | 0;
        break;
      case 5:
        policy.minAudioReadaheadMs = field.varint | 0;
        break;
      case 6:
        policy.minVideoReadaheadMs = field.varint | 0;
        break;
      case 7:
        if (field.wireType === WIRE_LENGTH_DELIMITED) {
          policy.playbackCookie = field.getBytes();
        }
        break;
      case 8:
        if (field.wireType === WIRE_LENGTH_DELIMITED) {
          policy.videoId = field.getString();
        }
        break;
      default:
        break;
    }
  }
  return policy;
}

function decodeRedirect(data: Uint8Array): SabrRedirectInfo {
  const redirect = new SabrRedirectInfo();
  for (const field of sabrReadFields(data)) {
    if (field.number === 1 && field.wireType === WIRE_LENGTH_DELIMITED) {
      redirect.url = field.getString();
    }
  }
  return redirect;
}

function decodeStreamProtection(data: Uint8Array): StreamProtectionResult {
  const result = new StreamProtectionResult();
  for (const field of sabrReadFields(data)) {
    if (field.number === 1 && field.wireType === WIRE_VARINT) {
      result.status = field.varint | 0;
    } else if (field.number === 2 && field.wireType === WIRE_VARINT) {
      result.maxRetries = field.varint | 0;
    }
  }
  return result;
}

/** SABR_SEEK part: field 1 = seek reason varint (-1 when absent). */
function decodeSabrSeekReason(data: Uint8Array): number {
  for (const field of sabrReadFields(data)) {
    if (field.number === 1 && field.wireType === WIRE_VARINT) {
      return field.varint | 0;
    }
  }
  return -1;
}

/**
 * RELOAD_PLAYER_RESPONSE (46): extracts
 * `ReloadPlaybackContext.reload_playback_params.token` — field 1
 * (length-delimited) → nested message → field 1 (length-delimited string).
 * PipePipe decodeReloadToken.
 */
function decodeReloadToken(data: Uint8Array): string | undefined {
  for (const field of sabrReadFields(data)) {
    if (field.number === 1 && field.wireType === WIRE_LENGTH_DELIMITED) {
      for (const inner of sabrReadFields(field.getBytes())) {
        if (inner.number === 1 && inner.wireType === WIRE_LENGTH_DELIMITED) {
          const token = inner.getString();
          return token.length > 0 ? token : undefined;
        }
      }
    }
  }
  return undefined;
}

function decodeContextUpdate(data: Uint8Array): SabrContextUpdate {
  const update = new SabrContextUpdate();
  for (const field of sabrReadFields(data)) {
    switch (field.number) {
      case 1:
        update.type = field.varint | 0;
        break;
      case 2:
        update.scope = field.varint | 0;
        break;
      case 3:
        if (field.wireType === WIRE_LENGTH_DELIMITED) {
          update.value = field.getBytes();
        }
        break;
      case 4:
        update.sendByDefault = field.varint !== 0;
        break;
      case 5:
        update.writePolicy = field.varint | 0;
        break;
      default:
        break;
    }
  }
  return update;
}

/**
 * PipePipe YoutubeSabrSession.ingestContextSendingPolicy: field 1 = activate,
 * field 2 = deactivate, field 3 = dispose. Values may be single varints or
 * packed varint lists (length-delimited).
 */
function decodeContextSendingPolicy(data: Uint8Array): SabrContextSendingPolicy {
  const policy = new SabrContextSendingPolicy();
  for (const field of sabrReadFields(data)) {
    let values: number[] = [];
    if (field.wireType === WIRE_VARINT) {
      values = [field.varint | 0];
    } else if (field.wireType === WIRE_LENGTH_DELIMITED) {
      const bytes = field.getBytes();
      let offset = 0;
      while (offset < bytes.length) {
        const parsed = readProtoVarint(bytes, offset);
        if (!parsed) {
          break;
        }
        values.push(parsed.value | 0);
        offset = parsed.next;
      }
    }
    for (const value of values) {
      if (field.number === 1) {
        policy.activateTypes.push(value);
      } else if (field.number === 2) {
        policy.deactivateTypes.push(value);
      } else if (field.number === 3) {
        policy.disposeTypes.push(value);
      }
    }
  }
  return policy;
}

function decodeFormatInitMeta(data: Uint8Array): SabrFormatInitMeta {
  const meta = new SabrFormatInitMeta();
  for (const field of sabrReadFields(data)) {
    if (field.number === 1 && field.wireType === WIRE_LENGTH_DELIMITED) {
      meta.videoId = field.getString();
    } else if (field.number === 2 && field.wireType === WIRE_LENGTH_DELIMITED) {
      // Nested FormatId. Field 1 is the video id, not this message.
      for (const inner of sabrReadFields(field.getBytes())) {
        if (inner.number === 1) {
          meta.itag = inner.varint | 0;
        } else if (inner.number === 2) {
          meta.lastModified = inner.varint;
        } else if (inner.number === 3 && inner.wireType === WIRE_LENGTH_DELIMITED) {
          meta.xtags = inner.getString();
        }
      }
    } else if (field.number === 3 && field.wireType === WIRE_VARINT) {
      meta.endTimeMs = field.varint;
    } else if (field.number === 4 && field.wireType === WIRE_VARINT) {
      meta.endSegmentNumber = field.varint | 0;
    } else if (field.number === 5 && field.wireType === WIRE_LENGTH_DELIMITED) {
      meta.mimeType = field.getString();
    } else if (field.number === 6 && field.wireType === WIRE_LENGTH_DELIMITED) {
      const range = decodeFormatByteRange(field.getBytes());
      meta.initRangeStart = range.start;
      meta.initRangeEnd = range.end;
    } else if (field.number === 7 && field.wireType === WIRE_LENGTH_DELIMITED) {
      const range = decodeFormatByteRange(field.getBytes());
      meta.indexRangeStart = range.start;
      meta.indexRangeEnd = range.end;
    } else if (field.number === 8 && field.wireType === WIRE_VARINT) {
      meta.field8 = field.varint;
    } else if (field.number === 9 && field.wireType === WIRE_VARINT) {
      meta.durationUnits = field.varint;
    } else if (field.number === 10 && field.wireType === WIRE_VARINT) {
      meta.durationTimescale = field.varint;
    }
  }
  return meta;
}

function decodeFormatByteRange(data: Uint8Array): FormatByteRange {
  const range = new FormatByteRange();
  for (const field of sabrReadFields(data)) {
    if ((field.number === 1 || field.number === 3) && field.wireType === WIRE_VARINT) {
      range.start = field.varint;
    } else if ((field.number === 2 || field.number === 4) && field.wireType === WIRE_VARINT) {
      range.end = field.varint;
    }
  }
  return range;
}

function summarizeOpaque(data: Uint8Array, label: string): string {
  try {
    const fields = sabrReadFields(data);
    const parts: string[] = [];
    for (const f of fields) {
      if (f.wireType === WIRE_VARINT) {
        parts.push(`${f.number}=${f.varint}`);
      } else {
        parts.push(`${f.number}=bytes(${f.bytes?.length ?? 0})`);
      }
    }
    return `${label}:{${parts.join(',')}}`;
  } catch (_e) {
    return `${label}:opaque(${data.length})`;
  }
}

export function requireUmpContentType(contentType: string | undefined, status: number): void {
  if (!contentType || contentType.toLowerCase().indexOf('application/vnd.yt-ump') < 0) {
    throw new SabrProtocolException(
      `Expected UMP response, got content type: ${contentType}, status=${status}`);
  }
}
