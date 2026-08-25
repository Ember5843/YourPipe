/**
 * Shared protobuf / base64 primitives (non-throwing core).
 * Used by the SABR protocol layer (sabr/SabrProto.ets wraps failures in
 * SabrProtocolException) and by YouTubeExtractor's xtags/audio-track parsing
 * (undefined on malformed input).
 */
import { util } from '@kit.ArkTS';

export interface ProtoVarintResult {
  value: number;
  next: number;
}

/**
 * Read a protobuf varint at `offset`. Returns undefined on truncation or
 * over-long encoding. Accumulates via multiplication so values above 2^32
 * (e.g. lastModified) are not truncated by 32-bit shifts; precision is exact
 * up to 2^53, which covers every field both callers parse.
 */
export function readProtoVarint(bytes: Uint8Array, offset: number): ProtoVarintResult | undefined {
  let result = 0;
  let shift = 0;
  let pos = offset;
  while (pos < bytes.length && shift < 64) {
    const b = bytes[pos++];
    result += (b & 0x7f) * Math.pow(2, shift);
    if ((b & 0x80) === 0) {
      const out: ProtoVarintResult = { value: result, next: pos };
      return out;
    }
    shift += 7;
  }
  return undefined;
}

/**
 * Base64 / base64url decode (padding optional, whitespace-tolerant at edges).
 * Returns undefined for empty input or when decoding fails — never throws.
 */
export function decodeBase64ToBytes(value: string): Uint8Array | undefined {
  const raw = (value || '').trim();
  if (raw.length === 0) {
    return undefined;
  }
  const padLen = (4 - (raw.length % 4)) % 4;
  const normalized = (raw + '='.repeat(padLen)).replace(/-/g, '+').replace(/_/g, '/');
  try {
    const bytes = new util.Base64Helper().decodeSync(normalized);
    return bytes.length === 0 ? undefined : bytes;
  } catch (ignored) {
    return undefined;
  }
}
