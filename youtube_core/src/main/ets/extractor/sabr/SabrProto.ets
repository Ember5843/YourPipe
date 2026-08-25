import { util } from '@kit.ArkTS';
import { SabrProtocolException } from './SabrProtocolException';
import { YoutubeSabrFormatMeta } from './YoutubeSabrInfo';
import { readProtoVarint, decodeBase64ToBytes as protoDecodeBase64 } from '../../common/ProtoUtil';

export const WIRE_VARINT = 0;
export const WIRE_FIXED64 = 1;
export const WIRE_LENGTH_DELIMITED = 2;
export const WIRE_FIXED32 = 5;

export class SabrProtoField {
  number: number = 0;
  wireType: number = 0;
  varint: number = 0;
  bytes?: Uint8Array;

  static ofVarint(number: number, value: number): SabrProtoField {
    const f = new SabrProtoField();
    f.number = number;
    f.wireType = WIRE_VARINT;
    f.varint = value;
    return f;
  }

  static ofBytes(number: number, wireType: number, value: Uint8Array): SabrProtoField {
    const f = new SabrProtoField();
    f.number = number;
    f.wireType = wireType;
    f.bytes = value;
    return f;
  }

  getBytes(): Uint8Array {
    if (!this.bytes) {
      throw new SabrProtocolException(`Field ${this.number} is not length-delimited`);
    }
    return this.bytes;
  }

  getString(): string {
    return new util.TextDecoder().decode(this.getBytes());
  }
}

export class SabrProtoWriter {
  private chunks: number[] = [];

  writeInt32(fieldNumber: number, value: number): void {
    this.writeUInt64(fieldNumber, value >>> 0);
  }

  writeUInt64(fieldNumber: number, value: number): void {
    this.writeTag(fieldNumber, WIRE_VARINT);
    this.writeVarint(value);
  }

  writeBool(fieldNumber: number, value: boolean): void {
    this.writeUInt64(fieldNumber, value ? 1 : 0);
  }

  writeFloat(fieldNumber: number, value: number): void {
    this.writeTag(fieldNumber, WIRE_FIXED32);
    const buf = new ArrayBuffer(4);
    new DataView(buf).setFloat32(0, value, true);
    const u8 = new Uint8Array(buf);
    for (let i = 0; i < 4; i++) {
      this.chunks.push(u8[i]);
    }
  }

  writeBytes(fieldNumber: number, bytes: Uint8Array): void {
    this.writeTag(fieldNumber, WIRE_LENGTH_DELIMITED);
    this.writeVarint(bytes.length);
    for (let i = 0; i < bytes.length; i++) {
      this.chunks.push(bytes[i]);
    }
  }

  writeStringIfNotEmpty(fieldNumber: number, value?: string): void {
    if (value && value.length > 0) {
      this.writeBytes(fieldNumber, new util.TextEncoder().encode(value));
    }
  }

  writeMessage(fieldNumber: number, bytes: Uint8Array): void {
    this.writeBytes(fieldNumber, bytes);
  }

  toUint8Array(): Uint8Array {
    return new Uint8Array(this.chunks);
  }

  private writeTag(fieldNumber: number, wireType: number): void {
    this.writeVarint((fieldNumber << 3) | wireType);
  }

  private writeVarint(value: number): void {
    // Always use Math.floor path so values > 2^32 (lastModified) are not truncated by >>>.
    let remaining = value < 0 ? 0 : Math.floor(value);
    while (true) {
      if (remaining < 0x80) {
        this.chunks.push(remaining & 0xff);
        return;
      }
      this.chunks.push((remaining & 0x7f) | 0x80);
      remaining = Math.floor(remaining / 128);
    }
  }
}

class Cursor {
  private data: Uint8Array;
  private offset: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  isDone(): boolean {
    return this.offset >= this.data.length;
  }

  readVarint(): number {
    // Shared non-throwing core (common/ProtoUtil); SABR wraps failure as a
    // protocol exception, preserving the EOF / too-long distinction.
    const start = this.offset;
    const result = readProtoVarint(this.data, this.offset);
    if (!result) {
      throw new SabrProtocolException(start >= this.data.length
        ? 'Unexpected EOF in protobuf varint'
        : 'Protobuf varint is too long');
    }
    this.offset = result.next;
    return result.value;
  }

  readBytes(length: number): Uint8Array {
    if (length < 0 || this.offset + length > this.data.length) {
      throw new SabrProtocolException(`Unexpected EOF while reading ${length} bytes`);
    }
    const result = this.data.subarray(this.offset, this.offset + length);
    this.offset += length;
    return result;
  }
}

export function sabrReadFields(data: Uint8Array): SabrProtoField[] {
  const cursor = new Cursor(data);
  const fields: SabrProtoField[] = [];
  while (!cursor.isDone()) {
    const tag = cursor.readVarint();
    const number = Math.floor(tag / 8);
    const wireType = tag & 0x07;
    if (number <= 0) {
      throw new SabrProtocolException(`Invalid protobuf field number: ${number}`);
    }
    switch (wireType) {
      case WIRE_VARINT:
        fields.push(SabrProtoField.ofVarint(number, cursor.readVarint()));
        break;
      case WIRE_FIXED64:
        fields.push(SabrProtoField.ofBytes(number, wireType, cursor.readBytes(8)));
        break;
      case WIRE_LENGTH_DELIMITED: {
        const len = cursor.readVarint();
        fields.push(SabrProtoField.ofBytes(number, wireType, cursor.readBytes(len)));
        break;
      }
      case WIRE_FIXED32:
        fields.push(SabrProtoField.ofBytes(number, wireType, cursor.readBytes(4)));
        break;
      default:
        throw new SabrProtocolException(`Unsupported protobuf wire type: ${wireType}`);
    }
  }
  return fields;
}

export function sabrFormatIdBytes(format: YoutubeSabrFormatMeta): Uint8Array {
  const writer = new SabrProtoWriter();
  writer.writeInt32(1, format.itag);
  const lastModified = parseLastModified(format.lastModified);
  if (lastModified > 0) {
    writer.writeUInt64(2, lastModified);
  }
  writer.writeStringIfNotEmpty(3, format.xtags);
  return writer.toUint8Array();
}

export function parseLastModified(value?: string | number): number {
  if (value === undefined || value === null) {
    return 0;
  }
  if (typeof value === 'number') {
    return value > 0 ? value : 0;
  }
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

export function decodeBase64ToBytes(value: string): Uint8Array {
  // Shared non-throwing core (common/ProtoUtil); SABR wraps failure as a
  // protocol exception.
  const bytes = protoDecodeBase64(value);
  if (!bytes) {
    throw new SabrProtocolException('Could not decode base64 ustreamer config');
  }
  return bytes;
}
