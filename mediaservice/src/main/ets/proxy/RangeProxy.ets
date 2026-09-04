import { StreamResource } from './SessionStore';
import { rcp } from '@kit.RemoteCommunicationKit';
import { http, socket } from '@kit.NetworkKit';
import { url } from '@kit.ArkTS';
import { ClientsConstants, HttpDownloader, HttpProxyOptions } from 'youtube_core';
import Logger from '../utils/Logger';
import { proxyTrafficMeter } from './ProxyTrafficMeter';
import { encodeUtf8, encodeUtf8Bytes } from './ProxyEncoding';
import { upstreamCancelRegistry, UpstreamAbortHandle } from './UpstreamCancelRegistry';
import { rcpSessionPool } from './RcpSessionPool';

const TAG = '[LocalProxy][RangeProxy]';
const MAX_RETRIES = 2;
// PipePipe parity: OkHttp DataSource uses ~8s connect/read timeouts. 10s here
// bounds connect (and socket-read inactivity) so a dead googlevideo edge fails
// into retry quickly instead of stalling the pipeline for 30s.
const CONNECT_TIMEOUT_MS = 10000;
// Total-transfer / read-inactivity budget. RCP transferMs covers the whole
// stream, so it stays generous to avoid aborting long media transfers.
const TIMEOUT_MS = 30000;
const requestNumberMap: Map<string, number> = new Map<string, number>();
/** rn 计数表上限：超出时按插入序淘汰最旧条目，避免全局 Map 随会话数无限增长 */
const REQUEST_NUMBER_MAP_CAP = 512;

function nextRequestNumber(urlKey: string): number {
  const rn = requestNumberMap.get(urlKey) || 0;
  // 删后重插刷新插入序，让淘汰近似 LRU
  requestNumberMap.delete(urlKey);
  requestNumberMap.set(urlKey, rn + 1);
  if (requestNumberMap.size > REQUEST_NUMBER_MAP_CAP) {
    const oldest = requestNumberMap.keys().next();
    if (!oldest.done) {
      requestNumberMap.delete(oldest.value);
    }
  }
  return rn;
}

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

/**
 * Query params of a googlevideo URL via the official url.URL API (@kit.ArkTS).
 * googlevideo videoplayback URLs are absolute https URLs, so construction
 * succeeds in practice; on malformed input we return null and callers keep
 * their "no match" semantics (empty value / flag false / URL unchanged).
 * This replaces per-request regex compilation on the range-fetch hot path.
 */
function getQueryParams(rawUrl: string): url.URLParams | null {
  try {
    return new url.URL(rawUrl).searchParams;
  } catch (_e) {
    return null;
  }
}

function stripQueryParam(rawUrl: string, name: string): string {
  try {
    const parsed = new url.URL(rawUrl);
    parsed.searchParams.delete(name);
    return parsed.toString();
  } catch (_e) {
    // Malformed (non-absolute) input: keep the URL unchanged.
    return rawUrl;
  }
}

function buildYoutubeRangeUrl(rawUrl: string, rangeSpec: string): string {
  // Drop any pre-existing range= so MPV/SIDX never send duplicate range params.
  const cleaned = stripQueryParam(rawUrl, 'range');
  const sep = cleaned.includes('?') ? '&' : '?';
  return cleaned + sep + 'range=' + rangeSpec;
}

function appendYoutubeRn(rawUrl: string, urlKey: string): string {
  let result = stripQueryParam(rawUrl, 'rn');
  const rn = nextRequestNumber(urlKey);
  const sep = result.includes('?') ? '&' : '?';
  return `${result}${sep}rn=${rn}`;
}

function getYoutubeClient(rawUrl: string): string {
  return (getQueryParams(rawUrl)?.get('c') ?? '').toUpperCase();
}

// Fingerprint-only regexes, hoisted to module level so the per-request log
// path does not recompile them. Host capture keeps the authority (host:port),
// matching the previous inline behavior.
const URL_AUTHORITY_RE = /^https?:\/\/([^/?#]+)/i;
const SENSITIVE_PARAM_RE = /([?&])(n|sig|lsig|signature|pot|s)=[^&]*/gi;

/** Safe fingerprint for comparing 403 vs success URLs without leaking sig/n/pot. */
function youtubeUrlFingerprint(rawUrl: string): string {
  let host = '';
  try {
    const m = rawUrl.match(URL_AUTHORITY_RE);
    host = m?.[1] || '';
  } catch (_e) {
    host = '';
  }
  // Short non-crypto digest of path+stable query shape (not secrets themselves).
  let hash = 2166136261;
  const sample = rawUrl.replace(SENSITIVE_PARAM_RE, '$1$2=*');
  for (let i = 0; i < sample.length; i++) {
    hash ^= sample.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  const fp = (hash >>> 0).toString(16).padStart(8, '0');
  // One url.URL parse feeds all fields (params is null only on malformed input).
  const params = getQueryParams(rawUrl);
  const client = (params?.get('c') ?? '').toUpperCase();
  const expire = params?.get('expire') ?? '';
  const rn = params?.get('rn') ?? '';
  const hasSig = (params?.has('sig') ?? false) || (params?.has('signature') ?? false)
    || (params?.has('lsig') ?? false);
  return `host=${host} c=${client || '-'} expire=${expire || '-'} `
    + `rn=${rn || '-'} hasN=${params?.has('n') ?? false} hasPot=${params?.has('pot') ?? false} `
    + `hasSig=${hasSig} fp=${fp}`;
}

// PipePipe YoutubeParsingHelper: ANDROID|ANDROID_VR → POST + Android app UA
function isAndroidUrl(url: string): boolean {
  const c = getYoutubeClient(url);
  return c === 'ANDROID' || c === 'ANDROID_VR' || c.startsWith('ANDROID_');
}

function isIosUrl(url: string): boolean {
  return getYoutubeClient(url) === 'IOS';
}

// PipePipe: VISIONOS videoplayback is a plain GET (not a mobile POST), but it
// must still be streamed — buffering the whole capped chunk before first byte
// adds seconds to TTFF on slow links.
function isVisionOsUrl(url: string): boolean {
  return getYoutubeClient(url) === 'VISIONOS';
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
    h['User-Agent'] = ClientsConstants.ANDROID_USER_AGENT;
  } else if (isIos) {
    h['User-Agent'] = ClientsConstants.IOS_USER_AGENT;
  } else if (resource.userAgent) {
    h['User-Agent'] = resource.userAgent;
  }

  // Do NOT fall back to resource.referer for TVHTML5/MWEB — PipePipe omits it.
  return h;
}

/**
 * Resolve the app proxy onto an rcp.Configuration. Shared by the YouTube
 * streaming session and the generic (non-YouTube) range session:
 * socks5 → loopback bridge URL with createTunnel:'always' (the bridge owns the
 * native SOCKS5 tunnel; without a listening bridge, 'no-proxy'), http → user
 * proxy URL (with user:pass auth when configured) + exclusions, otherwise
 * 'no-proxy'. Bypassed/loopback URLs always resolve to 'no-proxy'.
 */
function resolveRcpProxy(config: rcp.Configuration, url: string): void {
  const snap = HttpProxyOptions.getSnapshot();
  if (snap.kind === 'socks5' && HttpProxyOptions.isActive(snap) && !HttpProxyOptions.shouldBypass(url, snap)) {
    const localPort = snap.socks5LocalPort;
    if (localPort && localPort > 0) {
      config.proxy = {
        url: `http://127.0.0.1:${localPort}`,
        createTunnel: 'always'
      };
    } else {
      config.proxy = 'no-proxy';
    }
  } else if (snap.kind === 'http' && HttpProxyOptions.isActive(snap) && !HttpProxyOptions.shouldBypass(url, snap)) {
    const auth = snap.username
      ? `${encodeURIComponent(snap.username)}:${encodeURIComponent(snap.password || '')}@`
      : '';
    config.proxy = {
      url: `http://${auth}${snap.host.trim()}:${snap.port}`,
      exclusions: snap.exclusionList && snap.exclusionList.length > 0
        ? snap.exclusionList
        : HttpProxyOptions.defaultExclusions()
    };
  } else {
    config.proxy = 'no-proxy';
  }
}

/**
 * RCP session for streamed YouTube videoplayback fetches.
 * Android/iOS: empty-body POST — @ohos.net.http rejects zero-length bodies at
 * parameter validation (NETSTACK error 401) whether extraData is '' or
 * ArrayBuffer(0), and sending no body gets HTTP 411 from googlevideo; RCP
 * accepts an empty-string body and sends Content-Length: 0 — the shape
 * PipePipe's OkHttp path uses. VISIONOS: body-less GET on the same RCP
 * streaming path (first byte must not wait for the whole capped chunk).
 * Other clients' GET stays on @ohos.net.http (RCP streaming was 403-prone
 * for TVHTML5 range probes).
 */
function createYoutubePostSession(url: string): rcp.Session {
  const config: rcp.Configuration = {
    transfer: { timeout: { connectMs: CONNECT_TIMEOUT_MS, transferMs: TIMEOUT_MS } }
  };
  resolveRcpProxy(config, url);
  return rcp.createSession({ requestConfiguration: config });
}

/**
 * Fingerprint of the app-proxy decision for a URL, folded into the pooled
 * RCP session key so a proxy-config change lands on a fresh session instead
 * of reusing one built with stale proxy settings.
 */
function rcpProxyFingerprint(rawUrl: string): string {
  const snap = HttpProxyOptions.getSnapshot();
  if (!HttpProxyOptions.isActive(snap) || HttpProxyOptions.shouldBypass(rawUrl, snap)) {
    return 'direct';
  }
  if (snap.kind === 'socks5') {
    return `socks5:${snap.socks5LocalPort ?? 0}`;
  }
  if (snap.kind === 'http') {
    return `http:${snap.host.trim()}:${snap.port}:${snap.username}`;
  }
  return 'direct';
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

/** NETSTACK BusinessError does not stringify via String() — log code/message explicitly. */
function describeError(e: Object): string {
  if (e instanceof Error) return `${e.name}: ${e.message}`;
  try {
    return JSON.stringify(e);
  } catch (_e) {
    return String(e);
  }
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
    return encodeUtf8Bytes(result);
  }
  try {
    return new Uint8Array(result as ArrayBuffer);
  } catch (_e) {
    return new Uint8Array(0);
  }
}

/**
 * Fetch a small exact YouTube byte range for DASH SIDX preprocessing.
 * Android/iOS: empty-body POST over RCP (see createYoutubePostSession).
 * Other clients: GET via @ohos.net.http (same stack as youtube_core
 * extractor) — RCP streaming has produced consistent 403 on TVHTML5
 * indexRange probes.
 */
export async function fetchYoutubeRangeBytes(
  resource: StreamResource,
  start: number,
  end: number
): Promise<Uint8Array> {
  const rangeSpec = `${start}-${end}`;
  const fetchUrl = appendYoutubeRn(buildYoutubeRangeUrl(resource.url, rangeSpec), resource.url);
  const usePost = isAndroidUrl(resource.url) || isIosUrl(resource.url);
  if (usePost) {
    Logger.info(TAG, `SIDX fetch: transport=rcp ${describeYoutubeRequest(resource, 'POST', fetchUrl, rangeSpec)}`);
    const rcpSession = createYoutubePostSession(fetchUrl);
    try {
      const dest = new BufferWriter();
      const req = new rcp.Request(fetchUrl, 'POST', makeYoutubeHeaders(resource), '');
      req.destination = { kind: 'stream', stream: dest };
      const resp = await rcpSession.fetch(req);
      if (resp.statusCode !== 200 && resp.statusCode !== 206) {
        Logger.warn(TAG, `SIDX upstream ${resp.statusCode}: transport=rcp `
          + `${describeYoutubeRequest(resource, 'POST', fetchUrl, rangeSpec)}`);
        throw new Error(`SIDX upstream status ${resp.statusCode}`);
      }
      const bytes = dest.bytes();
      Logger.info(TAG, `SIDX ok itag=${resource.id} bytes=${bytes.length} range=${rangeSpec} transport=rcp`);
      return bytes;
    } finally {
      rcpSession.close();
    }
  }
  const headers = headersToHttpRecord(makeYoutubeHeaders(resource));
  Logger.info(TAG, `SIDX fetch: transport=http ${describeYoutubeRequest(resource, 'GET', fetchUrl, rangeSpec)}`);
  const req = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: CONNECT_TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      usingCache: false,
    };
    HttpDownloader.applyProxyToOptions(options, fetchUrl);
    const response = await req.request(fetchUrl, options);
    if (response.responseCode !== 200 && response.responseCode !== 206) {
      const bodyPreview = typeof response.result === 'string'
        ? response.result.substring(0, 160)
        : `bytes=${responseBodyToBytes(response.result).length}`;
      Logger.warn(TAG, `SIDX upstream ${response.responseCode}: transport=http body=${bodyPreview} `
        + `${describeYoutubeRequest(resource, 'GET', fetchUrl, rangeSpec)}`);
      throw new Error(`SIDX upstream status ${response.responseCode}`);
    }
    const bytes = responseBodyToBytes(response.result);
    Logger.info(TAG, `SIDX ok itag=${resource.id} bytes=${bytes.length} range=${rangeSpec} transport=http`);
    return bytes;
  } finally {
    req.destroy();
  }
}

/**
 * Fire-and-forget RCP pre-connect (API 24 `connectOnly`): warms TCP/TLS to
 * the googlevideo host(s) of a just-committed source on the SAME pooled
 * session the later range fetches acquire, so MPV's first upstream fetch
 * skips the handshake. Only streaming-branch clients (Android/iOS empty-body
 * POST and VISIONOS GET) fetch over RCP — other clients use buffered netstack
 * http, so their hosts are skipped. Never blocks source commit; failure is
 * WARN-only and leaves playback untouched (the first fetch simply pays the
 * handshake as before).
 */
export function preconnectYoutubeHosts(sessionId: string, urls: string[]): void {
  if (!sessionId) {
    return;
  }
  const hosts: string[] = [];
  for (const u of urls) {
    if (!u) {
      continue;
    }
    if (!isAndroidUrl(u) && !isIosUrl(u) && !isVisionOsUrl(u)) {
      continue;
    }
    const authority = u.match(URL_AUTHORITY_RE)?.[1] || '';
    if (authority && !hosts.includes(authority)) {
      hosts.push(authority);
    }
  }
  for (const authority of hosts) {
    const warmUrl = `https://${authority}/`;
    const entry = rcpSessionPool.acquire(`${sessionId}|${rcpProxyFingerprint(warmUrl)}`,
      () => createYoutubePostSession(warmUrl));
    if (entry.warmedHosts.has(authority)) {
      continue;
    }
    entry.warmedHosts.add(authority);
    const req = new rcp.Request(warmUrl, 'GET');
    req.connectOnly = true;
    Logger.info(TAG, `preconnect start session=${sessionId} host=${authority}`);
    entry.session.fetch(req).then(() => {
      Logger.debug(TAG, `preconnect done session=${sessionId} host=${authority}`);
    }).catch((e: Object) => {
      Logger.warn(TAG, `preconnect failed session=${sessionId} host=${authority}: ${describeError(e)}`);
    });
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
  if (!match[1] && match[2]) {
    // RFC 7233 suffix-byte-range-spec: bytes=-N requests the LAST N bytes,
    // not bytes 0-N. Resolvable only when the total length is known; with an
    // unknown total the caller rejects the request with 416.
    const suffixLen = parseInt(match[2], 10);
    if (suffixLen > 0 && totalLength > 0) {
      result.start = Math.max(0, totalLength - suffixLen);
      result.end = totalLength - 1;
    }
    return result;
  }
  if (match[1]) result.start = parseInt(match[1], 10);
  if (match[2]) result.end = parseInt(match[2], 10);
  else if (totalLength > 0) result.end = totalLength - 1;
  return result;
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
    await sendRaw(conn, encodeUtf8(hdr + body));
  } catch (_e) {}
}

/**
 * Per-session consecutive upstream-failure circuit breaker. MPV runs with
 * reconnect_at_eof=1, so every 502 (sent with Connection: close) makes FFmpeg
 * reconnect — against a dead/expired URL that is an unbounded loop of ~3
 * upstream requests every ~8s that never converges. After
 * UPSTREAM_FAILURE_CIRCUIT_THRESHOLD consecutive failure responses for the same
 * session we answer 410 Gone instead: FFmpeg treats 410 as fatal and stops
 * reconnecting. Any successfully served range resets the counter.
 */
const UPSTREAM_FAILURE_CIRCUIT_THRESHOLD = 5;
const upstreamFailureCountMap: Map<string, number> = new Map<string, number>();
/** 熔断计数表上限：超出时按插入序淘汰最旧条目，避免随会话数无限增长 */
const UPSTREAM_FAILURE_MAP_CAP = 512;

function noteUpstreamServeSuccess(sessionId: string): void {
  if (sessionId) {
    upstreamFailureCountMap.delete(sessionId);
  }
}

async function sendUpstreamFailure(conn: socket.TCPSocketConnection, sessionId: string, msg: string): Promise<void> {
  let count = 0;
  if (sessionId) {
    count = (upstreamFailureCountMap.get(sessionId) || 0) + 1;
    // 删后重插刷新插入序，让淘汰近似 LRU
    upstreamFailureCountMap.delete(sessionId);
    upstreamFailureCountMap.set(sessionId, count);
    if (upstreamFailureCountMap.size > UPSTREAM_FAILURE_MAP_CAP) {
      const oldest = upstreamFailureCountMap.keys().next();
      if (!oldest.done) {
        upstreamFailureCountMap.delete(oldest.value);
      }
    }
  }
  if (count >= UPSTREAM_FAILURE_CIRCUIT_THRESHOLD) {
    Logger.warn(TAG, `circuit open session=${sessionId} consecutiveFailures=${count} → 410 `
      + `(stops FFmpeg reconnect loop) msg=${msg}`);
    await sendError(conn, 410, `upstream gone: ${msg}`);
    return;
  }
  await sendError(conn, 502, msg);
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
  /** Fired once when a send failure marks the connection dead (MPV went away). */
  onClosed?: () => void;

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

  isClosed(): boolean {
    return this.closed;
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
        await this.conn.send({ data: encodeUtf8(hdr) });
        this.headerSent = true;
      }
      await this.conn.send({ data: buffer });
      this.bytesEmitted += buffer.byteLength;
      return buffer.byteLength;
    } catch (e) {
      this.closed = true;
      Logger.warn(TAG, `TcpWriter.write failed (conn closed?): ${(e as Error).message}`);
      // The client is gone: let the fetch path cancel the in-flight upstream
      // request instead of downloading the rest of the chunk into a dead writer.
      try {
        this.onClosed?.();
      } catch (_e) {
      }
      return 0;
    }
  }
}

/**
 * WriteStream wrapper that meters inbound network bytes. RCP invokes write()
 * once per received upstream chunk, so each call's byte count is fresh network
 * traffic; the wrapped writer's loopback send to MPV is not metered.
 */
class MeteredWriteStream implements rcp.WriteStream {
  private inner: rcp.WriteStream;

  constructor(inner: rcp.WriteStream) {
    this.inner = inner;
  }

  async write(buffer: ArrayBuffer): Promise<void | number> {
    proxyTrafficMeter.recordBytes(buffer.byteLength);
    return this.inner.write(buffer);
  }
}

/**
 * 带重试的上游拉取结果。三个 serveRange 分支共用同一循环骨架,只参数化
 * 传输差异:
 * - success: 数据已全部写入 writer,立即结束;
 * - retry:   可重试失败,error 记入 lastError;retryDelayMs 提供分支专属
 *            退避(如 YouTube 403/410 的 1000*(n+1)),缺省走 300*(n+1);
 * - fatal:   终态失败(分支内部已自行应答,如 4xx → 502),不再重试。
 */
type FetchAttemptOutcome = 'success' | 'retry' | 'fatal';

interface FetchAttemptResult {
  outcome: FetchAttemptOutcome;
  error?: string;
  retryDelayMs?: number;
}

interface UpstreamRetryHooks {
  /** 单次上游尝试(含分支专属日志与状态判定) */
  fetchOnce: (attempt: number) => Promise<FetchAttemptResult>;
  /** 每次尝试后释放传输句柄(RCP session.close / http.destroy) */
  cleanup: () => void;
  /** 异常 → 日志文本(YouTube 分支用 describeError,非 YouTube 分支沿用 String(e)) */
  describeError: (e: Object) => string;
  /**
   * 连接/会话被撤销（MPV 断开、destroySession）时为 true：中止是正常拆链，
   * 不重试、不应答错误页、只留 DEBUG 日志。
   */
  isAborted?: () => boolean;
}

/**
 * serveRange 的共用重试循环:MAX_RETRIES 次尝试、partial-write 短路
 * (writer.hasEmittedAny() 后绝不再重试)、默认 300*(attempt+1) 退避,
 * 循环耗尽后经每会话熔断器 sendUpstreamFailure 应答(连续失败达阈值时
 * 410 而非 502,阻止 FFmpeg reconnect_at_eof 无限重连)。各分支的退避公式
 * 与错误格式由 hooks 参数化,不在此统一。
 */
async function fetchUpstreamWithRetries(
  hooks: UpstreamRetryHooks,
  writer: TcpWriter,
  conn: socket.TCPSocketConnection,
  resourceId: string,
  rangeSpec: string,
  sessionId: string = ''
): Promise<void> {
  let lastError = '';
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    let retryDelayMs: number = 0;
    try {
      const result = await hooks.fetchOnce(attempt);
      if (result.outcome === 'success') {
        noteUpstreamServeSuccess(sessionId);
        return;
      }
      if (result.outcome === 'fatal') {
        return;
      }
      lastError = result.error ?? '';
      retryDelayMs = result.retryDelayMs ?? 0;
    } catch (e) {
      lastError = hooks.describeError(e as Object);
      if (!hooks.isAborted?.()) {
        Logger.warn(TAG, `serveRange attempt=${attempt} error: ${lastError} resource=${resourceId}`);
      }
    } finally {
      hooks.cleanup();
    }
    if (hooks.isAborted?.()) {
      // Aborted by connection/session teardown — quiet exit, never retry.
      Logger.debug(TAG, `serveRange aborted (conn/session teardown) resource=${resourceId} range=${rangeSpec}`);
      return;
    }
    if (writer.hasEmittedAny()) {
      Logger.error(TAG, `serveRange: aborting retry after partial write, resource=${resourceId} range=${rangeSpec} err=${lastError}`);
      return;
    }
    if (attempt < MAX_RETRIES) {
      await new Promise<void>(r => setTimeout(r, retryDelayMs > 0 ? retryDelayMs : 300 * (attempt + 1)));
      if (hooks.isAborted?.()) {
        Logger.debug(TAG, `serveRange aborted during retry backoff resource=${resourceId} range=${rangeSpec}`);
        return;
      }
    }
  }
  Logger.error(TAG, `serveRange failed: ${lastError} resource=${resourceId}`);
  if (!writer.hasEmittedAny()) {
    await sendUpstreamFailure(conn, sessionId, `upstream failed: ${lastError}`);
  }
}

/**
 * YouTube videoplayback range fetch shared by serveRange (open progressive
 * ranges) and serveExactSegmentRange (exact DASH segments). Android/iOS:
 * empty-body POST over RCP (see createYoutubePostSession), streamed straight
 * to the socket. Other clients: buffered GET via @ohos.net.http (same stack
 * as the extractor) — RCP streaming has been 403-prone for TVHTML5 range
 * probes.
 */
async function serveYoutubeRangeWithRetries(
  conn: socket.TCPSocketConnection,
  resource: StreamResource,
  rangeSpec: string,
  writer: TcpWriter,
  markAborted: () => void,
  isAborted: () => boolean,
  sessionId: string
): Promise<void> {
  const usePost = isAndroidUrl(resource.url) || isIosUrl(resource.url);
  const useStreamingGet = !usePost && isVisionOsUrl(resource.url);
  if (usePost || useStreamingGet) {
    const method = usePost ? 'POST' : 'GET';
    let rcpSession: rcp.Session | null = null;
    // Pooled sessions are long-lived (shared per proxy session so the
    // connectOnly pre-connect warms the very connection pool MPV's fetches
    // hit) and must NOT be closed per attempt; only the legacy per-attempt
    // fallback (no sessionId) is closed in cleanup.
    let pooledSession = false;
    let abortHandle: UpstreamAbortHandle | null = null;
    await fetchUpstreamWithRetries({
      fetchOnce: async (attempt: number): Promise<FetchAttemptResult> => {
        const fetchUrl = appendYoutubeRn(buildYoutubeRangeUrl(resource.url, rangeSpec), resource.url);
        if (attempt === 0) {
          Logger.info(TAG, `serveRange yt: transport=rcp ${describeYoutubeRequest(resource, method, fetchUrl, rangeSpec)}`);
        }
        if (sessionId) {
          rcpSession = rcpSessionPool.acquire(`${sessionId}|${rcpProxyFingerprint(fetchUrl)}`,
            () => createYoutubePostSession(fetchUrl)).session;
          pooledSession = true;
        } else {
          rcpSession = createYoutubePostSession(fetchUrl);
        }
        // GET must not carry a body (PipePipe plain GET); POST keeps the
        // empty-string body — googlevideo 411s on a body-less POST.
        const req = usePost
          ? new rcp.Request(fetchUrl, method, makeYoutubeHeaders(resource), '')
          : new rcp.Request(fetchUrl, method, makeYoutubeHeaders(resource));
        req.destination = { kind: 'stream', stream: new MeteredWriteStream(writer) };
        const sessionRef = rcpSession;
        abortHandle = upstreamCancelRegistry.register(sessionId, conn, () => {
          markAborted();
          sessionRef.cancel(req);
        });
        const resp = await rcpSession.fetch(req);
        if (resp.statusCode === 200 || resp.statusCode === 206) {
          return { outcome: 'success' };
        }
        Logger.warn(TAG, `serveRange: upstream ${resp.statusCode} resource=${resource.id} `
          + `${describeYoutubeRequest(resource, method, fetchUrl, rangeSpec)}`);
        if (resp.statusCode >= 400 && resp.statusCode < 500) {
          if (resp.statusCode === 403 || resp.statusCode === 410) {
            // YouTube 流未就绪/处理中窗口:有界退避重试而非立即失败
            // (对齐 PipePipe reloadPlayQueueManager / SmartTube reloadVideo 的原地重试语义)
            const retryDelayMs = 1000 * (attempt + 1);
            Logger.warn(TAG, `serveRange: upstream ${resp.statusCode} retryable, backoff=${retryDelayMs}ms attempt=${attempt} resource=${resource.id} range=${rangeSpec}`);
            return { outcome: 'retry', error: `status=${resp.statusCode}`, retryDelayMs };
          }
          if (!writer.hasEmittedAny()) {
            await sendUpstreamFailure(conn, sessionId, `upstream ${resp.statusCode}`);
          }
          return { outcome: 'fatal' };
        }
        return { outcome: 'retry', error: `status=${resp.statusCode}` };
      },
      cleanup: () => {
        if (abortHandle) {
          upstreamCancelRegistry.unregister(conn, abortHandle);
          abortHandle = null;
        }
        if (!pooledSession) {
          rcpSession?.close();
        }
        rcpSession = null;
        pooledSession = false;
      },
      describeError: describeError,
      isAborted: isAborted
    }, writer, conn, resource.id, rangeSpec, sessionId);
    return;
  }
  let req: http.HttpRequest | null = null;
  let httpAbortHandle: UpstreamAbortHandle | null = null;
  await fetchUpstreamWithRetries({
    fetchOnce: async (attempt: number): Promise<FetchAttemptResult> => {
      const fetchUrl = appendYoutubeRn(buildYoutubeRangeUrl(resource.url, rangeSpec), resource.url);
      const headers = headersToHttpRecord(makeYoutubeHeaders(resource));
      if (attempt === 0) {
        Logger.info(TAG, `serveRange yt: transport=http ${describeYoutubeRequest(resource, 'GET', fetchUrl, rangeSpec)}`);
      }
      req = http.createHttp();
      const reqRef = req;
      httpAbortHandle = upstreamCancelRegistry.register(sessionId, conn, () => {
        markAborted();
        reqRef.destroy();
      });
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: TIMEOUT_MS,
        usingCache: false,
      };
      HttpDownloader.applyProxyToOptions(options, fetchUrl);
      const response = await req.request(fetchUrl, options);
      if (response.responseCode === 200 || response.responseCode === 206) {
        const bytes = responseBodyToBytes(response.result);
        if (bytes.length === 0) {
          return { outcome: 'retry', error: `empty body status=${response.responseCode}` };
        }
        if (writer.isClosed()) {
          // Connection died while the body was buffering — nothing to serve.
          Logger.debug(TAG, `serveRange: conn closed before buffered write resource=${resource.id} range=${rangeSpec}`);
          return { outcome: 'fatal' };
        }
        // Buffered GET: the whole body already arrived from the network here.
        proxyTrafficMeter.recordBytes(bytes.length);
        await writer.write(bytes.buffer as ArrayBuffer);
        return { outcome: 'success' };
      }
      const bodyPreview = typeof response.result === 'string'
        ? response.result.substring(0, 120)
        : `bytes=${responseBodyToBytes(response.result).length}`;
      Logger.warn(TAG, `serveRange: upstream ${response.responseCode} resource=${resource.id} `
        + `body=${bodyPreview} ${describeYoutubeRequest(resource, 'GET', fetchUrl, rangeSpec)}`);
      if (response.responseCode >= 400 && response.responseCode < 500) {
        if (response.responseCode === 403 || response.responseCode === 410) {
          // YouTube 流未就绪/处理中窗口:有界退避重试而非立即失败
          // (对齐 PipePipe reloadPlayQueueManager / SmartTube reloadVideo 的原地重试语义)
          const retryDelayMs = 1000 * (attempt + 1);
          Logger.warn(TAG, `serveRange: upstream ${response.responseCode} retryable, backoff=${retryDelayMs}ms attempt=${attempt} resource=${resource.id} range=${rangeSpec}`);
          return { outcome: 'retry', error: `status=${response.responseCode}`, retryDelayMs };
        }
        if (!writer.hasEmittedAny()) {
          await sendUpstreamFailure(conn, sessionId, `upstream ${response.responseCode}`);
        }
        return { outcome: 'fatal' };
      }
      return { outcome: 'retry', error: `status=${response.responseCode}` };
    },
    cleanup: () => {
      if (httpAbortHandle) {
        upstreamCancelRegistry.unregister(conn, httpAbortHandle);
        httpAbortHandle = null;
      }
      req?.destroy();
      req = null;
    },
    describeError: describeError,
    isAborted: isAborted
  }, writer, conn, resource.id, rangeSpec, sessionId);
}

/**
 * youtube-dual exact DASH segment serving: a single standalone 200 response
 * whose Content-Length covers the WHOLE [start, end] segment. Upstream is
 * fetched in ≤10MB slices (YouTube throttles larger ranges, see serveRange's
 * MAX_CHUNK_SIZE) written sequentially into the same writer, so MPV always
 * sees a complete segment — a truncated segment would read as an early-EOF
 * timestamp hole to the DASH timeline.
 */
export async function serveExactSegmentRange(
  conn: socket.TCPSocketConnection,
  resource: StreamResource,
  start: number,
  end: number,
  headOnly: boolean,
  sessionId: string
): Promise<void> {
  const contentType = contentTypeFor(resource);
  if (headOnly) {
    const hdr = `HTTP/1.1 200 OK\r\nContent-Type: ${contentType}\r\nContent-Length: ${end - start + 1}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`;
    await sendRaw(conn, encodeUtf8(hdr));
    return;
  }
  if (!resource.isYoutubePlayback) {
    Logger.error(TAG, `serveExactSegmentRange: non-YouTube resource=${resource.id}, refusing`);
    await sendError(conn, 502, 'exact segments require a YouTube resource');
    return;
  }
  const writer = new TcpWriter(conn, start, end, resource.contentLength, contentType, true);
  let aborted = false;
  writer.onClosed = () => {
    aborted = true;
    upstreamCancelRegistry.cancelConnection(conn);
  };
  // Slice bound mirrors serveRange's MAX_CHUNK_SIZE.
  const MAX_SLICE_SIZE = 10 * 1024 * 1024;
  let sliceStart = start;
  while (sliceStart <= end && !aborted && !writer.isClosed()) {
    const sliceEnd = Math.min(sliceStart + MAX_SLICE_SIZE - 1, end);
    const rangeSpec = `${sliceStart}-${sliceEnd}`;
    const expectedBytes = sliceEnd - start + 1;
    await serveYoutubeRangeWithRetries(conn, resource, rangeSpec, writer,
      () => { aborted = true; }, () => aborted, sessionId);
    if (writer.bytesEmitted < expectedBytes) {
      // Slice failed after retries (or the connection died): the response is
      // truncated either way, so stop here and let MPV hit EOF.
      if (!aborted) {
        Logger.error(TAG, `serveExactSegmentRange: short slice resource=${resource.id} `
          + `range=${rangeSpec} emitted=${writer.bytesEmitted}/${expectedBytes}`);
      }
      return;
    }
    sliceStart = sliceEnd + 1;
  }
  if (end - start + 1 > MAX_SLICE_SIZE) {
    Logger.info(TAG, `serveExactSegmentRange: sliced ${Math.ceil((end - start + 1) / MAX_SLICE_SIZE)}x `
      + `resource=${resource.id} range=${start}-${end}`);
  }
}

export async function serveRange(
  conn: socket.TCPSocketConnection,
  resource: StreamResource,
  rangeHeader: string,
  headOnly: boolean,
  standaloneResponse: boolean = false,
  sessionId: string = ''
): Promise<void> {
  const total = resource.contentLength;
  if (total <= 0 && /^\s*bytes=-\d+\s*$/.test(rangeHeader)) {
    // Suffix range (bytes=-N) needs the total size (RFC 7233); it is unknown
    // for this resource, and serving bytes 0-N instead would be wrong data.
    Logger.warn(TAG, `serveRange: suffix range with unknown total → 416 resource=${resource.id} range=${rangeHeader}`);
    await sendError(conn, 416, 'suffix range requires known content length');
    return;
  }
  const parsed = parseRangeHeader(rangeHeader, total);
  const start = parsed.start;
  let end = parsed.end >= 0 ? parsed.end : (total > 0 ? total - 1 : start + 2 * 1024 * 1024 - 1);

  // Cap a single upstream fetch at 10MB — YouTube throttles large range
  // requests (~80KB/s), and a bounded in-flight download keeps seek cheap.
  // FFmpeg reconnects at the truncated EOF (reconnect_at_eof=1) and continues
  // with the next range, so playback is unaffected.
  const MAX_CHUNK_SIZE = 10 * 1024 * 1024;
  if (end - start + 1 > MAX_CHUNK_SIZE) {
    end = start + MAX_CHUNK_SIZE - 1;
    Logger.info(TAG, `serveRange: chunk-capped to ${MAX_CHUNK_SIZE} bytes resource=${resource.id} start=${start}`);
  }

  const contentType = contentTypeFor(resource);

  Logger.debug(TAG, `serveRange: resource=${resource.id} range=${start}-${end}/${total} headOnly=${headOnly}`);

  // AVPlayer sends 1-byte probe at file end; YouTube rejects these with 400.
  // Return empty 206 to satisfy the player without hitting upstream.
  if (start === end && total > 0 && start >= total) {
    const hdr = `HTTP/1.1 206 Partial Content\r\nContent-Type: ${contentType}\r\nContent-Range: bytes ${total - 1}-${total - 1}/${total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`;
    await sendRaw(conn, encodeUtf8(hdr));
    return;
  }

  if (headOnly) {
    const totalStr = total > 0 ? String(total) : '*';
    const hdr = standaloneResponse
      ? `HTTP/1.1 200 OK\r\nContent-Type: ${contentType}\r\nContent-Length: ${end - start + 1}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`
      : `HTTP/1.1 206 Partial Content\r\nContent-Type: ${contentType}\r\nContent-Range: bytes ${start}-${end}/${totalStr}\r\nContent-Length: ${end - start + 1}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n`;
    await sendRaw(conn, encodeUtf8(hdr));
    return;
  }

  const rangeSpec = `${start}-${end}`;
  const writer = new TcpWriter(conn, start, end, total, contentType, standaloneResponse);
  // Set once the connection/session teardown cancels an in-flight upstream op;
  // the retry loop treats it as quiet teardown (no retry, no error response).
  let aborted = false;
  // MPV closed the socket mid-stream (seek/disconnect): cancel this
  // connection's in-flight upstream fetch instead of downloading into the
  // dead writer (up to a full 10MB chunk per track would be wasted).
  writer.onClosed = () => {
    aborted = true;
    upstreamCancelRegistry.cancelConnection(conn);
  };

  // YouTube videoplayback is served by serveYoutubeRangeWithRetries (shared
  // with the exact DASH segment path below).
  if (resource.isYoutubePlayback) {
    await serveYoutubeRangeWithRetries(conn, resource, rangeSpec, writer,
      () => { aborted = true; }, () => aborted, sessionId);
    return;
  }

  let rcpSession: rcp.Session | null = null;
  let plainAbortHandle: UpstreamAbortHandle | null = null;
  await fetchUpstreamWithRetries({
    fetchOnce: async (_attempt: number): Promise<FetchAttemptResult> => {
      const sessionHeaders = makeHeaders(resource);
      // 非 YouTube 资源（字幕等）同样要走应用代理；与 createYoutubePostSession 共用代理解析。
      const config: rcp.Configuration = {
        transfer: { timeout: { connectMs: CONNECT_TIMEOUT_MS, transferMs: TIMEOUT_MS } }
      };
      resolveRcpProxy(config, resource.url);
      rcpSession = rcp.createSession({
        headers: sessionHeaders,
        requestConfiguration: config
      });
      const dest: rcp.DownloadToStream = { kind: 'stream', stream: writer };
      // UA/Referer/Accept-Encoding are already set as session headers via
      // makeHeaders above; request headers only add Range (a repeated
      // request-level header would just override the session value).
      const rangeHeaders: rcp.RequestHeaders = { 'Range': `bytes=${rangeSpec}` };
      const req = new rcp.Request(resource.url, 'GET', rangeHeaders);
      req.destination = dest;
      const sessionRef = rcpSession;
      plainAbortHandle = upstreamCancelRegistry.register(sessionId, conn, () => {
        aborted = true;
        sessionRef.cancel(req);
      });
      const resp = await rcpSession.fetch(req);

      if (resp.statusCode === 200 || resp.statusCode === 206) {
        return { outcome: 'success' };
      }
      if (resp.statusCode >= 400 && resp.statusCode < 500) {
        Logger.warn(TAG, `serveRange: upstream ${resp.statusCode} (non-retryable) resource=${resource.id} range=${rangeSpec}`);
        if (!writer.hasEmittedAny()) {
          await sendUpstreamFailure(conn, sessionId, `upstream ${resp.statusCode}`);
        }
        return { outcome: 'fatal' };
      }
      return { outcome: 'retry', error: `status=${resp.statusCode}` };
    },
    cleanup: () => {
      if (plainAbortHandle) {
        upstreamCancelRegistry.unregister(conn, plainAbortHandle);
        plainAbortHandle = null;
      }
      rcpSession?.close();
      rcpSession = null;
    },
    describeError: (e: Object) => String(e),
    isAborted: () => aborted
  }, writer, conn, resource.id, rangeSpec, sessionId);
}
