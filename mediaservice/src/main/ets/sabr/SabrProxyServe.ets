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

  // Keep individual reads small. MPV opens the EDL video input before audio; a large first
  // read can otherwise block on several SABR pumps and delay audio-track probing for seconds.
  const MAX_CHUNK = 256 * 1024;
  if (end < 0) {
    end = start + MAX_CHUNK - 1;
  } else if (end - start + 1 > MAX_CHUNK) {
    end = start + MAX_CHUNK - 1;
  }

  // Do not 416 before readRange — cold-seek may remap absurd lavf offsets.
  const data = await buffer.readRange(start, end);
  const knownLen = buffer.getContentLength();

  if (data.length === 0) {
    // Still empty after pump/seek: open-ended empty 206 keeps demuxer alive better than 416
    // when protection stalls mid-stream.
    if (isRange || start > 0) {
      const totalStr = knownLen > 0 ? String(knownLen) : '*';
      const hdr = `HTTP/1.1 206 Partial Content\r\n`
        + `Content-Type: ${mimeType || 'application/octet-stream'}\r\n`
        + `Accept-Ranges: bytes\r\n`
        + `Content-Range: bytes ${start}-${Math.max(0, start - 1)}/${totalStr}\r\n`
        + `Content-Length: 0\r\n`
        + `Connection: close\r\n\r\n`;
      Logger.warn(TAG, `serve empty itag=${buffer.getItag()} range=${start}- known=${knownLen}`);
      await conn.send({ data: encodeText(hdr) });
      return;
    }
  }

  // After cold-seek remaps absurd offsets, the bytes returned are from the post-seek window
  // (starting near init). Report that window so Content-Range stays self-consistent.
  const serveStart = (data.length > 0 && knownLen > 0 && start >= knownLen) ? 0 : start;
  const actualEnd = serveStart + Math.max(0, data.length) - 1;
  const totalStr = knownLen > 0 ? String(Math.max(knownLen, actualEnd + 1)) : '*';

  let header: string;
  if (isRange || serveStart > 0) {
    header = `HTTP/1.1 206 Partial Content\r\n`
      + `Content-Type: ${mimeType || 'application/octet-stream'}\r\n`
      + `Accept-Ranges: bytes\r\n`
      + `Content-Range: bytes ${serveStart}-${Math.max(serveStart, actualEnd)}/${totalStr}\r\n`
      + `Content-Length: ${data.length}\r\n`
      + `Connection: close\r\n\r\n`;
  } else {
    header = `HTTP/1.1 200 OK\r\n`
      + `Content-Type: ${mimeType || 'application/octet-stream'}\r\n`
      + `Accept-Ranges: bytes\r\n`
      + `Content-Length: ${data.length}\r\n`
      + `Connection: close\r\n\r\n`;
  }

  Logger.info(TAG, `serve itag=${buffer.getItag()} req=${start} serve=${serveStart}-${actualEnd} `
    + `len=${data.length} known=${knownLen}`);
  await conn.send({ data: encodeText(header) });
  if (data.length > 0) {
    const body = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
    await conn.send({ data: body });
  }
}
