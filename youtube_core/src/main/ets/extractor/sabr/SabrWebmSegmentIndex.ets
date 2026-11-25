import { SabrSegmentIndex, SabrSegmentIndexEntry } from './SabrMp4SegmentIndex';

const SEGMENT_ID = 0x18538067;
const INFO_ID = 0x1549a966;
const TIMECODE_SCALE_ID = 0x2ad7b1;
const CUES_ID = 0x1c53bb6b;
const CUE_POINT_ID = 0xbb;
const CUE_TIME_ID = 0xb3;
const DEFAULT_TIMECODE_SCALE_NANOS = 1000000;

class EbmlElement {
  readonly id: number;
  readonly contentStart: number;
  readonly contentEnd: number;

  constructor(id: number, contentStart: number, contentEnd: number) {
    this.id = id;
    this.contentStart = contentStart;
    this.contentEnd = contentEnd;
  }
}

class EbmlVarint {
  readonly value: number;
  readonly length: number;
  readonly unknown: boolean;

  constructor(value: number, length: number, unknown: boolean) {
    this.value = value;
    this.length = length;
    this.unknown = unknown;
  }
}

function readVintLength(data: Uint8Array, offset: number, end: number): number {
  if (offset < 0 || offset >= end) {
    throw new Error('Unexpected EOF while reading WebM vint');
  }
  const first = data[offset] & 0xff;
  for (let length = 1; length <= 8; length++) {
    if ((first & (0x80 >> (length - 1))) !== 0) {
      if (offset + length > end) {
        throw new Error('Truncated WebM vint');
      }
      return length;
    }
  }
  throw new Error('Invalid WebM vint');
}

function readElementId(data: Uint8Array, offset: number, end: number): EbmlVarint {
  const length = readVintLength(data, offset, end);
  let value = 0;
  for (let i = 0; i < length; i++) {
    value = value * 256 + (data[offset + i] & 0xff);
  }
  return new EbmlVarint(value, length, false);
}

function readElementSize(data: Uint8Array, offset: number, end: number): EbmlVarint {
  const length = readVintLength(data, offset, end);
  const firstMask = 0xff >> length;
  let value = data[offset] & firstMask;
  let allOnes = value === firstMask;
  for (let i = 1; i < length; i++) {
    const b = data[offset + i] & 0xff;
    if (b !== 0xff) {
      allOnes = false;
    }
    value = value * 256 + b;
  }
  return new EbmlVarint(value, length, allOnes);
}

function readElement(data: Uint8Array, offset: number, containerEnd: number): EbmlElement {
  const id = readElementId(data, offset, containerEnd);
  const size = readElementSize(data, offset + id.length, containerEnd);
  const contentStart = offset + id.length + size.length;
  let contentEnd: number;
  if (size.unknown || !Number.isSafeInteger(size.value) || contentStart + size.value > containerEnd) {
    // PipePipe SabrWebmSegmentIndexParser: Segment (master) in a DASH/SABR init declares its
    // full media size way past the init buffer we actually have. Clamp to containerEnd so
    // VP9/Opus WebM tracks (e.g. itag 313 / 303 / 248 / 251) parse their exact Cues index
    // instead of falling back to uniform-duration tiling (which drifts & stalls on seek).
    contentEnd = containerEnd;
  } else {
    contentEnd = contentStart + size.value;
  }
  return new EbmlElement(id.value, contentStart, contentEnd);
}

function findElement(data: Uint8Array, start: number, end: number, targetId: number): EbmlElement {
  let offset = start;
  while (offset < end) {
    const element = readElement(data, offset, end);
    if (element.id === targetId) {
      return element;
    }
    if (element.contentEnd <= offset) {
      break;
    }
    offset = element.contentEnd;
  }
  throw new Error(`WebM element not found: 0x${targetId.toString(16)}`);
}

function readUnsignedInteger(data: Uint8Array, offset: number, length: number): number {
  if (length <= 0 || length > 8 || offset < 0 || offset + length > data.length) {
    throw new Error('Invalid WebM unsigned integer length');
  }
  let value = 0;
  for (let i = 0; i < length; i++) {
    value = value * 256 + (data[offset + i] & 0xff);
  }
  return value;
}

function readTimecodeScale(data: Uint8Array, segment: EbmlElement): number {
  const info = findElement(data, segment.contentStart, segment.contentEnd, INFO_ID);
  let offset = info.contentStart;
  while (offset < info.contentEnd) {
    const element = readElement(data, offset, info.contentEnd);
    if (element.id === TIMECODE_SCALE_ID) {
      return readUnsignedInteger(data, element.contentStart, element.contentEnd - element.contentStart);
    }
    if (element.contentEnd <= offset) {
      break;
    }
    offset = element.contentEnd;
  }
  return DEFAULT_TIMECODE_SCALE_NANOS;
}

function readCueTime(data: Uint8Array, cuePoint: EbmlElement): number {
  let offset = cuePoint.contentStart;
  while (offset < cuePoint.contentEnd) {
    const element = readElement(data, offset, cuePoint.contentEnd);
    if (element.id === CUE_TIME_ID) {
      return readUnsignedInteger(data, element.contentStart, element.contentEnd - element.contentStart);
    }
    if (element.contentEnd <= offset) {
      break;
    }
    offset = element.contentEnd;
  }
  return -1;
}

function scaleWebmTimeToMs(cueTime: number, timecodeScaleNanos: number): number {
  return Math.floor((cueTime * timecodeScaleNanos + 500000) / 1000000);
}

function readCueTimes(data: Uint8Array, cues: EbmlElement, timecodeScaleNanos: number): number[] {
  const cueTimes: number[] = [];
  let offset = cues.contentStart;
  while (offset < cues.contentEnd) {
    const cuePoint = readElement(data, offset, cues.contentEnd);
    if (cuePoint.id === CUE_POINT_ID) {
      const cueTime = readCueTime(data, cuePoint);
      if (cueTime >= 0) {
        cueTimes.push(scaleWebmTimeToMs(cueTime, timecodeScaleNanos));
      }
    }
    if (cuePoint.contentEnd <= offset) {
      break;
    }
    offset = cuePoint.contentEnd;
  }
  return cueTimes;
}

/**
 * Port of PipePipe SabrWebmSegmentIndexParser: parses EBML Segment/Info/Cues from a SABR
 * WebM initialization segment (VP9 / Opus) into exact 1-based segment timestamps.
 */
export function parseWebmSegmentIndex(
  data: Uint8Array,
  indexStart: number = -1,
  indexEnd: number = -1,
  totalDurationMs: number = -1
): SabrSegmentIndex {
  const segment = findElement(data, 0, data.length, SEGMENT_ID);
  const timecodeScaleNanos = readTimecodeScale(data, segment);

  let cues: EbmlElement | undefined = undefined;
  if (indexStart >= 0 && indexEnd >= indexStart && indexEnd < data.length) {
    try {
      cues = findElement(data, indexStart, indexEnd + 1, CUES_ID);
    } catch (_) {
      // Some responses report offsets relative to the full stream while the UMP init payload
      // is sliced differently; fall through to scanning the Segment container.
    }
  }
  if (!cues) {
    cues = findElement(data, segment.contentStart, segment.contentEnd, CUES_ID);
  }

  const cueTimes = readCueTimes(data, cues, timecodeScaleNanos);
  if (cueTimes.length === 0) {
    throw new Error('WebM cues contain no cue times');
  }

  const entries: SabrSegmentIndexEntry[] = [];
  for (let i = 0; i < cueTimes.length; i++) {
    const startMs = cueTimes[i];
    let endMs: number;
    if (i + 1 < cueTimes.length) {
      endMs = cueTimes[i + 1];
    } else if (totalDurationMs > startMs) {
      endMs = totalDurationMs;
    } else if (i > 0) {
      endMs = startMs + Math.max(1, startMs - cueTimes[i - 1]);
    } else {
      endMs = startMs + 1;
    }
    entries.push(new SabrSegmentIndexEntry(i + 1, startMs, Math.max(1, endMs - startMs)));
  }
  return new SabrSegmentIndex(entries);
}
