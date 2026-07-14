import { SabrProtocolException } from './SabrProtocolException';
import { sabrReadFields, WIRE_LENGTH_DELIMITED, WIRE_VARINT } from './SabrProto';

export class SabrMediaHeader {
  headerId: number = -1;
  videoId?: string;
  itag: number = -1;
  lastModified: number = -1;
  xtags?: string;
  startRange: number = -1;
  compressionAlgorithm: number = -1;
  initSegment: boolean = false;
  sequenceNumber: number = -1;
  bitrateBps: number = -1;
  startMs: number = -1;
  durationMs: number = -1;
  contentLength: number = -1;
  timeRangeStartTicks: number = -1;
  timeRangeDurationTicks: number = -1;
  timeRangeTimescale: number = -1;
  sequenceLastModified: number = -1;

  static decode(data: Uint8Array): SabrMediaHeader {
    const header = new SabrMediaHeader();
    for (const field of sabrReadFields(data)) {
      switch (field.number) {
        case 1:
          header.headerId = field.varint | 0;
          break;
        case 2:
          if (field.wireType === WIRE_LENGTH_DELIMITED) {
            header.videoId = field.getString();
          }
          break;
        case 3:
          header.itag = field.varint | 0;
          break;
        case 4:
          header.lastModified = field.varint;
          break;
        case 5:
          if (field.wireType === WIRE_LENGTH_DELIMITED) {
            header.xtags = field.getString();
          }
          break;
        case 6:
          header.startRange = field.varint;
          break;
        case 7:
          header.compressionAlgorithm = field.varint | 0;
          break;
        case 8:
          header.initSegment = field.varint !== 0;
          break;
        case 9:
          header.sequenceNumber = field.varint | 0;
          break;
        case 10:
          header.bitrateBps = field.varint;
          break;
        case 11:
          header.startMs = field.varint;
          break;
        case 12:
          header.durationMs = field.varint;
          break;
        case 13:
          if (field.wireType === WIRE_LENGTH_DELIMITED) {
            const formatId = decodeFormatId(field.getBytes());
            if (header.itag < 0) {
              header.itag = formatId.itag;
            }
            if (header.lastModified < 0) {
              header.lastModified = formatId.lastModified;
            }
            if (!header.xtags) {
              header.xtags = formatId.xtags;
            }
          }
          break;
        case 14:
          header.contentLength = field.varint;
          break;
        case 15:
          if (field.wireType === WIRE_LENGTH_DELIMITED) {
            const tr = decodeTimeRange(field.getBytes());
            header.timeRangeStartTicks = tr.startTicks;
            header.timeRangeDurationTicks = tr.durationTicks;
            header.timeRangeTimescale = tr.timescale;
          }
          break;
        case 16:
          header.sequenceLastModified = field.varint;
          break;
        default:
          break;
      }
    }
    if (header.timeRangeTimescale > 0) {
      if (header.startMs < 0 && header.timeRangeStartTicks >= 0) {
        header.startMs = Math.floor(header.timeRangeStartTicks * 1000 / header.timeRangeTimescale);
      }
      if (header.durationMs < 0 && header.timeRangeDurationTicks >= 0) {
        header.durationMs =
          Math.floor(header.timeRangeDurationTicks * 1000 / header.timeRangeTimescale);
      }
    }
    if (header.headerId < 0) {
      throw new SabrProtocolException('MEDIA_HEADER missing headerId');
    }
    return header;
  }

  summarize(): string {
    return `headerId=${this.headerId} itag=${this.itag} init=${this.initSegment} `
      + `seq=${this.sequenceNumber} startMs=${this.startMs} durMs=${this.durationMs} `
      + `len=${this.contentLength}`;
  }
}

class FormatId {
  itag: number = -1;
  lastModified: number = -1;
  xtags?: string;
}

class TimeRange {
  startTicks: number = -1;
  durationTicks: number = -1;
  timescale: number = -1;
}

function decodeFormatId(data: Uint8Array): FormatId {
  const out = new FormatId();
  for (const field of sabrReadFields(data)) {
    if (field.number === 1 && field.wireType === WIRE_VARINT) {
      out.itag = field.varint | 0;
    } else if (field.number === 2 && field.wireType === WIRE_VARINT) {
      out.lastModified = field.varint;
    } else if (field.number === 3 && field.wireType === WIRE_LENGTH_DELIMITED) {
      out.xtags = field.getString();
    }
  }
  return out;
}

function decodeTimeRange(data: Uint8Array): TimeRange {
  const out = new TimeRange();
  for (const field of sabrReadFields(data)) {
    if (field.number === 1) {
      out.startTicks = field.varint;
    } else if (field.number === 2) {
      out.durationTicks = field.varint;
    } else if (field.number === 3) {
      out.timescale = field.varint | 0;
    }
  }
  return out;
}
