import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { ClientsConstants } from '../../model/ClientsConstants';
import { SabrDecodedResponse } from './SabrDecodedResponse';
import { SabrMediaSegment, SabrSegmentRequest } from './SabrMediaSegment';
import { SabrProtocolException } from './SabrProtocolException';
import { requireUmpContentType, sabrDecodeBody } from './SabrResponseDecoder';
import { SabrInfoReloader } from './SabrInfoReloader';
import { SabrPoTokenProvider } from './SabrPoTokenProvider';
import { SabrServerEpoch } from './SabrServerEpoch';
import { BuiltinSabrSessionPolicy } from './policy/BuiltinSabrSessionPolicy';
import {
  SABR_MAX_ATTESTATION_IDENTITY_ROTATIONS,
  SABR_MAX_PO_TOKEN_REFRESHES,
  SABR_MAX_RELOADS_PER_SESSION,
  SabrPolicyContext,
  SabrSessionPolicy
} from './policy/SabrSessionPolicy';
import { YoutubeSabrFormatMeta, YoutubeSabrInfo } from './YoutubeSabrInfo';
import { YoutubeSabrRequestBuilder } from './YoutubeSabrRequestBuilder';
import { YoutubeSabrStreamState } from './YoutubeSabrStreamState';

const logger = YTCoreLogger.getInstance('YoutubeSabrSession');

const MAX_REQUESTS_PER_SEGMENT = 16;
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
  private infoReloader?: SabrInfoReloader;
  /** Server-owned epoch state: url/rn/redirect/backoff/token-refresh counters. */
  private epoch: SabrServerEpoch;
  private policy: SabrSessionPolicy = new BuiltinSabrSessionPolicy();
  private segmentCache: Map<string, SabrMediaSegment> = new Map();
  private cacheOrder: string[] = [];
  private cachedBytes: number = 0;
  private playHeadMs: number = 0;
  private lastPlayHeadLogMs: number = -1;
  private closed: boolean = false;
  private useAuth: boolean = false;
  /** Serialize pumps — concurrent A/V ensureReady must not dual-fire rn=1. */
  private pumpBusy: boolean = false;
  private pumpWaiters: Array<() => void> = [];
  private consecutiveNoMedia: number = 0;
  /** ROTATE_IDENTITY attempts (session-scoped, survives an epoch reset). */
  private attestationRotations: number = 0;
  private consecutiveAttestationPending: number = 0;
  private poTokenWarmup?: Promise<boolean>;

  constructor(
    info: YoutubeSabrInfo,
    audioFormat: YoutubeSabrFormatMeta,
    videoFormat: YoutubeSabrFormatMeta,
    httpClient: YouTubeHttpClient,
    poTokenProvider?: SabrPoTokenProvider,
    useAuth: boolean = false,
    infoReloader?: SabrInfoReloader
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
    this.infoReloader = infoReloader;
    this.epoch = new SabrServerEpoch(info.serverAbrStreamingUrl);
    this.streamState = new YoutubeSabrStreamState(audioFormat, videoFormat, this.epoch);
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
    // PipePipe continuously feeds the real player position into SABR. Keep the request player
    // time moving after a seek instead of leaving prepareForSeek's target override frozen for the
    // rest of the session.
    this.streamState.setPlayerTimeMsOverride(this.playHeadMs);
    if (this.lastPlayHeadLogMs < 0 || Math.abs(this.playHeadMs - this.lastPlayHeadLogMs) >= 30000) {
      logger.debug(`[SABR] player time positionMs=${Math.floor(this.playHeadMs)}`);
      this.lastPlayHeadLogMs = this.playHeadMs;
    }
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
    return Math.max(0, this.epoch.backoffUntilMs - Date.now());
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
      throw new SabrProtocolException('SABR session closed', 'closed');
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
    let policyRecoveryApplied = false;
    for (let attempt = 0; attempt < MAX_REQUESTS_PER_SEGMENT; attempt++) {
      if (this.closed) {
        throw new SabrProtocolException('SABR session closed', 'closed');
      }
      const decoded = await this.pumpOnce();
      const hit = this.segmentCache.get(request.cacheKey());
      if (hit) {
        return hit;
      }
      if (this.isBeyondEnd(request)) {
        throw new SabrProtocolException(`SABR segment beyond end: ${request.cacheKey()}`);
      }
      // Track the attestation-pending streak before the policy sees the response.
      if (decoded.isNoMediaResponse() && decoded.isAttestationPending()) {
        this.consecutiveAttestationPending++;
      } else {
        this.consecutiveAttestationPending = 0;
      }
      // SABR can send later segments while leaving the exact requested sequence as a hole.
      // Rewind the advertised range once so the server is told honestly to refill that hole.
      const observedAheadHole = !request.initSegment && this.hasCachedMediaAfter(request);
      const holeRecoveryAvailable = !request.initSegment && !!requestFormat && !holeRecoveryApplied
        && (observedAheadHole
          || requestTargetMs + 500 < this.streamState.getBufferedEndMs(requestFormat));
      const policyRecoveryAvailable = !request.initSegment && !!requestFormat
        && !policyRecoveryApplied;
      const policyCtx: SabrPolicyContext = {
        phase: 'fetch',
        redirectCount: this.epoch.redirectCount,
        poTokenRefreshes: this.epoch.poTokenRefreshes,
        consecutiveNoMedia: this.consecutiveNoMedia,
        policyOnly: policyOnly,
        hasPoToken: !!this.streamState.getRawPoToken(),
        hasPoTokenProvider: !!this.poTokenProvider,
        requestKey: request.cacheKey(),
        holeRecoveryAvailable: holeRecoveryAvailable,
        policyRecoveryAvailable: policyRecoveryAvailable,
        reloads: this.epoch.reloads,
        attestationRotations: this.attestationRotations,
        consecutiveAttestationPending: this.consecutiveAttestationPending,
        hasInfoReloader: !!this.infoReloader,
        canRotateIdentity: !!this.poTokenProvider
          && !!this.poTokenProvider.invalidatePoTokenIdentity
      };
      const actions = this.policy.evaluate(decoded, policyCtx);
      for (const action of actions) {
        if (action.type === 'fail') {
          throw new SabrProtocolException(action.message, action.kind);
        }
        if (action.type === 'apply_po_token') {
          const applied = await this.applyPoTokenForProtectedResponse();
          if (applied) {
            break;
          }
          continue; // No PO yet: the chain's next action decides the fallback.
        }
        if (action.type === 'rotate_identity') {
          const rotated = await this.executeRotateIdentity();
          if (rotated) {
            break;
          }
          continue;
        }
        if (action.type === 'reload_player') {
          const reloaded = await this.executeReloadPlayer(action.message || 'policy');
          if (reloaded) {
            break;
          }
          continue;
        }
        if (action.type === 'recover_hole') {
          if (!requestFormat) {
            break;
          }
          holeRecoveryApplied = true;
          if (observedAheadHole) {
            // Keep server backoff: a hole refill must honor the cooldown too.
            this.consecutiveNoMedia = 0;
            this.streamState.prepareForMissingSegment(requestFormat, request.sequenceNumber);
          } else {
            this.prepareForRewind(requestTargetMs);
          }
          logger.info(`[SABR] recover hole itag=${request.itag} seq=${request.sequenceNumber} `
            + `targetMs=${requestTargetMs} observedAhead=${observedAheadHole}`);
          break;
        }
        if (action.type === 'recover_policy') {
          if (!requestFormat) {
            break;
          }
          // PipePipe's stream pump repositions an outstanding near-edge demand when the
          // server keeps acknowledging policy but returns no media. Without that step we
          // resend the same buffered range and playback cookie forever, then expose a
          // broken proxy response to the player. Re-advertise only the demanded track;
          // keep the companion timeline intact so normal A/V read-ahead can continue.
          policyRecoveryApplied = true;
          policyOnly = 0;
          // Keep server backoff: repositioning the demand must not bypass the cooldown.
          this.consecutiveNoMedia = 0;
          this.streamState.prepareForMissingSegment(requestFormat, request.sequenceNumber);
          logger.info(`[SABR] recover policy-only itag=${request.itag} `
            + `seq=${request.sequenceNumber} targetMs=${requestTargetMs}`);
          break;
        }
        if (action.type === 'count_policy_only') {
          policyOnly++;
          break;
        }
        // 'continue' / 'retry': nothing to execute; the fetch loop pumps again.
        break;
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
      throw new SabrProtocolException('SABR session closed', 'closed');
    }

    // Always honor server backoff before the next POST (prevents rn++ storm).
    // Logged-in sessions can get an empty first response with a multi-second
    // backoff; retrying early just burns the no-media budget and the server
    // keeps returning the remaining cooldown anyway.
    const waitMs = this.getBackoffRemainingMs();
    if (waitMs > 0) {
      logger.info(`[SABR] honor backoff ${waitMs}ms before rn=${this.epoch.requestNumber + 1}`);
      await sleepMs(Math.min(waitMs, MAX_BACKOFF_MS));
    }

    const isFirst = this.epoch.requestNumber === 0
      && !this.streamState.isInitialized(this.audioFormat)
      && !this.streamState.isInitialized(this.videoFormat);
    const body = isFirst
      ? YoutubeSabrRequestBuilder.buildFirstMediaRequest(
        this.info, this.audioFormat, this.videoFormat, this.streamState)
      : YoutubeSabrRequestBuilder.buildFollowUpMediaRequest(
        this.info, this.audioFormat, this.videoFormat, this.streamState);

    const url = YoutubeSabrRequestBuilder.withSabrSessionParameters(
      this.epoch.serverAbrStreamingUrl, this.info.cpn, this.epoch.requestNumber);

    const headers = this.buildSabrHeaders();
    const hasUstreamer = !!(this.info.videoPlaybackUstreamerConfig
      && this.info.videoPlaybackUstreamerConfig.length > 0);
    logger.info(`[SABR] POST rn=${this.epoch.requestNumber + 1} body=${body.length} `
      + `urlLen=${url.length} `
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
    this.epoch.requestNumber++;

    const pumpCtx: SabrPolicyContext = {
      phase: 'pump',
      redirectCount: this.epoch.redirectCount,
      poTokenRefreshes: this.epoch.poTokenRefreshes,
      consecutiveNoMedia: this.consecutiveNoMedia,
      policyOnly: 0,
      hasPoToken: !!this.streamState.getRawPoToken(),
      hasPoTokenProvider: !!this.poTokenProvider,
      requestKey: '',
      holeRecoveryAvailable: false,
      policyRecoveryAvailable: false,
      reloads: this.epoch.reloads,
      attestationRotations: this.attestationRotations,
      consecutiveAttestationPending: this.consecutiveAttestationPending,
      hasInfoReloader: !!this.infoReloader,
      canRotateIdentity: !!this.poTokenProvider
        && !!this.poTokenProvider.invalidatePoTokenIdentity
    };
    const actions = this.policy.evaluate(decoded, pumpCtx);

    // Pre-ingest control: apply the redirect swap / fail on the redirect limit.
    for (const action of actions) {
      if (action.type === 'fail') {
        throw new SabrProtocolException(action.message, action.kind);
      }
      if (action.type === 'apply_redirect') {
        this.epoch.redirectCount++;
        this.epoch.serverAbrStreamingUrl = action.url;
        logger.info(`[SABR] redirect #${this.epoch.redirectCount} urlLen=${action.url.length}`);
      }
    }

    this.streamState.ingest(decoded);
    for (const segment of decoded.segments) {
      this.ingestAndCacheSegment(segment);
    }
    this.evictCacheIfNeeded();

    if (decoded.segments.length > 0) {
      this.epoch.redirectCount = 0;
      this.epoch.poTokenRefreshes = 0;
      this.consecutiveNoMedia = 0;
      this.consecutiveAttestationPending = 0;
      this.epoch.backoffUntilMs = 0;
      if (decoded.streamProtectionStatus >= 2 && !this.streamState.getRawPoToken()) {
        this.startPoTokenWarmup();
      }
    } else {
      this.consecutiveNoMedia++;
      // Post-ingest control for an empty response: try PoToken, else back off.
      for (const action of actions) {
        if (action.type === 'apply_po_token') {
          const applied = await this.applyPoTokenForProtectedResponse();
          if (applied) {
            this.consecutiveNoMedia = 0;
            this.epoch.backoffUntilMs = 0;
            logger.info('[SABR] empty response: PoToken applied, retrying without backoff');
            break;
          }
          continue;
        }
        if (action.type === 'sleep_backoff') {
          this.scheduleBackoff(action.ms);
          break;
        }
      }
    }

    logger.info(`[SABR] pump segments=${decoded.segments.length} `
      + `cache=${this.segmentCache.size}/${this.cachedBytes} `
      + `seq=${summarizeSegmentSequences(decoded)} `
      + `protection=${decoded.streamProtectionStatus} `
      + `policy=${decoded.nextRequestPolicy?.summarize() || 'none'} `
      + `reload=${decoded.reloadRequested} seek=${decoded.sabrSeekReason} `
      + `noMedia=${this.consecutiveNoMedia}`);
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
    if (until > this.epoch.backoffUntilMs) {
      this.epoch.backoffUntilMs = until;
      logger.info(`[SABR] schedule backoff ${capped}ms (until=${this.epoch.backoffUntilMs})`);
    }
  }

  // Server backoff survives seeks and local stall resets (PipePipe demand backoff
  // semantics): a local reposition must never bypass the server's cooldown, or the
  // next POST just hits the protection boundary again and burns the mint budget.
  prepareForRewind(targetMs: number): void {
    this.consecutiveNoMedia = 0;
    this.streamState.prepareForSeek(targetMs);
    this.evictOutsideWindow(targetMs);
  }

  prepareForForwardJump(targetMs: number): void {
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
      // DORMANT: 当前不可达——SabrClientProfileKey 只有 'mweb' | 'web'，webLike 恒为 true；
      // 启用条件：为将来非 web profile（PipePipe 非 web UMP 头形状）预留，新增 profile 时生效。
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
    if (this.epoch.poTokenRefreshes < SABR_MAX_PO_TOKEN_REFRESHES) {
      this.epoch.poTokenRefreshes++;
      return await this.maybeApplyPoToken(true);
    }
    return false;
  }

  /**
   * RELOAD_PLAYER (PipePipe protected_no_media_reload): re-probe the SABR
   * bootstrap and swap it in place — requestNumber/playerTime/bufferedRanges
   * survive, only the url + redirect/token-refresh budgets reset. Returns
   * false when the action is unavailable or the re-probe failed (the policy
   * chain then falls through); throws kind='protocol' on a broken new info
   * or when the identity changed but no fresh PO token could be minted.
   */
  private async executeReloadPlayer(reason: string): Promise<boolean> {
    if (!this.infoReloader || this.epoch.reloads >= SABR_MAX_RELOADS_PER_SESSION) {
      return false;
    }
    this.epoch.reloads++;
    const videoId = this.info.videoId;
    logger.info(`[SABR] reload player video=${videoId} reason=${reason} `
      + `attempt=${this.epoch.reloads}/${SABR_MAX_RELOADS_PER_SESSION} rn=${this.epoch.requestNumber}`);
    let newInfo: YoutubeSabrInfo | undefined = undefined;
    try {
      newInfo = await this.infoReloader.reloadSabrInfo(this.info, reason);
    } catch (e) {
      logger.warn(`[SABR] reload player reloader threw video=${videoId}: ${String(e)}`);
      return false;
    }
    if (!newInfo) {
      logger.warn(`[SABR] reload player reprobe failed video=${videoId}`);
      return false;
    }
    if (!newInfo.serverAbrStreamingUrl) {
      throw new SabrProtocolException('SABR reload returned no streaming URL', 'protocol');
    }
    const previousVisitorData = this.info.visitorData || '';
    const hadPoToken = !!this.streamState.getRawPoToken();
    const visitorChanged = (newInfo.visitorData || '') !== previousVisitorData;
    this.info = newInfo;
    this.epoch.serverAbrStreamingUrl = newInfo.serverAbrStreamingUrl;
    this.epoch.redirectCount = 0;
    this.epoch.poTokenRefreshes = 0;
    this.consecutiveAttestationPending = 0;
    logger.info(`[SABR] reload player applied video=${videoId} visitorChanged=${visitorChanged} `
      + `rn=${this.epoch.requestNumber} urlLen=${newInfo.serverAbrStreamingUrl.length}`);
    if (visitorChanged) {
      // PoToken is bound to the visitor identity; the old token is invalid now
      // (PipePipe 3d309951: fail when a needed re-mint comes back empty).
      this.streamState.setPoToken(undefined);
      if (hadPoToken && !(await this.maybeApplyPoToken(false))) {
        throw new SabrProtocolException(
          'SABR reload changed visitor identity without a fresh PO token', 'protocol');
      }
    }
    return true;
  }

  /**
   * ROTATE_IDENTITY: invalidate the pinned visitor identity, re-probe, and
   * require the visitorData to actually change — then start a fresh epoch
   * (rn=0, cookie/contexts/backoff/poToken cleared) while local progress and
   * the segment cache survive. Returns false (chain falls through) when
   * unavailable, the re-probe failed, or the identity did not change.
   */
  private async executeRotateIdentity(): Promise<boolean> {
    const provider = this.poTokenProvider;
    if (!this.infoReloader || !provider || !provider.invalidatePoTokenIdentity
      || this.attestationRotations >= SABR_MAX_ATTESTATION_IDENTITY_ROTATIONS) {
      return false;
    }
    this.attestationRotations++;
    const videoId = this.info.videoId;
    logger.info(`[SABR] rotate identity video=${videoId} `
      + `attempt=${this.attestationRotations}/${SABR_MAX_ATTESTATION_IDENTITY_ROTATIONS}`);
    const previousVisitorData = this.info.visitorData || '';
    let invalidated = false;
    try {
      invalidated = await provider.invalidatePoTokenIdentity(this.info);
    } catch (e) {
      logger.warn(`[SABR] rotate identity invalidate threw video=${videoId}: ${String(e)}`);
      return false;
    }
    if (!invalidated) {
      logger.warn(`[SABR] rotate identity invalidate refused video=${videoId}`);
      return false;
    }
    let newInfo: YoutubeSabrInfo | undefined = undefined;
    try {
      newInfo = await this.infoReloader.reloadSabrInfo(this.info, 'rotate_identity');
    } catch (e) {
      logger.warn(`[SABR] rotate identity reloader threw video=${videoId}: ${String(e)}`);
      return false;
    }
    if (!newInfo || !newInfo.serverAbrStreamingUrl) {
      logger.warn(`[SABR] rotate identity reprobe failed video=${videoId}`);
      return false;
    }
    const visitorChanged = (newInfo.visitorData || '') !== previousVisitorData;
    if (!visitorChanged) {
      // Rotating onto the same identity proves rotation is impossible right
      // now; count it as a failure so the chain degrades to PoToken/reload.
      logger.warn(`[SABR] rotate identity visitorData unchanged video=${videoId}`);
      return false;
    }
    this.info = newInfo;
    this.epoch.resetServerState();
    this.epoch.serverAbrStreamingUrl = newInfo.serverAbrStreamingUrl;
    this.epoch.requestNumber = 0;
    this.epoch.redirectCount = 0;
    this.epoch.backoffUntilMs = 0;
    this.epoch.poTokenRefreshes = 0;
    this.consecutiveAttestationPending = 0;
    logger.info(`[SABR] rotate identity applied video=${videoId} visitorChanged=true `
      + `urlLen=${newInfo.serverAbrStreamingUrl.length}`);
    if (!(await this.maybeApplyPoToken(false))) {
      throw new SabrProtocolException(
        'SABR identity rotated without a fresh PO token', 'protocol');
    }
    return true;
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
