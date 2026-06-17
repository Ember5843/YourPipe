import { StreamResource, OtfSegmentTimelineEntry, DashSession } from './SessionStore';
import { rcp } from '@kit.RemoteCommunicationKit';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import Logger from '../utils/Logger';

const TAG = '[LocalProxy][RangeProxy]';
const MAX_RETRIES = 2;
const TIMEOUT_MS = 30000;
const requestNumberMap: Map<string, number> = new Map<string, number>();

function buildYoutubeRangeUrl(url: string, rangeSpec: string): string {
  const sep = url.includes('?') ? '&' : '?';
  return url + sep + 'range=' + rangeSpec;
}

function buildYoutubeSqUrl(url: string, sq: number): string {
  let result = url.replace(/([?&])sq=[^&]*&?/, (_match: string, sep: string): string => sep === '?' ? '?' : '');
  if (result.endsWith('?') || result.endsWith('&')) {
    result = result.substring(0, result.length - 1);
  }
  const sep = result.includes('?') ? '&' : '?';
  return `${result}${sep}sq=${sq}`;
}

function appendYoutubeAlr(url: string): string {
  if (url.includes('&alr=') || url.includes('?alr=')) {
    return url;
  }
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}alr=yes`;
}

function buildOtfRequestUrl(url: string, sq: number): string {
  let result = buildYoutubeSqUrl(url, sq);
  if (isWebUrl(url) || isTvUrl(url)) {
    result = appendYoutubeAlr(result);
  }
  return result;
}

function appendYoutubeRn(url: string, urlKey: string): string {
  let result = url.replace(/([?&])rn=[^&]*&?/, (_match: string, sep: string): string => sep === '?' ? '?' : '');
  if (result.endsWith('?') || result.endsWith('&')) {
    result = result.substring(0, result.length - 1);
  }
  const rn = requestNumberMap.get(urlKey) || 0;
  requestNumberMap.set(urlKey, rn + 1);
  const sep = result.includes('?') ? '&' : '?';
  return `${result}${sep}rn=${rn}`;
}

function getYoutubeClient(url: string): string {
  const match = url.match(/[?&]c=([^&]+)/);
  if (!match || !match[1]) {
    return '';
  }
  try {
    return decodeURIComponent(match[1]).toUpperCase();
  } catch (_error) {
    return match[1].toUpperCase();
  }
}

function isAndroidUrl(url: string): boolean {
  return getYoutubeClient(url).startsWith('ANDROID');
}

function isIosUrl(url: string): boolean {
  return getYoutubeClient(url).startsWith('IOS');
}

function isWebUrl(url: string): boolean {
  return getYoutubeClient(url).startsWith('WEB');
}

function isTvUrl(url: string): boolean {
  return getYoutubeClient(url) === 'TVHTML5_SIMPLY_EMBEDDED_PLAYER';
}

function makeHeaders(resource: StreamResource): rcp.RequestHeaders {
  const h: rcp.RequestHeaders = { 'Accept-Encoding': 'identity' };
  if (resource.userAgent) h['User-Agent'] = resource.userAgent;
  if (resource.referer) h['Referer'] = resource.referer;
  return h;
}

function makeYoutubeHeaders(resource: StreamResource): rcp.RequestHeaders {
  const h: rcp.RequestHeaders = { 'Accept-Encoding': 'identity' };
  const isAndroid = isAndroidUrl(resource.url);
  const isIos = isIosUrl(resource.url);
  const isWeb = isWebUrl(resource.url);
  const isTv = isTvUrl(resource.url);

  if (isWeb || isTv) {
    h['Origin'] = 'https://www.youtube.com';
    h['Referer'] = 'https://www.youtube.com';
    h['Sec-Fetch-Dest'] = 'empty';
    h['Sec-Fetch-Mode'] = 'cors';
    h['Sec-Fetch-Site'] = 'cross-site';
  }

  if (isAndroid) {
    h['User-Agent'] = 'com.google.android.youtube/21.03.36 (Linux; U; Android 16; GB) gzip';
  } else if (isIos) {
    h['User-Agent'] = 'com.google.ios.youtube/20.03.02(iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X; GB)';
  } else if (resource.userAgent) {
    h['User-Agent'] = resource.userAgent;
  }

  if (resource.referer && !h['Referer']) {
    h['Referer'] = resource.referer;
  }
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

class MemoryWriteStream implements rcp.WriteStream {
  private chunks: ArrayBuffer[] = [];

  async write(buffer: ArrayBuffer): Promise<void | number> {
    this.chunks.push(buffer.slice(0));
    return buffer.byteLength;
  }

  toText(): string {
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
    return new util.TextDecoder().decode(bytes);
  }
}

interface OtfTimelineParseResult {
  timeline: OtfSegmentTimelineEntry[];
  durationMs: number;
}

interface FetchTextResult {
  statusCode: number;
  body: string;
}

function parseOtfTimeline(body: string): OtfTimelineParseResult {
  const match = body.match(/Segment-Durations-Ms:\s*([^\n\r]*)/);
  if (!match || !match[1]) {
    throw new Error('missing Segment-Durations-Ms');
  }

  const timeline: OtfSegmentTimelineEntry[] = [];
  let durationMs = 0;
  const parts = match[1].split(',').map((p: string): string => p.trim()).filter((p: string): boolean => p.length > 0);
  for (const part of parts) {
    const segMatch = part.match(/^(\d+)(?:\(r=(\d+)\))?/);
    if (!segMatch || !segMatch[1]) {
      throw new Error(`invalid OTF duration entry: ${part}`);
    }
    const d = parseInt(segMatch[1], 10);
    const r = segMatch[2] ? parseInt(segMatch[2], 10) : 0;
    timeline.push({ durationMs: d, repeat: r });
    durationMs += d * (r + 1);
  }
  if (timeline.length === 0) {
    throw new Error('empty OTF timeline');
  }
  return { timeline, durationMs };
}

async function fetchYoutubeToMemory(resource: StreamResource, url: string): Promise<FetchTextResult> {
  const headers = makeYoutubeHeaders(resource);
  const usePost = isAndroidUrl(resource.url) || isIosUrl(resource.url);
  const runOnce = async (method: string): Promise<FetchTextResult> => {
    const rcpSession = rcp.createSession({
      headers,
      requestConfiguration: { transfer: { timeout: { connectMs: TIMEOUT_MS, transferMs: TIMEOUT_MS } } }
    });
    try {
      const writer = new MemoryWriteStream();
      const dest: rcp.DownloadToStream = { kind: 'stream', stream: writer };
      const req = method === 'POST'
        ? new rcp.Request(url, 'POST', headers, '')
        : new rcp.Request(url, 'GET', headers);
      req.destination = dest;
      const resp = await rcpSession.fetch(req);
      return { statusCode: resp.statusCode, body: writer.toText() };
    } finally {
      rcpSession.close();
    }
  };

  const first: FetchTextResult = await runOnce(usePost ? 'POST' : 'GET');
  if (!usePost && first.statusCode === 411) {
    return await runOnce('POST');
  }
  return first;
}

export async function fetchOtfInitialization(resource: StreamResource): Promise<boolean> {
  if (!resource.isOtf || resource.otfPrepared) {
    return resource.otfPrepared;
  }

  let initUrl = buildOtfRequestUrl(resource.url, 0);
  initUrl = appendYoutubeRn(initUrl, `${resource.url}:otf`);

  Logger.info(TAG, `otfInit: resource=${resource.id} sq=0 client=${getYoutubeClient(resource.url)}`);
  const result = await fetchYoutubeToMemory(resource, initUrl);
  if (result.statusCode !== 200) {
    Logger.warn(TAG, `otfInit: upstream ${result.statusCode} resource=${resource.id}`);
    return false;
  }

  try {
    const parsed = parseOtfTimeline(result.body);
    resource.otfSegmentTimeline = parsed.timeline;
    resource.otfDurationMs = parsed.durationMs;
    resource.otfPrepared = true;
    Logger.info(TAG, `otfInit: prepared resource=${resource.id} segments=${parsed.timeline.length} durationMs=${parsed.durationMs}`);
    return true;
  } catch (e) {
    Logger.warn(TAG, `otfInit: parse failed resource=${resource.id}: ${(e as Error).message}`);
    return false;
  }
}

export async function serveOtfSegment(
  conn: socket.TCPSocketConnection,
  resource: StreamResource,
  sq: number,
  headOnly: boolean
): Promise<void> {
  const contentType = contentTypeFor(resource);
  Logger.info(TAG, `otfSegment: resource=${resource.id} sq=${sq} headOnly=${headOnly}`);

  if (headOnly) {
    const hdr = `HTTP/1.1 200 OK\r\nContent-Type: ${contentType}\r\nAccept-Ranges: none\r\nConnection: close\r\n\r\n`;
    await sendRaw(conn, encodeStr(hdr));
    return;
  }

  const sqUrl = appendYoutubeRn(buildOtfRequestUrl(resource.url, sq), `${resource.url}:otf`);
  let lastError = '';
  const writer = new OtfTcpWriter(conn, contentType);
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const headers = makeYoutubeHeaders(resource);
    const rcpSession = rcp.createSession({
      headers,
      requestConfiguration: { transfer: { timeout: { connectMs: TIMEOUT_MS, transferMs: TIMEOUT_MS } } }
    });
    try {
      const dest: rcp.DownloadToStream = { kind: 'stream', stream: writer };
      let resp: rcp.Response;
      const usePost = isAndroidUrl(resource.url) || isIosUrl(resource.url);
      if (usePost) {
        const req = new rcp.Request(sqUrl, 'POST', headers, '');
        req.destination = dest;
        resp = await rcpSession.fetch(req);
      } else {
        const req = new rcp.Request(sqUrl, 'GET', headers);
        req.destination = dest;
        resp = await rcpSession.fetch(req);
        if (resp.statusCode === 411) {
          if (writer.hasEmittedAny()) {
            Logger.error(TAG, `otfSegment: 411 after bytes emitted resource=${resource.id} sq=${sq}`);
            return;
          }
          const retryReq = new rcp.Request(sqUrl, 'POST', headers, '');
          retryReq.destination = dest;
          resp = await rcpSession.fetch(retryReq);
        }
      }

      if (resp.statusCode === 200 || resp.statusCode === 206) {
        return;
      }
      if (resp.statusCode >= 400 && resp.statusCode < 500) {
        Logger.warn(TAG, `otfSegment: upstream ${resp.statusCode} resource=${resource.id} sq=${sq}`);
        if (!writer.hasEmittedAny()) {
          await sendError(conn, 502, `upstream ${resp.statusCode}`);
        }
        return;
      }
      lastError = `status=${resp.statusCode}`;
    } catch (e) {
      lastError = String(e);
      Logger.warn(TAG, `otfSegment attempt=${attempt} error: ${lastError} resource=${resource.id} sq=${sq}`);
    } finally {
      rcpSession.close();
    }
    // Same as serveRange: retrying after bytes have hit the wire would corrupt the stream.
    if (writer.hasEmittedAny()) {
      Logger.error(TAG, `otfSegment: aborting retry after partial write, resource=${resource.id} sq=${sq} err=${lastError}`);
      return;
    }
    if (attempt < MAX_RETRIES) {
      await new Promise<void>(r => setTimeout(r, 300 * (attempt + 1)));
    }
  }
  Logger.error(TAG, `otfSegment failed: ${lastError} resource=${resource.id} sq=${sq}`);
  if (!writer.hasEmittedAny()) {
    await sendError(conn, 502, `upstream failed: ${lastError}`);
  }
}

class TcpWriter implements rcp.WriteStream {
  private conn: socket.TCPSocketConnection;
  private headerSent: boolean = false;
  private closed: boolean = false;
  private start: number;
  private end: number;
  private total: number;
  private contentType: string;
  bytesEmitted: number = 0;

  constructor(conn: socket.TCPSocketConnection, start: number, end: number, total: number, contentType: string) {
    this.conn = conn;
    this.start = start;
    this.end = end;
    this.total = total;
    this.contentType = contentType;
  }

  hasEmittedAny(): boolean {
    return this.headerSent || this.bytesEmitted > 0;
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
      this.bytesEmitted += buffer.byteLength;
      return buffer.byteLength;
    } catch (e) {
      this.closed = true;
      Logger.warn(TAG, `TcpWriter.write failed (conn closed?): ${(e as Error).message}`);
      return 0;
    }
  }
}

class OtfTcpWriter implements rcp.WriteStream {
  private conn: socket.TCPSocketConnection;
  private headerSent: boolean = false;
  private closed: boolean = false;
  private contentType: string;
  bytesEmitted: number = 0;

  constructor(conn: socket.TCPSocketConnection, contentType: string) {
    this.conn = conn;
    this.contentType = contentType;
  }

  hasEmittedAny(): boolean {
    return this.headerSent || this.bytesEmitted > 0;
  }

  async write(buffer: ArrayBuffer): Promise<void | number> {
    if (this.closed) return 0;
    try {
      if (!this.headerSent) {
        const hdr = `HTTP/1.1 200 OK\r\n` +
          `Content-Type: ${this.contentType}\r\n` +
          `Accept-Ranges: none\r\n` +
          `Connection: close\r\n\r\n`;
        await this.conn.send({ data: encodeStr(hdr) });
        this.headerSent = true;
      }
      await this.conn.send({ data: buffer });
      this.bytesEmitted += buffer.byteLength;
      return buffer.byteLength;
    } catch (e) {
      this.closed = true;
      Logger.warn(TAG, `OtfTcpWriter.write failed (conn closed?): ${(e as Error).message}`);
      return 0;
    }
  }
}

export async function serveRange(
  conn: socket.TCPSocketConnection,
  resource: StreamResource,
  rangeHeader: string,
  headOnly: boolean,
  session?: DashSession
): Promise<void> {
  const total = resource.contentLength;
  const parsed = parseRangeHeader(rangeHeader, total);
  const start = parsed.start;
  let end = parsed.end >= 0 ? parsed.end : (total > 0 ? total - 1 : start + 2 * 1024 * 1024 - 1);

  // 限制单次请求的最大大小，避免触发YouTube的SABR限速
  // YouTube对大范围请求会限速到~80KB/s，导致超时
  // 将最大chunk限制为10MB，这是一个在性能和稳定性之间的平衡点
  const MAX_CHUNK_SIZE = 10 * 1024 * 1024; // 10MB
  if (end - start + 1 > MAX_CHUNK_SIZE) {
    end = start + MAX_CHUNK_SIZE - 1;
    Logger.info(TAG, `serveRange: limiting range from ${parsed.end - start + 1} to ${MAX_CHUNK_SIZE} bytes to avoid throttling, resource=${resource.id}`);
  }

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
  let lastError = '';
  const writer = new TcpWriter(conn, start, end, total, contentType);

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const sessionHeaders = resource.isYoutubePlayback ? makeYoutubeHeaders(resource) : makeHeaders(resource);
    const rcpSession = rcp.createSession({
      headers: sessionHeaders,
      requestConfiguration: { transfer: { timeout: { connectMs: TIMEOUT_MS, transferMs: TIMEOUT_MS } } }
    });
    try {
      const dest: rcp.DownloadToStream = { kind: 'stream', stream: writer };

      let resp: rcp.Response;
      if (resource.isYoutubePlayback) {
        const fetchUrl = appendYoutubeRn(buildYoutubeRangeUrl(resource.url, rangeSpec), resource.url);
        const headers = makeYoutubeHeaders(resource);
        const usePost = isAndroidUrl(resource.url) || isIosUrl(resource.url);
        if (usePost) {
          // PipePipe: Android/Android VR/iOS use POST with empty body and range= URL parameter.
          const req = new rcp.Request(fetchUrl, 'POST', headers, '');
          req.destination = dest;
          resp = await rcpSession.fetch(req);
        } else {
          const req = new rcp.Request(fetchUrl, 'GET', headers);
          req.destination = dest;
          resp = await rcpSession.fetch(req);
          if (resp.statusCode === 411) {
            if (writer.hasEmittedAny()) {
              Logger.error(TAG, `serveRange: 411 after bytes emitted, cannot retry resource=${resource.id} range=${rangeSpec}`);
              return;
            }
            Logger.warn(TAG, `serveRange: upstream 411, retry with empty POST resource=${resource.id} range=${rangeSpec}`);
            const retryReq = new rcp.Request(appendYoutubeRn(buildYoutubeRangeUrl(resource.url, rangeSpec), resource.url), 'POST', headers, '');
            retryReq.destination = dest;
            resp = await rcpSession.fetch(retryReq);
          }
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
      // 411 Length Required: YouTube URL 可能已过期，尝试刷新
      if (resp.statusCode === 411 && resource.isYoutubePlayback && session?.refreshUrls && !writer.hasEmittedAny()) {
        Logger.info(TAG, `serveRange: 411 detected, attempting URL refresh for resource=${resource.id}`);
        const refreshed = await session.refreshUrls();
        if (refreshed) {
          Logger.info(TAG, `serveRange: URL refreshed successfully, retrying resource=${resource.id}`);
          // 刷新成功，跳过延迟直接重试（resource.url 已被更新）
          continue;
        } else {
          Logger.warn(TAG, `serveRange: URL refresh failed for resource=${resource.id}`);
        }
      }
      // Non-retryable errors: 4xx client errors
      if (resp.statusCode >= 400 && resp.statusCode < 500) {
        Logger.warn(TAG, `serveRange: upstream ${resp.statusCode} (non-retryable) resource=${resource.id} range=${rangeSpec}`);
        if (!writer.hasEmittedAny()) {
          await sendError(conn, 502, `upstream ${resp.statusCode}`);
        }
        return;
      }
      lastError = `status=${resp.statusCode}`;
    } catch (e) {
      lastError = String(e);
      Logger.warn(TAG, `serveRange attempt=${attempt} error: ${lastError} resource=${resource.id}`);
    } finally {
      rcpSession.close();
    }
    // Cannot retry safely once any bytes have been written to the client connection:
    // the next attempt would re-send the HTTP header and a fresh upstream body, producing
    // [partial_body_1][header_2][body_2] on the wire and corrupting the bitstream.
    if (writer.hasEmittedAny()) {
      Logger.error(TAG, `serveRange: aborting retry after partial write, resource=${resource.id} range=${rangeSpec} err=${lastError}`);
      return;
    }
    if (attempt < MAX_RETRIES) {
      await new Promise<void>(r => setTimeout(r, 300 * (attempt + 1)));
    }
  }
  Logger.error(TAG, `serveRange failed: ${lastError} resource=${resource.id}`);
  if (!writer.hasEmittedAny()) {
    await sendError(conn, 502, `upstream failed: ${lastError}`);
  }
}
