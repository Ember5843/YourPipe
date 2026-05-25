import { StreamResource } from './SessionStore';
import { rcp } from '@kit.RemoteCommunicationKit';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import Logger from '../utils/Logger';

const TAG = '[LocalProxy][RangeProxy]';
const MAX_RETRIES = 2;
const TIMEOUT_MS = 30000;

function buildYoutubeRangeUrl(url: string, rangeSpec: string): string {
  const sep = url.includes('?') ? '&' : '?';
  return url + sep + 'range=' + rangeSpec;
}

function isAndroidUrl(url: string): boolean {
  return url.includes('&c=ANDROID');
}

function isIosUrl(url: string): boolean {
  return url.includes('&c=IOS');
}

function makeHeaders(resource: StreamResource): rcp.RequestHeaders {
  const h: rcp.RequestHeaders = { 'Accept-Encoding': 'identity' };
  if (resource.userAgent) h['User-Agent'] = resource.userAgent;
  if (resource.referer) h['Referer'] = resource.referer;
  return h;
}

export interface ParsedRange {
  start: number;
  end: number;
}

export function parseRangeHeader(header: string, totalLength: number): ParsedRange {
  const result: ParsedRange = { start: 0, end: totalLength > 0 ? totalLength - 1 : -1 };
  if (!header) return result;
  const match = header.match(/bytes=(\d*)-(\d*)/);
  if (!match) return result;
  if (match[1]) result.start = parseInt(match[1], 10);
  if (match[2]) result.end = parseInt(match[2], 10);
  else if (totalLength > 0) result.end = totalLength - 1;
  return result;
}

function encodeStr(s: string): ArrayBuffer {
  return new util.TextEncoder().encode(s).buffer as ArrayBuffer;
}

function contentTypeFor(resource: StreamResource): string {
  const mime = resource.mimeType.toLowerCase();
  if (mime) return mime;
  return resource.isAudio ? 'audio/mp4' : 'video/mp4';
}

async function sendRaw(conn: socket.TCPSocketConnection, data: ArrayBuffer): Promise<void> {
  await conn.send({ data });
}

async function sendError(conn: socket.TCPSocketConnection, status: number, msg: string): Promise<void> {
  const body = msg;
  const hdr = `HTTP/1.1 ${status} Error\r\nContent-Type: text/plain\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n`;
  try {
    await sendRaw(conn, encodeStr(hdr + body));
  } catch (_e) {}
}

class TcpWriter implements rcp.WriteStream {
  private conn: socket.TCPSocketConnection;
  private headerSent: boolean = false;
  private closed: boolean = false;
  private start: number;
  private end: number;
  private total: number;
  private contentType: string;

  constructor(conn: socket.TCPSocketConnection, start: number, end: number, total: number, contentType: string) {
    this.conn = conn;
    this.start = start;
    this.end = end;
    this.total = total;
    this.contentType = contentType;
  }

  async write(buffer: ArrayBuffer): Promise<void | number> {
    if (this.closed) return 0;
    try {
      if (!this.headerSent) {
        const contentLength = (this.end >= this.start) ? (this.end - this.start + 1) : buffer.byteLength;
        const totalStr = this.total > 0 ? String(this.total) : '*';
        const hdr = `HTTP/1.1 206 Partial Content\r\n` +
          `Content-Type: ${this.contentType}\r\n` +
          `Content-Range: bytes ${this.start}-${this.end}/${totalStr}\r\n` +
          `Content-Length: ${contentLength}\r\n` +
          `Accept-Ranges: bytes\r\n` +
          `Connection: close\r\n\r\n`;
        await this.conn.send({ data: encodeStr(hdr) });
        this.headerSent = true;
      }
      await this.conn.send({ data: buffer });
      return buffer.byteLength;
    } catch (e) {
      this.closed = true;
      Logger.warn(TAG, `TcpWriter.write failed (conn closed?): ${(e as Error).message}`);
      return 0;
    }
  }
}

export async function serveRange(
  conn: socket.TCPSocketConnection,
  resource: StreamResource,
  rangeHeader: string,
  headOnly: boolean
): Promise<void> {
  const total = resource.contentLength;
  const parsed = parseRangeHeader(rangeHeader, total);
  const start = parsed.start;
  const end = parsed.end >= 0 ? parsed.end : (total > 0 ? total - 1 : start + 2 * 1024 * 1024 - 1);
  const contentType = contentTypeFor(resource);

  Logger.debug(TAG, `serveRange: resource=${resource.id} range=${start}-${end}/${total} headOnly=${headOnly}`);

  // AVPlayer sends 1-byte probe at file end; YouTube rejects these with 400.
  // Return empty 206 to satisfy the player without hitting upstream.
  if (start === end && total > 0 && start >= total) {
    const hdr = `HTTP/1.1 206 Partial Content\r\nContent-Type: ${contentType}\r\nContent-Range: bytes ${total - 1}-${total - 1}/${total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`;
    await sendRaw(conn, encodeStr(hdr));
    return;
  }

  if (headOnly) {
    const totalStr = total > 0 ? String(total) : '*';
    const hdr = `HTTP/1.1 206 Partial Content\r\nContent-Type: ${contentType}\r\nContent-Range: bytes ${start}-${end}/${totalStr}\r\nContent-Length: ${end - start + 1}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n`;
    await sendRaw(conn, encodeStr(hdr));
    return;
  }

  const rangeSpec = `${start}-${end}`;
  const headers = makeHeaders(resource);
  let lastError = '';

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const rcpSession = rcp.createSession({
      headers,
      requestConfiguration: { transfer: { timeout: { connectMs: TIMEOUT_MS, transferMs: TIMEOUT_MS } } }
    });
    try {
      const writer = new TcpWriter(conn, start, end, total, contentType);
      const dest: rcp.DownloadToStream = { kind: 'stream', stream: writer };

      let resp: rcp.Response;
      if (resource.isYoutubePlayback) {
        const fetchUrl = buildYoutubeRangeUrl(resource.url, rangeSpec);
        const usePost = isAndroidUrl(resource.url) || isIosUrl(resource.url);
        if (usePost) {
          // Empty body required so RCP sends Content-Length: 0 (YouTube returns 411 otherwise)
          const req = new rcp.Request(fetchUrl, 'POST', headers, '');
          req.destination = dest;
          resp = await rcpSession.fetch(req);
        } else {
          resp = await rcpSession.downloadToStream(fetchUrl, dest);
        }
      } else {
        const rangeHeaders: rcp.RequestHeaders = { 'Accept-Encoding': 'identity' };
        if (resource.userAgent) rangeHeaders['User-Agent'] = resource.userAgent;
        if (resource.referer) rangeHeaders['Referer'] = resource.referer;
        rangeHeaders['Range'] = `bytes=${rangeSpec}`;
        const req = new rcp.Request(resource.url, 'GET', rangeHeaders);
        req.destination = dest;
        resp = await rcpSession.fetch(req);
      }

      if (resp.statusCode === 200 || resp.statusCode === 206) {
        return;
      }
      // Non-retryable errors: 4xx client errors
      if (resp.statusCode >= 400 && resp.statusCode < 500) {
        Logger.warn(TAG, `serveRange: upstream ${resp.statusCode} (non-retryable) resource=${resource.id} range=${rangeSpec}`);
        await sendError(conn, 502, `upstream ${resp.statusCode}`);
        return;
      }
      lastError = `status=${resp.statusCode}`;
    } catch (e) {
      lastError = String(e);
      Logger.warn(TAG, `serveRange attempt=${attempt} error: ${lastError} resource=${resource.id}`);
    } finally {
      rcpSession.close();
    }
    if (attempt < MAX_RETRIES) {
      await new Promise<void>(r => setTimeout(r, 300 * (attempt + 1)));
    }
  }
  Logger.error(TAG, `serveRange failed: ${lastError} resource=${resource.id}`);
  await sendError(conn, 502, `upstream failed: ${lastError}`);
}
