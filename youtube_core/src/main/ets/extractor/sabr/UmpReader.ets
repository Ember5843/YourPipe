import { SabrProtocolException } from './SabrProtocolException';

export class UmpPart {
  type: number;
  size: number;
  data: Uint8Array;

  constructor(type: number, size: number, data: Uint8Array) {
    this.type = type;
    this.size = size;
    this.data = data;
  }
}

class UmpCursor {
  private data: Uint8Array;
  private offset: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  isDone(): boolean {
    return this.offset >= this.data.length;
  }

  readUmpInt(): number {
    if (this.offset >= this.data.length) {
      throw new SabrProtocolException('Unexpected EOF in UMP integer');
    }
    const first = this.data[this.offset++];
    if (first < 128) {
      return first;
    }
    if (first < 192) {
      return (first & 0x3f) + 64 * this.readByte();
    }
    if (first < 224) {
      return (first & 0x1f) + 32 * (this.readByte() + 256 * this.readByte());
    }
    if (first < 240) {
      return (first & 0x0f) + 16 * (this.readByte()
        + 256 * (this.readByte() + 256 * this.readByte()));
    }
    return this.readByte() + 256 * (this.readByte()
      + 256 * (this.readByte() + 256 * this.readByte()));
  }

  readBytes(length: number): Uint8Array {
    if (length < 0 || this.offset + length > this.data.length) {
      throw new SabrProtocolException(`Unexpected EOF while reading UMP part data (${length})`);
    }
    const slice = this.data.subarray(this.offset, this.offset + length);
    this.offset += length;
    return slice;
  }

  private readByte(): number {
    if (this.offset >= this.data.length) {
      throw new SabrProtocolException('Unexpected EOF in UMP integer');
    }
    return this.data[this.offset++];
  }
}

/**
 * Parse complete UMP envelope from a buffer (PipePipe UmpReader.readAll).
 * Large responses should later use streaming; MVP holds one response body.
 */
export function umpReadAll(data: Uint8Array): UmpPart[] {
  const cursor = new UmpCursor(data);
  const parts: UmpPart[] = [];
  while (!cursor.isDone()) {
    const type = cursor.readUmpInt();
    const size = cursor.readUmpInt();
    if (type < 0 || size < 0) {
      throw new SabrProtocolException('Invalid UMP part header');
    }
    const payload = cursor.readBytes(size);
    parts.push(new UmpPart(type, size, payload));
  }
  return parts;
}
