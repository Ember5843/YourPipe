import { YTCoreLogger } from '../../common/YTCoreLogger';
import { http } from '@kit.NetworkKit';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { HttpAbortToken, HttpError } from '../../network/HttpDownloader';
import { ClientsConstants } from '../../model/ClientsConstants';
import { SabrDecodedResponse, SabrFormatInitMeta, SabrLiveMetadata } from './SabrDecodedResponse';
import { SabrMediaHeader } from './SabrMediaHeader';
import { SabrMediaSegment, SabrSegmentRequest } from './SabrMediaSegment';
import { SabrProtocolException } from './SabrProtocolException';
import { splitSelfInitializingSegment } from './SabrSelfInitializingSegment';
import { isRecoverableIntegrityIssues, requireUmpContentType, SabrPartProcessor } from './SabrResponseDecoder';
import { UmpStreamReader } from './UmpStreamReader';
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

/** Streaming segment arrival waiter — woken immediately on PART_MEDIA_END (PipePipe streaming parity). */
class SegmentWaiter {
  readonly resolve: (segment: SabrMediaSegment) => void;
  readonly reject: (reason?: Object) => void;

  constructor(resolve: (segment: SabrMediaSegment) => void, reject: (reason?: Object) => void) {
    this.resolve = resolve;
    this.reject = reject;
  }
}

class WaiterRegistration {
  readonly promise: Promise<SabrMediaSegment>;
  readonly cancel: () => void;

  constructor(promise: Promise<SabrMediaSegment>, cancel: () => void) {
    this.promise = promise;
    this.cancel = cancel;
  }
}

class PumpStepResult {
  segment?: SabrMediaSegment;
  decoded?: SabrDecodedResponse;
  joinedInFlight: boolean = false;
}

class SabrSeekAbortedError extends Error {
  constructor(message: string = 'SABR POST aborted for seek') {
    super(message);
    this.name = 'SabrSeekAbortedError';
  }
}

export function setSabrNetworkTrafficSink(sink?: SabrNetworkTrafficSink): void {
  networkTrafficSink = sink;
}

const MAX_REQUESTS_PER_SEGMENT = 16;
const MAX_BACKOFF_MS = 30000;
const MAX_INCOMPLETE_MEDIA_RESPONSES = 3;
/** Per-track cache budgets so high-bitrate 4K60 video (4×15MB = 64MB/POST) never self-evicts or evicts audio. */
const AUDIO_CACHE_MAX_BYTES = 16 * 1024 * 1024;
const VIDEO_CACHE_MIN_BYTES = 48 * 1024 * 1024;
const VIDEO_CACHE_MID_BYTES = 80 * 1024 * 1024;
const VIDEO_CACHE_MAX_BYTES = 128 * 1024 * 1024;
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
  private audioCachedBytes: number = 0;
  private videoCachedBytes: number = 0;
  private readonly videoCacheMaxBytes: number;
  /** Ref-counted keys actively awaited by fetchSegment — never evicted. */
  private activeDemands: Map<string, number> = new Map();
  /** Media segment keys already delivered to the player (reclaimable first). */
  private servedKeys: Set<string> = new Set();
  /** Highest sequence number already served per itag (protects initial probe before first serve). */
  private lastServedSeqByItag: Map<number, number> = new Map();
  /** Streaming arrival waiters keyed by SabrSegmentRequest.cacheKey(). */
  private segmentWaiters: Map<string, SegmentWaiter[]> = new Map();
  private playHeadMs: number = 0;
  private lastPlayHeadLogMs: number = -1;
  private closed: boolean = false;
  private useAuth: boolean = false;
  /** Serialize pumps — concurrent A/V ensureReady must not dual-fire rn=1. */
  private pumpBusy: boolean = false;
  private pumpWaiters: PumpWaiter[] = [];
  /** In-flight pump promise so concurrent readers can join & wake on segment arrival. */
  private activePumpPromise?: Promise<SabrDecodedResponse>;
  /** In-flight UMP POST abort handle — close() or seek-reposition destroys it to unblock the pump. */
  private activePostAbort?: HttpAbortToken;
  /** True while activePostAbort was tripped intentionally for a seek jump (not a close/error). */
  private activePumpSeekAbort: boolean = false;
  /** Request playerTimeMs of the currently running UMP POST. */
  private activePumpPlayerTimeMs: number = 0;
  /** Monotonic counter bumped on seek/reposition so stale pre-seek POSTs don't overwrite playbackCookie. */
  private seekEpoch: number = 0;
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
    const videoBitrate = videoFormat.bitrate ?? 0;
    if (videoBitrate > 24_000_000) {
      this.videoCacheMaxBytes = VIDEO_CACHE_MAX_BYTES;
    } else if (videoBitrate > 12_000_000) {
      this.videoCacheMaxBytes = VIDEO_CACHE_MID_BYTES;
    } else {
      this.videoCacheMaxBytes = VIDEO_CACHE_MIN_BYTES;
    }
    this.httpClient = httpClient;
    this.poTokenProvider = poTokenProvider;
    this.useAuth = useAuth;
    this.infoReloader = infoReloader;
    this.epoch = new SabrServerEpoch(info.serverAbrStreamingUrl);
    this.streamState = new YoutubeSabrStreamState(audioFormat, videoFormat, this.epoch, info.isPostLive);
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
    this.audioCachedBytes = 0;
    this.videoCachedBytes = 0;
    this.activeDemands.clear();
    this.servedKeys.clear();
    this.lastServedSeqByItag.clear();
    // Unblock everything the pump may be waiting on: queued pump waiters,
    // streaming segment arrival waiters, server-backoff sleep, and in-flight UMP POST.
    const closeError = new SabrProtocolException('SABR session closed', 'closed');
    for (const waiter of this.pumpWaiters) {
      waiter.reject(closeError);
    }
    this.pumpWaiters = [];
    this.segmentWaiters.forEach((waiters: SegmentWaiter[]) => {
      for (const waiter of waiters) {
        waiter.reject(closeError);
      }
    });
    this.segmentWaiters.clear();
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
    return endSegment >= 0 && request.sequenceNumber > endSegment;
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
   * Ensure a segment is available (init or media sequence).
   * Joins an in-flight streaming UMP POST when possible and wakes immediately when the target
   * segment finishes arriving (PipePipe streaming parity), instead of waiting for the full 64MB+
   * UMP response body to finish downloading.
   */
  async fetchSegment(request: SabrSegmentRequest): Promise<SabrMediaSegment> {
    if (this.closed) {
      throw new SabrProtocolException('SABR session closed', 'closed');
    }
    const key = request.cacheKey();
    const cached = this.segmentCache.get(key);
    if (cached) {
      return cached;
    }
    if (this.isBeyondEnd(request)) {
      throw new SabrProtocolException(`SABR segment beyond end: ${key}`, 'beyond_end');
    }

    const requestFormat = request.itag === this.audioFormat.itag ? this.audioFormat
      : (request.itag === this.videoFormat.itag ? this.videoFormat : undefined);
    const requestTargetMs = !request.initSegment && requestFormat
      ? Math.max(0, this.streamState.getSegmentStartMs(requestFormat, request.sequenceNumber)) : 0;

    this.pinDemand(key);
    try {
      if (!request.initSegment && requestFormat) {
        this.positionStreamForRequest(request, requestFormat, requestTargetMs);
      }

      let policyOnly = 0;
      let holeRecoveryCount = 0;
      let policyRecoveryApplied = false;
      let seekAbortRetries = 0;
      let inFlightJoins = 0;
      for (let attempt = 0; attempt < MAX_REQUESTS_PER_SEGMENT; attempt++) {
        if (this.closed) {
          throw new SabrProtocolException('SABR session closed', 'closed');
        }
        const hitBefore = this.segmentCache.get(key);
        if (hitBefore) {
          return hitBefore;
        }
        const step = await this.runOrJoinPumpForKey(key);
        if (step.segment) {
          return step.segment;
        }
        const hitAfter = this.segmentCache.get(key);
        if (hitAfter) {
          return hitAfter;
        }
        if (this.isBeyondEnd(request)) {
          throw new SabrProtocolException(`SABR segment beyond end: ${key}`, 'beyond_end');
        }
        const decoded = step.decoded;
        if (!decoded) {
          continue;
        }
        if (decoded.abortedForSeek) {
          if (seekAbortRetries < 6) {
            seekAbortRetries++;
            attempt--;
          }
          continue;
        }
        if (step.joinedInFlight && inFlightJoins < 4) {
          // The pump we joined was already running before this demand; re-check positioning
          // and start our own targeted POST without burning policy attempts.
          inFlightJoins++;
          if (!request.initSegment && requestFormat) {
            this.positionStreamForRequest(request, requestFormat, requestTargetMs);
          }
          attempt--;
          continue;
        }
        // Track the attestation-pending streak before the policy sees the response.
        if (decoded.isNoMediaResponse() && decoded.isAttestationPending()) {
          this.consecutiveAttestationPending++;
        } else {
          this.consecutiveAttestationPending = 0;
        }
        // SABR can send later segments while leaving the exact requested sequence as a hole
        // (e.g. slight boundary skew on fallback timeline). Allow up to 3 progressive
        // single-track step-backs (seq, seq-1, seq-2) so we never loop 10x on the same POST.
        const observedAheadHole = !request.initSegment && this.hasCachedMediaAfter(request);
        const holeRecoveryAvailable = !request.initSegment && !!requestFormat && holeRecoveryCount < 3
          && (observedAheadHole
            || request.sequenceNumber <= this.streamState.getLastSequence(requestFormat)
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
          requestKey: key,
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
            const minSeq = this.streamState.getStartSegment(requestFormat);
            const targetSeq = Math.max(minSeq, request.sequenceNumber - holeRecoveryCount);
            holeRecoveryCount++;
            // Always reposition ONLY the missing track (PipePipe SabrMediaBridge.track parity)
            // so a missing audio segment never wipes video bufferedRanges and re-downloads 60MB+.
            this.seekEpoch++;
            this.consecutiveNoMedia = 0;
            this.streamState.prepareForMissingSegment(requestFormat, targetSeq);
            logger.info(`[SABR] recover hole #${holeRecoveryCount} itag=${request.itag} `
              + `reqSeq=${request.sequenceNumber} targetSeq=${targetSeq} `
              + `targetMs=${this.streamState.getSegmentStartMs(requestFormat, targetSeq)} `
              + `observedAhead=${observedAheadHole}`);
            break;
          }
          if (action.type === 'recover_policy') {
            if (!requestFormat) {
              break;
            }
            policyRecoveryApplied = true;
            policyOnly = 0;
            // Keep server backoff: repositioning the demand must not bypass the cooldown.
            this.seekEpoch++;
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
      throw new SabrProtocolException(`SABR segment not available: ${key}`, 'segment_unavailable');
    } finally {
      this.releaseDemand(key);
    }
  }

  /**
   * Align streamState with an explicit segment demand before pumping (PipePipe SabrMediaBridge parity).
   * Handles forward jumps, two-track backward seeks, and single-track holes without letting a
   * missing audio segment wipe video bufferedRanges (or vice versa).
   */
  private positionStreamForRequest(
    request: SabrSegmentRequest,
    requestFormat: YoutubeSabrFormatMeta,
    requestTargetMs: number
  ): void {
    const cachedTailSequence = this.getMaxCachedSequence(request.itag);
    // DASH normally asks for the segment immediately after the cached tail as read-ahead.
    // Audio segments are ~10s long, so a time-only +8s test misclassified normal audio prefetch.
    const sequentialReadAhead = cachedTailSequence > 0
      && request.sequenceNumber <= cachedTailSequence + 1;
    if (!sequentialReadAhead
      && requestTargetMs > this.streamState.getBufferedEndMs(requestFormat) + 8000) {
      this.prepareForForwardJump(requestTargetMs);
      this.abortActivePumpForSeek('forward_jump');
      return;
    }
    const lastSeq = this.streamState.getLastSequence(requestFormat);
    if (lastSeq >= request.sequenceNumber) {
      // Track already advertised at/past this sequence, yet it is absent from cache.
      const companion = requestFormat === this.audioFormat ? this.videoFormat : this.audioFormat;
      const companionHasNear = this.hasCachedMediaNear(companion.itag, requestTargetMs);
      const companionEndMs = this.streamState.getBufferedEndMs(companion);
      if (!companionHasNear && requestTargetMs + 8000 < companionEndMs) {
        // Genuine two-track backward seek: rewind both tracks so one POST fetches both.
        this.prepareForRewind(requestTargetMs);
        this.abortActivePumpForSeek('backward_seek');
      } else {
        // Single-track hole / initial seq=1 probe: reposition ONLY this track.
        this.seekEpoch++;
        this.consecutiveNoMedia = 0;
        this.streamState.prepareForMissingSegment(requestFormat, request.sequenceNumber);
        if (this.pumpBusy && Math.abs(this.activePumpPlayerTimeMs - requestTargetMs) > 15000) {
          this.abortActivePumpForSeek('reposition');
        }
        logger.info(`[SABR] position track itag=${request.itag} seq=${request.sequenceNumber} `
          + `targetMs=${requestTargetMs} lastSeq=${lastSeq}`);
      }
    }
  }

  private startBackgroundPump(): Promise<SabrDecodedResponse> {
    const p = this.pumpOnce();
    // Early segment wakeup can resolve fetchSegment before this HTTP response finishes;
    // attach a sink so a later background error/abort never becomes an unhandled rejection.
    p.catch(() => {});
    return p;
  }

  private async runOrJoinPumpForKey(key: string): Promise<PumpStepResult> {
    const immediate = this.segmentCache.get(key);
    if (immediate) {
      const hit = new PumpStepResult();
      hit.segment = immediate;
      return hit;
    }
    const joinedInFlight = this.activePumpPromise !== undefined;
    const pumpPromise: Promise<SabrDecodedResponse> = joinedInFlight
      ? (this.activePumpPromise as Promise<SabrDecodedResponse>)
      : this.startBackgroundPump();
    const waiter = this.registerSegmentWaiter(key);
    return await new Promise<PumpStepResult>((resolve, reject) => {
      let settled = false;
      waiter.promise.then((segment: SabrMediaSegment) => {
        if (settled) {
          return;
        }
        settled = true;
        const res = new PumpStepResult();
        res.segment = segment;
        res.joinedInFlight = joinedInFlight;
        resolve(res);
      }).catch((err: Object) => {
        if (settled) {
          return;
        }
        settled = true;
        reject(err);
      });
      pumpPromise.then((decoded: SabrDecodedResponse) => {
        if (settled) {
          return;
        }
        settled = true;
        waiter.cancel();
        const res = new PumpStepResult();
        res.joinedInFlight = joinedInFlight;
        const arrived = this.segmentCache.get(key);
        if (arrived) {
          res.segment = arrived;
        } else {
          res.decoded = decoded;
        }
        resolve(res);
      }).catch((err: Object) => {
        if (settled) {
          return;
        }
        settled = true;
        waiter.cancel();
        const arrived = this.segmentCache.get(key);
        if (arrived) {
          const res = new PumpStepResult();
          res.segment = arrived;
          res.joinedInFlight = joinedInFlight;
          resolve(res);
          return;
        }
        reject(err);
      });
    });
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
    const work = this.pumpOnceLocked();
    this.activePumpPromise = work;
    try {
      return await work;
    } finally {
      if (this.activePumpPromise === work) {
        this.activePumpPromise = undefined;
      }
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
    this.activePumpSeekAbort = false;
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
    let startSeekEpoch = this.seekEpoch;
    /** Sequence numbers of the segments delivered by the accepted response. */
    const deliveredSeq = new Map<number, number[]>();
    while (true) {
      startSeekEpoch = this.seekEpoch;
      this.activePumpPlayerTimeMs = this.streamState.getRequestPlayerTimeMs();
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
        + `tMs=${Math.floor(this.activePumpPlayerTimeMs)} `
        + `lmA=${this.audioFormat.lastModified || 0} lmV=${this.videoFormat.lastModified || 0}`);

      const abortToken = new HttpAbortToken();
      this.activePostAbort = abortToken;
      let response: http.HttpResponse;
      const postStartedMs = Date.now();
      let receivedBytes = 0;
      // PipePipe SabrStreamingResponseReader: the UMP reply is decoded while it
      // downloads. A completed segment is handed to the segment cache right
      // away and wakes any waiting reader, so playback starts on the first
      // segment instead of waiting for a 64MB+ response to finish.
      const reader = new UmpStreamReader();
      deliveredSeq.clear();
      let firstSegmentLogged = false;
      const processor = new SabrPartProcessor(
        (segment: SabrMediaSegment) => {
          this.ingestAndCacheSegment(segment);
          if (!segment.header.initSegment && segment.header.sequenceNumber >= 0) {
            const values = deliveredSeq.get(segment.header.itag) ?? [];
            values.push(segment.header.sequenceNumber);
            deliveredSeq.set(segment.header.itag, values);
          }
          if (!segment.header.initSegment && !firstSegmentLogged) {
            firstSegmentLogged = true;
            logger.info(`[SABR] first segment delivered +${Date.now() - postStartedMs}ms `
              + `itag=${segment.header.itag} seq=${segment.header.sequenceNumber} `
              + `bytes=${segment.getLength()}`);
          }
        },
        (meta: SabrFormatInitMeta) => { this.streamState.observeFormatInitMeta(meta); },
        (liveMeta: SabrLiveMetadata) => { this.streamState.observeLiveMetadata(liveMeta); }
      );
      try {
        response = await this.postBinaryWithNetworkRetry(url, body, headers, abortToken,
          (chunk: Uint8Array) => {
            receivedBytes += chunk.length;
            reader.push(chunk);
            let part = reader.nextPart();
            while (part !== undefined) {
              processor.acceptPart(part);
              part = reader.nextPart();
            }
          });
      } catch (e) {
        if (e instanceof SabrSeekAbortedError) {
          this.epoch.requestNumber++;
          this.evictCacheIfNeeded();
          logger.info(`[SABR] pump aborted for seek after ${receivedBytes}B `
            + `delivered=${summarizeSequenceMap(deliveredSeq)}`);
          const aborted = new SabrDecodedResponse();
          aborted.abortedForSeek = true;
          return aborted;
        }
        throw e instanceof Error ? e : new Error(String(e));
      } finally {
        if (this.activePostAbort === abortToken) {
          this.activePostAbort = undefined;
        }
        this.activePumpSeekAbort = false;
      }
      const status = response.responseCode;
      const contentType = extractContentType(response.header);
      requireUmpContentType(contentType, status);

      // Truncated reply: the last part never completed. Treat it as a
      // recoverable incomplete-media response so the re-POST below asks the
      // server for a clean batch.
      const trailingBytes = reader.pendingBytes();
      this.streamState.updateBandwidthEstimate(receivedBytes, Date.now() - postStartedMs);
      logger.info(`[SABR] response status=${status} bytes=${receivedBytes} ct=${contentType} `
        + `trailing=${trailingBytes}`);

      const attemptDecoded = processor.finish();
      this.epoch.requestNumber++;

      const issues = trailingBytes > 0
        ? attemptDecoded.integrityIssues.concat([`truncated-ump-response:${trailingBytes}`])
        : attemptDecoded.integrityIssues;
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

    const seekChangedDuringPost = this.seekEpoch !== startSeekEpoch;
    this.streamState.ingest(decoded);
    if (seekChangedDuringPost) {
      // A seek repositioned the stream while this pre-seek response was finishing;
      // do not let the stale pre-seek playbackCookie contaminate the next seek POST.
      this.streamState.clearPlaybackCookie();
    }
    // PipePipe updateBackoff applies to EVERY response (media or not) and a
    // server backoff above the limit is fatal — media must not silently
    // discard a cooldown the server attached to it.
    this.applyServerBackoff(decoded.backoffTimeMs);
    // The media segments were already handed to the segment cache while the
    // response streamed in (PipePipe streaming parity) — nothing to re-ingest.
    this.evictCacheIfNeeded();

    if (decoded.segmentCount > 0) {
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

    logger.info(`[SABR] pump segments=${decoded.segmentCount} `
      + `cache=${this.segmentCache.size}/${this.cachedBytes} `
      + `(v=${Math.round(this.videoCachedBytes / 1048576)}M/${Math.round(this.videoCacheMaxBytes / 1048576)}M `
      + `a=${Math.round(this.audioCachedBytes / 1048576)}M) `
      + `seq=${summarizeSequenceMap(deliveredSeq)} `
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
    headers: Record<string, string[] | string>, abortToken: HttpAbortToken,
    onChunk?: (chunk: Uint8Array) => void): Promise<http.HttpResponse> {
    const deadline = Date.now() + NETWORK_RETRY_BUDGET_MS;
    let attempt = 0;
    let dnsRetries = 0;
    let postUrl = url;
    while (true) {
      if (this.closed) {
        throw new SabrProtocolException('SABR session closed', 'closed');
      }
      if (abortToken.aborted) {
        if (this.activePumpSeekAbort) {
          throw new SabrSeekAbortedError();
        }
        throw new SabrProtocolException('SABR request aborted', 'closed');
      }
      attempt++;
      try {
        // Inner downloader retry disabled: this method owns the retry policy so
        // DNS retries + host rotation are not stacked on the downloader's 3x loop.
        return onChunk
          ? await this.httpClient.postBinaryStreaming(postUrl, body, headers, this.useAuth,
            onChunk, (bytes: number) => networkTrafficSink?.(bytes), abortToken, false)
          : await this.httpClient.postBinary(postUrl, body, headers, this.useAuth,
            (bytes: number) => networkTrafficSink?.(bytes), abortToken, false);
      } catch (e) {
        if (this.closed) {
          throw new SabrProtocolException('SABR session closed', 'closed');
        }
        if (this.activePumpSeekAbort && abortToken.aborted) {
          throw new SabrSeekAbortedError();
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
    this.seekEpoch++;
    this.consecutiveNoMedia = 0;
    this.streamState.prepareForSeek(targetMs);
    this.evictOutsideWindow(targetMs);
  }

  prepareForForwardJump(targetMs: number): void {
    this.seekEpoch++;
    this.consecutiveNoMedia = 0;
    this.streamState.prepareForSeek(targetMs);
    this.evictOutsideWindow(targetMs);
    this.setPlayHeadMs(targetMs);
    logger.info(`[SABR] prepare seek targetMs=${Math.floor(targetMs)}`);
  }

  /**
   * PipePipe SabrSegmentDataSource.close() -> bridge.discard() parity:
   * once a media segment has been delivered to MPV, mark it served and immediately reclaim
   * older served segments of the same track (keeping 1 prior segment as a short reconnect
   * safety cushion). Keeps memory lean and guarantees unconsumed segments are never starved.
   */
  markSegmentServed(request: SabrSegmentRequest): void {
    if (request.initSegment || request.sequenceNumber < 0) {
      return;
    }
    const key = request.cacheKey();
    if (this.segmentCache.has(key)) {
      this.servedKeys.add(key);
    }
    const prev = this.lastServedSeqByItag.get(request.itag) ?? -1;
    const latest = Math.max(prev, request.sequenceNumber);
    this.lastServedSeqByItag.set(request.itag, latest);
    const keepFromSeq = latest - 1;
    const remaining: string[] = [];
    for (const k of this.cacheOrder) {
      const seg = this.segmentCache.get(k);
      if (!seg) {
        continue;
      }
      if (!seg.header.initSegment
        && seg.header.itag === request.itag
        && this.servedKeys.has(k)
        && seg.header.sequenceNumber < keepFromSeq
        && !this.isDemanded(k)) {
        this.deleteCachedKey(k);
        continue;
      }
      remaining.push(k);
    }
    this.cacheOrder = remaining;
  }

  private pinDemand(key: string): void {
    this.activeDemands.set(key, (this.activeDemands.get(key) ?? 0) + 1);
  }

  private releaseDemand(key: string): void {
    const count = (this.activeDemands.get(key) ?? 0) - 1;
    if (count <= 0) {
      this.activeDemands.delete(key);
    } else {
      this.activeDemands.set(key, count);
    }
  }

  private isDemanded(key: string): boolean {
    return (this.activeDemands.get(key) ?? 0) > 0;
  }

  private registerSegmentWaiter(key: string): WaiterRegistration {
    let waiterRef: SegmentWaiter | undefined = undefined;
    const promise = new Promise<SabrMediaSegment>((resolve, reject) => {
      waiterRef = new SegmentWaiter(resolve, reject);
      const list = this.segmentWaiters.get(key);
      if (list) {
        list.push(waiterRef);
      } else {
        this.segmentWaiters.set(key, [waiterRef]);
      }
    });
    const cancel = (): void => {
      if (!waiterRef) {
        return;
      }
      const list = this.segmentWaiters.get(key);
      if (!list) {
        return;
      }
      const idx = list.indexOf(waiterRef);
      if (idx >= 0) {
        list.splice(idx, 1);
      }
      if (list.length === 0) {
        this.segmentWaiters.delete(key);
      }
    };
    return new WaiterRegistration(promise, cancel);
  }

  private notifySegmentWaiters(key: string, segment: SabrMediaSegment): void {
    const list = this.segmentWaiters.get(key);
    if (!list || list.length === 0) {
      return;
    }
    this.segmentWaiters.delete(key);
    for (const waiter of list) {
      waiter.resolve(segment);
    }
  }

  private abortActivePumpForSeek(reason: string): void {
    if (this.closed || !this.pumpBusy || !this.activePostAbort || this.activePumpSeekAbort) {
      return;
    }
    // Never interrupt server-mandated backoff (only abort an active old-window HTTP download).
    this.activePumpSeekAbort = true;
    logger.info(`[SABR] abort in-flight POST for seek (${reason}) rn=${this.epoch.requestNumber}`);
    this.activePostAbort.abort();
  }

  private addCachedSegment(key: string, seg: SabrMediaSegment): void {
    this.segmentCache.set(key, seg);
    this.cacheOrder.push(key);
    const len = seg.getLength();
    this.cachedBytes += len;
    if (seg.header.itag === this.audioFormat.itag) {
      this.audioCachedBytes += len;
    } else if (seg.header.itag === this.videoFormat.itag) {
      this.videoCachedBytes += len;
    }
  }

  private deleteCachedKey(key: string): void {
    const seg = this.segmentCache.get(key);
    if (!seg) {
      return;
    }
    this.segmentCache.delete(key);
    this.servedKeys.delete(key);
    const len = seg.getLength();
    this.cachedBytes = Math.max(0, this.cachedBytes - len);
    if (seg.header.itag === this.audioFormat.itag) {
      this.audioCachedBytes = Math.max(0, this.audioCachedBytes - len);
    } else if (seg.header.itag === this.videoFormat.itag) {
      this.videoCachedBytes = Math.max(0, this.videoCachedBytes - len);
    }
  }

  private ingestAndCacheSegment(segment: SabrMediaSegment): void {
    let mediaSegment: SabrMediaSegment = segment;
    if (this.info.isPostLive && !segment.header.initSegment) {
      const split = splitSelfInitializingSegment(segment.data);
      if (split) {
        const initReq = SabrSegmentRequest.init(segment.header.itag);
        const initKey = initReq.cacheKey();
        if (!this.segmentCache.has(initKey)) {
          const initHeader = new SabrMediaHeader();
          initHeader.videoId = segment.header.videoId;
          initHeader.itag = segment.header.itag;
          initHeader.lastModified = segment.header.lastModified;
          initHeader.xtags = segment.header.xtags;
          initHeader.initSegment = true;
          initHeader.sequenceNumber = -1;
          initHeader.contentLength = split.initBytes.length;
          const synthInit = new SabrMediaSegment(initHeader, split.initBytes);
          this.addCachedSegment(initKey, synthInit);
          this.streamState.markInitReceived(segment.header.itag);
          logger.info(`[SABR] post-live synthesized init itag=${segment.header.itag} `
            + `initBytes=${split.initBytes.length} mediaBytes=${split.mediaBytes.length}`);
          this.notifySegmentWaiters(initKey, synthInit);
        }
        mediaSegment = new SabrMediaSegment(segment.header, split.mediaBytes);
      }
    }
    const key = mediaSegment.cacheKey();
    if (this.segmentCache.has(key)) {
      this.notifySegmentWaiters(key, this.segmentCache.get(key) as SabrMediaSegment);
      return;
    }
    this.addCachedSegment(key, mediaSegment);
    this.streamState.ingestSegment(mediaSegment);
    if (mediaSegment.header.initSegment) {
      this.streamState.markInitReceived(mediaSegment.header.itag);
    }
    // Wake any fetchSegment waiting on this exact init/media segment immediately while
    // the rest of the UMP response continues downloading in the background.
    this.notifySegmentWaiters(key, mediaSegment);
  }

  private evictCacheIfNeeded(): void {
    this.evictTrackIfNeeded(this.videoFormat.itag, this.videoCacheMaxBytes);
    this.evictTrackIfNeeded(this.audioFormat.itag, AUDIO_CACHE_MAX_BYTES);
  }

  /**
   * Per-track safe eviction:
   * - Never evicts init segments or actively demanded keys.
   * - Audio and video budgets are isolated so 15MB 4K60 video segments never evict audio.
   * - Priority: (1) already-served segments oldest-first, (2) segments behind playHeadMs
   *   (never touching startSeq before first serve), (3) above hard cap 1.25x, evict
   *   furthest-ahead (highest seq) unconsumed segments — NEVER the earliest needed segment.
   */
  private evictTrackIfNeeded(itag: number, maxBytes: number): void {
    const getTrackBytes = (): number => {
      return itag === this.audioFormat.itag ? this.audioCachedBytes : this.videoCachedBytes;
    };
    if (getTrackBytes() <= maxBytes) {
      return;
    }
    const format = itag === this.audioFormat.itag ? this.audioFormat : this.videoFormat;
    const startSeq = this.streamState.getStartSegment(format);
    const hasServedAny = this.lastServedSeqByItag.has(itag);
    const keepBehind = Math.max(0, this.playHeadMs - EVICT_BEHIND_MS);
    const hardCap = Math.floor(maxBytes * 1.25);

    // Tier 1: already-served segments (oldest first).
    if (getTrackBytes() > maxBytes) {
      const nextOrder: string[] = [];
      for (const key of this.cacheOrder) {
        const seg = this.segmentCache.get(key);
        if (!seg) {
          continue;
        }
        if (getTrackBytes() > maxBytes
          && !seg.header.initSegment
          && seg.header.itag === itag
          && this.servedKeys.has(key)
          && !this.isDemanded(key)) {
          this.deleteCachedKey(key);
          continue;
        }
        nextOrder.push(key);
      }
      this.cacheOrder = nextOrder;
    }

    // Tier 2: segments strictly behind playHeadMs - EVICT_BEHIND_MS (oldest first).
    if (getTrackBytes() > maxBytes && hasServedAny) {
      const nextOrder: string[] = [];
      for (const key of this.cacheOrder) {
        const seg = this.segmentCache.get(key);
        if (!seg) {
          continue;
        }
        const endMs = (seg.header.startMs >= 0 ? seg.header.startMs : 0)
          + Math.max(0, seg.header.durationMs);
        if (getTrackBytes() > maxBytes
          && !seg.header.initSegment
          && seg.header.itag === itag
          && endMs <= keepBehind
          && !this.isDemanded(key)) {
          this.deleteCachedKey(key);
          continue;
        }
        nextOrder.push(key);
      }
      this.cacheOrder = nextOrder;
    }

    // Tier 3: hard cap — trim furthest-ahead (highest seq) unconsumed segments first,
    // leaving the earliest unconsumed segment intact so playback can never self-starve.
    while (getTrackBytes() > hardCap) {
      let lowestUnconsumedSeq = Number.MAX_SAFE_INTEGER;
      let highestKey = '';
      let highestSeq = -1;
      for (const key of this.cacheOrder) {
        const seg = this.segmentCache.get(key);
        if (!seg || seg.header.initSegment || seg.header.itag !== itag) {
          continue;
        }
        const seq = seg.header.sequenceNumber;
        if (!this.servedKeys.has(key) && seq < lowestUnconsumedSeq) {
          lowestUnconsumedSeq = seq;
        }
      }
      for (const key of this.cacheOrder) {
        const seg = this.segmentCache.get(key);
        if (!seg || seg.header.initSegment || seg.header.itag !== itag || this.isDemanded(key)) {
          continue;
        }
        const seq = seg.header.sequenceNumber;
        if (!hasServedAny && seq === startSeq) {
          continue;
        }
        if (seq === lowestUnconsumedSeq) {
          continue;
        }
        if (seq > highestSeq) {
          highestSeq = seq;
          highestKey = key;
        }
      }
      if (!highestKey) {
        break;
      }
      this.deleteCachedKey(highestKey);
      const idx = this.cacheOrder.indexOf(highestKey);
      if (idx >= 0) {
        this.cacheOrder.splice(idx, 1);
      }
    }
  }

  private hasCachedMediaNear(itag: number, targetMs: number): boolean {
    let found = false;
    this.segmentCache.forEach((segment: SabrMediaSegment) => {
      if (segment.header.itag !== itag || segment.header.initSegment) {
        return;
      }
      const start = segment.header.startMs >= 0 ? segment.header.startMs : 0;
      const end = start + Math.max(1000, segment.header.durationMs);
      if (targetMs >= start - 2000 && targetMs <= end + 2000) {
        found = true;
      }
    });
    return found;
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
      if (segment.header.initSegment || this.isDemanded(key)) {
        keep.push(key);
        continue;
      }
      const start = segment.header.startMs >= 0 ? segment.header.startMs : 0;
      const end = start + Math.max(0, segment.header.durationMs);
      if (end >= lo && start <= hi) {
        keep.push(key);
      } else {
        this.deleteCachedKey(key);
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

  /**
   * PipePipe SabrAttestationRetryHandler -> YoutubeSabrSession.resetProtocolState():
   * drop cookie + sabrContexts while preserving streaming URL, rn and buffered media cache.
   */
  resetProtocolState(): void {
    this.epoch.resetServerState();
    this.consecutiveAttestationPending = 0;
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
      const rejected = this.streamState.getRawPoToken();
      if (rejected && rejected.length > 0 && this.poTokenProvider?.invalidateRejectedToken) {
        this.poTokenProvider.invalidateRejectedToken(rejected, this.info.videoId);
      }
      this.resetProtocolState();
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

/** Per-itag sequence summary of the segments delivered by one response. */
function summarizeSequenceMap(byItag: Map<number, number[]>): string {
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
