import { util } from '@kit.ArkTS';

/**
 * Shared UTF-8 encoder for the loopback proxy. TextEncoder.encode() is
 * stateless, so one module-level instance replaces the four per-file copies
 * that allocated a new encoder on every header/body write.
 */
const sharedEncoder: util.TextEncoder = new util.TextEncoder();

/** Encode a string to a standalone ArrayBuffer (HTTP status line + headers). */
export function encodeUtf8(text: string): ArrayBuffer {
  return sharedEncoder.encode(text).buffer as ArrayBuffer;
}

/** Encode a string to a Uint8Array (text response bodies from @ohos.net.http). */
export function encodeUtf8Bytes(text: string): Uint8Array {
  return sharedEncoder.encode(text);
}
