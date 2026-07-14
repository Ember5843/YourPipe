import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import Logger from '../utils/Logger';
import { SabrTrackBuffer } from './SabrTrackBuffer';

const TAG = '[SabrProxyServe]';

function encodeText(s: string): ArrayBuffer {
  return new util.TextEncoder().encode(s).buffer as ArrayBuffer;
}

/**
 * Serve HTTP range from a SABR track buffer (pseudo-progressive).
 */
export async function serveSabrRange(
  conn: socket.TCPSocketConnection,
  buffer: SabrTrackBuffer,
  rangeHeader: string,
  mimeType: string
): Promise<void> {
  await buffer.ensureReady();

  let start = 0;
  let end = -1;
  let isRange = false;
  if (rangeHeader && rangeHeader.startsWith('bytes=')) {
    isRange = true;
    const spec = rangeHeader.substring(6);
    const dash = spec.indexOf('-');
    if (dash >= 0) {
      const a = spec.substring(0, dash);
      const b = spec.substring(dash + 1);
      if (a.length > 0) {
        start = parseInt(a, 10) || 0;
      }
      if (b.length > 0) {
        end = parseInt(b, 10);
      }
    }
  }

  // Cap single response to 2MB to force progressive pump without huge allocations
  const MAX_CHUNK = 2 * 1024 * 1024;
  if (end < 0) {
    end = start + MAX_CHUNK - 1;
  } else if (end - start + 1 > MAX_CHUNK) {
    end = start + MAX_CHUNK - 1;
  }

  const data = await buffer.readRange(start, end);
  if (data.length === 0 && start > 0) {
    // Beyond known data — 416 or empty
    const known = buffer.getContentLength();
    if (known > 0 && start >= known) {
      const hdr = `HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */${known}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`;
      await conn.send({ data: encodeText(hdr) });
      return;
    }
  }

  const actualEnd = start + Math.max(0, data.length) - 1;
  const knownLen = buffer.getContentLength();
  const totalStr = knownLen > actualEnd ? String(knownLen) : '*';

  let header: string;
  if (isRange || start > 0) {
    header = `HTTP/1.1 206 Partial Content\r\n`
      + `Content-Type: ${mimeType || 'application/octet-stream'}\r\n`
      + `Accept-Ranges: bytes\r\n`
      + `Content-Range: bytes ${start}-${Math.max(start, actualEnd)}/${totalStr}\r\n`
      + `Content-Length: ${data.length}\r\n`
      + `Connection: close\r\n\r\n`;
  } else {
    header = `HTTP/1.1 200 OK\r\n`
      + `Content-Type: ${mimeType || 'application/octet-stream'}\r\n`
      + `Accept-Ranges: bytes\r\n`
      + `Content-Length: ${data.length}\r\n`
      + `Connection: close\r\n\r\n`;
  }

  Logger.info(TAG, `serve itag=${buffer.getItag()} range=${start}-${actualEnd} len=${data.length} known=${knownLen}`);
  await conn.send({ data: encodeText(header) });
  if (data.length > 0) {
    // Send body in chunks
    const body = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
    await conn.send({ data: body });
  }
}
