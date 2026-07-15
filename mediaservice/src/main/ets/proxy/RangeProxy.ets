import { StreamResource } from './SessionStore';
import { rcp } from '@kit.RemoteCommunicationKit';
import { http, socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import Logger from '../utils/Logger';

const TAG = '[LocalProxy][RangeProxy]';
const MAX_RETRIES = 2;
const TIMEOUT_MS = 30000;
const requestNumberMap: Map<string, number> = new Map<string, number>();

class BufferWriter implements rcp.WriteStream {
  private chunks: Uint8Array[] = [];
  private length: number = 0;

  async write(buffer: ArrayBuffer): Promise<number> {
    const chunk = new Uint8Array(buffer.slice(0));
    this.chunks.push(chunk);
    this.length += chunk.length;
    return chunk.length;
  }

  bytes(): Uint8Array {
    const result = new Uint8Array(this.length);
    let offset = 0;
    for (const chunk of this.chunks) {
      result.set(chunk, offset);
      offset += chunk.length;
    }
    return result;
  }
}

function stripQueryParam(url: string, name: string): string {
  const re = new RegExp(`([?&])${name}=[^&]*&?`);
  let result = url.replace(re, (_match: string, sep: string): string => sep === '?' ? '?' : '');
  if (result.endsWith('?') || result.endsWith('&')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

function buildYoutubeRangeUrl(url: string, rangeSpec: string): string {
  // Drop any pre-existing range= so MPV/SIDX never send duplicate range params.
  const cleaned = stripQueryParam(url, 'range');
  const sep = cleaned.includes('?') ? '&' : '?';
  return cleaned + sep + 'range=' + rangeSpec;
}

function appendYoutubeRn(url: string, urlKey: string): string {
  let result = stripQueryParam(url, 'rn');
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

function getQueryFlag(url: string, name: string): boolean {
  return new RegExp(`[?&]${name}=`).test(url);
}

function getQueryValue(url: string, name: string): string {
  const match = url.match(new RegExp(`[?&]${name}=([^&]*)`));
  if (!match || match[1] === undefined) {
    return '';
  }
  try {
    return decodeURIComponent(match[1]);
  } catch (_error) {
    return match[1];
  }
}

/** Safe fingerprint for comparing 403 vs success URLs without leaking sig/n/pot. */
function youtubeUrlFingerprint(url: string): string {
  let host = '';
  try {
    const m = url.match(/^https?:\/\/([^/?#]+)/i);
    host = m?.[1] || '';
  } catch (_e) {
    host = '';
  }
  // Short non-crypto digest of path+stable query shape (not secrets themselves).
  let hash = 2166136261;
  const sample = url.replace(/([?&])(n|sig|lsig|signature|pot|s)=[^&]*/gi, '$1$2=*');
  for (let i = 0; i < sample.length; i++) {
    hash ^= sample.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  const fp = (hash >>> 0).toString(16).padStart(8, '0');
  return `host=${host} c=${getYoutubeClient(url) || '-'} expire=${getQueryValue(url, 'expire') || '-'} `
    + `rn=${getQueryValue(url, 'rn') || '-'} hasN=${getQueryFlag(url, 'n')} hasPot=${getQueryFlag(url, 'pot')} `
    + `hasSig=${getQueryFlag(url, 'sig') || getQueryFlag(url, 'signature') || getQueryFlag(url, 'lsig')} fp=${fp}`;
}

// PipePipe YoutubeParsingHelper: ANDROID|ANDROID_VR → POST + Android app UA
function isAndroidUrl(url: string): boolean {
  const c = getYoutubeClient(url);
  return c === 'ANDROID' || c === 'ANDROID_VR' || c.startsWith('ANDROID_');
}

function isIosUrl(url: string): boolean {
  return getYoutubeClient(url) === 'IOS';
}

// PipePipe: exact c=WEB only (not MWEB / WEB_EMBEDDED / …)
function isWebUrl(url: string): boolean {
  return getYoutubeClient(url) === 'WEB';
}

// PipePipe only special-cases TVHTML5_SIMPLY_EMBEDDED_PLAYER for Origin/Referer/Sec-Fetch
function isTvSimplyEmbeddedUrl(url: string): boolean {
  return getYoutubeClient(url) === 'TVHTML5_SIMPLY_EMBEDDED_PLAYER';
}

function makeHeaders(resource: StreamResource): rcp.RequestHeaders {
  const h: rcp.RequestHeaders = { 'Accept-Encoding': 'identity' };
  if (resource.userAgent) h['User-Agent'] = resource.userAgent;
  if (resource.referer) h['Referer'] = resource.referer;
  return h;
}

function makeYoutubeHeaders(resource: StreamResource): rcp.RequestHeaders {
  // Align with PipePipe YoutubeHttpDataSource.makeConnection:
  // - TE: trailers on all videoplayback requests
  // - Origin/Referer/Sec-Fetch ONLY for c=WEB or c=TVHTML5_SIMPLY_EMBEDDED_PLAYER
  // - regular TVHTML5 / MWEB / ANDROID_VR: no Origin/Referer (extra Referer → 403)
  const h: rcp.RequestHeaders = {
    'Accept-Encoding': 'identity',
    'TE': 'trailers'
  };
  const isAndroid = isAndroidUrl(resource.url);
  const isIos = isIosUrl(resource.url);
  const isWeb = isWebUrl(resource.url);
  const isTvEmbed = isTvSimplyEmbeddedUrl(resource.url);

  if (isWeb || isTvEmbed) {
    h['Origin'] = 'https://www.youtube.com';
    h['Referer'] = 'https://www.youtube.com';
    h['Sec-Fetch-Dest'] = 'empty';
    h['Sec-Fetch-Mode'] = 'cors';
    h['Sec-Fetch-Site'] = 'cross-site';
  }

  if (isAndroid) {
    // PipePipe getAndroidUserAgent — also used for ANDROID_VR streaming URLs
    h['User-Agent'] = 'com.google.android.youtube/21.03.36 (Linux; U; Android 16; GB) gzip';
  } else if (isIos) {
    h['User-Agent'] = 'com.google.ios.youtube/20.03.02(iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X; GB)';
  } else if (resource.userAgent) {
    h['User-Agent'] = resource.userAgent;
  }

  // Do NOT fall back to resource.referer for TVHTML5/MWEB — PipePipe omits it.
  return h;
}

function uaKind(resource: StreamResource): string {
  const ua = resource.userAgent || '';
  if (ua.includes('Cobalt')) return 'tv-cobalt';
  if (ua.includes('iPad') && ua.includes('Safari')) return 'mweb-ipad';
  if (ua.includes('Macintosh') && ua.includes('Safari')) return 'safari';
  if (ua.startsWith('com.google.android.youtube/')) return 'android-app';
  if (ua.startsWith('com.google.android.apps.youtube.vr')) return 'android-vr';
  if (ua.startsWith('com.google.ios.youtube/')) return 'ios-app';
  if (ua.includes('Chrome/')) return 'web-chrome';
  return resource.userAgent ? 'custom' : 'default';
}

function describeYoutubeRequest(resource: StreamResource, method: string, fetchUrl: string, rangeSpec: string): string {
  const client = getYoutubeClient(resource.url) || resource.sourceClient || '-';
  const html5Headers = isWebUrl(resource.url) || isTvSimplyEmbeddedUrl(resource.url);
  return `itag=${resource.id} sourceClient=${resource.sourceClient || '-'} c=${client} method=${method} `
    + `range=${rangeSpec} uaKind=${uaKind(resource)} html5Hdr=${html5Headers} `
    + `${youtubeUrlFingerprint(fetchUrl)}`;
}

function headersToHttpRecord(headers: rcp.RequestHeaders): Record<string, string> {
  const out: Record<string, string> = {};
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = headers[key];
    if (typeof value === 'string') {
      out[key] = value;
    } else if (Array.isArray(value) && value.length > 0) {
      out[key] = String(value[0]);
    }
  }
  return out;
}

function responseBodyToBytes(result: string | Object | ArrayBuffer): Uint8Array {
  if (typeof result === 'string') {
    return new util.TextEncoder().encode(result);
  }
  try {
    return new Uint8Array(result as ArrayBuffer);
  } catch (_e) {
    return new Uint8Array(0);
  }
}

/**
 * Fetch a small exact YouTube byte range for DASH SIDX preprocessing.
 * Uses @ohos.net.http (same stack as youtube_core extractor) — RCP streaming
 * has produced consistent 403 on TVHTML5 indexRange probes.
 */
export async function fetchYoutubeRangeBytes(
  resource: StreamResource,
  start: number,
  end: number
): Promise<Uint8Array> {
  const rangeSpec = `${start}-${end}`;
  const fetchUrl = appendYoutubeRn(buildYoutubeRangeUrl(resource.url, rangeSpec), resource.url);
  const headers = headersToHttpRecord(makeYoutubeHeaders(resource));
  const usePost = isAndroidUrl(resource.url) || isIosUrl(resource.url);
  const method = usePost ? 'POST' : 'GET';
  Logger.info(TAG, `SIDX fetch: transport=http ${describeYoutubeRequest(resource, method, fetchUrl, rangeSpec)}`);
  const req = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: usePost ? http.RequestMethod.POST : http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      usingCache: false,
    };
    // Android/iOS: empty-body POST (PipePipe). Do not set Content-Type.
    if (usePost) {
      options.extraData = '';
    }
    const response = await req.request(fetchUrl, options);
    if (response.responseCode !== 200 && response.responseCode !== 206) {
      const bodyPreview = typeof response.result === 'string'
        ? response.result.substring(0, 160)
        : `bytes=${responseBodyToBytes(response.result).length}`;
      Logger.warn(TAG, `SIDX upstream ${response.responseCode}: transport=http body=${bodyPreview} `
        + `${describeYoutubeRequest(resource, method, fetchUrl, rangeSpec)}`);
      throw new Error(`SIDX upstream status ${response.responseCode}`);
    }
    const bytes = responseBodyToBytes(response.result);
    Logger.info(TAG, `SIDX ok itag=${resource.id} bytes=${bytes.length} range=${rangeSpec} transport=http`);
    return bytes;
  } finally {
    req.destroy();
  }
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
  private standalone: boolean;
  bytesEmitted: number = 0;

  constructor(conn: socket.TCPSocketConnection, start: number, end: number, total: number,
    contentType: string, standalone: boolean = false) {
    this.conn = conn;
    this.start = start;
    this.end = end;
    this.total = total;
    this.contentType = contentType;
    this.standalone = standalone;
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
        const hdr = this.standalone
          ? `HTTP/1.1 200 OK\r\nContent-Type: ${this.contentType}\r\nContent-Length: ${contentLength}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`
          : `HTTP/1.1 206 Partial Content\r\nContent-Type: ${this.contentType}\r\nContent-Range: bytes ${this.start}-${this.end}/${totalStr}\r\nContent-Length: ${contentLength}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n`;
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

export async function serveRange(
  conn: socket.TCPSocketConnection,
  resource: StreamResource,
  rangeHeader: string,
  headOnly: boolean,
  standaloneResponse: boolean = false
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
    const hdr = standaloneResponse
      ? `HTTP/1.1 200 OK\r\nContent-Type: ${contentType}\r\nContent-Length: ${end - start + 1}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`
      : `HTTP/1.1 206 Partial Content\r\nContent-Type: ${contentType}\r\nContent-Range: bytes ${start}-${end}/${totalStr}\r\nContent-Length: ${end - start + 1}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n`;
    await sendRaw(conn, encodeStr(hdr));
    return;
  }

  const rangeSpec = `${start}-${end}`;
  let lastError = '';
  const writer = new TcpWriter(conn, start, end, total, contentType, standaloneResponse);

  // YouTube videoplayback: buffer via @ohos.net.http (same stack as extractor).
  // RCP streaming has been 403-prone for TVHTML5 range probes.
  if (resource.isYoutubePlayback) {
    for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
      const fetchUrl = appendYoutubeRn(buildYoutubeRangeUrl(resource.url, rangeSpec), resource.url);
      const headers = headersToHttpRecord(makeYoutubeHeaders(resource));
      const usePost = isAndroidUrl(resource.url) || isIosUrl(resource.url);
      const method = usePost ? 'POST' : 'GET';
      if (attempt === 0) {
        Logger.info(TAG, `serveRange yt: transport=http ${describeYoutubeRequest(resource, method, fetchUrl, rangeSpec)}`);
      }
      const req = http.createHttp();
      try {
        const options: http.HttpRequestOptions = {
          method: usePost ? http.RequestMethod.POST : http.RequestMethod.GET,
          header: headers,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: TIMEOUT_MS,
          readTimeout: TIMEOUT_MS,
          usingCache: false,
        };
        if (usePost) {
          options.extraData = '';
        }
        const response = await req.request(fetchUrl, options);
        if (response.responseCode === 200 || response.responseCode === 206) {
          const bytes = responseBodyToBytes(response.result);
          if (bytes.length === 0) {
            lastError = `empty body status=${response.responseCode}`;
          } else {
            await writer.write(bytes.buffer as ArrayBuffer);
            return;
          }
        } else {
          lastError = `status=${response.responseCode}`;
          const bodyPreview = typeof response.result === 'string'
            ? response.result.substring(0, 120)
            : `bytes=${responseBodyToBytes(response.result).length}`;
          Logger.warn(TAG, `serveRange: upstream ${response.responseCode} resource=${resource.id} `
            + `body=${bodyPreview} ${describeYoutubeRequest(resource, method, fetchUrl, rangeSpec)}`);
          if (response.responseCode >= 400 && response.responseCode < 500) {
            if (!writer.hasEmittedAny()) {
              await sendError(conn, 502, `upstream ${response.responseCode}`);
            }
            return;
          }
        }
      } catch (e) {
        lastError = String(e);
        Logger.warn(TAG, `serveRange attempt=${attempt} error: ${lastError} resource=${resource.id}`);
      } finally {
        req.destroy();
      }
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
    return;
  }

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const sessionHeaders = makeHeaders(resource);
    const rcpSession = rcp.createSession({
      headers: sessionHeaders,
      requestConfiguration: { transfer: { timeout: { connectMs: TIMEOUT_MS, transferMs: TIMEOUT_MS } } }
    });
    try {
      const dest: rcp.DownloadToStream = { kind: 'stream', stream: writer };
      const rangeHeaders: rcp.RequestHeaders = { 'Accept-Encoding': 'identity' };
      if (resource.userAgent) rangeHeaders['User-Agent'] = resource.userAgent;
      if (resource.referer) rangeHeaders['Referer'] = resource.referer;
      rangeHeaders['Range'] = `bytes=${rangeSpec}`;
      const req = new rcp.Request(resource.url, 'GET', rangeHeaders);
      req.destination = dest;
      const resp = await rcpSession.fetch(req);

      if (resp.statusCode === 200 || resp.statusCode === 206) {
        return;
      }
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
