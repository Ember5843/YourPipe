import { parseLastModified, sabrFormatIdBytes, SabrProtoWriter } from './SabrProto';
import { YoutubeSabrFormatMeta } from './YoutubeSabrInfo';

const MAX_INT32 = 2147483647;

export class SabrBufferedRange {
  itag: number;
  lastModified: number;
  xtags?: string;
  startTimeMs: number;
  durationMs: number;
  startSegmentIndex: number;
  endSegmentIndex: number;
  timescale: number;

  constructor(
    itag: number,
    lastModified: number,
    xtags: string | undefined,
    startTimeMs: number,
    durationMs: number,
    startSegmentIndex: number,
    endSegmentIndex: number,
    timescale: number
  ) {
    this.itag = itag;
    this.lastModified = lastModified;
    this.xtags = xtags;
    this.startTimeMs = startTimeMs;
    this.durationMs = durationMs;
    this.startSegmentIndex = startSegmentIndex;
    this.endSegmentIndex = endSegmentIndex;
    this.timescale = timescale;
  }

  static full(format: YoutubeSabrFormatMeta): SabrBufferedRange {
    return new SabrBufferedRange(
      format.itag,
      parseLastModified(format.lastModified),
      format.xtags,
      0,
      MAX_INT32,
      MAX_INT32,
      MAX_INT32,
      1000
    );
  }

  static fromProgress(
    format: YoutubeSabrFormatMeta,
    startTimeMs: number,
    durationMs: number,
    startSegmentIndex: number,
    endSegmentIndex: number
  ): SabrBufferedRange {
    return new SabrBufferedRange(
      format.itag,
      parseLastModified(format.lastModified),
      format.xtags,
      startTimeMs,
      durationMs,
      startSegmentIndex,
      endSegmentIndex,
      1000
    );
  }

  toProto(includeTimeRange: boolean = true): Uint8Array {
    const range = new SabrProtoWriter();
    range.writeMessage(1, this.formatIdProto());
    range.writeUInt64(2, this.startTimeMs);
    range.writeUInt64(3, this.durationMs);
    range.writeInt32(4, this.startSegmentIndex);
    range.writeInt32(5, this.endSegmentIndex);
    if (includeTimeRange) {
      range.writeMessage(6, this.timeRangeProto());
    }
    return range.toUint8Array();
  }

  private formatIdProto(): Uint8Array {
    const meta: YoutubeSabrFormatMeta = {
      itag: this.itag,
      lastModified: String(this.lastModified),
      xtags: this.xtags,
      isAudio: false,
      isVideo: false
    };
    return sabrFormatIdBytes(meta);
  }

  private timeRangeProto(): Uint8Array {
    const timeRange = new SabrProtoWriter();
    timeRange.writeUInt64(1, this.startTimeMs);
    timeRange.writeUInt64(2, this.durationMs);
    timeRange.writeInt32(3, this.timescale);
    return timeRange.toUint8Array();
  }
}
