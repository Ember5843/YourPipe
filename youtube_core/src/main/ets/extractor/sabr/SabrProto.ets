import { SabrProtocolException } from './SabrProtocolException';
import { YoutubeSabrFormatMeta } from './YoutubeSabrInfo';

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
    return bytesToUtf8(this.getBytes());
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
      this.writeBytes(fieldNumber, utf8ToBytes(value));
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
    let remaining = value >>> 0;
    // Support values larger than 32-bit via number (lossy above 2^53; enough for SABR fields).
    if (value > 0xFFFFFFFF) {
      remaining = value;
    }
    while (true) {
      if (remaining < 0x80) {
        this.chunks.push(remaining & 0xff);
        return;
      }
      this.chunks.push((remaining & 0x7f) | 0x80);
      // Use division for >32bit friendliness in JS number path
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
    let result = 0;
    let shift = 0;
    while (shift < 53) {
      if (this.offset >= this.data.length) {
        throw new SabrProtocolException('Unexpected EOF in protobuf varint');
      }
      const current = this.data[this.offset++];
      result += (current & 0x7f) * Math.pow(2, shift);
      if ((current & 0x80) === 0) {
        return result;
      }
      shift += 7;
    }
    throw new SabrProtocolException('Protobuf varint is too long');
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

export function utf8ToBytes(value: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < value.length; i++) {
    let code = value.charCodeAt(i);
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
      const next = value.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
        i++;
        out.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
        continue;
      }
      out.push(0xef, 0xbf, 0xbd);
    } else {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return new Uint8Array(out);
}

export function bytesToUtf8(data: Uint8Array): string {
  let result = '';
  let i = 0;
  while (i < data.length) {
    const b0 = data[i++];
    if (b0 < 0x80) {
      result += String.fromCharCode(b0);
    } else if ((b0 & 0xe0) === 0xc0 && i < data.length) {
      const b1 = data[i++];
      result += String.fromCharCode(((b0 & 0x1f) << 6) | (b1 & 0x3f));
    } else if ((b0 & 0xf0) === 0xe0 && i + 1 < data.length) {
      const b1 = data[i++];
      const b2 = data[i++];
      result += String.fromCharCode(((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f));
    } else if ((b0 & 0xf8) === 0xf0 && i + 2 < data.length) {
      const b1 = data[i++];
      const b2 = data[i++];
      const b3 = data[i++];
      let code = ((b0 & 0x07) << 18) | ((b1 & 0x3f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f);
      code -= 0x10000;
      result += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    } else {
      result += '\uFFFD';
    }
  }
  return result;
}

export function decodeBase64ToBytes(value: string): Uint8Array {
  const padded = padBase64(value);
  // Manual base64 decode (standard + url-safe)
  const table =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const normalized = padded.replace(/-/g, '+').replace(/_/g, '/');
  const bytes: number[] = [];
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < normalized.length; i++) {
    const ch = normalized.charAt(i);
    if (ch === '=') {
      break;
    }
    const val = table.indexOf(ch);
    if (val < 0) {
      continue;
    }
    buffer = (buffer << 6) | val;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((buffer >> bits) & 0xff);
    }
  }
  if (bytes.length === 0) {
    throw new SabrProtocolException('Could not decode base64 ustreamer config');
  }
  return new Uint8Array(bytes);
}

function padBase64(value: string): string {
  const padding = (4 - (value.length % 4)) % 4;
  return value + '='.repeat(padding);
}
