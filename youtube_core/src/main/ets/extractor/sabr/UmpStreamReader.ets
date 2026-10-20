import { SabrProtocolException } from './SabrProtocolException';
import { UmpPart } from './UmpReader';

interface PeekedVarint {
  value: number;
  next: number;
}

/**
 * Incremental UMP envelope reader (PipePipe `UmpReader.readPayloadsUntil` parity).
 *
 * <p>Chunks are pushed in arrival order and complete parts are pulled out one
 * at a time. A part header (type + size varints) or a part payload may be
 * split across chunk boundaries — the reader keeps the partial bytes until the
 * rest arrives. Payload bytes are copied out, so the internal buffer can be
 * compacted in place without invalidating an already-returned part.
 *
 * <p>Only the bytes of the part currently being assembled are held, so the
 * reader's memory is bounded by the largest single UMP part instead of the
 * whole response (PipePipe's 4K OOM fix).
 */
export class UmpStreamReader {
  private buf: Uint8Array = new Uint8Array(0);
  /** Offset of the first unconsumed byte. */
  private start: number = 0;
  /** Offset one past the last valid byte. */
  private end: number = 0;

  /**
   * Append a received chunk. The chunk is copied (the framework may reuse its
   * buffer on the next callback).
   */
  push(chunk: Uint8Array): void {
    if (chunk.length === 0) {
      return;
    }
    const unconsumed = this.end - this.start;
    const need = unconsumed + chunk.length;
    if (need > this.buf.length) {
      // Grow (and compact in the same step): the old buffer is dropped, the
      // unconsumed prefix is moved to the front.
      const capacity = Math.max(need, this.buf.length * 2, 4096);
      const grown = new Uint8Array(capacity);
      grown.set(this.buf.subarray(this.start, this.end), 0);
      this.buf = grown;
      this.end = unconsumed;
      this.start = 0;
    } else if (this.buf.length - this.end < chunk.length) {
      // Enough capacity but not enough tail room: compact in place.
      this.buf.copyWithin(0, this.start, this.end);
      this.end = unconsumed;
      this.start = 0;
    }
    this.buf.set(chunk, this.end);
    this.end += chunk.length;
  }

  /**
   * Next complete part, or undefined when the buffer does not hold one yet
   * (the part header or its payload is still incomplete).
   */
  nextPart(): UmpPart | undefined {
    const type = this.peekVarint(this.start);
    if (!type) {
      return undefined;
    }
    const size = this.peekVarint(type.next);
    if (!size) {
      return undefined;
    }
    const payloadStart = size.next;
    if (this.end - payloadStart < size.value) {
      return undefined;
    }
    const payload = new Uint8Array(size.value);
    payload.set(this.buf.subarray(payloadStart, payloadStart + size.value));
    this.start = payloadStart + size.value;
    return new UmpPart(type.value, size.value, payload);
  }

  /** Bytes received but not yet consumed as a complete part. */
  pendingBytes(): number {
    return this.end - this.start;
  }

  /**
   * End of stream: a non-zero pending count means the response was truncated
   * in the middle of a part.
   */
  finish(): void {
    if (this.end - this.start > 0) {
      throw new SabrProtocolException(
        `Truncated UMP response: ${this.end - this.start} trailing bytes`);
    }
  }

  /**
   * Read a UMP varint without consuming it. The first byte alone determines the
   * encoded length (PipePipe UmpCursor.readUmpInt), so a header split across
   * chunks is detected by the missing continuation bytes.
   */
  private peekVarint(offset: number): PeekedVarint | undefined {
    if (offset >= this.end) {
      return undefined;
    }
    const first = this.buf[offset];
    let length: number;
    let value: number;
    if (first < 128) {
      length = 1;
      value = first;
    } else if (first < 192) {
      length = 2;
      value = first & 0x3f;
    } else if (first < 224) {
      length = 3;
      value = first & 0x1f;
    } else if (first < 240) {
      length = 4;
      value = first & 0x0f;
    } else {
      length = 5;
      value = 0;
    }
    if (this.end - offset < length) {
      return undefined;
    }
    if (length === 2) {
      value += 64 * this.buf[offset + 1];
    } else if (length === 3) {
      value += 32 * (this.buf[offset + 1] + 256 * this.buf[offset + 2]);
    } else if (length === 4) {
      value += 16 * (this.buf[offset + 1] + 256 * this.buf[offset + 2]
        + 65536 * this.buf[offset + 3]);
    } else if (length === 5) {
      value += this.buf[offset + 1] + 256 * this.buf[offset + 2]
        + 65536 * this.buf[offset + 3] + 16777216 * this.buf[offset + 4];
    }
    return { value: value, next: offset + length };
  }
}
