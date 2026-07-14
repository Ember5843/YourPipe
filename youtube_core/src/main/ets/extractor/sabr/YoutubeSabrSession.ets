import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { ClientsConstants } from '../../model/ClientsConstants';
import { SabrDecodedResponse } from './SabrDecodedResponse';
import { SabrMediaSegment, SabrSegmentRequest } from './SabrMediaSegment';
import { SabrProtocolException } from './SabrProtocolException';
import { requireUmpContentType, sabrDecodeBody } from './SabrResponseDecoder';
import { SabrPoTokenProvider } from './SabrPoTokenProvider';
import { YoutubeSabrFormatMeta, YoutubeSabrInfo } from './YoutubeSabrInfo';
import { YoutubeSabrRequestBuilder } from './YoutubeSabrRequestBuilder';
import { YoutubeSabrStreamState } from './YoutubeSabrStreamState';

const logger = YTCoreLogger.getInstance('YoutubeSabrSession');

const MAX_REQUESTS_PER_SEGMENT = 16;
const MAX_POLICY_ONLY_RESPONSES = 3;
const MAX_REDIRECTS = 3;
const MAX_PO_TOKEN_REFRESHES = 2;
const MAX_BACKOFF_MS = 30000;
const MAX_CACHE_BYTES = 32 * 1024 * 1024;
const SEEK_KEEP_WINDOW_MS = 8000;
const EVICT_BEHIND_MS = 10000;

/**
 * Stateful SABR media session (PipePipe YoutubeSabrSession subset for VOD).
 * POSTs protobuf to serverAbrStreamingUrl, parses UMP, caches init/media segments.
 */
export class YoutubeSabrSession {
  private info: YoutubeSabrInfo;
  private audioFormat: YoutubeSabrFormatMeta;
  private videoFormat: YoutubeSabrFormatMeta;
  private streamState: YoutubeSabrStreamState;
  private httpClient: YouTubeHttpClient;
  private poTokenProvider?: SabrPoTokenProvider;
  private serverAbrStreamingUrl: string;
  private requestNumber: number = 0;
  private redirectCount: number = 0;
  private poTokenRefreshes: number = 0;
  private segmentCache: Map<string, SabrMediaSegment> = new Map();
  private cacheOrder: string[] = [];
  private cachedBytes: number = 0;
  private playHeadMs: number = 0;
  private closed: boolean = false;
  private useAuth: boolean = false;

  constructor(
    info: YoutubeSabrInfo,
    audioFormat: YoutubeSabrFormatMeta,
    videoFormat: YoutubeSabrFormatMeta,
    httpClient: YouTubeHttpClient,
    poTokenProvider?: SabrPoTokenProvider,
    useAuth: boolean = false
  ) {
    if (!audioFormat.isAudio) {
      throw new SabrProtocolException(`SABR audio format must be audio: itag=${audioFormat.itag}`);
    }
    if (!videoFormat.isVideo) {
      throw new SabrProtocolException(`SABR video format must be video: itag=${videoFormat.itag}`);
    }
    if (!info.serverAbrStreamingUrl) {
      throw new SabrProtocolException('Missing SABR streaming URL');
    }
    this.info = info;
    this.audioFormat = audioFormat;
    this.videoFormat = videoFormat;
    this.httpClient = httpClient;
    this.poTokenProvider = poTokenProvider;
    this.useAuth = useAuth;
    this.streamState = new YoutubeSabrStreamState(audioFormat, videoFormat);
    this.serverAbrStreamingUrl = info.serverAbrStreamingUrl;
  }

  getStreamState(): YoutubeSabrStreamState {
    return this.streamState;
  }

  getInfo(): YoutubeSabrInfo {
    return this.info;
  }

  getAudioFormat(): YoutubeSabrFormatMeta {
    return this.audioFormat;
  }

  getVideoFormat(): YoutubeSabrFormatMeta {
    return this.videoFormat;
  }

  setPlayHeadMs(ms: number): void {
    this.playHeadMs = Math.max(0, ms);
  }

  close(): void {
    this.closed = true;
    this.segmentCache.clear();
    this.cacheOrder = [];
    this.cachedBytes = 0;
  }

  getCachedSegment(request: SabrSegmentRequest): SabrMediaSegment | undefined {
    return this.segmentCache.get(request.cacheKey());
  }

  listCachedKeys(): string[] {
    const keys: string[] = [];
    this.segmentCache.forEach((_v: SabrMediaSegment, k: string) => {
      keys.push(k);
    });
    return keys;
  }

  /**
   * Ensure a segment is available (init or media sequence). Pumps the session until found or budget spent.
   */
  async fetchSegment(request: SabrSegmentRequest): Promise<SabrMediaSegment> {
    if (this.closed) {
      throw new SabrProtocolException('SABR session closed');
    }
    const cached = this.segmentCache.get(request.cacheKey());
    if (cached) {
      return cached;
    }

    let policyOnly = 0;
    for (let attempt = 0; attempt < MAX_REQUESTS_PER_SEGMENT; attempt++) {
      if (this.closed) {
        throw new SabrProtocolException('SABR session closed');
      }
      const decoded = await this.pumpOnce();
      const hit = this.segmentCache.get(request.cacheKey());
      if (hit) {
        return hit;
      }
      if (decoded.sabrError) {
        throw new SabrProtocolException(
          `SABR error while fetching ${request.cacheKey()}: ${decoded.sabrError}`);
      }
      if (decoded.reloadRequested) {
        throw new SabrProtocolException(
          `SABR reload requested (not auto-reprobed yet): ${decoded.summarizeNoMediaResponse()}`);
      }
      if (decoded.isProtectionBoundaryNoMediaResponse()) {
        const applied = await this.applyPoTokenForProtectedResponse();
        if (!applied) {
          throw new SabrProtocolException(
            `SABR protected no-media: ${decoded.summarizeNoMediaResponse()}`);
        }
        if (decoded.backoffTimeMs > 0) {
          await sleepMs(Math.min(decoded.backoffTimeMs, MAX_BACKOFF_MS));
        }
        continue;
      }
      if (decoded.isPolicyOnlyResponse()) {
        policyOnly++;
        if (policyOnly >= MAX_POLICY_ONLY_RESPONSES) {
          throw new SabrProtocolException(
            `SABR repeated policy-only responses: ${decoded.summarizeNoMediaResponse()}`);
        }
        if (decoded.backoffTimeMs > 0) {
          await sleepMs(Math.min(decoded.backoffTimeMs, MAX_BACKOFF_MS));
        }
        continue;
      }
      if (decoded.backoffTimeMs > 0) {
        await sleepMs(Math.min(decoded.backoffTimeMs, 2000));
      }
    }
    throw new SabrProtocolException(`SABR segment not available: ${request.cacheKey()}`);
  }

  /**
   * One POST + UMP decode + cache ingest. Returns decoded control summary.
   */
  async pumpOnce(): Promise<SabrDecodedResponse> {
    if (this.closed) {
      throw new SabrProtocolException('SABR session closed');
    }
    await this.maybeApplyPoToken(false);

    const isFirst = this.requestNumber === 0
      && !this.streamState.isInitialized(this.audioFormat)
      && !this.streamState.isInitialized(this.videoFormat);
    const body = isFirst
      ? YoutubeSabrRequestBuilder.buildFirstMediaRequest(
        this.info, this.audioFormat, this.videoFormat, this.streamState)
      : YoutubeSabrRequestBuilder.buildFollowUpMediaRequest(
        this.info, this.audioFormat, this.videoFormat, this.streamState);

    let url = YoutubeSabrRequestBuilder.withSabrSessionParameters(
      this.serverAbrStreamingUrl, this.info.cpn, this.requestNumber);

    logger.info(`[SABR] POST rn=${this.requestNumber + 1} body=${body.length} urlLen=${url.length}`);

    const headers = this.buildSabrHeaders();
    const response = await this.httpClient.postBinary(url, body, headers, this.useAuth);
    const status = response.responseCode;
    const contentType = extractContentType(response.header);
    requireUmpContentType(contentType, status);

    const bodyBytes = toUint8Array(response.result);
    logger.info(`[SABR] response status=${status} bytes=${bodyBytes.length} ct=${contentType}`);

    const decoded = sabrDecodeBody(bodyBytes);
    this.requestNumber++;

    // Redirect
    if (decoded.redirectUrl && decoded.redirectUrl.length > 0) {
      if (this.redirectCount >= MAX_REDIRECTS) {
        throw new SabrProtocolException(`SABR too many redirects: ${decoded.redirectUrl}`);
      }
      this.redirectCount++;
      this.serverAbrStreamingUrl = decoded.redirectUrl;
      logger.info(`[SABR] redirect #${this.redirectCount} urlLen=${decoded.redirectUrl.length}`);
    }

    this.streamState.ingest(decoded);
    for (const segment of decoded.segments) {
      this.ingestAndCacheSegment(segment);
    }
    this.evictCacheIfNeeded();

    if (decoded.isProtectionBoundaryNoMediaResponse()) {
      await this.applyPoTokenForProtectedResponse();
    }
    if (decoded.segments.length > 0) {
      this.redirectCount = 0;
      this.poTokenRefreshes = 0;
    }

    logger.info(`[SABR] pump segments=${decoded.segments.length} `
      + `cache=${this.segmentCache.size}/${this.cachedBytes} `
      + `protection=${decoded.streamProtectionStatus} `
      + `policy=${decoded.nextRequestPolicy?.summarize() || 'none'} `
      + `reload=${decoded.reloadRequested}`);
    return decoded;
  }

  prepareForRewind(targetMs: number): void {
    this.streamState.prepareForSeek(targetMs);
    this.evictOutsideWindow(targetMs);
  }

  prepareForForwardJump(targetMs: number): void {
    this.streamState.prepareForSeek(targetMs);
    this.evictOutsideWindow(targetMs);
  }

  private ingestAndCacheSegment(segment: SabrMediaSegment): void {
    const key = segment.cacheKey();
    if (this.segmentCache.has(key)) {
      return;
    }
    this.segmentCache.set(key, segment);
    this.cacheOrder.push(key);
    this.cachedBytes += segment.getLength();
    this.streamState.ingestSegment(segment);
    if (segment.header.initSegment) {
      this.streamState.markInitReceived(segment.header.itag);
    }
  }

  private evictCacheIfNeeded(): void {
    const keepBehind = Math.max(0, this.playHeadMs - EVICT_BEHIND_MS);
    while (this.cachedBytes > MAX_CACHE_BYTES && this.cacheOrder.length > 0) {
      const key = this.cacheOrder[0];
      const segment = this.segmentCache.get(key);
      if (!segment) {
        this.cacheOrder.shift();
        continue;
      }
      // Never evict init segments
      if (segment.header.initSegment) {
        this.cacheOrder.push(this.cacheOrder.shift() as string);
        // prevent infinite loop if only init left
        if (this.cacheOrder.every(k => this.segmentCache.get(k)?.header.initSegment)) {
          break;
        }
        continue;
      }
      const endMs = (segment.header.startMs >= 0 ? segment.header.startMs : 0)
        + Math.max(0, segment.header.durationMs);
      if (endMs > keepBehind && this.cachedBytes <= MAX_CACHE_BYTES * 1.2) {
        break;
      }
      this.cacheOrder.shift();
      this.segmentCache.delete(key);
      this.cachedBytes -= segment.getLength();
    }
  }

  private evictOutsideWindow(targetMs: number): void {
    const lo = Math.max(0, targetMs - SEEK_KEEP_WINDOW_MS);
    const hi = targetMs + SEEK_KEEP_WINDOW_MS;
    const keep: string[] = [];
    for (const key of this.cacheOrder) {
      const segment = this.segmentCache.get(key);
      if (!segment) {
        continue;
      }
      if (segment.header.initSegment) {
        keep.push(key);
        continue;
      }
      const start = segment.header.startMs >= 0 ? segment.header.startMs : 0;
      const end = start + Math.max(0, segment.header.durationMs);
      if (end >= lo && start <= hi) {
        keep.push(key);
      } else {
        this.segmentCache.delete(key);
        this.cachedBytes -= segment.getLength();
      }
    }
    this.cacheOrder = keep;
  }

  private buildSabrHeaders(): Record<string, string> {
    const ua = this.info.profile === 'web'
      ? ClientsConstants.WEB_USER_AGENT
      : ClientsConstants.MWEB_USER_AGENT;
    const headers: Record<string, string> = {
      'Content-Type': 'application/x-protobuf',
      'Accept': 'application/vnd.yt-ump',
      'Accept-Encoding': 'identity',
      'User-Agent': ua,
      'Origin': 'https://www.youtube.com',
      'Referer': 'https://www.youtube.com/'
    };
    if (this.info.visitorData) {
      headers['X-Goog-Visitor-Id'] = this.info.visitorData;
    }
    return headers;
  }

  private async maybeApplyPoToken(forceRefresh: boolean): Promise<boolean> {
    if (!this.poTokenProvider) {
      return false;
    }
    const current = this.streamState.getRawPoToken();
    if (current && current.length > 0 && !forceRefresh) {
      return false;
    }
    try {
      const token = await this.poTokenProvider.getPoToken(this.info, this.streamState, forceRefresh);
      if (token && token.length > 0) {
        this.streamState.setPoToken(token);
        logger.info(`[SABR] PO token applied bytes=${token.length} force=${forceRefresh}`);
        return true;
      }
    } catch (e) {
      logger.warn('[SABR] PO token provider failed:', e);
    }
    return false;
  }

  private async applyPoTokenForProtectedResponse(): Promise<boolean> {
    if (await this.maybeApplyPoToken(false)) {
      return true;
    }
    if (this.poTokenRefreshes < MAX_PO_TOKEN_REFRESHES) {
      this.poTokenRefreshes++;
      return await this.maybeApplyPoToken(true);
    }
    return false;
  }
}

function toUint8Array(result: Object | string | ArrayBuffer | undefined): Uint8Array {
  if (!result) {
    return new Uint8Array(0);
  }
  if (result instanceof ArrayBuffer) {
    return new Uint8Array(result);
  }
  if (typeof result === 'string') {
    // Treat as binary string
    const out = new Uint8Array(result.length);
    for (let i = 0; i < result.length; i++) {
      out[i] = result.charCodeAt(i) & 0xff;
    }
    return out;
  }
  // Uint8Array-like
  const maybe = result as Uint8Array;
  if (maybe && maybe.buffer && typeof maybe.length === 'number') {
    return new Uint8Array(maybe.buffer, maybe.byteOffset, maybe.byteLength);
  }
  return new Uint8Array(0);
}

function extractContentType(header: Object | undefined): string | undefined {
  if (!header) {
    return undefined;
  }
  const h = header as Record<string, string | string[] | undefined>;
  const keys = Object.keys(h);
  for (const key of keys) {
    if (key.toLowerCase() === 'content-type') {
      const v = h[key];
      if (Array.isArray(v)) {
        return v[0];
      }
      return v as string | undefined;
    }
  }
  return undefined;
}

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms);
  });
}
