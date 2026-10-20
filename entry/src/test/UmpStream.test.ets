import { describe, it, expect } from '@ohos/hypium';
import { UmpStreamReader, umpReadAll, UmpPart } from 'youtube_core';

interface UmpTestPart {
  type: number;
  payload: number[];
}

/**
 * UMP varint encoder — the inverse of the reader's format
 * (youtube_core UmpReader.UmpCursor.readUmpInt). The first byte alone
 * determines the encoded length, and the value bits are split as:
 *   1 byte : value
 *   2 bytes: (value & 0x3f) | 0x80 , value >> 6
 *   3 bytes: (value & 0x1f) | 0xC0 , (value >> 5) & 0xFF , value >> 13
 *   4 bytes: (value & 0x0f) | 0xE0 , (value >> 4) & 0xFF , (value >> 12) & 0xFF , (value >> 20) & 0xFF
 *   5 bytes: 0xF0 , value & 0xFF , (value >> 8) & 0xFF , (value >> 16) & 0xFF , (value >> 24) & 0xFF
 */
function encodeUmpInt(value: number): number[] {
  if (value < 0) {
    throw new Error('negative ump int');
  }
  const out: number[] = [];
  if (value < 128) {
    out.push(value);
  } else if (value < 16384) {
    out.push(0x80 | (value & 0x3f), (value >> 6) & 0xff);
  } else if (value < 2097152) {
    out.push(0xc0 | (value & 0x1f), (value >> 5) & 0xff, (value >> 13) & 0xff);
  } else if (value < 268435456) {
    out.push(0xe0 | (value & 0x0f), (value >> 4) & 0xff, (value >> 12) & 0xff, (value >> 20) & 0xff);
  } else {
    out.push(0xf0, value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff);
  }
  return out;
}

function buildEnvelope(parts: UmpTestPart[]): number[] {
  const out: number[] = [];
  for (const part of parts) {
    // Appended one by one: a spread would blow the call stack on big payloads.
    for (const b of encodeUmpInt(part.type)) {
      out.push(b);
    }
    for (const b of encodeUmpInt(part.payload.length)) {
      out.push(b);
    }
    for (const b of part.payload) {
      out.push(b);
    }
  }
  return out;
}

function bytesOf(values: number[]): Uint8Array {
  const out: Uint8Array = new Uint8Array(values.length);
  for (let i = 0; i < values.length; i++) {
    out[i] = values[i] & 0xff;
  }
  return out;
}

function describeParts(parts: UmpPart[]): string {
  const parts2: string[] = [];
  for (const p of parts) {
    parts2.push(`${p.type}:${p.size}`);
  }
  return parts2.join(',');
}

function drain(reader: UmpStreamReader): UmpPart[] {
  const parts: UmpPart[] = [];
  let part: UmpPart | undefined = reader.nextPart();
  while (part !== undefined) {
    parts.push(part);
    part = reader.nextPart();
  }
  return parts;
}

export default function umpStreamTest() {
  describe('umpStreamTest', () => {
    it('wholeEnvelopeMatchesBufferedReader', 0, () => {
      const parts: UmpTestPart[] = [
        { type: 20, payload: [1, 2, 3] },
        { type: 21, payload: [9, 8, 7, 6, 5] },
        { type: 22, payload: [4] }
      ];
      const body: Uint8Array = bytesOf(buildEnvelope(parts));
      const buffered: UmpPart[] = umpReadAll(body);
      expect(buffered.length).assertEqual(3);
      expect(describeParts(buffered)).assertEqual('20:3,21:5,22:1');
    });

    it('streamsWholeEnvelopeInOneChunk', 0, () => {
      const parts: UmpTestPart[] = [
        { type: 20, payload: [1, 2, 3] },
        { type: 21, payload: [9, 8, 7] }
      ];
      const body: Uint8Array = bytesOf(buildEnvelope(parts));
      const reader: UmpStreamReader = new UmpStreamReader();
      reader.push(body);
      const streamed: UmpPart[] = drain(reader);
      expect(streamed.length).assertEqual(2);
      expect(describeParts(streamed)).assertEqual('20:3,21:3');
      expect(reader.pendingBytes()).assertEqual(0);
    });

    it('streamsEnvelopeSplitAtEveryByteBoundary', 0, () => {
      const parts: UmpTestPart[] = [
        { type: 20, payload: [1, 2, 3, 4, 5] },
        { type: 35, payload: [7] },
        { type: 21, payload: [8, 9, 10, 11, 12, 13, 14] }
      ];
      const body: Uint8Array = bytesOf(buildEnvelope(parts));
      // Byte-at-a-time: every header and every payload boundary is split.
      const reader: UmpStreamReader = new UmpStreamReader();
      const streamed: UmpPart[] = [];
      for (let i = 0; i < body.length; i++) {
        reader.push(body.subarray(i, i + 1));
        for (const part of drain(reader)) {
          streamed.push(part);
        }
      }
      expect(streamed.length).assertEqual(3);
      expect(describeParts(streamed)).assertEqual('20:5,35:1,21:7');
      expect(reader.pendingBytes()).assertEqual(0);
    });

    it('streamsEnvelopeWithRandomChunkSizes', 0, () => {
      const payload: number[] = [];
      for (let i = 0; i < 300; i++) {
        payload.push(i & 0xff);
      }
      const parts: UmpTestPart[] = [
        { type: 21, payload: payload },
        { type: 22, payload: [5] }
      ];
      const body: Uint8Array = bytesOf(buildEnvelope(parts));
      const reader: UmpStreamReader = new UmpStreamReader();
      const streamed: UmpPart[] = [];
      let offset: number = 0;
      let size: number = 1;
      while (offset < body.length) {
        const end: number = Math.min(body.length, offset + size);
        reader.push(body.subarray(offset, end));
        offset = end;
        size = (size * 7 + 13) % 97 + 1;
        for (const part of drain(reader)) {
          streamed.push(part);
        }
      }
      expect(streamed.length).assertEqual(2);
      expect(describeParts(streamed)).assertEqual('21:300,22:1');
      // The payload must survive the split byte-for-byte.
      let sum: number = 0;
      let expected: number = 0;
      for (let i = 0; i < 300; i++) {
        expected = (expected + (i & 0xff)) & 0xffff;
      }
      for (const b of streamed[0].data) {
        sum = (sum + b) & 0xffff;
      }
      expect(sum).assertEqual(expected);
    });

    it('keepsPartialPartPending', 0, () => {
      const parts: UmpTestPart[] = [
        { type: 20, payload: [1, 2, 3, 4] }
      ];
      const body: Uint8Array = bytesOf(buildEnvelope(parts));
      const reader: UmpStreamReader = new UmpStreamReader();
      // Only the header plus two payload bytes.
      reader.push(body.subarray(0, 4));
      expect(reader.nextPart() === undefined).assertTrue();
      expect(reader.pendingBytes()).assertEqual(4);
      reader.push(body.subarray(4));
      const part: UmpPart | undefined = reader.nextPart();
      expect(part !== undefined).assertTrue();
      expect(describeParts([part as UmpPart])).assertEqual('20:4');
      expect(reader.pendingBytes()).assertEqual(0);
    });

    it('reportsTrailingBytesForTruncatedResponse', 0, () => {
      const parts: UmpTestPart[] = [
        { type: 20, payload: [1, 2, 3, 4] }
      ];
      const body: Uint8Array = bytesOf(buildEnvelope(parts));
      const reader: UmpStreamReader = new UmpStreamReader();
      reader.push(body.subarray(0, 5));
      expect(reader.nextPart() === undefined).assertTrue();
      expect(reader.pendingBytes()).assertEqual(5);
    });

    it('streamsPayloadLargerThanTheInitialBuffer', 0, () => {
      // 64 KB payload: forces the reader's growth path (initial capacity 4096).
      const payload: number[] = [];
      for (let i = 0; i < 65536; i++) {
        payload.push(i & 0xff);
      }
      const parts: UmpTestPart[] = [
        { type: 21, payload: payload },
        { type: 22, payload: [5] }
      ];
      const body: Uint8Array = bytesOf(buildEnvelope(parts));
      const reader: UmpStreamReader = new UmpStreamReader();
      const streamed: UmpPart[] = [];
      let offset: number = 0;
      let size: number = 7777;
      while (offset < body.length) {
        const end: number = Math.min(body.length, offset + size);
        reader.push(body.subarray(offset, end));
        offset = end;
        size = (size * 7 + 13) % 97 + 1;
        for (const part of drain(reader)) {
          streamed.push(part);
        }
      }
      expect(streamed.length).assertEqual(2);
      expect(describeParts(streamed)).assertEqual('21:65536,22:1');
      expect(reader.pendingBytes()).assertEqual(0);
      let mismatch: number = 0;
      for (let i = 0; i < 65536; i++) {
        if (streamed[0].data[i] !== (i & 0xff)) {
          mismatch++;
        }
      }
      expect(mismatch).assertEqual(0);
    });
  });
}
