export interface YoutubeDashSegment {
  sequence: number;
  start: number;
  end: number;
  startMs: number;
  durationMs: number;
}

function u16(data: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 2 > data.length) throw new Error('SIDX u16 out of range');
  return data[offset] * 0x100 + data[offset + 1];
}

function u32(data: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 4 > data.length) throw new Error('SIDX u32 out of range');
  return data[offset] * 0x1000000 + data[offset + 1] * 0x10000 + data[offset + 2] * 0x100 + data[offset + 3];
}

function u64(data: Uint8Array, offset: number): number {
  const value = u32(data, offset) * 0x100000000 + u32(data, offset + 4);
  if (!Number.isSafeInteger(value)) throw new Error('SIDX u64 exceeds safe integer range');
  return value;
}

function findSidx(data: Uint8Array): number {
  for (let offset = 0; offset + 8 <= data.length; offset++) {
    if (data[offset + 4] === 0x73 && data[offset + 5] === 0x69
      && data[offset + 6] === 0x64 && data[offset + 7] === 0x78) return offset;
  }
  throw new Error('SIDX box not found');
}

export function parseYoutubeDashIndex(data: Uint8Array, absoluteRangeStart: number): YoutubeDashSegment[] {
  const sidx = findSidx(data);
  const size = u32(data, sidx);
  if (size < 8 || sidx + size > data.length) throw new Error('Invalid SIDX size');
  let cursor = sidx + 8;
  const version = data[cursor];
  cursor += 8; // version/flags + reference ID
  const timescale = u32(data, cursor);
  cursor += 4;
  if (timescale <= 0) throw new Error('Invalid SIDX timescale');
  let presentation = 0;
  let firstOffset = 0;
  if (version === 0) {
    presentation = u32(data, cursor);
    firstOffset = u32(data, cursor + 4);
    cursor += 8;
  } else if (version === 1) {
    presentation = u64(data, cursor);
    firstOffset = u64(data, cursor + 8);
    cursor += 16;
  } else {
    throw new Error(`Unsupported SIDX version ${version}`);
  }
  cursor += 2;
  const count = u16(data, cursor);
  cursor += 2;
  let byteStart = absoluteRangeStart + sidx + size + firstOffset;
  const result: YoutubeDashSegment[] = [];
  for (let i = 0; i < count; i++) {
    const reference = u32(data, cursor);
    const duration = u32(data, cursor + 4);
    cursor += 12;
    if (reference >= 0x80000000) throw new Error('Nested SIDX is unsupported');
    const referencedSize = reference & 0x7fffffff;
    if (referencedSize <= 0) throw new Error('Empty SIDX reference');
    result.push({
      sequence: i + 1,
      start: byteStart,
      end: byteStart + referencedSize - 1,
      startMs: Math.floor(presentation * 1000 / timescale),
      durationMs: Math.max(1, Math.floor(duration * 1000 / timescale)),
    });
    byteStart += referencedSize;
    presentation += duration;
  }
  if (result.length === 0) throw new Error('SIDX has no media references');
  return result;
}
