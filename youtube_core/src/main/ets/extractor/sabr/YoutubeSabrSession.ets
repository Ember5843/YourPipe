import { YTCoreLogger } from '../../common/YTCoreLogger';
import { http } from '@kit.NetworkKit';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { HttpAbortToken, HttpError } from '../../network/HttpDownloader';
import { ClientsConstants } from '../../model/ClientsConstants';
import { SabrDecodedResponse } from './SabrDecodedResponse';
import { SabrMediaSegment, SabrSegmentRequest } from './SabrMediaSegment';
import { SabrProtocolException } from './SabrProtocolException';
import { isRecoverableIntegrityIssues, requireUmpContentType, sabrDecodeBody } from './SabrResponseDecoder';
import { SabrInfoReloader } from './SabrInfoReloader';
import { SabrPoTokenProvider } from './SabrPoTokenProvider';
import { SabrServerEpoch } from './SabrServerEpoch';
import { BuiltinSabrSessionPolicy } from './policy/BuiltinSabrSessionPolicy';
import {
  SABR_MAX_ATTESTATION_IDENTITY_ROTATIONS,
  SABR_MAX_PO_TOKEN_REFRESHES,
  SABR_MAX_RELOADS_PER_SESSION,
  SabrControlAction,
  SabrPolicyContext,
  SabrSessionPolicy
} from './policy/SabrSessionPolicy';
import { YoutubeSabrFormatMeta, YoutubeSabrInfo } from './YoutubeSabrInfo';
import { YoutubeSabrRequestBuilder } from './YoutubeSabrRequestBuilder';
import { YoutubeSabrStreamState } from './YoutubeSabrStreamState';

const logger = YTCoreLogger.getInstance('YoutubeSabrSession');

/**
 * Network-traffic hook: invoked with UMP response body bytes as they arrive
 * from the network (per dataReceive chunk). mediaservice wires this to its
 * proxy traffic meter so the stats panel reports real SABR throughput —
 * segment-ingest callbacks cannot tell a session-cache hit from a fresh
 * network arrival. High-frequency path: the sink must not log.
 */
type SabrNetworkTrafficSink = (bytes: number) => void;
let networkTrafficSink: SabrNetworkTrafficSink | undefined = undefined;

/** Queued pump waiter — close() rejects them all so no one hangs on the lock. */
class PumpWaiter {
  readonly resolve: () => void;
  readonly reject: (reason?: Object) => void;

  constructor(resolve: () => void, reject: (reason?: Object) => void) {
    this.resolve = resolve;
    this.reject = reject;
  }
}

export function setSabrNetworkTrafficSink(sink?: SabrNetworkTrafficSink): void {
  networkTrafficSink = sink;
}

const MAX_REQUESTS_PER_SEGMENT = 16;
const MAX_BACKOFF_MS = 30000;
const MAX_INCOMPLETE_MEDIA_RESPONSES = 3;
const MAX_CACHE_BYTES = 32 * 1024 * 1024;
const SEEK_KEEP_WINDOW_MS = 8000;
const EVICT_BEHIND_MS = 10000;
/** Total wall-clock budget for in-pump network-error retries of one POST. */
const NETWORK_RETRY_BUDGET_MS = 75000;
/** 主机不可达（DNS/连接/无路由）时的快速重试次数，发生在主机轮换之前。 */
const MAX_DNS_RETRIES = 2;
const DNS_RETRY_DELAY_MS = 500;
/**
 * 连续退避 / 无进展预算（PipePipe SabrRequestCoordinator）。两者互独立，
 * 任一到顶即抛类型化可恢复错误（kind='network'），交给上层既有的重建/停止路径，
 * 绝不无限空转。计数在锁内（pumpOnceLocked）推进，故等待本地串行锁的时间不计入。
 */
const MAX_CONTINUOUS_BACKOFF_MS = 30000;
const MAX_CONTINUOUS_NO_PROGRESS_MS = 30000;

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
  private pumpWaiters: PumpWaiter[] = [];
  /** In-flight UMP POST abort handle — close() destroys it to unblock the pump. */
  private activePostAbort?: HttpAbortToken;
  /** Resolves the interruptible server-backoff sleep early on close(). */
  private backoffWaker?: () => void;
  private consecutiveNoMedia: number = 0;
  private consecutiveIntegrityFailures: number = 0;
  /** ROTATE_IDENTITY attempts (session-scoped, survives an epoch reset). */
  private attestationRotations: number = 0;
  private consecutiveAttestationPending: number = 0;
  private poTokenWarmup?: Promise<boolean>;
  /** Equivalent googlevideo host variants (index 0 = current URL, preserved). */
  private hostCandidates: string[] = [];
  private hostCandidateIndex: number = 0;
  /** 连续退避 / 无进展累计（ms）；有媒体到达时清零。 */
  private continuousBackoffMs: number = 0;
  private continuousNoProgressMs: number = 0;

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
    this.hostCandidates = YoutubeSabrSession.buildHostCandidates(info.serverAbrStreamingUrl);
    this.hostCandidateIndex = 0;
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
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.segmentCache.clear();
    this.cacheOrder = [];
    this.cachedBytes = 0;
    // Unblock everything the pump may be waiting on: queued pump waiters, the
    // server-backoff sleep, and the in-flight UMP POST (destroying its request
    // makes the downloader throw through the normal error path).
    const closeError = new SabrProtocolException('SABR session closed', 'closed');
    for (const waiter of this.pumpWaiters) {
      waiter.reject(closeError);
    }
    this.pumpWaiters = [];
    this.backoffWaker?.();
    this.activePostAbort?.abort();
  }

  /**
   * Network-handover lever (wired by entry through mediaservice): abort the
   * in-flight UMP POST so a stale connection (default network switched) errors
   * out now instead of hanging until the read timeout. The session stays open
   * and no policy/epoch state changes — the abort surfaces as a normal network
   * error through the existing catch paths and the next pump re-POSTs on the
   * new network (requestNumber only advances on a decoded response, so the
   * aborted rn is simply re-sent). Returns true when a POST was aborted.
   */
  abortInFlightPost(reason: string): boolean {
    if (this.closed || !this.activePostAbort) {
      return false;
    }
    logger.info(`[SABR] abort in-flight POST rn=${this.epoch.requestNumber}: ${reason}`);
    this.activePostAbort.abort();
    return true;
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
      throw new SabrProtocolException(`SABR segment beyond end: ${request.cacheKey()}`, 'beyond_end');
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
        throw new SabrProtocolException(`SABR segment beyond end: ${request.cacheKey()}`, 'beyond_end');
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
        // 'reload_player' never reaches the fetch phase: the pump policy decides
        // and executes it for every response (see pumpOnceLocked).
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
    throw new SabrProtocolException(`SABR segment not available: ${request.cacheKey()}`, 'segment_unavailable');
  }

  /**
   * One POST + UMP decode + cache ingest. Returns decoded control summary.
   * Serialized so concurrent track buffers cannot race the request counter.
   */
  async pumpOnce(): Promise<SabrDecodedResponse> {
    while (this.pumpBusy) {
      await new Promise<void>((resolve: () => void, reject: (reason?: Object) => void) => {
        this.pumpWaiters.push(new PumpWaiter(resolve, reject));
      });
      if (this.closed) {
        throw new SabrProtocolException('SABR session closed', 'closed');
      }
    }
    this.pumpBusy = true;
    try {
      return await this.pumpOnceLocked();
    } finally {
      this.pumpBusy = false;
      const next = this.pumpWaiters.shift();
      if (next) {
        next.resolve();
      }
    }
  }

  private async pumpOnceLocked(): Promise<SabrDecodedResponse> {
    if (this.closed) {
      throw new SabrProtocolException('SABR session closed', 'closed');
    }
    // 锁内起点：以下计入的“无进展/退避”时间不含等待本地串行锁的时间
    // （pumpOnceLocked 只在获得 pumpBusy 之后进入）。
    const lockedStartMs = Date.now();

    // Always honor server backoff before the next POST (prevents rn++ storm).
    // Logged-in sessions can get an empty first response with a multi-second
    // backoff; retrying early just burns the no-media budget and the server
    // keeps returning the remaining cooldown anyway.
    const waitMs = this.getBackoffRemainingMs();
    if (waitMs > 0) {
      const sleptMs = Math.min(waitMs, MAX_BACKOFF_MS);
      logger.info(`[SABR] honor backoff ${waitMs}ms before rn=${this.epoch.requestNumber}`);
      await this.sleepBackoffInterruptible(sleptMs);
      if (this.closed) {
        throw new SabrProtocolException('SABR session closed', 'closed');
      }
      // 连续退避预算：累计等待超过上限即失败，避免无限冷启动循环。
      this.continuousBackoffMs += sleptMs;
      if (this.continuousBackoffMs > MAX_CONTINUOUS_BACKOFF_MS) {
        throw new SabrProtocolException(
          `SABR continuous backoff exceeded ${MAX_CONTINUOUS_BACKOFF_MS}ms`, 'network');
      }
    }

    // PipePipe fetchAndProcessResponse: a media-incomplete response is never
    // ingested — recoverable issues retry the POST (budget
    // MAX_INCOMPLETE_MEDIA_RESPONSES), anything else is fatal.
    let decoded: SabrDecodedResponse | undefined = undefined;
    while (true) {
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
      logger.info(`[SABR] POST rn=${this.epoch.requestNumber} body=${body.length} `
        + `urlLen=${url.length} `
        + `profile=${this.info.profile} ustreamer=${hasUstreamer} `
        + `a=${this.audioFormat.itag} v=${this.videoFormat.itag} `
        + `lmA=${this.audioFormat.lastModified || 0} lmV=${this.videoFormat.lastModified || 0}`);

      const abortToken = new HttpAbortToken();
      this.activePostAbort = abortToken;
      let response: http.HttpResponse;
      try {
        response = await this.postBinaryWithNetworkRetry(url, body, headers, abortToken);
      } finally {
        if (this.activePostAbort === abortToken) {
          this.activePostAbort = undefined;
        }
      }
      const status = response.responseCode;
      const contentType = extractContentType(response.header);
      requireUmpContentType(contentType, status);

      const bodyBytes = toUint8Array(response.result);
      logger.info(`[SABR] response status=${status} bytes=${bodyBytes.length} ct=${contentType}`);

      const attemptDecoded = sabrDecodeBody(bodyBytes);
      this.epoch.requestNumber++;

      const issues = attemptDecoded.integrityIssues;
      if (issues.length === 0) {
        this.consecutiveIntegrityFailures = 0;
        decoded = attemptDecoded;
        break;
      }
      if (!isRecoverableIntegrityIssues(issues)) {
        throw new SabrProtocolException(`SABR media integrity issue: ${issues.join(',')}`);
      }
      this.consecutiveIntegrityFailures++;
      if (this.consecutiveIntegrityFailures >= MAX_INCOMPLETE_MEDIA_RESPONSES) {
        throw new SabrProtocolException(`SABR media integrity issue: ${issues.join(',')}`);
      }
      logger.warn(`[SABR] incomplete media response `
        + `#${this.consecutiveIntegrityFailures}/${MAX_INCOMPLETE_MEDIA_RESPONSES}: `
        + `${issues.join(',')} — retrying`);
    }

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
    // A RELOAD_PLAYER action is captured here but executed after ingest — the
    // response that asked for the reload must still be cached (PipePipe streams
    // media before handleControlResponse decides), and the trailing FAIL of the
    // reload chain fires only when the reload cannot handle the response.
    let reloadAction: SabrControlAction | undefined = undefined;
    let reloadFallback: SabrControlAction | undefined = undefined;
    for (const action of actions) {
      if (action.type === 'reload_player') {
        reloadAction = action;
        continue;
      }
      if (action.type === 'fail') {
        if (reloadAction) {
          reloadFallback = action;
          break;
        }
        throw new SabrProtocolException(action.message, action.kind);
      }
      if (action.type === 'apply_redirect') {
        this.epoch.redirectCount++;
        this.epoch.serverAbrStreamingUrl = action.url;
        // 新 URL 的 mn/mvi 才是有效候选 —— 重建候选并回到 index 0。
        this.updateHostCandidates(action.url);
        logger.info(`[SABR] redirect #${this.epoch.redirectCount} urlLen=${action.url.length}`);
      }
    }

    this.streamState.ingest(decoded);
    // PipePipe updateBackoff applies to EVERY response (media or not) and a
    // server backoff above the limit is fatal — media must not silently
    // discard a cooldown the server attached to it.
    this.applyServerBackoff(decoded.backoffTimeMs);
    for (const segment of decoded.segments) {
      this.ingestAndCacheSegment(segment);
    }
    this.evictCacheIfNeeded();

    if (decoded.segments.length > 0) {
      this.epoch.redirectCount = 0;
      this.epoch.poTokenRefreshes = 0;
      // PipePipe handleControlResponse resets BOTH episode counters when media
      // arrives (redirectCount + reloads) — except on a response that itself
      // carried the reload request (the reload check returns before the reset
      // there), so a reload response's own media never re-arms the budget.
      if (!reloadAction) {
        this.epoch.reloads = 0;
      }
      this.consecutiveNoMedia = 0;
      this.consecutiveAttestationPending = 0;
      this.continuousBackoffMs = 0;
      this.continuousNoProgressMs = 0;
      if (decoded.streamProtectionStatus >= 2 && !this.streamState.getRawPoToken()) {
        this.startPoTokenWarmup();
      }
    } else {
      this.consecutiveNoMedia++;
      // 无进展预算：锁内运行时间（不含等待本地锁）累计，超过上限即失败。
      this.continuousNoProgressMs += Math.max(0, Date.now() - lockedStartMs);
      if (this.continuousNoProgressMs > MAX_CONTINUOUS_NO_PROGRESS_MS) {
        throw new SabrProtocolException(
          `SABR continuous no-progress exceeded ${MAX_CONTINUOUS_NO_PROGRESS_MS}ms`, 'network');
      }
      // Post-ingest control for an empty response: try PoToken, else back off.
      for (const action of actions) {
        if (action.type === 'apply_po_token') {
          const applied = await this.applyPoTokenForProtectedResponse();
          if (applied) {
            this.consecutiveNoMedia = 0;
            this.epoch.backoffUntilMs = 0;
            this.continuousBackoffMs = 0;
            this.continuousNoProgressMs = 0;
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

    // RELOAD_PLAYER (decided by the pump policy for every response): swap the
    // bootstrap in place so the fetch path AND the background read-ahead pump
    // both recover. Success starts a fresh server session (empty streak
    // cleared); failure falls through to the chain's terminal FAIL.
    if (reloadAction) {
      const reloaded = await this.executeReloadPlayer(
        reloadAction.message || 'policy', reloadAction.token);
      if (reloaded) {
        this.consecutiveNoMedia = 0;
      } else if (reloadFallback) {
        throw new SabrProtocolException(reloadFallback.message, reloadFallback.kind);
      } else {
        logger.warn('[SABR] reload player failed without a fallback action');
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

  /**
   * One UMP POST with bounded in-pump retries for network-class failures
   * (connection reset / TLS handshake break / timeout / 5xx). A transient
   * network drop used to propagate straight out of the pump: every layer up to
   * the proxy had zero retry, the segment request died, and FFmpeg skipped to
   * the next segment, drifting the session playhead. Retrying here keeps the
   * pump lock held, so no other track's request can interleave; a failed POST
   * never received a response, so rn and the server backoff state stay untouched.
   * Budget-bounded so a dead link fails into kind='network' (→ 502 → the
   * controller's recovery ladder) instead of hanging the read forever.
   */
  private async postBinaryWithNetworkRetry(url: string, body: Uint8Array,
    headers: Record<string, string[] | string>, abortToken: HttpAbortToken): Promise<http.HttpResponse> {
    const deadline = Date.now() + NETWORK_RETRY_BUDGET_MS;
    let attempt = 0;
    let dnsRetries = 0;
    let postUrl = url;
    while (true) {
      if (this.closed) {
        throw new SabrProtocolException('SABR session closed', 'closed');
      }
      if (abortToken.aborted) {
        throw new SabrProtocolException('SABR request aborted', 'closed');
      }
      attempt++;
      try {
        // Inner downloader retry disabled: this method owns the retry policy so
        // DNS retries + host rotation are not stacked on the downloader's 3x loop.
        return await this.httpClient.postBinary(postUrl, body, headers, this.useAuth,
          (bytes: number) => networkTrafficSink?.(bytes), abortToken, false);
      } catch (e) {
        if (this.closed) {
          throw new SabrProtocolException('SABR session closed', 'closed');
        }
        const hostUnreachable = e instanceof HttpError && e.isHostUnreachable;
        // 1) 传输层主机不可达（DNS/连接/无路由）：轮换之前先做几次快速重试 ——
        //    负 DNS 缓存/瞬时抖动常常重试即通，不必换节点。
        if (hostUnreachable && dnsRetries < MAX_DNS_RETRIES) {
          dnsRetries++;
          logger.warn(`[SABR] host unreachable, DNS retry ${dnsRetries}/${MAX_DNS_RETRIES} `
            + `host=${hostOfUrl(postUrl) || '-'} rn=${this.epoch.requestNumber}`);
          await this.sleepBackoffInterruptible(DNS_RETRY_DELAY_MS);
          continue;
        }
        // 2) 重试仍不可达 → 换一个 googlevideo 节点（rn/epoch 不变，无响应即同一逻辑请求）。
        if (hostUnreachable) {
          const from = hostOfUrl(postUrl) || '-';
          if (this.rotateHost()) {
            postUrl = this.epoch.serverAbrStreamingUrl;
            dnsRetries = 0;
            logger.warn(`[SABR] host_rotate from=${from} to=${hostOfUrl(postUrl) || '-'} `
              + `rn=${this.epoch.requestNumber}`);
            continue;
          }
          logger.error(`[SABR] host candidates exhausted host=${from} rn=${this.epoch.requestNumber}`);
          throw new SabrProtocolException(
            `SABR host unreachable: ${(e as Error).message}`, 'network');
        }
        // 3) 其他网络类错误：在总预算内退避重试；预算耗尽→类型化可恢复错误。
        const isNetworkClass = e instanceof HttpError && e.responseCode !== 403 && e.isRecoverable;
        if (!isNetworkClass || Date.now() >= deadline) {
          if (isNetworkClass) {
            logger.error(`[SABR] network retry budget exhausted rn=${this.epoch.requestNumber} `
              + `attempts=${attempt} error=${(e as Error).message}`);
            throw new SabrProtocolException(`SABR network failure: ${(e as Error).message}`, 'network');
          }
          throw e instanceof Error ? e : new Error(String(e));
        }
        const waitMs = Math.min(1000 * attempt, 5000);
        logger.warn(`[SABR] network retry attempt=${attempt} waitMs=${waitMs} `
          + `rn=${this.epoch.requestNumber} error=${(e as Error).message}`);
        await this.sleepBackoffInterruptible(waitMs);
      }
    }
  }

  /** Advance to the next equivalent host; false when the candidate list is exhausted. */
  private rotateHost(): boolean {
    if (this.hostCandidateIndex + 1 >= this.hostCandidates.length) {
      return false;
    }
    this.hostCandidateIndex++;
    this.epoch.serverAbrStreamingUrl = this.hostCandidates[this.hostCandidateIndex];
    return true;
  }

  /** Rebuild the candidate list for a new URL and reset the cursor to the original. */
  private updateHostCandidates(url: string): void {
    this.hostCandidates = YoutubeSabrSession.buildHostCandidates(url);
    this.hostCandidateIndex = 0;
  }

  /**
   * Build equivalent googlevideo URLs by rewriting the host to each node advertised in the
   * {@code mn} query parameter (PipePipe buildHostCandidates). The current URL stays first;
   * the node index comes from {@code mvi} when numeric, else from the current host's
   * {@code rr<digits>} prefix. All other parameters — including the signature — are preserved
   * (not bound to the host). Returns a single-element list when the URL is not rotatable.
   */
  private static buildHostCandidates(url: string): string[] {
    const host = hostOfUrl(url);
    if (!host) {
      return [url];
    }
    const match = /^rr(\d+)---[^/]+\.googlevideo\.com$/.exec(host);
    const mn = queryParamOf(url, 'mn');
    if (!match || !mn || mn.length === 0) {
      return [url];
    }
    const mvi = queryParamOf(url, 'mvi');
    const rrIndex = mvi && /^\d+$/.test(mvi) ? mvi : match[1];
    const candidates: string[] = [url];
    for (const node of mn.split(',')) {
      const trimmed = node.trim();
      if (trimmed.length === 0) {
        continue;
      }
      const candidateHost = `rr${rrIndex}---${trimmed}.googlevideo.com`;
      if (candidateHost === host) {
        continue;
      }
      const candidateUrl = replaceHostInUrl(url, candidateHost);
      if (candidates.indexOf(candidateUrl) < 0) {
        candidates.push(candidateUrl);
      }
    }
    return candidates;
  }

  /**
   * Server-backoff sleep that close() cuts short via backoffWaker — a closed
   * session must not keep the pump parked for up to MAX_BACKOFF_MS.
   */
  private sleepBackoffInterruptible(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        this.backoffWaker = undefined;
        resolve();
      }, ms);
      this.backoffWaker = () => {
        clearTimeout(timer);
        this.backoffWaker = undefined;
        resolve();
      };
    });
  }

  /**
   * PipePipe updateBackoff: the server backoff applies to every response and
   * overwrites the deadline (cleared when absent); above the limit is fatal.
   */
  private applyServerBackoff(backoffTimeMs: number): void {
    if (backoffTimeMs > MAX_BACKOFF_MS) {
      throw new SabrProtocolException(`SABR backoff exceeds limit: ${backoffTimeMs}ms`);
    }
    this.epoch.backoffUntilMs = backoffTimeMs > 0 ? Date.now() + backoffTimeMs : 0;
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

  // PipePipe buildRequestHeaders: one constant header shape for every profile —
  // Content-Type x-protobuf, Accept vnd.yt-ump, Accept-Encoding identity, MWEB UA.
  // No Origin/Referer/Accept-Language, no X-Goog-Visitor-Id on the UMP rail.
  // OHOS net.http needs Content-Type for binary POST body delivery; PipePipe omits it on
  // OkHttp (MediaType null). Keep protobuf CT so the body is actually sent.
  private buildSabrHeaders(): Record<string, string> {
    const ua = this.info.profile === 'web'
      ? ClientsConstants.WEB_USER_AGENT
      : ClientsConstants.MWEB_USER_AGENT;
    const headers: Record<string, string> = {};
    headers['Content-Type'] = 'application/x-protobuf';
    headers['Accept'] = 'application/vnd.yt-ump';
    headers['Accept-Encoding'] = 'identity';
    headers['User-Agent'] = ua;
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
   * RELOAD_PLAYER (PipePipe applyReload): re-probe the SABR bootstrap and swap
   * it in place — requestNumber/playerTime/bufferedRanges survive, the streaming
   * URL / host candidates / redirect + token-refresh budgets are replaced, and
   * the server-owned contexts are dropped (they belong to the dead session).
   * `reloadToken` is echoed into the re-probe player request. Returns false when
   * the action is unavailable or the re-probe failed (the policy chain then
   * falls through); throws kind='protocol' on a broken new info or when the
   * identity changed but no fresh PO token could be minted.
   */
  private async executeReloadPlayer(reason: string, reloadToken: string): Promise<boolean> {
    if (!this.infoReloader || this.epoch.reloads >= SABR_MAX_RELOADS_PER_SESSION) {
      return false;
    }
    this.epoch.reloads++;
    const videoId = this.info.videoId;
    logger.info(`[SABR] reload player video=${videoId} reason=${reason} `
      + `token=${reloadToken.length > 0 ? 'present' : 'absent'} `
      + `attempt=${this.epoch.reloads}/${SABR_MAX_RELOADS_PER_SESSION} rn=${this.epoch.requestNumber}`);
    let newInfo: YoutubeSabrInfo | undefined = undefined;
    try {
      newInfo = await this.infoReloader.reloadSabrInfo(this.info, reason, reloadToken);
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
    // The fresh URL's mn/mvi are the only valid host-rotation candidates and
    // the cursor must restart from the URL itself (PipePipe applyReload).
    this.updateHostCandidates(newInfo.serverAbrStreamingUrl);
    this.epoch.redirectCount = 0;
    this.epoch.poTokenRefreshes = 0;
    // PipePipe applyReload: contexts and the integrity-failure streak belong to
    // the dead server session — clear them so the fresh session starts clean.
    this.epoch.sabrContexts.clear();
    this.epoch.activeSabrContextTypes.clear();
    this.consecutiveIntegrityFailures = 0;
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
      newInfo = await this.infoReloader.reloadSabrInfo(this.info, 'rotate_identity', '');
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

/** Hostname of an absolute URL (lowercase, no port strip needed for googlevideo); '' when unparseable. */
function hostOfUrl(url: string): string {
  const match = /^[a-z]+:\/\/([^/?#]+)/i.exec(url);
  return match ? match[1] : '';
}

/** First value of a query parameter ('' when absent); value is percent-decoded. */
function queryParamOf(url: string, key: string): string {
  const qIdx = url.indexOf('?');
  if (qIdx < 0) {
    return '';
  }
  const fragmentIdx = url.indexOf('#', qIdx);
  const query = fragmentIdx >= 0 ? url.substring(qIdx + 1, fragmentIdx) : url.substring(qIdx + 1);
  const pairs = query.split('&');
  for (const pair of pairs) {
    const eq = pair.indexOf('=');
    const name = eq >= 0 ? pair.substring(0, eq) : pair;
    if (name === key) {
      const raw = eq >= 0 ? pair.substring(eq + 1) : '';
      try {
        return decodeURIComponent(raw);
      } catch (_e) {
        return raw;
      }
    }
  }
  return '';
}

/** Rewrite only the host of an absolute URL; scheme, port, path and query stay byte-identical. */
function replaceHostInUrl(url: string, newHost: string): string {
  const match = /^([a-z]+:\/\/)([^/?#]+)(.*)$/i.exec(url);
  if (!match) {
    return url;
  }
  return `${match[1]}${newHost}${match[3]}`;
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
