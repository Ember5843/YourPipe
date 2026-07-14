import { SabrMediaHeader } from './SabrMediaHeader';

export class SabrMediaSegment {
  header: SabrMediaHeader;
  data: Uint8Array;

  constructor(header: SabrMediaHeader, data: Uint8Array) {
    this.header = header;
    this.data = data;
  }

  getLength(): number {
    return this.data.length;
  }

  cacheKey(): string {
    const h = this.header;
    return `${h.itag}:${h.initSegment ? 'init' : h.sequenceNumber}`;
  }
}

export class SabrSegmentRequest {
  itag: number;
  initSegment: boolean;
  sequenceNumber: number;

  constructor(itag: number, initSegment: boolean, sequenceNumber: number = -1) {
    this.itag = itag;
    this.initSegment = initSegment;
    this.sequenceNumber = sequenceNumber;
  }

  cacheKey(): string {
    return `${this.itag}:${this.initSegment ? 'init' : this.sequenceNumber}`;
  }

  matches(header: SabrMediaHeader): boolean {
    if (header.itag !== this.itag) {
      return false;
    }
    if (this.initSegment) {
      return header.initSegment;
    }
    return !header.initSegment && header.sequenceNumber === this.sequenceNumber;
  }

  static init(itag: number): SabrSegmentRequest {
    return new SabrSegmentRequest(itag, true, -1);
  }

  static media(itag: number, sequenceNumber: number): SabrSegmentRequest {
    return new SabrSegmentRequest(itag, false, sequenceNumber);
  }
}
