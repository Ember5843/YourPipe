import { AppLog } from '../../common/AppLog';
import { media } from '@kit.MediaKit';
import { common } from '@kit.AbilityKit';
import {
  YouTubeExtractor,
  WebClientVersionResolver,
  VideoInfo,
  StreamInfo as YouTubeStreamInfo,
  CommentResponse,
  AgeRestrictedContentException,
  PrivateContentException,
  PaidContentException,
  YoutubeMusicPremiumContentException,
  GeographicRestrictionException,
  LoginRequiredException,
  AccountTerminatedException,
  LiveStreamOfflineException,
  SignInConfirmNotBotException,
  ContentNotAvailableException,
  ContentNotSupportedException,
  ExtractionException,
  YoutubeJavaScriptPlayerManager,
  YoutubeSabrInfo,
  SabrInfoReloader,
  SessionIdentityManager,
  YoutubePlayerClientConfig
} from 'youtube_core';
import { StreamInfo, SubtitleTrack, sabrSessionStore, LocalMediaProxy } from 'mediaservice';
import { buildAutoTranslatedTrack } from 'youtube_core';
import { TranslationService } from '../../common/TranslationService';
import { SearchLocaleManager } from '../../common/SearchLocaleManager';
import { ErrorInfo } from '../../common/model/ErrorInfo';
import { SabrWebViewPoTokenProvider } from './SabrWebViewPoTokenProvider';

const logger = AppLog.getInstance('YouTubePlayService');

const TAG: string = '[PlayerLog][YouTubePlayService]';

export interface YouTubePlayResult {
  success: boolean;
  videoInfo?: VideoInfo;
  playerStreams?: StreamInfo[];
  subtitleTracks?: SubtitleTrack[];
  mediaSource?: media.MediaSource;
  error?: ErrorInfo;
  errorCode?: YouTubeErrorCode;
}

/** Layer 4 queue-prefetch cache entry. */
interface PrefetchedPlayResult {
  result: YouTubePlayResult;
  fetchedAtMs: number;
}

/**
 * Bridges SABR session RELOAD_PLAYER / ROTATE_IDENTITY re-probes into the
 * play service extraction mutex. A class (not an object literal) so the
 * ArkTS typed-object-literal rule is satisfied across the HAR boundary.
 */
class PlayServiceSabrInfoReloader implements SabrInfoReloader {
  private readonly reprobe:
    (info: YoutubeSabrInfo, reason: string) => Promise<YoutubeSabrInfo | undefined>;

  constructor(
    reprobe: (info: YoutubeSabrInfo, reason: string) => Promise<YoutubeSabrInfo | undefined>
  ) {
    this.reprobe = reprobe;
  }

  reloadSabrInfo(info: YoutubeSabrInfo, reason: string): Promise<YoutubeSabrInfo | undefined> {
    return this.reprobe(info, reason);
  }
}

export enum YouTubeErrorCode {
  INVALID_INPUT = 'INVALID_INPUT',
  INITIALIZE_FAILED = 'INITIALIZE_FAILED',
  EXTRACT_FAILED = 'EXTRACT_FAILED',
  CIPHER_DECRYPT_FAILED = 'CIPHER_DECRYPT_FAILED',
  PARSE_FAILED = 'PARSE_FAILED',
  NO_STREAMS = 'NO_STREAMS',
  NO_PLAYABLE_URL = 'NO_PLAYABLE_URL',
  CONTENT_NOT_AVAILABLE = 'CONTENT_NOT_AVAILABLE',
  VIDEO_DELETED = 'VIDEO_DELETED',
  VIDEO_PRIVATE = 'VIDEO_PRIVATE',
  AGE_RESTRICTED = 'AGE_RESTRICTED',
  GEO_RESTRICTED = 'GEO_RESTRICTED',
  PAID_CONTENT = 'PAID_CONTENT',
  PREMIUM_CONTENT = 'PREMIUM_CONTENT',
  MEMBERSHIP_REQUIRED = 'MEMBERSHIP_REQUIRED',
  SUBSCRIPTION_REQUIRED = 'SUBSCRIPTION_REQUIRED',
  LOGIN_REQUIRED = 'LOGIN_REQUIRED',
  COPYRIGHT_RESTRICTED = 'COPYRIGHT_RESTRICTED',
  NETWORK_ERROR = 'NETWORK_ERROR',
  TIMEOUT = 'TIMEOUT',
  PLAYER_NOT_FOUND = 'PLAYER_NOT_FOUND',
  PLAYER_PARSE_FAILED = 'PLAYER_PARSE_FAILED',
  UNKNOWN_ERROR = 'UNKNOWN_ERROR'
}

export class YouTubePlayService {
  private static instance: YouTubePlayService | undefined = undefined;
  private extractor: YouTubeExtractor | undefined = undefined;
  private context: common.UIAbilityContext;
  /** In-flight initialize() shared by concurrent callers (replaces the old
   * isInitializing busy-wait). Rejects with the real init error on failure. */
  private initPromise: Promise<void> | null = null;
  /** In-flight DASH PoToken mint/injection for the currently playing video
   * (P0-2). Awaited by the proxy-side startup gate, never by play() itself.
   * Written by play() and by takePrefetched() when a prefetch hit promotes its
   * video to current — never by a prefetch play() directly. */
  private pendingDashPotPromise: Promise<void> | null = null;
  /** DASH pot injections keyed by videoId — lets a prefetched video's injection
   * be promoted to the startup gate only when that video actually plays. */
  private dashPotInjections: Map<string, Promise<void>> = new Map();

  /** Barrier used by the mediaservice startup gate: resolves when the pending
   * pot injection for the most recent play() finished (or none was needed). */
  async awaitPendingDashPoToken(): Promise<void> {
    const pending = this.pendingDashPotPromise;
    if (!pending) return;
    try {
      await pending;
    } catch (e) {
      // Failure is already logged at the injection site; the gate must not break playback.
    }
  }

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  static getInstance(context: common.UIAbilityContext): YouTubePlayService {
    if (!YouTubePlayService.instance) {
      YouTubePlayService.instance = new YouTubePlayService(context);
    }
    return YouTubePlayService.instance;
  }

  // ── 队列预取（Layer 4）：播放稳定后提前提取下一个视频的流，切换时零网络 ──
  private static readonly PREFETCH_TTL_MS: number = 30 * 60 * 1000;
  private prefetchedResults: Map<string, PrefetchedPlayResult> = new Map();
  private prefetchInFlight: Map<string, Promise<YouTubePlayResult>> = new Map();
  /** Extraction mutex: YouTubeExtractor is a stateful singleton — prefetch and
   *  real playback must never extract concurrently. */
  private extractChain: Promise<void> = Promise.resolve();

  private async extractSerialized(videoId: string, attemptId: string): Promise<VideoInfo> {
    const run: Promise<VideoInfo> = this.extractChain.then(() => {
      if (!this.extractor) {
        throw new Error('extractor not initialized');
      }
      return this.extractor.extractVideoStreams(videoId, { attemptId: attemptId });
    });
    this.extractChain = run.then(() => undefined).catch(() => undefined);
    return run;
  }

  /**
   * SABR RELOAD_PLAYER / ROTATE_IDENTITY re-probe. Serialized through the same
   * extraction mutex as play()/prefetch — the extractor is a stateful singleton,
   * so a mid-playback re-probe must never run beside a real extraction.
   */
  private async reprobeSabrInfoSerialized(
    info: YoutubeSabrInfo,
    reason: string
  ): Promise<YoutubeSabrInfo | undefined> {
    logger.info(`${TAG} sabr reprobe queued video=${info.videoId} reason=${reason}`);
    const run: Promise<YoutubeSabrInfo | undefined> = this.extractChain.then(() => {
      if (!this.extractor) {
        throw new Error('extractor not initialized');
      }
      return this.extractor.reprobeSabrInfo(info.videoId);
    });
    this.extractChain = run.then(() => undefined).catch(() => undefined);
    return run;
  }

  /**
   * Fire-and-forget light extraction for an upcoming queue item. The result is
   * consumed by takePrefetched(); misses fall back to the normal play() path.
   */
  prefetch(videoId: string): void {
    if (!videoId) {
      return;
    }
    const cached = this.prefetchedResults.get(videoId);
    if (cached && Date.now() - cached.fetchedAtMs < YouTubePlayService.PREFETCH_TTL_MS) {
      return;
    }
    if (this.prefetchInFlight.has(videoId)) {
      return;
    }
    logger.info(`${TAG} prefetch start video=${videoId}`);
    const task = this.play(videoId, `prefetch-${Date.now()}`, true);
    this.prefetchInFlight.set(videoId, task);
    task.then((result: YouTubePlayResult) => {
      this.prefetchInFlight.delete(videoId);
      if (result.success) {
        const entry: PrefetchedPlayResult = { result: result, fetchedAtMs: Date.now() };
        this.prefetchedResults.set(videoId, entry);
        logger.info(`${TAG} prefetch done video=${videoId} streams=${result.playerStreams?.length || 0}`);
      } else {
        logger.warn(`${TAG} prefetch failed video=${videoId} code=${result.errorCode || '-'}`);
      }
    }).catch((e: Error) => {
      this.prefetchInFlight.delete(videoId);
      logger.warn(`${TAG} prefetch exception video=${videoId}: ${e.message || e}`);
    });
  }

  /**
   * Consume a prefetched result for videoId. A still-running prefetch is awaited
   * (dedup) instead of starting a second extraction. undefined = nothing usable.
   * A fresh entry is KEPT after a hit: queue revisits (switching back to a
   * recently played video) reuse it until the TTL expires instead of paying a
   * full re-extraction + PoToken mint.
   */
  async takePrefetched(videoId: string): Promise<YouTubePlayResult | undefined> {
    const cached = this.prefetchedResults.get(videoId);
    if (cached) {
      if (Date.now() - cached.fetchedAtMs < YouTubePlayService.PREFETCH_TTL_MS) {
        logger.info(`${TAG} prefetch hit video=${videoId} age=${Date.now() - cached.fetchedAtMs}ms`);
        // Promote the prefetched video's pot injection to the startup gate:
        // it is now the currently playing video.
        this.pendingDashPotPromise = this.dashPotInjections.get(videoId) ?? null;
        return cached.result;
      }
      this.prefetchedResults.delete(videoId);
    }
    const inFlight = this.prefetchInFlight.get(videoId);
    if (inFlight) {
      logger.info(`${TAG} prefetch in-flight, awaiting video=${videoId}`);
      const result = await inFlight.catch(() => undefined);
      this.prefetchInFlight.delete(videoId);
      if (result && result.success) {
        logger.info(`${TAG} prefetch in-flight consumed video=${videoId}`);
        this.pendingDashPotPromise = this.dashPotInjections.get(videoId) ?? null;
        return result;
      }
    }
    return undefined;
  }

  /**
   * 卡片长按「下载」入口的流提取：不触碰播放器，也不改写
   * pendingDashPotPromise（forPrefetch=true）；经 extractChain 互斥串行。
   * 命中 30 分钟 prefetch 缓存时零网络（不消费、不提升为播放会话）。
   * 返回前等待该视频的 DASH PoToken 注入落地，保证交给下载器的直链已带 pot=。
   */
  async extractForDownload(videoId: string): Promise<YouTubePlayResult> {
    const trimmed = (videoId || '').trim();
    const cached = this.prefetchedResults.get(trimmed);
    let result: YouTubePlayResult;
    if (cached && Date.now() - cached.fetchedAtMs < YouTubePlayService.PREFETCH_TTL_MS) {
      logger.info(`${TAG} download extract prefetch hit video=${trimmed}`);
      result = cached.result;
    } else {
      logger.info(`${TAG} download extract start video=${trimmed}`);
      result = await this.play(trimmed, '', true);
    }
    if (result.success) {
      const injection = this.dashPotInjections.get(trimmed);
      if (injection) {
        // play() 内已对注入 Promise 挂 catch 兜底；await 只为时序（pot= 先于建任务）
        await injection;
      }
    }
    return result;
  }

  /**
   * Drop every cached/in-flight prefetch. Required on playback-endpoint
   * changes: prefetched stream URLs were extracted with the old client and
   * must not be served by takePrefetched under the new one.
   */
  clearPrefetchCache(): void {
    if (this.prefetchedResults.size > 0 || this.prefetchInFlight.size > 0) {
      logger.info(`${TAG} prefetch cache cleared results=${this.prefetchedResults.size} inFlight=${this.prefetchInFlight.size}`);
    }
    this.prefetchedResults.clear();
    this.prefetchInFlight.clear();
    this.dashPotInjections.clear();
  }

  async initialize(): Promise<void> {
    if (this.extractor) return;
    if (this.initPromise) {
      return this.initPromise;
    }
    this.initPromise = this.doInitialize();
    try {
      await this.initPromise;
    } catch (e) {
      // Surface the real init failure instead of letting callers hit
      // 'extractor not initialized' later in extractSerialized.
      this.extractor = undefined;
      logger.error(`${TAG} initialize failed: ${(e as Error).message || e}`);
      throw e as Error;
    } finally {
      this.initPromise = null;
    }
  }

  private async doInitialize(): Promise<void> {
    this.extractor = new YouTubeExtractor(this.context);
    await this.extractor.initialize();
    this.syncExtractorLocale();
    sabrSessionStore.setHttpClient(this.extractor.getHttpClient());
    sabrSessionStore.setPoTokenProvider(SabrWebViewPoTokenProvider.getInstance());
    // Stage 2: player /player requests pick up visitor-bound PoTokens through
    // the identity layer; the provider fast-skips while BotGuard is cold.
    SessionIdentityManager.setPlayerPoTokenHook(SabrWebViewPoTokenProvider.getInstance());
    sabrSessionStore.setInfoReloader(new PlayServiceSabrInfoReloader(
      (info: YoutubeSabrInfo, reason: string): Promise<YoutubeSabrInfo | undefined> =>
        this.reprobeSabrInfoSerialized(info, reason)));
    logger.info(`${TAG} YouTubePlayService initialized`);
  }

  async prewarmClientVersion(): Promise<void> {
    if (!this.extractor) await this.initialize();
    if (!this.extractor) return;
    const version = await WebClientVersionResolver.getClientVersion(this.extractor.getHttpClient());
    logger.info(`${TAG} WEB client version prewarmed version=${version}`);
  }

  /** Clear-all-app-data hook: drop the extractor's in-memory network state (cookie jar). */
  resetNetworkState(): void {
    if (!this.extractor) return;
    this.extractor.resetNetworkState();
    logger.info(`${TAG} extractor network state reset`);
  }

  /** Playback-only: sync stream extract hl/gl from content language/region settings. */
  private syncExtractorLocale(): void {
    if (!this.extractor) {
      return;
    }
    const hl = SearchLocaleManager.resolveSearchLanguage();
    const gl = SearchLocaleManager.resolveSearchCountry();
    this.extractor.hl = hl;
    this.extractor.gl = gl;
    logger.info(`${TAG} locale synced hl=${hl} gl=${gl}`);
  }

  /**
   * 获取视频评论
   */
  async fetchComments(videoId: string, nextPageToken: string | null = null): Promise<CommentResponse> {
    if (!this.extractor) await this.initialize();
    this.syncExtractorLocale();
    return await this.extractor!.fetchComments(videoId, nextPageToken);
  }

  /**
   * 获取评论回复
   */
  async fetchCommentReplies(replyContinuation: string): Promise<CommentResponse> {
    if (!this.extractor) await this.initialize();
    this.syncExtractorLocale();
    return await this.extractor!.fetchCommentReplies(replyContinuation);
  }

  async fetchPlaybackExtras(videoId: string): Promise<VideoInfo | null> {
    if (!this.extractor) await this.initialize();
    this.syncExtractorLocale();
    try {
      return await this.extractor!.fetchPlaybackExtras(videoId);
    } catch (e) {
      logger.warn(`${TAG} fetchPlaybackExtras failed: ${(e as Error).message || e}`);
      return null;
    }
  }

  async fetchPlaybackExtrasFor(videoInfo: VideoInfo): Promise<VideoInfo | null> {
    if (!this.extractor) await this.initialize();
    this.syncExtractorLocale();
    try {
      return await this.extractor!.fetchPlaybackExtras(videoInfo.videoId, videoInfo.playerResponse);
    } catch (e) {
      logger.warn(`${TAG} fetchPlaybackExtrasFor failed: ${(e as Error).message || e}`);
      return null;
    }
  }

  async play(videoIdOrUrl: string, attemptId: string = '', forPrefetch: boolean = false): Promise<YouTubePlayResult> {
    logger.info(`${TAG} play() called for ${videoIdOrUrl} attempt=${attemptId || '-'}`);
    if (!this.extractor) {
      try {
        await this.initialize();
      } catch (e) {
        const errorCode = YouTubeErrorCode.INITIALIZE_FAILED;
        logger.error(`${TAG} play() aborted, initialize failed: ${(e as Error).message || e}`);
        return { success: false, error: this.getErrorMessage(errorCode, undefined, e as Error), errorCode: errorCode };
      }
    }

    this.syncExtractorLocale();

    const videoId = this.extractVideoId(videoIdOrUrl);
    if (!videoId) {
      const result: YouTubePlayResult = {
        success: false,
        error: new ErrorInfo(
          YouTubeErrorCode.INVALID_INPUT,
          $r('app.string.yt_error_invalid_video_id'),
          { isRetryable: false }
        ),
        errorCode: YouTubeErrorCode.INVALID_INPUT
      };
      return result;
    }

    try {
      logger.info(`${TAG} 开始提取视频流及元数据 (包含 Player JS 和解密)...`);
      const extractStartMs = Date.now();
      const videoInfo = await this.extractSerialized(videoId, attemptId);
      const extractElapsed = Date.now() - extractStartMs;
      logger.info(`${TAG} 提取完成 elapsed=${extractElapsed}ms streams=${videoInfo.streams.length} subtitles=${videoInfo.subtitleTracks.length} isLive=${videoInfo.isLive}`);
      if (videoInfo.streams.length === 0) {
        const errorCode = this.determineNoStreamsErrorCode(videoInfo);
        logger.warn(`${TAG} 无可用流 errorCode=${errorCode} ageRestricted=${videoInfo.isAgeRestricted} requiresLogin=${videoInfo.requiresLogin}`);
        const result: YouTubePlayResult = {
          success: false,
          videoInfo: videoInfo,
          error: this.getErrorMessage(errorCode, videoInfo),
          errorCode: errorCode
        };
        return result;
      }

      const hasDirectUrlStream = videoInfo.streams.some((stream: YouTubeStreamInfo) =>
        !!stream.url && stream.deliveryMethod !== 'SABR' && stream.kind !== 'sabr');
      if (hasDirectUrlStream) {
        // P0-2 (TTFF): mint/inject the DASH PoToken in parallel with source
        // submission instead of blocking play(). The proxy-side gate
        // (LocalMediaProxy.setStartupUrlGate) is the barrier that guarantees
        // pot= lands before the first upstream fetch consumes these URLs.
        const injection = this.injectDashPoToken(videoInfo).catch((e: Error) => {
          logger.warn(`${TAG} Dash PoToken injection failed, continuing without pot: ${String(e)}`);
        });
        // Track per-videoId so a prefetch never clobbers the startup gate of
        // the currently playing video; takePrefetched() promotes it on hit.
        this.dashPotInjections.set(videoId, injection);
        if (!forPrefetch) {
          this.pendingDashPotPromise = injection;
        }
      } else {
        if (!forPrefetch) {
          this.pendingDashPotPromise = null;
        }
        logger.info(`${TAG} all playable streams are SABR; skipping Dash PoToken`);
      }
      const playerStreams: StreamInfo[] = this.mapToPlayerStreams(videoInfo.streams, videoInfo.durationMs);

      logger.info(`${TAG} 流摘要: video_only=${playerStreams.filter(s => s.kind === 'video_only').length} audio_only=${playerStreams.filter(s => s.kind === 'audio_only').length} progressive=${playerStreams.filter(s => s.kind === 'progressive' || s.kind === '').length} sabr=${playerStreams.filter(s => s.kind === 'sabr' || s.deliveryMethod === 'SABR').length} subtitles=${videoInfo.subtitleTracks.length}`);
      // SIDX prefetch removed: its cache is consumed only by the reference
      // youtube-dual session builder, never by the product EDL single-session
      // path — the prefetch was dead upstream traffic inside the TTFF window.
      // (LocalMediaProxy.prefetchLikelyDashSidx stays available for the dual path.)
      return {
        success: true,
        videoInfo: videoInfo,
        playerStreams: playerStreams,
        subtitleTracks: this.withAutoTranslatedTrack(videoInfo)
      };
    } catch (e) {
      const errorCode = this.analyzeErrorCode(e as Error);
      logger.error(`${TAG} play() extraction exception: errorCode=${errorCode} message=${(e as Error).message}`);
      return { success: false, error: this.getErrorMessage(errorCode, undefined, e as Error), errorCode: errorCode };
    }
  }

  /**
   * P0 自动翻译轨（YouTube timedtext tlang）：有可翻译轨且没有目标语言原生轨时，
   * 追加一条服务端机器翻译虚拟轨。目标语言与评论翻译共用 TranslationService 设置。
   * 返回新数组，不改动 videoInfo.subtitleTracks（prefetch 缓存复用同一 VideoInfo）。
   * 注意：tlang 端点受 YouTube 按 IP 的 429 风控（"automated queries"），
   * 被标记的网络会取不到内容（overlay 一次重试后静默失败）；登录头已挂
   * （mediaservice fetchText），能否出字幕取决于出口 IP 信誉。
   */
  private withAutoTranslatedTrack(videoInfo: VideoInfo): SubtitleTrack[] {
    const tracks = videoInfo.subtitleTracks;
    if (videoInfo.isLive || tracks.length === 0) {
      return tracks;
    }
    try {
      const translated = buildAutoTranslatedTrack(tracks, TranslationService.subtitleTargetLanguage());
      if (translated) {
        logger.info(`${TAG} auto-translate track added: tlang=${translated.languageCode} video=${videoInfo.videoId}`);
        return tracks.concat([translated]);
      }
    } catch (e) {
      logger.warn(`${TAG} auto-translate track build failed: ${(e as Error).message || e}`);
    }
    return tracks;
  }

  /** youtube_core StreamInfo → mediaservice StreamInfo (shared by play() and
   * the live HLS variant path). durationMs backfills approxDurationMs for
   * clients (e.g. android_vr) whose formats omit it — the EDL/DASH dual-track
   * builders refuse to build without a duration. */
  private mapToPlayerStreams(streams: YouTubeStreamInfo[], durationMs?: number): StreamInfo[] {
    const fallbackDuration = durationMs && durationMs > 0 ? durationMs : undefined;
    return streams.map((stream: YouTubeStreamInfo): StreamInfo => ({
      url: stream.url,
      isUrl: stream.isUrl,
      itag: stream.itag,
      hasVideo: stream.hasVideo,
      hasAudio: stream.hasAudio,
      kind: stream.kind || '',
      quality: stream.qualityLabel,
      format: stream.container,
      audioQuality: stream.audioQuality,
      videoQuality: stream.qualityLabel,
      mimeType: stream.mimeType,
      codecs: stream.codecs,
      bitrate: stream.bitrate,
      fps: stream.videoFps,
      deliveryMethod: stream.deliveryMethod,
      height: stream.height,
      width: stream.width,
      audioLanguage: stream.audioLanguage,
      audioTrackId: stream.audioTrackId,
      audioTrackName: stream.audioTrackName,
      audioTrackType: stream.audioTrackType,
      // DASH SegmentBase (用于生成 MPD)
      initRangeStart: stream.initRange?.start,
      initRangeEnd: stream.initRange?.end,
      indexRangeStart: stream.indexRange?.start,
      indexRangeEnd: stream.indexRange?.end,
      contentLength: stream.contentLength,
      approxDurationMs: stream.approxDurationMs ?? fallbackDuration,
      isOtf: stream.isOtf,
      sourceClient: stream.sourceClient,
      sabrInfo: stream.sabrInfo,
    }));
  }

  /**
   * Live quality management: background fetch + parse of the HLS master
   * playlist into per-variant streams. Must only be called after playback has
   * started — it adds one manifest GET and must never sit on the TTFF path.
   */
  async fetchLiveHlsVariants(videoInfo: VideoInfo): Promise<StreamInfo[]> {
    if (!videoInfo.isLive || !videoInfo.hlsUrl) return [];
    if (!this.extractor) await this.initialize();
    if (!this.extractor) return [];
    try {
      const variants = await this.extractor.fetchHlsVariantStreams(videoInfo.hlsUrl, videoInfo.videoId);
      return this.mapToPlayerStreams(variants, videoInfo.durationMs);
    } catch (e) {
      logger.warn(`${TAG} fetchLiveHlsVariants failed: ${(e as Error).message || e}`);
      return [];
    }
  }

  /** Inject pot= into DASH/progressive stream URLs (not SABR). */
  private async injectDashPoToken(videoInfo: VideoInfo): Promise<void> {
    // PipePipe: tv_downgraded and visionos are fully token-free — /player
    // carries no pot and media URLs never get pot= either.
    const clientKey = YoutubePlayerClientConfig.getYoutubePlayerClient();
    if (clientKey === 'tv_downgraded' || clientKey === 'visionos') {
      logger.info(`${TAG} ${clientKey} is token-free; skipping Dash PoToken injection`);
      return;
    }
    // Identity layer is the single visitorData source: the session-pinned value
    // (pinned from this extraction's player response when still unpinned) so the
    // DASH mint reuses the already initialized BotGuard runtime.
    const visitorData = YoutubeJavaScriptPlayerManager.getSessionVisitorData(
      videoInfo.playerResponse?.responseContext?.visitorData);
    if (!visitorData || visitorData.length === 0) {
      logger.info(`${TAG} no visitorData, skipping Dash PoToken injection`);
      return;
    }
    const startMs = Date.now();
    const potStr = await SabrWebViewPoTokenProvider.getInstance()
      .getDashPoToken(visitorData, videoInfo.videoId);
    if (!potStr) {
      logger.info(`${TAG} Dash PoToken not available video=${videoInfo.videoId}`);
      return;
    }
    let injected = 0;
    for (const stream of videoInfo.streams) {
      if (!stream.url || stream.url.includes('pot=')) continue;
      if (stream.deliveryMethod === 'SABR' || stream.kind === 'sabr') continue;
      const sep = stream.url.includes('?') ? '&' : '?';
      stream.url = `${stream.url}${sep}pot=${potStr}`;
      injected++;
    }
    const elapsed = Date.now() - startMs;
    logger.info(`${TAG} Dash PoToken injected for ${injected} streams video=${videoInfo.videoId} elapsed=${elapsed}ms`);
  }

  private determineNoStreamsErrorCode(videoInfo: VideoInfo): YouTubeErrorCode {
    if (videoInfo.isAgeRestricted) return YouTubeErrorCode.AGE_RESTRICTED;
    if (videoInfo.requiresLogin) return YouTubeErrorCode.LOGIN_REQUIRED;
    return YouTubeErrorCode.NO_STREAMS;
  }

  private analyzeErrorCode(error: Error): YouTubeErrorCode {
    if (error instanceof AgeRestrictedContentException) {
      return YouTubeErrorCode.AGE_RESTRICTED;
    }
    if (error instanceof GeographicRestrictionException) {
      return YouTubeErrorCode.GEO_RESTRICTED;
    }
    if (error instanceof PaidContentException) {
      return YouTubeErrorCode.PAID_CONTENT;
    }
    if (error instanceof YoutubeMusicPremiumContentException) {
      return YouTubeErrorCode.PREMIUM_CONTENT;
    }
    if (error instanceof PrivateContentException) {
      return YouTubeErrorCode.VIDEO_PRIVATE;
    }
    if (error instanceof LoginRequiredException || error instanceof SignInConfirmNotBotException) {
      return YouTubeErrorCode.LOGIN_REQUIRED;
    }
    if (error instanceof AccountTerminatedException) {
      return YouTubeErrorCode.CONTENT_NOT_AVAILABLE;
    }
    if (error instanceof LiveStreamOfflineException) {
      return YouTubeErrorCode.CONTENT_NOT_AVAILABLE;
    }
    if (error instanceof ContentNotSupportedException) {
      return YouTubeErrorCode.CONTENT_NOT_AVAILABLE;
    }
    if (error instanceof ContentNotAvailableException) {
      return YouTubeErrorCode.CONTENT_NOT_AVAILABLE;
    }
    if (error instanceof ExtractionException) {
      return YouTubeErrorCode.EXTRACT_FAILED;
    }

    const errorMsg = error.message?.toLowerCase() || '';
    const errorName = error.name?.toLowerCase() || '';
    // HttpError from HttpDownloader (@kit.NetworkKit http module)
    // http 模块 BusinessError.code 在 message 中的格式：{"code":2300028,"message":"Timeout was reached"}
    if (errorName === 'httperror') {
      if (errorMsg.includes('401') || errorMsg.includes('403') || errorMsg.includes('2300009')) {
        return YouTubeErrorCode.CONTENT_NOT_AVAILABLE;
      }
      if (errorMsg.includes('429')) {
        return YouTubeErrorCode.NETWORK_ERROR;
      }
      return YouTubeErrorCode.NETWORK_ERROR;
    }
    // RCP 模块 (@kit.RemoteCommunicationKit) BusinessError 错误码
    if (errorMsg.includes('1007900028') || errorMsg.includes('2300028') ||
        errorMsg.includes('timeout')) {
      return YouTubeErrorCode.TIMEOUT;
    }
    // 网络连接失败类错误：DNS 解析失败、连接被拒绝、连接重置
    if (errorMsg.includes('2300006') || errorMsg.includes('2300007')) {
      return YouTubeErrorCode.NETWORK_ERROR;
    }
    // 通用网络错误关键词
    if (errorMsg.includes('network') || errorMsg.includes('连接') ||
        errorMsg.includes('econnrefused') || errorMsg.includes('econnreset') ||
        errorMsg.includes('enotfound') || errorMsg.includes('socket')) {
      return YouTubeErrorCode.NETWORK_ERROR;
    }

    return YouTubeErrorCode.UNKNOWN_ERROR;
  }

  private getErrorMessage(errorCode: YouTubeErrorCode, videoInfo?: VideoInfo, error?: Error): ErrorInfo {
    let message: string | Resource;
    let actionHint: string | Resource | undefined;
    let isRetryable = true;
    let openInBrowserUrl: string | undefined;

    switch (errorCode) {
      case YouTubeErrorCode.AGE_RESTRICTED:
        message = $r('app.string.yt_error_age_restricted');
        actionHint = $r('app.string.yt_error_age_restricted_hint');
        isRetryable = false;
        openInBrowserUrl = videoInfo?.videoId ? `https://www.youtube.com/watch?v=${videoInfo.videoId}` : undefined;
        break;
      case YouTubeErrorCode.GEO_RESTRICTED:
        message = $r('app.string.yt_error_geo_restricted');
        actionHint = $r('app.string.yt_error_geo_restricted_hint');
        isRetryable = false;
        break;
      case YouTubeErrorCode.PAID_CONTENT:
        message = $r('app.string.yt_error_paid_content');
        actionHint = $r('app.string.yt_error_paid_content_hint');
        isRetryable = false;
        openInBrowserUrl = videoInfo?.videoId ? `https://www.youtube.com/watch?v=${videoInfo.videoId}` : undefined;
        break;
      case YouTubeErrorCode.PREMIUM_CONTENT:
        message = $r('app.string.yt_error_premium_content');
        actionHint = $r('app.string.yt_error_premium_content_hint');
        isRetryable = false;
        openInBrowserUrl = videoInfo?.videoId ? `https://www.youtube.com/watch?v=${videoInfo.videoId}` : undefined;
        break;
      case YouTubeErrorCode.VIDEO_PRIVATE:
        message = $r('app.string.yt_error_private_content');
        actionHint = $r('app.string.yt_error_private_content_hint');
        isRetryable = false;
        break;
      case YouTubeErrorCode.LOGIN_REQUIRED:
        message = $r('app.string.yt_error_login_required');
        actionHint = $r('app.string.yt_error_login_required_hint');
        isRetryable = false;
        openInBrowserUrl = videoInfo?.videoId ? `https://www.youtube.com/watch?v=${videoInfo.videoId}` : undefined;
        break;
      case YouTubeErrorCode.NETWORK_ERROR:
        message = $r('app.string.yt_error_network');
        actionHint = $r('app.string.yt_error_network_hint');
        isRetryable = true;
        break;
      case YouTubeErrorCode.TIMEOUT:
        message = $r('app.string.yt_error_timeout');
        actionHint = $r('app.string.yt_error_timeout_hint');
        isRetryable = true;
        break;
      case YouTubeErrorCode.CIPHER_DECRYPT_FAILED:
        message = $r('app.string.yt_error_cipher_failed');
        actionHint = $r('app.string.yt_error_cipher_failed_hint');
        isRetryable = false;
        break;
      case YouTubeErrorCode.EXTRACT_FAILED:
        message = $r('app.string.yt_error_extraction_failed');
        actionHint = $r('app.string.yt_error_extraction_failed_hint');
        isRetryable = true;
        break;
      case YouTubeErrorCode.CONTENT_NOT_AVAILABLE:
        if (error instanceof AccountTerminatedException) {
          message = $r('app.string.yt_error_account_terminated');
          actionHint = $r('app.string.yt_error_account_terminated_hint');
          isRetryable = false;
        } else if (error instanceof LiveStreamOfflineException) {
          message = $r('app.string.yt_error_live_offline');
          actionHint = $r('app.string.yt_error_live_offline_hint');
          isRetryable = true;
        } else if (error instanceof ContentNotSupportedException) {
          message = $r('app.string.yt_error_content_not_supported');
          actionHint = $r('app.string.yt_error_content_not_supported_hint');
          isRetryable = false;
        } else {
          message = $r('app.string.yt_error_load_video');
          isRetryable = false;
        }
        break;
      default:
        message = error?.message || $r('app.string.yt_error_playback_failed');
        isRetryable = true;
    }

    return new ErrorInfo(errorCode, message, {
      isRetryable,
      openInBrowserUrl,
      actionHint,
      exception: error
    });
  }

  private extractVideoId(input: string): string | undefined {
    if (!input) return undefined;
    const trimmed = input.trim();
    if (trimmed.length === 11) return trimmed;
    const match = trimmed.match(/(?:v=|\/)([a-zA-Z0-9_-]{11})(?:&|\?|$)/);
    return match ? match[1] : undefined;
  }

  clearCache(): void {
    if (this.extractor) this.extractor.clearCache();
  }
}
