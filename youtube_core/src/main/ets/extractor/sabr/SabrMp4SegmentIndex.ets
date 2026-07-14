export class SabrSegmentIndexEntry {
  sequenceNumber: number;
  startMs: number;
  durationMs: number;

  constructor(sequenceNumber: number, startMs: number, durationMs: number) {
    this.sequenceNumber = sequenceNumber;
    this.startMs = startMs;
    this.durationMs = durationMs;
  }

  getEndMs(): number {
    return this.startMs + this.durationMs;
  }
}

export class SabrSegmentIndex {
  private entries: SabrSegmentIndexEntry[];

  constructor(entries: SabrSegmentIndexEntry[]) {
    this.entries = entries;
  }

  getEntry(sequenceNumber: number): SabrSegmentIndexEntry | undefined {
    if (sequenceNumber <= 0 || sequenceNumber > this.entries.length) {
      return undefined;
    }
    return this.entries[sequenceNumber - 1];
  }

  size(): number {
    return this.entries.length;
  }
}

function requireBytes(data: Uint8Array, offset: number, length: number): void {
  if (offset < 0 || length < 0 || offset + length > data.length) {
    throw new Error('Unexpected EOF while reading MP4 SIDX');
  }
}

function readUint16(data: Uint8Array, offset: number): number {
  requireBytes(data, offset, 2);
  return data[offset] * 0x100 + data[offset + 1];
}

function readUint32(data: Uint8Array, offset: number): number {
  requireBytes(data, offset, 4);
  return data[offset] * 0x1000000 + data[offset + 1] * 0x10000
    + data[offset + 2] * 0x100 + data[offset + 3];
}

function readUint64(data: Uint8Array, offset: number): number {
  const value = readUint32(data, offset) * 0x100000000 + readUint32(data, offset + 4);
  if (!Number.isSafeInteger(value)) {
    throw new Error('MP4 SIDX uint64 exceeds safe integer range');
  }
  return value;
}

function scaleToMs(value: number, timescale: number): number {
  return Math.floor((value * 1000 + timescale / 2) / timescale);
}

function findSidx(data: Uint8Array, start: number, endExclusive: number): number {
  const first = Math.max(0, start);
  const end = Math.min(data.length, endExclusive);
  for (let offset = first; offset + 8 <= end; offset++) {
    if (data[offset + 4] === 0x73 && data[offset + 5] === 0x69
      && data[offset + 6] === 0x64 && data[offset + 7] === 0x78) {
      return offset;
    }
  }
  throw new Error('MP4 SIDX box not found');
}

function parseAt(data: Uint8Array, sidxOffset: number, rangeEnd: number): SabrSegmentIndex {
  const boxSize = readUint32(data, sidxOffset);
  const boxEnd = sidxOffset + boxSize;
  if (boxSize < 8 || boxEnd > rangeEnd || boxEnd > data.length) {
    throw new Error('Invalid MP4 SIDX box size');
  }
  let cursor = sidxOffset + 8;
  requireBytes(data, cursor, 4);
  const version = data[cursor];
  cursor += 4; // version + flags
  cursor += 4; // reference_ID
  const timescale = readUint32(data, cursor);
  cursor += 4;
  if (timescale <= 0) {
    throw new Error('Invalid MP4 SIDX timescale');
  }

  let earliestPresentationTime = 0;
  if (version === 0) {
    earliestPresentationTime = readUint32(data, cursor);
    cursor += 8; // earliest_presentation_time + first_offset
  } else if (version === 1) {
    earliestPresentationTime = readUint64(data, cursor);
    cursor += 16; // earliest_presentation_time + first_offset
  } else {
    throw new Error(`Unsupported MP4 SIDX version: ${version}`);
  }

  cursor += 2; // reserved
  const referenceCount = readUint16(data, cursor);
  cursor += 2;
  const entries: SabrSegmentIndexEntry[] = [];
  let unscaledStart = earliestPresentationTime;
  for (let i = 0; i < referenceCount; i++) {
    requireBytes(data, cursor, 12);
    const reference = readUint32(data, cursor);
    cursor += 4;
    if (reference >= 0x80000000) {
      throw new Error('Nested MP4 SIDX references are unsupported');
    }
    const duration = readUint32(data, cursor);
    cursor += 8; // duration + SAP flags
    entries.push(new SabrSegmentIndexEntry(i + 1,
      scaleToMs(unscaledStart, timescale), Math.max(1, scaleToMs(duration, timescale))));
    unscaledStart += duration;
  }
  return new SabrSegmentIndex(entries);
}

export function parseMp4SegmentIndex(data: Uint8Array, indexStart: number = -1,
  indexEnd: number = -1): SabrSegmentIndex {
  if (indexStart >= 0 && indexEnd >= indexStart && indexEnd < data.length) {
    try {
      const offset = findSidx(data, indexStart, indexEnd + 1);
      return parseAt(data, offset, indexEnd + 1);
    } catch (_) {
      // Some responses report ranges relative to the original resource while the UMP init
      // payload has already been sliced. Fall through to scanning the complete init payload.
    }
  }
  const offset = findSidx(data, 0, data.length);
  return parseAt(data, offset, data.length);
}
