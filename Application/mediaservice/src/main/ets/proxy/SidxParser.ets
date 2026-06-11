import { StreamResource, SidxSegment } from './SessionStore';
import { rcp } from '@kit.RemoteCommunicationKit';
import Logger from '../utils/Logger';

const TAG = '[LocalProxy][SidxParser]';

/**
 * Parse ISO BMFF box structure to extract SIDX (Segment Index Box)
 * SIDX contains timing and byte-range information for all segments
 */

function readUint32BE(buffer: Uint8Array, offset: number): number {
  return (buffer[offset] << 24) | (buffer[offset + 1] << 16) |
         (buffer[offset + 2] << 8) | buffer[offset + 3];
}

function readUint64BE(buffer: Uint8Array, offset: number): number {
  const high = readUint32BE(buffer, offset);
  const low = readUint32BE(buffer, offset + 4);
  // For video files, we assume high is 0 (files < 4GB range)
  return high * 0x100000000 + low;
}

interface BoxInfo {
  offset: number;
  size: number;
}

function findBox(buffer: Uint8Array, targetType: string): BoxInfo | null {
  let offset = 0;
  while (offset < buffer.length - 8) {
    const size = readUint32BE(buffer, offset);
    if (size < 8 || offset + size > buffer.length) break;

    const type = String.fromCharCode(buffer[offset + 4], buffer[offset + 5],
                                     buffer[offset + 6], buffer[offset + 7]);

    if (type === targetType) {
      const boxInfo: BoxInfo = { offset: offset + 8, size: size - 8 };
      return boxInfo;
    }
    offset += size;
  }
  return null;
}

export interface SidxParseResult {
  segments: SidxSegment[];
  initOffset: number;
  initSize: number;
  timescale: number;
}

function parseSidxBox(buffer: Uint8Array, indexRangeStart: number): SidxParseResult | null {
  const sidx = findBox(buffer, 'sidx');
  if (!sidx) {
    Logger.warn(TAG, 'SIDX box not found in index range');
    return null;
  }

  const data = buffer.slice(sidx.offset, sidx.offset + sidx.size);
  if (data.length < 12) return null;

  const version = data[0];
  let pos = 4; // skip version + flags

  // reference_ID (32 bits)
  pos += 4;

  // timescale (32 bits)
  const timescale = readUint32BE(data, pos);
  pos += 4;

  // earliest_presentation_time (32 or 64 bits based on version)
  pos += version === 0 ? 4 : 8;

  // first_offset (32 or 64 bits based on version)
  const firstOffset = version === 0 ? readUint32BE(data, pos) : readUint64BE(data, pos);
  pos += version === 0 ? 4 : 8;

  // reserved (16 bits)
  pos += 2;

  // reference_count (16 bits)
  const referenceCount = (data[pos] << 8) | data[pos + 1];
  pos += 2;

  const segments: SidxSegment[] = [];
  // ISO 14496-12: firstOffset is from the first byte of the SIDX box to the first byte of media data
  // indexRangeStart is the file position where the SIDX box begins (including header)
  let currentOffset = indexRangeStart + firstOffset;

  for (let i = 0; i < referenceCount && pos + 12 <= data.length; i++) {
    const referencedSize = readUint32BE(data, pos) & 0x7FFFFFFF; // Clear reference_type bit
    pos += 4;

    const subsegmentDuration = readUint32BE(data, pos);
    pos += 4;

    // SAP info (32 bits) - skip
    pos += 4;

    segments.push({
      offset: currentOffset,
      size: referencedSize,
      duration: subsegmentDuration / timescale // Convert to seconds
    });

    currentOffset += referencedSize;
  }

  // Init segment is from start to index range start
  const initOffset = 0;
  const initSize = indexRangeStart;

  Logger.info(TAG, `parseSidxBox: found ${segments.length} segments, timescale=${timescale}`);
  return { segments, initOffset, initSize, timescale };
}

export async function fetchAndParseSidx(resource: StreamResource): Promise<SidxParseResult | null> {
  const indexStart = parseInt(resource.indexRangeStart, 10);
  const indexEnd = parseInt(resource.indexRangeEnd, 10);

  if (isNaN(indexStart) || isNaN(indexEnd) || indexStart < 0 || indexEnd < indexStart) {
    Logger.warn(TAG, `fetchAndParseSidx: invalid indexRange resource=${resource.id}`);
    return null;
  }

  const rangeSpec = `${indexStart}-${indexEnd}`;
  const headers: rcp.RequestHeaders = {
    'Range': `bytes=${rangeSpec}`,
    'Accept-Encoding': 'identity'
  };
  if (resource.userAgent) headers['User-Agent'] = resource.userAgent;
  if (resource.referer) headers['Referer'] = resource.referer;

  Logger.info(TAG, `fetchAndParseSidx: resource=${resource.id} range=${rangeSpec}`);

  const rcpSession = rcp.createSession({
    headers,
    requestConfiguration: { transfer: { timeout: { connectMs: 10000, transferMs: 10000 } } }
  });

  try {
    // Use MemoryWriteStream to collect response data (same as RangeProxy)
    class MemoryWriteStream implements rcp.WriteStream {
      private chunks: ArrayBuffer[] = [];

      async write(buffer: ArrayBuffer): Promise<void | number> {
        this.chunks.push(buffer.slice(0));
        return buffer.byteLength;
      }

      toUint8Array(): Uint8Array {
        let total = 0;
        for (const chunk of this.chunks) {
          total += chunk.byteLength;
        }
        const bytes = new Uint8Array(total);
        let offset = 0;
        for (const chunk of this.chunks) {
          bytes.set(new Uint8Array(chunk), offset);
          offset += chunk.byteLength;
        }
        return bytes;
      }
    }

    const writer = new MemoryWriteStream();
    const dest: rcp.DownloadToStream = { kind: 'stream', stream: writer };
    const req = new rcp.Request(resource.url, 'GET', headers);
    req.destination = dest;
    const resp = await rcpSession.fetch(req);

    if (resp.statusCode !== 206 && resp.statusCode !== 200) {
      Logger.warn(TAG, `fetchAndParseSidx: upstream ${resp.statusCode} resource=${resource.id}`);
      return null;
    }

    const buffer = writer.toUint8Array();
    return parseSidxBox(buffer, indexStart);
  } catch (e) {
    const error = e as Error;
    Logger.error(TAG, `fetchAndParseSidx: error ${error.message} resource=${resource.id}`);
    return null;
  } finally {
    rcpSession.close();
  }
}
