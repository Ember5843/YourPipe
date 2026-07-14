import { SabrProtocolException } from './SabrProtocolException';
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
 * MVP: whole-body path (acceptable for lower resolutions; stream later for 4K).
 */
export function sabrDecodeBody(data: Uint8Array): SabrDecodedResponse {
  const parts = umpReadAll(data);
  return sabrDecodeParts(parts);
}

export function sabrDecodeParts(parts: UmpPart[]): SabrDecodedResponse {
  const decoded = new SabrDecodedResponse();
  const open = new Map<number, OpenMediaAssembly>();

  for (const part of parts) {
    try {
      switch (part.type) {
        case PART_MEDIA_HEADER: {
          const header = SabrMediaHeader.decode(part.data);
          decoded.mediaHeaders.push(header);
          open.set(header.headerId, new OpenMediaAssembly(header));
          break;
        }
        case PART_MEDIA: {
          if (part.data.length > 0) {
            const headerId = part.data[0];
            const media = part.data.subarray(1);
            const entry = open.get(headerId);
            if (entry) {
              entry.chunks.push(media);
            }
            const prev = decoded.mediaBytesByHeaderId.get(headerId) ?? 0;
            decoded.mediaBytesByHeaderId.set(headerId, prev + media.length);
          }
          break;
        }
        case PART_MEDIA_END: {
          if (part.data.length > 0) {
            const headerId = part.data[0];
            decoded.mediaEndHeaderIds.push(headerId);
            const entry = open.get(headerId);
            if (entry) {
              const segmentData = concatChunks(entry.chunks);
              decoded.segments.push(new SabrMediaSegment(entry.header, segmentData));
              open.delete(headerId);
            }
          }
          break;
        }
        case PART_NEXT_REQUEST_POLICY: {
          const policy = decodeNextRequestPolicy(part.data);
          decoded.nextRequestPolicy = policy;
          if (policy.backoffTimeMs > 0) {
            decoded.backoffTimeMs = policy.backoffTimeMs;
          }
          break;
        }
        case PART_SABR_REDIRECT: {
          const redirect = decodeRedirect(part.data);
          decoded.redirectUrl = redirect.url;
          break;
        }
        case PART_SABR_ERROR: {
          decoded.sabrError = summarizeOpaque(part.data, 'error');
          break;
        }
        case PART_RELOAD_PLAYER_RESPONSE: {
          decoded.reloadRequested = true;
          break;
        }
        case PART_STREAM_PROTECTION_STATUS: {
          const prot = decodeStreamProtection(part.data);
          decoded.streamProtectionStatus = prot.status;
          decoded.streamProtectionMaxRetries = prot.maxRetries;
          break;
        }
        case PART_SABR_CONTEXT_UPDATE: {
          decoded.sabrContextUpdates.push(decodeContextUpdate(part.data));
          break;
        }
        case PART_SABR_CONTEXT_SENDING_POLICY: {
          decoded.sabrContextSendingPolicy = decodeContextSendingPolicy(part.data);
          break;
        }
        case PART_FORMAT_INITIALIZATION_METADATA: {
          decoded.formatInitializationMetadata.push(decodeFormatInitMeta(part.data));
          break;
        }
        case PART_SABR_SEEK:
        default:
          if (part.type !== PART_MEDIA && part.type !== PART_MEDIA_END
            && part.type !== PART_MEDIA_HEADER) {
            // keep quiet for known optional parts
            if (part.type < 10 || part.type > 70) {
              decoded.unknownPartTypes.push(part.type);
            }
          }
          break;
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      decoded.integrityIssues.push(`part=${part.type} decode-failed: ${msg}`);
    }
  }
  return decoded;
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

function decodeContextSendingPolicy(data: Uint8Array): SabrContextSendingPolicy {
  const policy = new SabrContextSendingPolicy();
  for (const field of sabrReadFields(data)) {
    if (field.number === 1) {
      policy.startTimeMs = field.varint;
    } else if (field.number === 2) {
      policy.durationMs = field.varint;
    } else if (field.number === 3) {
      policy.types.push(field.varint | 0);
    } else if (field.number === 4) {
      policy.disposeTypes.push(field.varint | 0);
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
