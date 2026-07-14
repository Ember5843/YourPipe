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
  /** Serialize pumps — concurrent A/V ensureReady must not dual-fire rn=1. */
  private pumpBusy: boolean = false;
  private pumpWaiters: Array<() => void> = [];
  /** Server-requested cooldown (Date.now() deadline). Honored before every POST. */
  private backoffUntilMs: number = 0;
  private consecutiveNoMedia: number = 0;
  private poTokenWarmup?: Promise<boolean>;

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

  /** Remaining server backoff ms (0 if clear). */
  getBackoffRemainingMs(): number {
    return Math.max(0, this.backoffUntilMs - Date.now());
  }

  isInBackoff(): boolean {
    return this.getBackoffRemainingMs() > 0;
  }

  /** True only when initialization metadata proves the requested media sequence is past EOF. */
  isBeyondEnd(request: SabrSegmentRequest): boolean {
    if (request.initSegment) {
      return false;
    }
    const format = request.itag === this.audioFormat.itag ? this.audioFormat
      : (request.itag === this.videoFormat.itag ? this.videoFormat : undefined);
    if (!format) {
      return false;
    }
    const endSegment = this.streamState.getEndSegment(format);
    return endSegment > 0 && request.sequenceNumber > endSegment;
  }

  isComplete(requestItag?: number): boolean {
    if (requestItag === this.audioFormat.itag) {
      return this.streamState.isComplete(this.audioFormat);
    }
    if (requestItag === this.videoFormat.itag) {
      return this.streamState.isComplete(this.videoFormat);
    }
    return this.streamState.isComplete();
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
    if (this.isBeyondEnd(request)) {
      throw new SabrProtocolException(`SABR segment beyond end: ${request.cacheKey()}`);
    }

    // A DASH reader requests the target segment directly on seek. Move SABR's reported
    // contiguous edge near that target instead of downloading the skipped span first.
    const requestFormat = request.itag === this.audioFormat.itag ? this.audioFormat
      : (request.itag === this.videoFormat.itag ? this.videoFormat : undefined);
    const requestTargetMs = !request.initSegment && requestFormat
      ? this.streamState.getSegmentStartMs(requestFormat, request.sequenceNumber) : 0;
    const cachedTailSequence = request.initSegment ? 0 : this.getMaxCachedSequence(request.itag);
    // DASH normally asks for the segment immediately after the cached tail as read-ahead.
    // Audio segments are about 10s long, so a time-only +8s test misclassified every normal
    // audio prefetch as a seek and reset both tracks. A real forward seek skips sequence numbers.
    const sequentialReadAhead = cachedTailSequence > 0
      && request.sequenceNumber <= cachedTailSequence + 1;
    if (requestFormat
      && !sequentialReadAhead
      && requestTargetMs > this.streamState.getBufferedEndMs(requestFormat) + 8000) {
      this.prepareForForwardJump(requestTargetMs);
    }

    let policyOnly = 0;
    let holeRecoveryApplied = false;
    for (let attempt = 0; attempt < MAX_REQUESTS_PER_SEGMENT; attempt++) {
      if (this.closed) {
        throw new SabrProtocolException('SABR session closed');
      }
      const decoded = await this.pumpOnce();
      const hit = this.segmentCache.get(request.cacheKey());
      if (hit) {
        return hit;
      }
      if (this.isBeyondEnd(request)) {
        throw new SabrProtocolException(`SABR segment beyond end: ${request.cacheKey()}`);
      }
      if (decoded.sabrError) {
        throw new SabrProtocolException(
          `SABR error while fetching ${request.cacheKey()}: ${decoded.sabrError}`);
      }
      if (decoded.reloadRequested) {
        throw new SabrProtocolException(
          `SABR reload requested (not auto-reprobed yet): ${decoded.summarizeNoMediaResponse()}`);
      }
      // SABR can send later segments while leaving the exact requested sequence as a hole.
      // Rewind the advertised range once so the server is told honestly to refill that hole.
      const observedAheadHole = !request.initSegment && this.hasCachedMediaAfter(request);
      if (!request.initSegment && requestFormat && !holeRecoveryApplied
        && (observedAheadHole
          || requestTargetMs + 500 < this.streamState.getBufferedEndMs(requestFormat))) {
        holeRecoveryApplied = true;
        if (observedAheadHole) {
          this.backoffUntilMs = 0;
          this.consecutiveNoMedia = 0;
          this.streamState.prepareForMissingSegment(requestFormat, request.sequenceNumber);
        } else {
          this.prepareForRewind(requestTargetMs);
        }
        logger.info(`[SABR] recover hole itag=${request.itag} seq=${request.sequenceNumber} `
          + `targetMs=${requestTargetMs} observedAhead=${observedAheadHole}`);
        continue;
      }
      if (decoded.isProtectionBoundaryNoMediaResponse()) {
        const applied = await this.applyPoTokenForProtectedResponse();
        if (!applied) {
          // No PO yet: stop immediately. Caller must serve cache / wait, not free-pump.
          throw new SabrProtocolException(
            `SABR protected no-media: ${decoded.summarizeNoMediaResponse()}`);
        }
        continue;
      }
      if (decoded.isPolicyOnlyResponse()) {
        policyOnly++;
        if (policyOnly >= MAX_POLICY_ONLY_RESPONSES) {
          throw new SabrProtocolException(
            `SABR repeated policy-only responses: ${decoded.summarizeNoMediaResponse()}`);
        }
        continue;
      }
      if (this.consecutiveNoMedia >= MAX_POLICY_ONLY_RESPONSES && decoded.isNoMediaResponse()) {
        throw new SabrProtocolException(
          `SABR repeated no-media: ${decoded.summarizeNoMediaResponse()}`);
      }
    }
    throw new SabrProtocolException(`SABR segment not available: ${request.cacheKey()}`);
  }

  /**
   * One POST + UMP decode + cache ingest. Returns decoded control summary.
   * Serialized so concurrent track buffers cannot race the request counter.
   */
  async pumpOnce(): Promise<SabrDecodedResponse> {
    while (this.pumpBusy) {
      await new Promise<void>((resolve: () => void) => {
        this.pumpWaiters.push(resolve);
      });
    }
    this.pumpBusy = true;
    try {
      return await this.pumpOnceLocked();
    } finally {
      this.pumpBusy = false;
      const next = this.pumpWaiters.shift();
      if (next) {
        next();
      }
    }
  }

  private async pumpOnceLocked(): Promise<SabrDecodedResponse> {
    if (this.closed) {
      throw new SabrProtocolException('SABR session closed');
    }

    // Always honor server backoff before the next POST (prevents rn++ storm).
    const waitMs = this.getBackoffRemainingMs();
    if (waitMs > 0) {
      logger.info(`[SABR] honor backoff ${waitMs}ms before rn=${this.requestNumber + 1}`);
      await sleepMs(Math.min(waitMs, MAX_BACKOFF_MS));
    }

    const isFirst = this.requestNumber === 0
      && !this.streamState.isInitialized(this.audioFormat)
      && !this.streamState.isInitialized(this.videoFormat);
    const body = isFirst
      ? YoutubeSabrRequestBuilder.buildFirstMediaRequest(
        this.info, this.audioFormat, this.videoFormat, this.streamState)
      : YoutubeSabrRequestBuilder.buildFollowUpMediaRequest(
        this.info, this.audioFormat, this.videoFormat, this.streamState);

    const url = YoutubeSabrRequestBuilder.withSabrSessionParameters(
      this.serverAbrStreamingUrl, this.info.cpn, this.requestNumber);

    const headers = this.buildSabrHeaders();
    const hasUstreamer = !!(this.info.videoPlaybackUstreamerConfig
      && this.info.videoPlaybackUstreamerConfig.length > 0);
    logger.info(`[SABR] POST rn=${this.requestNumber + 1} body=${body.length} urlLen=${url.length} `
      + `profile=${this.info.profile} ustreamer=${hasUstreamer} `
      + `a=${this.audioFormat.itag} v=${this.videoFormat.itag} `
      + `lmA=${this.audioFormat.lastModified || 0} lmV=${this.videoFormat.lastModified || 0}`);

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

    if (decoded.segments.length > 0) {
      this.redirectCount = 0;
      this.poTokenRefreshes = 0;
      this.consecutiveNoMedia = 0;
      this.backoffUntilMs = 0;
      if (decoded.streamProtectionStatus >= 2 && !this.streamState.getRawPoToken()) {
        this.startPoTokenWarmup();
      }
    } else {
      this.consecutiveNoMedia++;
      this.scheduleBackoff(decoded.backoffTimeMs);
    }

    logger.info(`[SABR] pump segments=${decoded.segments.length} `
      + `cache=${this.segmentCache.size}/${this.cachedBytes} `
      + `seq=${summarizeSegmentSequences(decoded)} `
      + `protection=${decoded.streamProtectionStatus} `
      + `policy=${decoded.nextRequestPolicy?.summarize() || 'none'} `
      + `reload=${decoded.reloadRequested} noMedia=${this.consecutiveNoMedia}`);
    return decoded;
  }

  private scheduleBackoff(serverMs: number): void {
    let ms = serverMs > 0 ? serverMs : 0;
    if (ms <= 0 && this.consecutiveNoMedia > 0) {
      // Floor when server says nothing but keeps returning empty (avoid spin).
      ms = Math.min(500 * this.consecutiveNoMedia, 2000);
    }
    if (ms <= 0) {
      return;
    }
    const capped = Math.min(ms, MAX_BACKOFF_MS);
    const until = Date.now() + capped;
    if (until > this.backoffUntilMs) {
      this.backoffUntilMs = until;
      logger.info(`[SABR] schedule backoff ${capped}ms (until=${this.backoffUntilMs})`);
    }
  }

  prepareForRewind(targetMs: number): void {
    this.backoffUntilMs = 0;
    this.consecutiveNoMedia = 0;
    this.streamState.prepareForSeek(targetMs);
    this.evictOutsideWindow(targetMs);
  }

  prepareForForwardJump(targetMs: number): void {
    this.backoffUntilMs = 0;
    this.consecutiveNoMedia = 0;
    this.streamState.prepareForSeek(targetMs);
    this.evictOutsideWindow(targetMs);
    this.setPlayHeadMs(targetMs);
    logger.info(`[SABR] prepare seek targetMs=${Math.floor(targetMs)}`);
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

  private hasCachedMediaAfter(request: SabrSegmentRequest): boolean {
    if (request.initSegment) {
      return false;
    }
    let found = false;
    this.segmentCache.forEach((segment: SabrMediaSegment) => {
      if (segment.header.itag === request.itag && !segment.header.initSegment
        && segment.header.sequenceNumber > request.sequenceNumber) {
        found = true;
      }
    });
    return found;
  }

  private getMaxCachedSequence(itag: number): number {
    let maxSequence = 0;
    this.segmentCache.forEach((segment: SabrMediaSegment) => {
      if (segment.header.itag === itag && !segment.header.initSegment
        && segment.header.sequenceNumber > maxSequence) {
        maxSequence = segment.header.sequenceNumber;
      }
    });
    return maxSequence;
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

  // PipePipe buildSabrHeaders (web-like mweb/web omit visitor).
  // OHOS net.http needs Content-Type for binary POST body delivery; PipePipe omits it on
  // OkHttp (MediaType null). Keep protobuf CT so the body is actually sent.
  private buildSabrHeaders(): Record<string, string> {
    const webLike = this.info.profile === 'mweb' || this.info.profile === 'web';
    const ua = this.info.profile === 'web'
      ? ClientsConstants.WEB_USER_AGENT
      : ClientsConstants.MWEB_USER_AGENT;
    const headers: Record<string, string> = {};
    headers['Content-Type'] = 'application/x-protobuf';
    headers['User-Agent'] = ua;
    if (webLike) {
      headers['Accept'] = '*/*';
      headers['Accept-Language'] = 'en-US,en;q=0.9';
      headers['Origin'] = 'https://www.youtube.com';
      headers['Referer'] = 'https://www.youtube.com/';
    } else {
      headers['Accept'] = 'application/vnd.yt-ump';
      headers['Accept-Encoding'] = 'identity';
      if (this.info.visitorData) {
        headers['X-Goog-Visitor-Id'] = this.info.visitorData;
      }
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
    if (this.poTokenWarmup) {
      const warmed = await this.poTokenWarmup;
      if (warmed || !!this.streamState.getRawPoToken()) {
        return true;
      }
    }
    if (await this.maybeApplyPoToken(false)) {
      return true;
    }
    if (this.poTokenRefreshes < MAX_PO_TOKEN_REFRESHES) {
      this.poTokenRefreshes++;
      return await this.maybeApplyPoToken(true);
    }
    return false;
  }

  private startPoTokenWarmup(): void {
    if (this.poTokenWarmup || this.streamState.getRawPoToken() || !this.poTokenProvider) {
      return;
    }
    logger.info('[SABR] PO token warmup started');
    this.poTokenWarmup = this.maybeApplyPoToken(false).then((applied: boolean): boolean => {
      this.poTokenWarmup = undefined;
      return applied;
    }).catch((e: Error): boolean => {
      this.poTokenWarmup = undefined;
      logger.warn('[SABR] PO token warmup failed:', e);
      return false;
    });
  }
}

function summarizeSegmentSequences(decoded: SabrDecodedResponse): string {
  const byItag: Map<number, number[]> = new Map();
  for (const segment of decoded.segments) {
    if (segment.header.initSegment || segment.header.sequenceNumber < 0) {
      continue;
    }
    const values = byItag.get(segment.header.itag) ?? [];
    values.push(segment.header.sequenceNumber);
    byItag.set(segment.header.itag, values);
  }
  const groups: string[] = [];
  byItag.forEach((values: number[], itag: number) => {
    values.sort((a: number, b: number): number => a - b);
    groups.push(`${itag}:${values.join(',')}`);
  });
  return groups.length > 0 ? groups.join('|') : '-';
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
