import { YTCoreLogger } from '../common/YTCoreLogger';
import {
  fixThumbnailUrl,
  pickHighestThumbnailUrl,
  getTextFromObject,
  parseDurationString,
  generateContentPlaybackNonce,
  generateTParameter,
  getNestedValue,
  parseMixedNumber,
  parseSubscriberCount,
  parseDurationText
} from '../common/YoutubeParsingHelper';
import { YouTubeHttpClient } from '../network/YouTubeHttpClient';
import { AuthSessionManager } from '../auth/AuthSessionManager';
import { http } from '@kit.NetworkKit';

import { VideoInfo, ThumbnailInfo, ChapterInfo, SubtitleTrack, RelatedVideoInfo } from './VideoInfo';
import { PlayerResponse, VideoDetails, PlayerMicroformatRenderer, ThumbnailItem, Chapter, TextRuns, StreamingData, Format, MimeTypeParseResult, AudioTrackInfo, Range, PlayabilityStatus, CaptionTrack, NextResponse, CompactVideoRenderer, VideoSecondaryInfoRenderer, VideoPrimaryInfoRenderer, LockupViewModel, NextResponseText } from './PlayerResponseTypes';
import { ClientsConstants } from '../model/ClientsConstants';
import { StreamInfo, StreamRange, containSimilarStream } from './StreamInfo';
import { DeliveryMethod } from '../model/DeliveryType';
import { common } from '@kit.AbilityKit';
import { ClientFetchContext, ClientFetchResult } from './clients/ClientTypes';
import { ConfiguredPlayerClient } from './clients/ConfiguredPlayerClient';
import { WebClientVersionResolver } from '../common/WebClientVersionResolver';
import {
  YoutubePlayerClientConfig,
  YoutubePlayerClientKey
} from '../model/YoutubePlayerClientConfig';
import { YoutubeSabrInfo, YoutubeSabrFormatMeta } from './sabr/YoutubeSabrInfo';
import { ItagItem, ItagType } from './itag/ItagItem';
import { MediaFormat, getMediaFormatMimeType, getMediaFormatSuffix } from './itag/MediaFormat';
import { ItagInfo } from './ItagInfo';
import { parseHlsMasterManifest } from './HlsManifestParser';
import { YoutubeJavaScriptPlayerManager } from './cipher/YoutubeJavaScriptPlayerManager';
import { PipePipeApiDecoder, PlayerMetadata } from './cipher/PipePipeApiDecoder';
import {
  ExtractorException,
  ContentNotAvailableException,
  AgeRestrictedContentException,
  PrivateContentException,
  PaidContentException,
  YoutubeMusicPremiumContentException,
  GeographicRestrictionException,
  LoginRequiredException,
  AccountTerminatedException,
  LiveStreamOfflineException,
  SignInConfirmNotBotException,
  ContentNotSupportedException,
  ExtractionException
} from './YouTubeExceptions';

import { CommentItem, CommentResponse } from './CommentItem';

const logger = YTCoreLogger.getInstance('YouTubeExtractor');

/**
 * Selected stream player result (PipePipe configuredStreamingData).
 */
export interface InnertubePlayerResult {
  /** Selected stream client player response */
  player: PlayerResponse | undefined;
  cpn: string | undefined;
  sourceClient: string | undefined;
  /** @deprecated use player — kept for transitional call sites */
  android: PlayerResponse | undefined;
  /** @deprecated use player */
  safari: PlayerResponse | undefined;
  androidCpn: string | undefined;
  safariCpn: string | undefined;
}

/** One failed InnerTube client fetch (for aggregated error reporting). */
export class ExtractorStageError {
  source: string = '';
  error: Error = new Error('');

  constructor(source: string, error: Error) {
    this.source = source;
    this.error = error;
  }
}

/** Cached manifest n-decryption result */
interface ManifestNDecodeResult {
  original: string;
  decoded: string;
}

interface PlaybackEnrichmentTask {
  webMetaPromise: Promise<PlayerResponse | undefined>;
  nextPromise: Promise<NextResponse | null>;
  startedAt: number;
}

/**
 * Android visitor ID request context
 */
export interface AndroidVisitorClientContext {
  clientName: string;
  clientVersion: string;
  clientScreen: string;
  androidSdkVersion: string;
  osName: string;
  osVersion: string;
  hl: string;
  gl: string;
  platform: string;
  utcOffsetMinutes: number;
}

/**
 * Android visitor ID internal context
 */
export interface AndroidVisitorContext {
  client: AndroidVisitorClientContext;
  request: InnerTubeRequest;
  user: InnerTubeUser;
}

/**
 * Android visitor ID request payload
 */
export interface AndroidVisitorPayload {
  context: AndroidVisitorContext;
}

/**
 * Android visitor ID response context
 */
export interface AndroidVisitorResponseContext {
  visitorData?: string;
}

/**
 * Android visitor ID response
 */
export interface AndroidVisitorResponse {
  responseContext?: AndroidVisitorResponseContext;
}

/**
 * Candidate playerResponse
 */
export interface PlayerCandidate {
  source: string;
  pr: PlayerResponse | undefined;
}

/**
 * InnerTube client context
 */
export interface InnerTubeClientContext {
  clientName: string;
  clientVersion: string;
  clientScreen?: string;
  androidSdkVersion?: string;
  deviceMake?: string;
  deviceModel?: string;
  osName?: string;
  osVersion?: string;
  hl: string;
  gl: string;
  platform: string;
  visitorData?: string;
  utcOffsetMinutes?: number;
  originalUrl?: string;
}

/**
 * InnerTube request context (contains client only)
 */
export interface InnerTubeContext {
  client: InnerTubeClientContext;
  request?: InnerTubeRequest;
  user?: InnerTubeUser;
}

/**
 * InnerTube request config
 */
export interface InnerTubeRequest {
  internalExperimentFlags: string[];
  useSsl: boolean;
}

/**
 * InnerTube user config
 */
export interface InnerTubeUser {
  lockedSafetyMode: boolean;
}

/**
 * InnerTube next request payload (for comments etc.)
 */
export interface InnerTubeNextPayload {
  context: InnerTubeContext;
  videoId?: string;
  continuation?: string;
}

/**
 * Extraction error class
 */
export class ExtractError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ExtractError';
  }
}

/**
 * YouTube Video Extractor
 */
export class YouTubeExtractor {
  private client: YouTubeHttpClient;
  private context: common.UIAbilityContext;

  // Process-level STS cache (watch HTML or remote latest-player).
  private static cachedSignatureTimestamp: number | undefined = undefined;

  // WEB desktop client version for metadata / next (PipePipe getClientVersion fallback).
  private static cachedWebClientVersion: string | undefined = undefined;

  // Live HLS recovered via extra MWEB player (PipePipe mwebHlsManifestUrl).
  private mwebHlsManifestUrl: string = '';

  // Cached /next from extractVideoStreams (PipePipe onFetchPage await); reused by extras.
  private playbackEnrichmentTasks: Map<string, PlaybackEnrichmentTask> = new Map();

  // Localization settings (playback path overwrites via YouTubePlayService)
  public hl: string = 'en-GB';
  public gl: string = 'US';

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.client = new YouTubeHttpClient(context);
    const authSession = AuthSessionManager.getInstance();
    if (authSession) {
      this.client.setAuthSession(authSession);
    }
  }

  /**
   * Initialize extractor
   */
  async initialize(): Promise<void> {
    const startedAt = Date.now();
    await this.client.initialize();
    logger.info(`[TIMING] http init elapsed=${Date.now() - startedAt}ms`);
  }

  /**
   * Get HTTP client
   */
  getHttpClient(): YouTubeHttpClient {
    return this.client;
  }

  /**
   * Extract video info (metadata only — tests / non-playback callers).
   * Aligned with PipePipe WEB metadata player ($fields, no streamingData).
   */
  async extractVideoInfo(videoId: string): Promise<VideoInfo> {
    logger.info(`Extracting video info for: ${videoId}`);

    // Prefer PipePipe-style WEB metadata /player; fall back to watch HTML for STS/playerId.
    const metaPromise = this.fetchWebMetadataPlayerResponse(videoId);
    const watchPagePromise = this.fetchWatchPage(videoId);

    const metaPr = await metaPromise;
    if (metaPr) {
      this.checkWebMetadataPlayability(metaPr.playabilityStatus);
      this.assertPlayerResponseVideoId(metaPr, videoId);
    }

    const html = await watchPagePromise;
    this.extractPlayerMetadata(html);
    const watchPr = this.extractPlayerResponse(html);

    const playerResponse = this.mergeMetadataPlayerResponse(metaPr, watchPr);
    if (!metaPr) {
      // Watch HTML path: same login skip as stream extract when anonymous page says LOGIN_REQUIRED.
      const authManager = AuthSessionManager.getInstance();
      const hasCookieAuth = authManager?.isSignedIn() === true && !!(authManager?.getCookieString());
      const watchStatus = watchPr.playabilityStatus?.status?.toUpperCase();
      if (!hasCookieAuth || watchStatus !== 'LOGIN_REQUIRED') {
        this.checkPlayabilityStatus(watchPr.playabilityStatus);
      }
    }

    const videoInfo = this.extractMetadata(videoId, playerResponse);
    videoInfo.playerResponse = playerResponse;
    logger.info(`Successfully extracted: ${videoInfo.title}`);
    return videoInfo;
  }

  /**
   * Fetch watch page HTML
   * @param videoId video ID
   * @returns HTML string
   */
  async fetchWatchPage(videoId: string): Promise<string> {
    const watchUrl = `https://www.youtube.com/watch?v=${videoId}&bpctr=9999999999&has_verified=1&hl=en`;
    logger.debug(`Fetching watch page: ${watchUrl}`);

    const response = await this.client.get(watchUrl);

    if (response.responseCode !== 200) {
      throw new ExtractError(`Failed to fetch watch page: HTTP ${response.responseCode}`);
    }

    const html = response.result as string;
    if (!html || html.length === 0) {
      throw new ExtractError('Empty watch page response');
    }

    return html;
  }

  /**
   * Extract ytInitialPlayerResponse from HTML
   * @param html HTML string
   * @returns PlayerResponse
   */
  extractPlayerResponse(html: string): PlayerResponse {
    logger.debug('Extracting player response from HTML');

    const marker = 'ytInitialPlayerResponse';
    const idx = html.indexOf(marker);
    if (idx === -1) {
      throw new ExtractError('Could not find ytInitialPlayerResponse in watch page');
    }

    // Find the opening brace after the marker
    const braceStart = html.indexOf('{', idx + marker.length);
    if (braceStart === -1) {
      throw new ExtractError('Could not find opening brace for ytInitialPlayerResponse');
    }

    // Use brace-matching to extract the complete JSON object
    let depth = 0;
    let inString = false;
    let escaped = false;
    let endPos = -1;
    for (let i = braceStart; i < html.length; i++) {
      const ch = html[i];
      if (escaped) { escaped = false; continue; }
      if (ch === '\\' && inString) { escaped = true; continue; }
      if (ch === '"' && !escaped) { inString = !inString; continue; }
      if (inString) continue;
      if (ch === '{') depth++;
      else if (ch === '}') {
        depth--;
        if (depth === 0) { endPos = i; break; }
      }
    }

    if (endPos === -1) {
      throw new ExtractError('Could not find matching brace for ytInitialPlayerResponse');
    }

    const jsonStr = html.substring(braceStart, endPos + 1);
    try {
      const playerResponse = JSON.parse(jsonStr) as PlayerResponse;
      logger.debug('Successfully parsed player response');
      return playerResponse;
    } catch (e) {
      throw new ExtractError(`Failed to parse player response: ${e}`);
    }
  }

  /**
   * Resolve human-readable playability reason from either direct `reason` string
   * (WEB metadata player) or errorScreen runs (watch HTML / stream clients).
   */
  private resolvePlayabilityReason(playabilityStatus: PlayabilityStatus | undefined): string {
    if (!playabilityStatus) {
      return '';
    }
    if (playabilityStatus.reason && playabilityStatus.reason.length > 0) {
      return playabilityStatus.reason;
    }
    return this.extractTextFromRuns(playabilityStatus.errorScreen?.playerErrorMessageRenderer?.reason);
  }

  /**
   * PipePipe getWebPlayerResponse: only LOGIN_REQUIRED / age-gate hard-fail here.
   * WEB $fields metadata often returns UNPLAYABLE while the stream client (mweb)
   * is still OK — do not abort the whole extract on metadata status alone.
   */
  private checkWebMetadataPlayability(playabilityStatus: PlayabilityStatus | undefined): void {
    if (!playabilityStatus) {
      return;
    }
    const status = playabilityStatus.status?.toUpperCase();
    if (!status || status === 'OK') {
      return;
    }
    if (status === 'LOGIN_REQUIRED') {
      const reason = this.resolvePlayabilityReason(playabilityStatus);
      const reasonLower = reason.toLowerCase();
      if (reasonLower.includes('age') || reasonLower.includes('inappropriate')) {
        throw new AgeRestrictedContentException('This age-restricted video cannot be watched anonymously');
      }
      if (playabilityStatus.desktopLegacyAgeGateReason !== undefined
        && playabilityStatus.desktopLegacyAgeGateReason !== null
        && playabilityStatus.desktopLegacyAgeGateReason !== false
        && playabilityStatus.desktopLegacyAgeGateReason !== 0
        && playabilityStatus.desktopLegacyAgeGateReason !== '0') {
        throw new AgeRestrictedContentException('This age-restricted video cannot be watched anonymously');
      }
      throw new SignInConfirmNotBotException(reason || 'Login required / anti-bot');
    }
    // Soft: metadata WEB may be blocked/unplayable while stream player has streamingData.
    const reason = this.resolvePlayabilityReason(playabilityStatus);
    logger.warn(`[META] WEB metadata playability ignored status=${status} reason=${reason || '(none)'}`);
  }

  private assertPlayerResponseVideoId(playerResponse: PlayerResponse, videoId: string): void {
    const responseId = playerResponse.videoDetails?.videoId;
    if (responseId && responseId !== videoId) {
      throw new ExtractionException(
        `WEB metadata player response videoId mismatch: expected ${videoId}, got ${responseId}`
      );
    }
  }

  /**
   * Merge PipePipe-style WEB metadata fields onto watch HTML player response.
   * Watch HTML remains the STS/playerId source; metadata player owns microformat /
   * storyboards / higher-quality videoDetails when present.
   */
  private mergeMetadataPlayerResponse(
    metaPr: PlayerResponse | undefined,
    watchPr: PlayerResponse
  ): PlayerResponse {
    if (!metaPr) {
      return watchPr;
    }
    if (metaPr.microformat) {
      watchPr.microformat = metaPr.microformat;
    }
    if (metaPr.storyboards) {
      watchPr.storyboards = metaPr.storyboards;
    }
    if (metaPr.videoDetails) {
      // Prefer metadata videoDetails when present (PipePipe stores WEB microformat/videoDetails).
      watchPr.videoDetails = metaPr.videoDetails;
    }
    if (metaPr.playabilityStatus) {
      watchPr.playabilityStatus = metaPr.playabilityStatus;
    }
    return watchPr;
  }

  /**
   * Check playability status
   * @param playabilityStatus
   */
  private checkPlayabilityStatus(playabilityStatus: PlayabilityStatus | undefined): void {
    if (!playabilityStatus) {
      logger.warn('No playabilityStatus in playerResponse');
      return;
    }

    const status: string | undefined = playabilityStatus.status;
    
    if (!status || status.toUpperCase() === 'OK') {
      return;
    }

    logger.info(`Playability status: ${status}`);

    const reason = this.resolvePlayabilityReason(playabilityStatus);
    const reasonLower = reason.toLowerCase();

    if (status.toUpperCase() === 'LOGIN_REQUIRED') {
      if (reasonLower.includes('inappropriate for some users') || reasonLower.includes('age')) {
        throw new AgeRestrictedContentException('Age restricted content');
      }
      if (reasonLower.includes('private')) {
        throw new PrivateContentException('Private video');
      }
      if (reasonLower.includes('bot')) {
        throw new SignInConfirmNotBotException('Bot protection triggered');
      }
      // Age-restricted may also show with "Sign in to confirm your age"
      if (reasonLower.includes('confirm your age')) {
        throw new AgeRestrictedContentException('Age restricted content (confirm age)');
      }
      if (playabilityStatus.desktopLegacyAgeGateReason !== undefined
        && playabilityStatus.desktopLegacyAgeGateReason !== null
        && playabilityStatus.desktopLegacyAgeGateReason !== false
        && playabilityStatus.desktopLegacyAgeGateReason !== 0
        && playabilityStatus.desktopLegacyAgeGateReason !== '0') {
        throw new AgeRestrictedContentException('Age restricted content (desktop age gate)');
      }
      throw new LoginRequiredException('Login required');
    }

    if (status.toUpperCase() === 'UNPLAYABLE' || status.toUpperCase() === 'ERROR') {
      if (reasonLower.includes('music premium')) {
        throw new YoutubeMusicPremiumContentException('Music Premium content');
      }
      if (reasonLower.includes('payment') || reasonLower.includes('paid') || 
          reasonLower.includes('purchase') || reasonLower.includes('rent') || 
          reasonLower.includes('buy') || reasonLower.includes('members-only') ||
          reasonLower.includes('members')) {
        throw new PaidContentException('Paid content');
      }
      if (reasonLower.includes('country') || reasonLower.includes('geo') || 
          reasonLower.includes('region') || reasonLower.includes('available in your country')) {
        throw new GeographicRestrictionException('Geo restricted');
      }
      if (reasonLower.includes('closed') || reasonLower.includes('terminated')) {
        throw new AccountTerminatedException('Account terminated');
      }
      if (reasonLower.includes('unavailable')) {
        const subreason = this.extractTextFromRuns(
          playabilityStatus.errorScreen?.playerErrorMessageRenderer?.subreason);
        if (subreason && (subreason.toLowerCase().includes('country') || 
            subreason.toLowerCase().includes('region') || 
            subreason.toLowerCase().includes('available in your'))) {
          throw new GeographicRestrictionException('Geo restricted');
        }
        if (subreason) {
          throw new ContentNotAvailableException(subreason);
        }
        throw new ContentNotAvailableException(reason);
      }
      if (reasonLower.includes('this live event')) {
        throw new LiveStreamOfflineException('Live event not started');
      }
      if (reasonLower.includes('premieres in')) {
        throw new ContentNotAvailableException('Premiere not started');
      }
    }

    if (status.toUpperCase() === 'LIVE_STREAM_OFFLINE') {
      throw new LiveStreamOfflineException('Live offline');
    }

    if (status.toUpperCase() === 'UNAVAILABLE') {
      throw new ContentNotAvailableException('Content unavailable');
    }

    const errorMsg = reason ? `Unplayable: ${reason}` : `Unplayable: ${status}`;
    throw new ContentNotAvailableException(errorMsg);
  }

  /**
   * Extract video metadata
   * @param videoId video ID
   * @param playerResponse
   * @returns VideoInfo
   */
  extractMetadata(videoId: string, playerResponse: PlayerResponse): VideoInfo {
    logger.debug('Extracting metadata');

    const videoInfo = new VideoInfo(videoId);

    const vd = playerResponse.videoDetails || {};
    const micro = (playerResponse.microformat?.playerMicroformatRenderer) || {};

    videoInfo.title = vd.title || this.extractTextFromRuns(micro.title) || '';
    videoInfo.author = vd.author || micro.ownerChannelName || '';
    videoInfo.channelId = vd.channelId || micro.externalChannelId || '';
    
    // Duration fallback (Fix #1464)
    let lengthSecs = this.parseIntSafe(vd.lengthSeconds) || this.parseIntSafe(micro.lengthSeconds);
    
    // Fallback to adaptiveFormats approxDurationMs if length is still unknown
    if (lengthSecs === undefined && playerResponse.streamingData?.adaptiveFormats?.length) {
      const approxMs = this.parseIntSafe(playerResponse.streamingData.adaptiveFormats[0].approxDurationMs);
      if (approxMs) {
        lengthSecs = Math.round(approxMs / 1000);
      }
    }
    
    videoInfo.lengthSeconds = lengthSecs;
    if (videoInfo.lengthSeconds) {
      videoInfo.durationMs = videoInfo.lengthSeconds * 1000;
    }
    
    videoInfo.viewCount = this.parseIntSafe(vd.viewCount) || this.parseIntSafe(micro.viewCount);
    // 使用 liveBroadcastDetails.isLiveNow 区分直播与回放
    // vd.isLiveContent 对回放也返回 true，只有 isLiveNow 代表真正在直播
    videoInfo.isLive = micro.liveBroadcastDetails?.isLiveNow === true;
    videoInfo.description = vd.shortDescription || this.extractTextFromRuns(micro.description) || '';

    const thumbs = vd.thumbnail?.thumbnails || micro.thumbnail?.thumbnails || [];
    videoInfo.thumbnails = thumbs.map((t: ThumbnailItem) => new ThumbnailInfo(
      t.url || '',
      t.width,
      t.height
    ));

    videoInfo.publishDate = micro.publishDate || micro.uploadDate;
    videoInfo.uploadDate = micro.uploadDate;
    videoInfo.category = micro.category;

    const tags = micro.tags || vd.keywords || [];
    videoInfo.tags = Array.isArray(tags) ? tags : [];

    const sb = playerResponse.storyboards?.playerStoryboardSpecRenderer || {};
    videoInfo.storyboardSpec = sb.spec || undefined;

    const chapters = playerResponse.chapters || [];
    videoInfo.chapters = chapters.map((c: Chapter) => new ChapterInfo(
      this.extractTextFromRuns(c.title),
      (c.timeRangeStartMillis || 0) / 1000
    ));

    // 字幕轨道不在此处提取——watch HTML 的 ytInitialPlayerResponse.captions 经常被裁剪/baseUrl 为空。
    // 字幕统一在 extractVideoStreams 末尾基于 selectBestPlayerResponse 选出的 best PR 提取一次，避免重复解析。

    logger.debug(`Metadata extracted: ${videoInfo.title}`);

    return videoInfo;
  }

  /**
   * 从指定 PlayerResponse 提取字幕轨道列表。
   * 与 PipePipe YoutubeStreamExtractor.getSubtitles 等价：跳过无 baseUrl 的 track，去除已有 fmt/tlang，
   * 再追加 &fmt=vtt（PipePipe 默认 TTML，这里保留 VTT 以匹配下游解码器）。
   */
  private extractSubtitleTracks(playerResponse: PlayerResponse | undefined): SubtitleTrack[] {
    const tracklist = playerResponse?.captions?.playerCaptionsTracklistRenderer;
    if (!tracklist?.captionTracks?.length) {
      return [];
    }
    const subtitleTracks: SubtitleTrack[] = [];
    for (let i = 0; i < tracklist.captionTracks.length; i++) {
      const track = tracklist.captionTracks[i];
      const baseUrl = track.baseUrl || '';
      if (!baseUrl) {
        continue;
      }
      // WEB/MWEB /player can return `/api/timedtext?...` while watch HTML usually returned
      // an absolute URL. MPV cannot resolve that path against youtube.com (the media source is
      // our loopback DASH proxy), so normalize it before handing the track to the player.
      const absoluteBaseUrl = baseUrl.startsWith('//')
        ? `https:${baseUrl}`
        : (baseUrl.startsWith('/') ? `https://www.youtube.com${baseUrl}` : baseUrl);
      const cleanUrl = absoluteBaseUrl
        .replace(/([?&])fmt=[^&]*/g, '$1')
        .replace(/([?&])tlang=[^&]*/g, '$1')
        .replace(/\?&/, '?')
        .replace(/&&/g, '&')
        .replace(/&$/, '')
        .replace(/\?$/, '');
      const vttUrl = cleanUrl.includes('?') ? `${cleanUrl}&fmt=vtt` : `${cleanUrl}?fmt=vtt`;
      const name = this.extractTextFromRuns(track.name);
      const isAutoGenerated = track.vssId?.startsWith('a.') ?? false;

      logger.debug(`[SUBTITLE_EXTRACT] lang=${track.languageCode} kind=${track.kind} autoGen=${isAutoGenerated} baseUrlLen=${baseUrl.length}`);
      // 帮助排查 lang 混淆问题：抽 baseUrl 中的语言相关参数
      const langMatch = baseUrl.match(/[?&]lang=([^&]+)/);
      const nameMatch = baseUrl.match(/[?&]name=([^&]+)/);
      const kindMatch = baseUrl.match(/[?&]kind=([^&]+)/);
      const tlangMatch = baseUrl.match(/[?&]tlang=([^&]+)/);
      logger.info(`[SUBTITLE_EXTRACT]   baseUrl lang=${langMatch?.[1] || '(none)'} tlang=${tlangMatch?.[1] || '(none)'} name=${nameMatch?.[1] || '(none)'} kind=${kindMatch?.[1] || '(none)'}`);
      logger.info(`[SUBTITLE_EXTRACT]   vttUrl=${vttUrl}`);

      subtitleTracks.push(new SubtitleTrack(vttUrl, track.languageCode || '', name, track.kind, isAutoGenerated, track.isTranslatable));
    }
    return subtitleTracks;
  }

  /**
   * Extract text from TextRuns
   * @param textRuns
   * @returns string
   */
  private extractTextFromRuns(textRuns?: TextRuns): string {
    return getTextFromObject(textRuns as Record<string, Object>);
  }

  /**
   * Safe parse int
   * @param value
   * @returns number or undefined
   */
  private parseIntSafe(value: string | undefined): number | undefined {
    if (!value) {
      return undefined;
    }
    const parsed = parseInt(value, 10);
    return isNaN(parsed) ? undefined : parsed;
  }

  // ========================================================================
  // Stream extraction - Phase 2 will rewrite ensureStreamsAreCached() pattern
  // ========================================================================

  private cachedAudioStreams: StreamInfo[] = [];
  private cachedVideoStreams: StreamInfo[] = [];
  private cachedVideoOnlyStreams: StreamInfo[] = [];
  private streamsCachedVideoId: string = '';
  private cachedManifestNResult: ManifestNDecodeResult | null = null;
  private decoderPlayerId: string | null = null;

  // Selected stream client streaming data (PipePipe configuredStreamingData)
  private configuredStreamingData: StreamingData | undefined;
  private configuredCpn: string | undefined;
  private configuredSourceClient: string | undefined;
  private cachedInnertubePlayers: InnertubePlayerResult | undefined;
  // Transitional aliases used by older helpers
  private safariStreamingData: StreamingData | undefined;
  private androidStreamingData: StreamingData | undefined;
  private safariCpn: string | undefined;
  private androidCpn: string | undefined;

  // Aggregated errors across fetch stages (对齐 PipePipe YoutubeStreamExtractor.errors[]).
  // In allow surfacing root cause when all clients fail; otherwise final exception loses details.
  private errors: ExtractorStageError[] = [];

  /**
   * PipePipe ensureStreamsAreCached:
   *   mweb/web + VOD + serverAbrStreamingUrl → SABR bootstrap streams
   *   else adaptiveFormats (not formats[]) except tv_downgraded+LIVE
   *   + HLS for post-live / live+tv / web_safari
   */
  private async buildAndCacheStreams(videoId: string, innertubePlayers: InnertubePlayerResult,
    metaPlayerResponse: PlayerResponse): Promise<void> {
    this.cachedManifestNResult = null;
    this.cachedInnertubePlayers = innertubePlayers;
    this.cachedAudioStreams = [];
    this.cachedVideoStreams = [];
    this.cachedVideoOnlyStreams = [];

    const primaryPr = innertubePlayers.player
      ?? innertubePlayers.safari
      ?? innertubePlayers.android;
    if (primaryPr?.playabilityStatus) {
      this.checkPlayabilityStatus(primaryPr.playabilityStatus);
    }

    this.configuredStreamingData = primaryPr?.streamingData
      ?? innertubePlayers.player?.streamingData
      ?? innertubePlayers.safari?.streamingData
      ?? innertubePlayers.android?.streamingData;
    this.configuredCpn = innertubePlayers.cpn
      ?? innertubePlayers.safariCpn
      ?? innertubePlayers.androidCpn
      ?? '';
    this.configuredSourceClient = innertubePlayers.sourceClient
      ?? YoutubePlayerClientConfig.getYoutubePlayerClient();
    this.safariStreamingData = this.configuredStreamingData;
    this.androidStreamingData = this.configuredStreamingData;
    this.safariCpn = this.configuredCpn;
    this.androidCpn = this.configuredCpn;

    const selectedClient = YoutubePlayerClientConfig.getYoutubePlayerClient();
    const isLive = this.resolveIsLive(metaPlayerResponse, primaryPr);
    const isPostLive = this.resolveIsPostLive(metaPlayerResponse, primaryPr);
    const hasSabrUrl = !!(this.configuredStreamingData?.serverAbrStreamingUrl
      && this.configuredStreamingData.serverAbrStreamingUrl.length > 0);

    logger.info(`[STREAM] ensureStreams client=${selectedClient} isLive=${isLive} postLive=${isPostLive} `
      + `hasSabrUrl=${hasSabrUrl} adaptive=${this.configuredStreamingData?.adaptiveFormats?.length ?? 0}`);

    // SABR path (PipePipe): mweb|web + VOD + serverAbrStreamingUrl
    if ((selectedClient === 'mweb')
      && !isLive && !isPostLive
      && hasSabrUrl) {
      const sabrBuilt = await this.buildSabrStreams(videoId, primaryPr, this.configuredCpn || '', selectedClient);
      if (sabrBuilt) {
        this.streamsCachedVideoId = videoId;
        return;
      }
      logger.warn('[SABR] bootstrap build failed; falling through to adaptive/HLS');
    }

    // Adaptive progressive URLs (PipePipe skips for tv_downgraded + LIVE)
    if (!(selectedClient === 'tv_downgraded' && isLive)) {
      await this.extractAdaptiveFormats(videoId, this.configuredStreamingData, this.configuredCpn || '',
        this.configuredSourceClient || selectedClient);
    }

    // HLS: PipePipe ensureStreamsAreCached conditions only
    // (post-live | live+tv_downgraded | web_safari). No empty-stream extra GET.
    if (isPostLive
      || (isLive && selectedClient === 'tv_downgraded')
      || selectedClient === 'web_safari') {
      await this.tryExtractHlsStreams(videoId);
    }

    this.checkAggregatedErrors(innertubePlayers);

    const hasAnyStream = this.cachedAudioStreams.length > 0
      || this.cachedVideoOnlyStreams.length > 0
      || this.cachedVideoStreams.length > 0;
    if (!hasAnyStream && !this.getHlsManifestUrlFromStreamingData()) {
      throw new ContentNotSupportedException(
        `No playable streams from client=${selectedClient} `
        + `(adaptive=${this.configuredStreamingData?.adaptiveFormats?.length ?? 0}, `
        + `serverAbr=${hasSabrUrl})`
      );
    }

    this.streamsCachedVideoId = videoId;
  }

  private resolveIsLive(meta: PlayerResponse, player?: PlayerResponse): boolean {
    if (meta.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.isLiveNow === true) {
      return true;
    }
    if (player?.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.isLiveNow === true) {
      return true;
    }
    // Fallback: isLiveContent alone is true for VOD of past lives; prefer isLiveNow only.
    return false;
  }

  private resolveIsPostLive(meta: PlayerResponse, player?: PlayerResponse): boolean {
    // Approximate PipePipe isPostLiveDvr: was live content, not live now, has HLS.
    const pr = player ?? meta;
    const isLiveContent = pr.videoDetails?.isLiveContent === true
      || meta.videoDetails?.isLiveContent === true;
    const isLiveNow = meta.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.isLiveNow === true
      || pr.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.isLiveNow === true;
    return isLiveContent && !isLiveNow && !!(pr.streamingData?.hlsManifestUrl || this.mwebHlsManifestUrl);
  }

  /**
   * PipePipe extractAdaptiveFormats: adaptiveFormats only (not formats[]).
   */
  private async extractAdaptiveFormats(
    videoId: string,
    streamingData: StreamingData | undefined,
    cpn: string,
    sourceClient: string
  ): Promise<void> {
    if (!streamingData) {
      return;
    }
    const allItagInfos: ItagInfo[] = [];
    const audioStreams = this.getStreamsFromStreamingDataKey(
      videoId, streamingData, 'adaptiveFormats', ItagType.AUDIO, cpn);
    allItagInfos.push(...audioStreams);
    const videoOnlyStart = allItagInfos.length;
    const videoOnlyStreams = this.getStreamsFromStreamingDataKey(
      videoId, streamingData, 'adaptiveFormats', ItagType.VIDEO_ONLY, cpn);
    allItagInfos.push(...videoOnlyStreams);

    await this.batchDeobfuscateItagUrls(videoId, allItagInfos);

    for (let i = 0; i < videoOnlyStart; i++) {
      const stream = this.buildAudioStreamInfo(allItagInfos[i], sourceClient);
      if (!containSimilarStream(stream, this.cachedAudioStreams)) {
        this.cachedAudioStreams.push(stream);
      }
    }
    this.cachedAudioStreams.sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0));

    for (let i = videoOnlyStart; i < allItagInfos.length; i++) {
      const stream = this.buildVideoStreamInfo(allItagInfos[i], true, sourceClient);
      if (!containSimilarStream(stream, this.cachedVideoOnlyStreams)) {
        this.cachedVideoOnlyStreams.push(stream);
      }
    }
  }

  /**
   * PipePipe buildSabrStreams — reserved entry.
   * Produces StreamInfo with DeliveryMethod.SABR + sabrInfo bootstrap.
   * Full UMP session playback is not implemented yet; mediaservice will reject SABR until then.
   */
  private async buildSabrStreams(
    videoId: string,
    playerResponse: PlayerResponse | undefined,
    cpn: string,
    sourceClient: string
  ): Promise<boolean> {
    if (!playerResponse?.streamingData) {
      return false;
    }
    const sd = playerResponse.streamingData;
    let serverAbr = sd.serverAbrStreamingUrl || '';
    if (!serverAbr) {
      return false;
    }
    const serverAbrBefore = serverAbr;
    try {
      serverAbr = await this.deobfuscateManifestUrl(serverAbr);
      if (serverAbr !== serverAbrBefore) {
        logger.info(`[SABR] serverAbr n-deobfuscated len ${serverAbrBefore.length}->${serverAbr.length}`);
      } else if (/[?&]n=/.test(serverAbrBefore) || /\/n\//.test(serverAbrBefore)) {
        logger.warn('[SABR] serverAbr still has encrypted n (decode may have failed)');
      }
    } catch (e) {
      logger.warn('[SABR] n-deobfuscate serverAbr failed:', e);
    }

    const formats = this.parseSabrFormats(sd);
    if (formats.length === 0) {
      return false;
    }

    const profile = sourceClient === 'web_safari' ? 'web' : 'mweb';
    const clientVersion = sourceClient === 'web_safari'
      ? ClientsConstants.SAFARI_CLIENT_VERSION
      : WebClientVersionResolver.getCachedOrHardcoded();
    const sabrInfo = new YoutubeSabrInfo(profile, videoId, cpn, clientVersion, formats);
    sabrInfo.serverAbrStreamingUrl = serverAbr;
    sabrInfo.visitorData = playerResponse.responseContext?.visitorData;
    sabrInfo.videoPlaybackUstreamerConfig =
      playerResponse.playerConfig?.mediaCommonConfig
        ?.mediaUstreamerRequestConfig?.videoPlaybackUstreamerConfig;

    for (const fmt of formats) {
      if (fmt.isAudio) {
        const stream: StreamInfo = {
          url: serverAbr,
          isUrl: false,
          itag: fmt.itag,
          mimeType: fmt.mimeType,
          qualityLabel: undefined,
          audioQuality: undefined,
          bitrate: fmt.bitrate,
          contentLength: fmt.contentLength,
          hasVideo: false,
          hasAudio: true,
          deliveryMethod: DeliveryMethod.SABR,
          kind: 'sabr',
          sourceClient: sourceClient,
          container: undefined,
          codecs: fmt.codecs,
          initRange: undefined,
          indexRange: undefined,
          approxDurationMs: fmt.approxDurationMs,
          durationMs: fmt.approxDurationMs,
          isLive: false,
          isOtf: false,
          // Locale from track id (e.g. "en.0" / "zh-Hans.4") — required for language ranking.
          audioLanguage: (() => {
            const id = fmt.audioTrackId || '';
            if (!id) {
              return undefined;
            }
            return id.split('.')[0].split('-')[0] || undefined;
          })(),
          audioTrackId: fmt.audioTrackId,
          audioTrackName: fmt.audioTrackName,
          audioTrackType: fmt.isOriginalAudio ? 'original' : undefined,
          audioChannels: undefined,
          audioSampleRate: undefined,
          videoFps: undefined,
          codec: fmt.codecs,
          width: undefined,
          height: undefined,
          sabrInfo: sabrInfo
        };
        if (!containSimilarStream(stream, this.cachedAudioStreams)) {
          this.cachedAudioStreams.push(stream);
        }
      } else if (fmt.isVideo) {
        const stream: StreamInfo = {
          url: serverAbr,
          isUrl: false,
          itag: fmt.itag,
          mimeType: fmt.mimeType,
          qualityLabel: fmt.qualityLabel,
          audioQuality: undefined,
          bitrate: fmt.bitrate,
          contentLength: fmt.contentLength,
          hasVideo: true,
          hasAudio: false,
          deliveryMethod: DeliveryMethod.SABR,
          kind: 'sabr',
          sourceClient: sourceClient,
          container: undefined,
          codecs: fmt.codecs,
          initRange: undefined,
          indexRange: undefined,
          approxDurationMs: fmt.approxDurationMs,
          durationMs: fmt.approxDurationMs,
          isLive: false,
          isOtf: false,
          audioLanguage: undefined,
          audioTrackId: undefined,
          audioTrackName: undefined,
          audioTrackType: undefined,
          audioChannels: undefined,
          audioSampleRate: undefined,
          videoFps: undefined,
          codec: fmt.codecs,
          width: fmt.width,
          height: fmt.height,
          sabrInfo: sabrInfo
        };
        if (!containSimilarStream(stream, this.cachedVideoOnlyStreams)) {
          this.cachedVideoOnlyStreams.push(stream);
        }
      }
    }

    logger.info(`[SABR] reserved bootstrap streams audio=${this.cachedAudioStreams.length} `
      + `videoOnly=${this.cachedVideoOnlyStreams.length} serverAbrLen=${serverAbr.length}`);
    return this.cachedAudioStreams.length > 0 || this.cachedVideoOnlyStreams.length > 0;
  }

  private parseSabrFormats(sd: StreamingData): YoutubeSabrFormatMeta[] {
    const out: YoutubeSabrFormatMeta[] = [];
    const adaptive = sd.adaptiveFormats || [];
    for (const fmt of adaptive) {
      if (!fmt.itag) {
        continue;
      }
      const mime = fmt.mimeType || '';
      const isAudio = mime.startsWith('audio/');
      const isVideo = mime.startsWith('video/');
      if (!isAudio && !isVideo) {
        continue;
      }
      let codecs: string | undefined = undefined;
      const codecMatch = mime.match(/codecs="([^"]+)"/);
      if (codecMatch) {
        codecs = codecMatch[1];
      }
      const track = fmt.audioTrack;
      const displayName = (track?.displayName || '').trim();
      const trackId = track?.id || '';
      const langPart = trackId.length > 0 ? trackId.split('.')[0] : '';
      const audioLocale = langPart.length > 0 ? langPart.split('-')[0] : undefined;
      const isOriginal = (!!displayName
        && (displayName.toLowerCase().includes('original')
          || displayName.toLowerCase().includes('default')
          || displayName.includes('yokuqala')))
        || track?.audioIsDefault === true;
      let initStart: number | undefined = undefined;
      let initEnd: number | undefined = undefined;
      if (fmt.initRange?.start !== undefined) {
        initStart = this.parseIntSafe(fmt.initRange.start);
      }
      if (fmt.initRange?.end !== undefined) {
        initEnd = this.parseIntSafe(fmt.initRange.end);
      }
      if (fmt.indexRange?.end !== undefined) {
        const indexEnd = this.parseIntSafe(fmt.indexRange.end);
        if (indexEnd !== undefined && (initEnd === undefined || indexEnd > initEnd)) {
          initEnd = indexEnd;
        }
      }
      const contentLength = fmt.contentLength
        ? this.parseIntSafe(fmt.contentLength)
        : undefined;
      const approxDurationMs = fmt.approxDurationMs
        ? this.parseIntSafe(fmt.approxDurationMs)
        : undefined;
      const meta: YoutubeSabrFormatMeta = {
        itag: fmt.itag,
        mimeType: mime,
        bitrate: fmt.bitrate ?? fmt.averageBitrate,
        width: fmt.width,
        height: fmt.height,
        lastModified: fmt.lastModified,
        xtags: fmt.xtags,
        isAudio: isAudio,
        isVideo: isVideo && !isAudio,
        qualityLabel: fmt.qualityLabel,
        codecs: codecs,
        audioTrackId: trackId || undefined,
        // Prefer raw YouTube displayName; else raw track id — no synthesized labels.
        audioTrackName: displayName.length > 0 ? displayName : (trackId || undefined),
        isOriginalAudio: isOriginal,
        initializationUrl: fmt.url,
        initRangeStart: initStart,
        initRangeEnd: initEnd,
        contentLength: contentLength,
        approxDurationMs: approxDurationMs
      };
      out.push(meta);
    }
    return out;
  }

  private checkAggregatedErrors(players: InnertubePlayerResult): void {
    const hasAnyPlayer = !!(players.player || players.android || players.safari);
    const hasAnyStream = this.cachedAudioStreams.length > 0
      || this.cachedVideoOnlyStreams.length > 0
      || this.cachedVideoStreams.length > 0;
    if (hasAnyPlayer || hasAnyStream || this.errors.length === 0) {
      return;
    }
    const parts: string[] = [];
    for (const item of this.errors) {
      const msg = item.error?.message || String(item.error);
      parts.push(`${item.source}: ${msg}`);
    }
    throw new ContentNotSupportedException(
      `Stream player failed to return streams. ${parts.join(' | ')}`
    );
  }

  /** True when adaptiveFormats exist but none have progressive url/cipher (SABR-shaped). */
  private isSabrOnlyResponse(players: InnertubePlayerResult): boolean {
    const primarySd = players.player?.streamingData
      ?? this.configuredStreamingData
      ?? players.safari?.streamingData
      ?? players.android?.streamingData;
    if (!primarySd) {
      return false;
    }
    if (primarySd.serverAbrStreamingUrl && primarySd.serverAbrStreamingUrl.length > 0) {
      const adaptive = primarySd.adaptiveFormats;
      if (!adaptive || adaptive.length === 0) {
        return true;
      }
      for (const fmt of adaptive) {
        if (fmt.url || fmt.signatureCipher || fmt.cipher) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  getAudioStreams(): StreamInfo[] {
    return this.cachedAudioStreams;
  }

  getVideoStreams(): StreamInfo[] {
    return this.cachedVideoStreams;
  }

  getVideoOnlyStreams(): StreamInfo[] {
    return this.cachedVideoOnlyStreams;
  }

  /**
   * Extract video streams — PipePipe onFetchPage shape:
   * STS (latest-player primary) → parallel meta + next + stream player → ensureStreams.
   * No watch HTML on critical path; no stream-player pre-fire/retry.
   */
  async extractVideoStreams(videoId: string): Promise<VideoInfo> {
    const criticalStartedAt = Date.now();
    logger.info(`Extracting video streams for: ${videoId}`);
    this.errors = [];
    this.mwebHlsManifestUrl = '';

    const hasCookieAuth = this.hasCookieAuthForRequests();
    YoutubePlayerClientConfig.applyAuthDefault(hasCookieAuth);
    const selectedClient = YoutubePlayerClientConfig.getYoutubePlayerClient();
    logger.info(`[STREAM] selectedClient=${selectedClient} cookieAuth=${hasCookieAuth}`);

    // Stream process cache disabled: always re-hit stream /player (align with fresh extract).
    this.streamsCachedVideoId = '';
    this.cachedAudioStreams = [];
    this.cachedVideoStreams = [];
    this.cachedVideoOnlyStreams = [];

    // STS (latest-player) + WEB clientVersion (sw.js) before parallel trio — independent.
    const stsStartedAt = Date.now();
    const stsPromise = this.resolveSignatureTimestamp(videoId).then((value: number | undefined) => {
      logger.info(`[TIMING] video=${videoId} stage=STS elapsed=${Date.now() - stsStartedAt}ms`);
      return value;
    });
    const versionStartedAt = Date.now();
    const versionPromise = this.ensureWebClientVersion().then((value: string) => {
      logger.info(`[TIMING] video=${videoId} stage=clientVersion elapsed=${Date.now() - versionStartedAt}ms`);
      return value;
    });
    const enrichmentStartedAt = Date.now();
    const webMetaPromise = versionPromise.then(() => {
      const startedAt = Date.now();
      return this.fetchWebMetadataPlayerResponse(videoId).then((value: PlayerResponse | undefined) => {
        logger.info(`[TIMING] video=${videoId} stage=metadata elapsed=${Date.now() - startedAt}ms`);
        return value;
      });
    }).catch((e: Error) => {
      logger.warn(`[META] background fetch failed video=${videoId}: ${e.message || e}`);
      return undefined;
    });
    const nextPromise = versionPromise.then(() => {
      const startedAt = Date.now();
      return this.fetchNextResponse(videoId).then((value: NextResponse | null) => {
        logger.info(`[TIMING] video=${videoId} stage=next elapsed=${Date.now() - startedAt}ms`);
        return value;
      });
    }).catch((e: Error) => {
      logger.warn(`[NEXT] background fetch failed video=${videoId}: ${e.message || e}`);
      return null;
    });
    const enrichmentTask: PlaybackEnrichmentTask = {
      webMetaPromise: webMetaPromise,
      nextPromise: nextPromise,
      startedAt: enrichmentStartedAt
    };
    this.playbackEnrichmentTasks.set(videoId, enrichmentTask);
    setTimeout(() => {
      if (this.playbackEnrichmentTasks.get(videoId) === enrichmentTask) {
        this.playbackEnrichmentTasks.delete(videoId);
      }
    }, 120000);

    const sts = await stsPromise;
    if (sts === undefined || sts <= 0) {
      throw new ExtractionException('signatureTimestamp unavailable (latest-player / cache failed)');
    }

    if (selectedClient === 'mweb') {
      await versionPromise;
    }

    // PipePipe onFetchPage parallel trio: WEB meta + next + selected stream player
    const streamStartedAt = Date.now();
    const innertubePlayers = await this.fetchSelectedStreamPlayer(
      videoId, sts, selectedClient, hasCookieAuth);
    logger.info(`[TIMING] video=${videoId} stage=streamPlayer client=${selectedClient} auth=${hasCookieAuth} elapsed=${Date.now() - streamStartedAt}ms`);

    // Stream-player metadata is sufficient for ordinary startup. TV downgraded
    // responses can expose only videoDetails.isLiveContent, while the definitive
    // isLiveNow flag remains in the WEB metadata response. Resolve that ambiguity
    // here so a current live is not accidentally sent through the DASH/SIDX path.
    let metaBase: PlayerResponse = innertubePlayers.player
      ?? ({ videoDetails: { videoId: videoId } } as PlayerResponse);
    const streamPr = innertubePlayers.player;
    let isLive = this.resolveIsLive(metaBase, streamPr);
    const isPossibleTvLive = selectedClient === 'tv_downgraded'
      && streamPr?.videoDetails?.isLiveContent === true;
    const hlsRecoveryPromise = (isLive || isPossibleTvLive)
      ? ConfiguredPlayerClient.fetchMwebHlsOnly({
        videoId: videoId,
        hl: this.hl,
        gl: this.gl,
        visitorData: undefined,
        signatureTimestamp: sts
      }, this.client, false).catch((e: Error) => {
        logger.warn(`[STREAM] MWEB HLS helper failed: ${e.message || e}`);
        return undefined;
      })
      : Promise.resolve(undefined);

    if (!isLive && isPossibleTvLive) {
      const liveMetaStartedAt = Date.now();
      const webMeta = await webMetaPromise;
      if (webMeta) {
        metaBase = webMeta;
        isLive = this.resolveIsLive(webMeta, streamPr);
      }
      logger.info(`[TIMING] video=${videoId} stage=liveClassification isLive=${isLive} `
        + `elapsed=${Date.now() - liveMetaStartedAt}ms`);
    }

    const videoInfo = this.extractMetadata(videoId, metaBase);
    this.fillMissingIdentityFromPlayer(videoInfo, innertubePlayers.player);
    videoInfo.playerResponse = metaBase;

    const hasConfiguredHls = !!(streamPr?.streamingData?.hlsManifestUrl);
    if ((isLive && (selectedClient === 'tv_downgraded'
      || (selectedClient === 'web_safari' && !hasConfiguredHls))) || isPossibleTvLive) {
      const hls = await hlsRecoveryPromise;
      if (hls) {
        this.mwebHlsManifestUrl = hls;
        logger.info(`[STREAM] recovered anonymous MWEB hlsManifestUrl len=${hls.length}`);
      }
    }
    const streamBuildStartedAt = Date.now();
    await this.buildAndCacheStreams(videoId, innertubePlayers, metaBase);
    logger.info(`[TIMING] video=${videoId} stage=urlDecodeBuild elapsed=${Date.now() - streamBuildStartedAt}ms`);

    videoInfo.streams = [
      ...this.cachedAudioStreams,
      ...this.cachedVideoStreams,
      ...this.cachedVideoOnlyStreams,
    ];

    let captionsSource: PlayerResponse = metaBase;
    if (this.cachedInnertubePlayers) {
      const bestPr = this.selectBestPlayerResponse(videoId, metaBase, this.cachedInnertubePlayers);
      const bestTracks = this.extractSubtitleTracks(bestPr);
      if (bestTracks.length > 0) {
        videoInfo.subtitleTracks = bestTracks;
        captionsSource = bestPr;
      } else {
        videoInfo.subtitleTracks = this.extractSubtitleTracks(metaBase);
      }
    } else {
      videoInfo.subtitleTracks = this.extractSubtitleTracks(metaBase);
    }
    videoInfo.playerResponse = captionsSource;
    logger.info(`[SUBTITLE_EXTRACT] final tracks=${videoInfo.subtitleTracks.length}`);

    const hlsRaw = this.getHlsManifestUrlFromStreamingData();
    if (hlsRaw) {
      videoInfo.hlsUrl = await this.deobfuscateManifestUrl(hlsRaw);
    }
    videoInfo.dashMpdUrl = undefined;

    logger.info(`[TIMING] video=${videoId} stage=criticalExtractComplete client=${selectedClient} auth=${hasCookieAuth} elapsed=${Date.now() - criticalStartedAt}ms streams=${videoInfo.streams.length}`);

    return videoInfo;
  }

  /**
   * STS for stream player: process cache → remote latest-player → optional watch HTML fallback.
   */
  private async resolveSignatureTimestamp(videoId: string): Promise<number | undefined> {
    if (YouTubeExtractor.cachedSignatureTimestamp
      && YouTubeExtractor.cachedSignatureTimestamp > 0) {
      return YouTubeExtractor.cachedSignatureTimestamp;
    }
    try {
      const remote = await PipePipeApiDecoder.getLatestPlayer();
      if (remote.signatureTimestamp > 0) {
        YouTubeExtractor.cachedSignatureTimestamp = remote.signatureTimestamp;
        logger.info(`[STREAM] STS from latest-player: ${remote.signatureTimestamp} player=${remote.playerId}`);
        return remote.signatureTimestamp;
      }
    } catch (e) {
      logger.warn('[STREAM] latest-player STS failed, trying watch HTML fallback:', e);
    }
    // Optional fallback only — not on the happy path.
    try {
      const html = await this.fetchWatchPage(videoId);
      const sts = this.extractPlayerMetadata(html);
      if (sts !== undefined && sts > 0) {
        logger.info(`[STREAM] STS from watch HTML fallback: ${sts}`);
        return sts;
      }
    } catch (e) {
      logger.warn('[STREAM] watch HTML STS fallback failed:', e);
    }
    return YouTubeExtractor.cachedSignatureTimestamp;
  }

  private emptyInnertubeResult(selectedClient: YoutubePlayerClientKey): InnertubePlayerResult {
    return {
      player: undefined,
      cpn: undefined,
      sourceClient: selectedClient,
      android: undefined,
      safari: undefined,
      androidCpn: undefined,
      safariCpn: undefined
    };
  }

  async fetchPlaybackExtras(videoId: string, playerResponse?: PlayerResponse): Promise<VideoInfo> {
    logger.info(`Fetching playback extras for: ${videoId}`);
    const startedAt = Date.now();
    const task = this.playbackEnrichmentTasks.get(videoId);
    const webMetaPromise = task?.webMetaPromise
      ?? this.fetchWebMetadataPlayerResponse(videoId).catch(() => undefined);
    const nextPromise = task?.nextPromise
      ?? this.fetchNextResponse(videoId).catch(() => null);
    const settled = await Promise.allSettled([
      webMetaPromise,
      nextPromise,
      this.fetchDislikeCount(videoId)
    ]);
    this.playbackEnrichmentTasks.delete(videoId);

    const webMeta = settled[0].status === 'fulfilled'
      ? settled[0].value as PlayerResponse | undefined : undefined;
    const nextResponse = settled[1].status === 'fulfilled'
      ? settled[1].value as NextResponse | null : null;
    const dislikeCount = settled[2].status === 'fulfilled'
      ? settled[2].value as number : -1;
    const baseInfo = webMeta ? this.extractMetadata(videoId, webMeta) : new VideoInfo(videoId);
    baseInfo.playerResponse = webMeta ?? playerResponse;
    if (dislikeCount >= 0) {
      baseInfo.dislikeCount = dislikeCount;
    }

    if (nextResponse) {
      this.enrichFromNextResponse(baseInfo, nextResponse, webMeta ?? playerResponse);
    }

    logger.info(`[TIMING] video=${videoId} stage=backgroundEnrichment elapsed=${Date.now() - startedAt}ms totalSinceStart=${task ? Date.now() - task.startedAt : -1}ms`);

    return baseInfo;
  }

  private parseRange(range: Range | undefined): StreamRange | undefined {
    if (!range || !range.start || !range.end) return undefined;
    const start = parseInt(range.start, 10);
    const end = parseInt(range.end, 10);
    if (isNaN(start) || isNaN(end)) return undefined;
    return { start, end };
  }

  private splitMimeType(mimeType: string | undefined): MimeTypeParseResult {
    const result: MimeTypeParseResult = { container: undefined, codecs: undefined };
    if (!mimeType) return result;
    const parts = mimeType.split(';');
    result.container = parts[0]?.trim();
    for (let i = 1; i < parts.length; i++) {
      const part = parts[i].trim();
      if (part.startsWith('codecs=')) {
        result.codecs = part.substring(7).replace(/"/g, '');
        break;
      }
    }
    return result;
  }

  private extractCodecFromMimeType(mimeType: string | undefined): string | undefined {
    if (!mimeType) return undefined;
    const parts = mimeType.split(';');
    for (let i = 1; i < parts.length; i++) {
      const part = parts[i].trim();
      if (part.startsWith('codecs=')) return part.substring(7).replace(/"/g, '');
    }
    return undefined;
  }

  private extractAudioTrackTypeFromUrl(url: string): string | undefined {
    const match = url.match(/[?&]xtags=[^&]*audio_track_type%3D([^%&]+)/);
    return match ? decodeURIComponent(match[1]) : undefined;
  }

  private appendQueryParam(url: string, key: string, value: string): string {
    const separator = url.includes('?') ? '&' : '?';
    return `${url}${separator}${key}=${encodeURIComponent(value)}`;
  }

  private parseCipherParams(cipherText: string): Map<string, string> {
    const normalized = cipherText.replace(/\\u0026/g, '&');
    const params = new Map<string, string>();
    for (const pair of normalized.split('&')) {
      const eqIdx = pair.indexOf('=');
      if (eqIdx > 0) {
        params.set(decodeURIComponent(pair.substring(0, eqIdx)),
          decodeURIComponent(pair.substring(eqIdx + 1)));
      }
    }
    return params;
  }

  private extractSigFromCipher(cipherText: string): string | null {
    return this.parseCipherParams(cipherText).get('s') || null;
  }

  private extractUrlFromCipher(cipherText: string): string | null {
    return this.parseCipherParams(cipherText).get('url') || null;
  }

  private extractSpFromCipher(cipherText: string): string {
    return this.parseCipherParams(cipherText).get('sp') || 'signature';
  }

  clearCache(): void {
    this.streamsCachedVideoId = '';
    this.cachedAudioStreams = [];
    this.cachedVideoStreams = [];
    this.cachedVideoOnlyStreams = [];
    this.cachedManifestNResult = null;
    this.decoderPlayerId = null;
    this.cachedInnertubePlayers = undefined;
    this.configuredStreamingData = undefined;
    this.configuredCpn = undefined;
    this.configuredSourceClient = undefined;
    this.safariStreamingData = undefined;
    this.androidStreamingData = undefined;
    this.safariCpn = undefined;
    this.androidCpn = undefined;
    this.mwebHlsManifestUrl = '';
    this.playbackEnrichmentTasks.clear();
    // 注意：cachedSignatureTimestamp 是进程级 STS 缓存，不在此清空，复用提速
    logger.debug('Cache cleared');
  }

  private hasDirectUrl(streamingData: StreamingData | undefined): boolean {
    if (!streamingData) return false;
    const formats = streamingData.formats || [];
    const adaptive = streamingData.adaptiveFormats || [];
    for (const fmt of [...formats, ...adaptive]) if (fmt.url) return true;
    return false;
  }

  private hasStreamUrls(streamingData: StreamingData | undefined): boolean {
    if (!streamingData) return false;
    const formats = streamingData.formats || [];
    const adaptive = streamingData.adaptiveFormats || [];
    for (const fmt of [...formats, ...adaptive]) if (fmt.url || fmt.signatureCipher || fmt.cipher) return true;
    return false;
  }

  private usableCount(streamingData: StreamingData | undefined): number {
    if (!streamingData) return 0;
    const formats = streamingData.formats || [];
    const adaptive = streamingData.adaptiveFormats || [];
    let count = 0;
    for (const fmt of [...formats, ...adaptive]) if (fmt.url || fmt.signatureCipher || fmt.cipher) count++;
    return count;
  }

  private isTrustworthyPlayerResponse(playerResponse: PlayerResponse | undefined, videoId: string): boolean {
    if (!playerResponse) return false;
    const respVideoId = playerResponse.videoDetails?.videoId;
    return respVideoId === videoId;
  }

  private parseYtcfgValue(html: string, key: string): string | undefined {
    const pattern = new RegExp(`"${key}"\\s*:\\s*"([^"]+)"`);
    const match = html.match(pattern);
    return match ? match[1] : undefined;
  }

  /**
   * Extract ytcfg JSON from HTML — mirrors yt-dlp's extract_ytcfg:
   *   r'ytcfg\.set\s*\(\s*({.+?})\s*\)\s*;'
   * Uses [\s\S] instead of . to match across newlines.
   */
  private parseYtcfgSet(html: string): Record<string, Object> | null {
    const ytcfgRegex = /ytcfg\.set\s*\(\s*(\{[\s\S]+?\})\s*\)\s*;/;
    const match = ytcfgRegex.exec(html);
    if (!match || !match[1]) {
      logger.debug('parseYtcfgSet: no ytcfg.set({...}) match found in HTML');
      return null;
    }
    try {
      const parsed = JSON.parse(match[1]) as Record<string, Object>;
      const keys = Object.keys(parsed);
      logger.debug(`parseYtcfgSet: parsed ${keys.length} ytcfg keys, has STS=${parsed['STS'] !== undefined ? 'Y' : 'N'}, has PLAYER_JS_URL=${parsed['PLAYER_JS_URL'] !== undefined ? 'Y' : 'N'}`);
      return parsed;
    } catch (e) {
      logger.warn('parseYtcfgSet: JSON.parse failed:', e);
      return null;
    }
  }

  /**
   * Extract 8-char hex player ID from a player JS URL.
   * Mirrors yt-dlp's _extract_player_info.
   * Input:  /s/player/abc12345/player_ias.vflset/en_US/base.js
   * Output: "abc12345"
   */
  private extractPlayerIdFromUrl(playerJsUrl: string): string | null {
    const idRegex = /\/s\/player\/([a-fA-F0-9]{8,})\//;
    const match = idRegex.exec(playerJsUrl);
    return match ? match[1] : null;
  }

  private randomCpn(): string {
    return generateContentPlaybackNonce();
  }

  private randomTParameter(): string {
    return generateTParameter();
  }

  /**
   * Extract player metadata (STS / playerId) from the watch HTML ytcfg, update the
   * process-level cache, and feed the decoder. Synchronous — no network.
   * Split out of fetchInnertubePlayer so the /player call can be fired in parallel
   * with the watch-page fetch when a cached STS is already available.
   * Returns the freshly extracted STS (or undefined if ytcfg lacked it).
   */
  private extractPlayerMetadata(html: string): number | undefined {
    const ytcfg = this.parseYtcfgSet(html);
    let localSts: number | undefined;
    let playerId: string | null = null;

    if (ytcfg) {
      const stsValue = ytcfg['STS'];
      if (typeof stsValue === 'number') {
        localSts = stsValue;
      }
      const playerJsUrl = ytcfg['PLAYER_JS_URL'];
      if (typeof playerJsUrl === 'string') {
        playerId = this.extractPlayerIdFromUrl(playerJsUrl);
      }
    }

    // Update process-level cache so subsequent extractions can fire /player early
    if (localSts !== undefined) {
      YouTubeExtractor.cachedSignatureTimestamp = localSts;
    }

    if (localSts !== undefined || playerId) {
      const meta: PlayerMetadata = {
        playerId: playerId ?? '',
        signatureTimestamp: localSts ?? 0,
      };
      PipePipeApiDecoder.setLocalMetadata(meta);
      if (meta.playerId && meta.signatureTimestamp > 0) {
        this.decoderPlayerId = meta.playerId;
      }
      logger.info(`[METADATA] local extraction OK: playerId=${meta.playerId || '(missing)'} sts=${meta.signatureTimestamp || '(missing)'}`);
    } else {
      logger.warn('[METADATA] ytcfg did not contain STS or PLAYER_JS_URL — decode will use API fallback');
    }

    return localSts;
  }

  /**
   * PipePipe single configured stream /player (www + STS + selected client).
   */
  private async fetchSelectedStreamPlayer(
    videoId: string,
    sts: number | undefined,
    selectedClient: YoutubePlayerClientKey,
    hasCookieAuth: boolean
  ): Promise<InnertubePlayerResult> {
    const empty: InnertubePlayerResult = {
      player: undefined,
      cpn: undefined,
      sourceClient: selectedClient,
      android: undefined,
      safari: undefined,
      androidCpn: undefined,
      safariCpn: undefined
    };
    logger.info(`[STREAM] fetchSelectedStreamPlayer client=${selectedClient} sts=${sts ?? '(none)'} auth=${hasCookieAuth}`);
    const ctx: ClientFetchContext = {
      videoId: videoId,
      hl: this.hl,
      gl: this.gl,
      visitorData: undefined,
      signatureTimestamp: sts
    };
    try {
      const fetched = await ConfiguredPlayerClient.fetch(
        selectedClient, ctx, this.client, hasCookieAuth);
      if (!fetched?.playerResponse) {
        this.errors.push(new ExtractorStageError(selectedClient,
          new Error('stream player returned no playerResponse')));
        return empty;
      }
      // Keep legacy aliases pointing at the same response for caption scoring helpers.
      const isSafariLike = selectedClient === 'web_safari' || selectedClient === 'mweb';
      return {
        player: fetched.playerResponse,
        cpn: fetched.cpn,
        sourceClient: selectedClient,
        android: isSafariLike ? undefined : fetched.playerResponse,
        safari: isSafariLike ? fetched.playerResponse : undefined,
        androidCpn: isSafariLike ? undefined : fetched.cpn,
        safariCpn: isSafariLike ? fetched.cpn : undefined
      };
    } catch (e) {
      this.errors.push(new ExtractorStageError(selectedClient, e as Error));
      logger.warn(`[STREAM] ${selectedClient} fetch error:`, e);
      return empty;
    }
  }

  /**
   * WEB desktop / mweb client version (PipePipe getClientVersion).
   * Process cache via WebClientVersionResolver; sync fallback is hardcoded only.
   */
  private getWebClientVersion(): string {
    const resolved = WebClientVersionResolver.getCachedOrHardcoded();
    YouTubeExtractor.cachedWebClientVersion = resolved;
    return resolved;
  }

  /** Resolve dynamic WEB version once per process (sw.js → results → hardcoded). */
  private async ensureWebClientVersion(): Promise<string> {
    const version = await WebClientVersionResolver.getClientVersion(this.client);
    YouTubeExtractor.cachedWebClientVersion = version;
    return version;
  }

  /**
   * PipePipe prepareDesktopJsonBuilder + videoId / contentCheckOk / racyCheckOk.
   * Used by WEB metadata /player and /next.
   */
  private buildDesktopWebPayload(videoId: string): Record<string, Object> {
    const client: Record<string, Object> = {
      'hl': this.hl,
      'gl': this.gl,
      'clientName': ClientsConstants.WEB_CLIENT_NAME,
      'clientVersion': this.getWebClientVersion(),
      'originalUrl': 'https://www.youtube.com',
      'platform': ClientsConstants.DESKTOP_CLIENT_PLATFORM,
      'utcOffsetMinutes': 0
    };
    const request: Record<string, Object> = {
      'internalExperimentFlags': [] as string[],
      'useSsl': true
    };
    const user: Record<string, Object> = {
      'lockedSafetyMode': false
    };
    const context: Record<string, Object> = {
      'client': client,
      'request': request,
      'user': user
    };
    const payload: Record<string, Object> = {
      'context': context,
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true
    };
    return payload;
  }

  /**
   * Headers for WEB desktop Innertube posts (metadata player + next).
   * Aligns with PipePipe addYoutubeHeaders client name/version + Content-Type.
   * Auth is applied separately via postJson(..., withAuth=true) when signed in.
   */
  private webDesktopApiHeaders(): Record<string, string> {
    return {
      'Content-Type': 'application/json',
      'X-YouTube-Client-Name': ClientsConstants.WEB_CLIENT_ID,
      'X-YouTube-Client-Version': this.getWebClientVersion(),
      'Origin': 'https://www.youtube.com',
      'Referer': 'https://www.youtube.com/'
    };
  }

  private hasCookieAuthForRequests(): boolean {
    const authManager = AuthSessionManager.getInstance();
    return authManager?.isSignedIn() === true && !!(authManager?.getCookieString());
  }

  /**
   * PipePipe getWebPlayerResponse:
   * POST youtubei/v1/player?prettyPrint=false
   *   &$fields=microformat,playabilityStatus,storyboards,videoDetails
   * Desktop WEB body; Cookie/SAPISID when logged in.
   * Does NOT return streamingData (fields projection).
   */
  private async fetchWebMetadataPlayerResponse(videoId: string): Promise<PlayerResponse | undefined> {
    const url = `${ClientsConstants.YOUTUBEI_V1_URL}player`
      + `?prettyPrint=false`
      + `&$fields=microformat,playabilityStatus,storyboards,videoDetails`;
    const payload = this.buildDesktopWebPayload(videoId);
    const withAuth = this.hasCookieAuthForRequests();
    try {
      const resp = await this.client.postJson(
        url,
        payload,
        this.webDesktopApiHeaders(),
        withAuth
      );
      if (resp.responseCode !== 200 || !resp.result) {
        logger.warn(`[META] WEB metadata player HTTP ${resp.responseCode}`);
        return undefined;
      }
      const pr = JSON.parse(resp.result as string) as PlayerResponse;
      // Cache client version if response tracking carries a fresher one (best-effort).
      YouTubeExtractor.cachedWebClientVersion = this.getWebClientVersion();
      logger.info(`[META] WEB metadata player ok status=${pr.playabilityStatus?.status || '(none)'} `
        + `hasMicro=${!!pr.microformat} hasDetails=${!!pr.videoDetails}`);
      return pr;
    } catch (e) {
      if (e instanceof AgeRestrictedContentException) {
        throw e as AgeRestrictedContentException;
      }
      if (e instanceof SignInConfirmNotBotException) {
        throw e as SignInConfirmNotBotException;
      }
      if (e instanceof ExtractionException) {
        throw e as ExtractionException;
      }
      logger.warn('[META] fetchWebMetadataPlayerResponse failed:', e);
      return undefined;
    }
  }

  /** 获取 next 端点响应（对标 PipePipe nextDataCall / prepareDesktopJsonBuilder） */
  private async fetchNextResponse(videoId: string): Promise<NextResponse | null> {
    const url = `${ClientsConstants.YOUTUBEI_V1_URL}next?prettyPrint=false`;
    const payload = this.buildDesktopWebPayload(videoId);
    const withAuth = this.hasCookieAuthForRequests();
    try {
      const resp = await this.client.postJson(
        url,
        payload,
        this.webDesktopApiHeaders(),
        withAuth
      );
      if (resp.responseCode === 200 && resp.result) {
        return JSON.parse(resp.result as string) as NextResponse;
      }
      logger.warn(`fetchNextResponse HTTP ${resp.responseCode}`);
    } catch (e) {
      logger.warn('fetchNextResponse failed:', e);
    }
    return null;
  }

  /** 从 RYD API 获取点踩数（对标 PipePipe dislikeCall） */
  private async fetchDislikeCount(videoId: string): Promise<number> {
    const url = `https://returnyoutubedislikeapi.com/votes?videoId=${videoId}`;
    try {
      const resp = await this.client.get(url);
      if (resp.responseCode === 200) {
        const body = resp.result as string;
        interface DislikeData {
          dislikes?: number;
        }
        const data = JSON.parse(body) as DislikeData;
        return data.dislikes ?? -1;
      }
    } catch (e) {
      logger.warn('fetchDislikeCount failed:', e);
    }
    return -1;
  }

  /** 从 nextResponse 提取补充元数据（对标 PipePipe getRelatedItems/getUploaderXxx/getLikeCount） */
  private enrichFromNextResponse(
    videoInfo: VideoInfo,
    nextResponse: NextResponse,
    playerResponse?: PlayerResponse
  ): void {
    const twoCol = nextResponse.contents?.twoColumnWatchNextResults;
    const contents = twoCol?.results?.results?.contents || [];

    // videoPrimaryInfoRenderer → likeCount
    const primaryInfo = contents.find(c => c.videoPrimaryInfoRenderer)?.videoPrimaryInfoRenderer;
    if (primaryInfo && playerResponse) {
      const likeCount = this.extractLikeCount(primaryInfo, playerResponse);
      if (likeCount >= 0) {
        videoInfo.likeCount = likeCount;
      }
    }

    // videoSecondaryInfoRenderer → uploaderUrl / uploaderAvatarUrl / uploaderSubscriberCount
    const secondaryInfo = contents.find(c => c.videoSecondaryInfoRenderer)?.videoSecondaryInfoRenderer;
    if (secondaryInfo) {
      this.extractUploaderInfo(videoInfo, secondaryInfo);
    }

    // secondaryResults → relatedItems
    const secondaryResults = twoCol?.secondaryResults?.secondaryResults?.results || [];
    const related: RelatedVideoInfo[] = [];
    for (const item of secondaryResults) {
      if (item.compactVideoRenderer) {
        const r = this.parseCompactVideoRenderer(item.compactVideoRenderer);
        if (r) {
          related.push(r);
        }
      } else if (item.lockupViewModel?.contentType === 'LOCKUP_CONTENT_TYPE_VIDEO') {
        const r = this.parseLockupViewModel(item.lockupViewModel);
        if (r) {
          related.push(r);
        }
      }
    }
    videoInfo.relatedItems = related;
    logger.info(`enrichFromNextResponse: likeCount=${videoInfo.likeCount}, uploaderUrl=${videoInfo.uploaderUrl}, related=${related.length}`);
  }

  private extractLikeCount(primary: VideoPrimaryInfoRenderer, playerResponse: PlayerResponse): number {
    if (playerResponse.videoDetails?.allowRatings === false) {
      return -1;
    }
    try {
      const buttons = primary.videoActions?.menuRenderer?.topLevelButtons || [];
      for (const btn of buttons) {
        const text = btn.segmentedLikeDislikeButtonViewModel
          ?.likeButtonViewModel?.likeButtonViewModel
          ?.toggleButtonViewModel?.toggleButtonViewModel
          ?.defaultButtonViewModel?.buttonViewModel?.accessibilityText;
        if (text) {
          if (text.toLowerCase().includes('no likes')) {
            return 0;
          }
          const digits = text.replace(/\D/g, '');
          if (digits) {
            return parseInt(digits);
          }
        }
      }
    } catch (e) {
      logger.warn('extractLikeCount failed:', e);
    }
    return -1;
  }

  private extractUploaderInfo(videoInfo: VideoInfo, secondary: VideoSecondaryInfoRenderer): void {
    const owner = secondary.owner?.videoOwnerRenderer;
    if (!owner) {
      return;
    }
    // Prefer channel id from owner browseEndpoint when metadata path left it empty.
    if (!videoInfo.channelId) {
      const browseId = this.getNestedValue(
        owner as Object,
        'navigationEndpoint.browseEndpoint.browseId'
      ) as string;
      if (browseId && browseId.startsWith('UC')) {
        videoInfo.channelId = browseId;
      }
    }
    if (videoInfo.channelId) {
      videoInfo.uploaderUrl = `https://www.youtube.com/channel/${videoInfo.channelId}`;
    }
    const thumbs = owner.thumbnail?.thumbnails || [];
    if (thumbs.length > 0) {
      videoInfo.uploaderAvatarUrl = pickHighestThumbnailUrl(thumbs as Array<Record<string, Object>>);
    }
    const subText = this.extractNextText(owner.subscriberCountText);
    if (subText) {
      videoInfo.uploaderSubscriberCount = parseSubscriberCount(subText);
    }
  }

  /** When WEB metadata is UNPLAYABLE / partial, recover channelId/author from stream player. */
  private fillMissingIdentityFromPlayer(videoInfo: VideoInfo, streamPr?: PlayerResponse): void {
    if (!streamPr) {
      return;
    }
    const vd = streamPr.videoDetails;
    const micro = streamPr.microformat?.playerMicroformatRenderer;
    if (!videoInfo.channelId) {
      videoInfo.channelId = vd?.channelId || micro?.externalChannelId || '';
    }
    if (!videoInfo.author) {
      videoInfo.author = vd?.author || micro?.ownerChannelName || '';
    }
    if (videoInfo.channelId && !videoInfo.uploaderUrl) {
      videoInfo.uploaderUrl = `https://www.youtube.com/channel/${videoInfo.channelId}`;
    }
  }

  private parseCompactVideoRenderer(r: CompactVideoRenderer): RelatedVideoInfo | null {
    const videoId = r.videoId;
    if (!videoId) {
      return null;
    }
    const title = this.extractNextText(r.title) || '';
    const author = this.extractNextText(r.longBylineText || r.shortBylineText) || '';
    const item = new RelatedVideoInfo(videoId, title, author);
    item.channelId = r.channelId;
    const thumbs = r.thumbnail?.thumbnails || [];
    if (thumbs.length > 0) {
      item.thumbnailUrl = pickHighestThumbnailUrl(thumbs as Array<Record<string, Object>>);
    }
    const lenText = this.extractNextText(r.lengthText);
    if (lenText) {
      item.lengthSeconds = parseDurationText(lenText);
    }
    const badges = r.badges || [];
    item.isLive = badges.some(b => b.metadataBadgeRenderer?.label?.toLowerCase() === 'live');
    return item;
  }

  private parseLockupViewModel(lv: LockupViewModel): RelatedVideoInfo | null {
    const videoId = lv.rendererContext?.commandContext?.onTap?.innertubeCommand?.watchEndpoint?.videoId
      || lv.contentId;
    if (!videoId) {
      return null;
    }
    const meta = lv.metadata?.lockupMetadataViewModel;
    const title = meta?.title?.content || '';
    const rows = meta?.metadata?.contentMetadataViewModel?.metadataRows || [];
    const author = rows[0]?.metadataParts?.[0]?.text?.content || '';
    const item = new RelatedVideoInfo(videoId, title, author);
    const src = lv.thumbnail?.thumbnailViewModel?.image?.sources || [];
    if (src.length > 0) {
      item.thumbnailUrl = pickHighestThumbnailUrl(src as Array<Record<string, Object>>);
    }
    return item;
  }

  private extractNextText(t?: NextResponseText): string {
    if (!t) {
      return '';
    }
    if (t.simpleText) {
      return t.simpleText;
    }
    return (t.runs || []).map(r => r.text || '').join('');
  }

  private selectBestPlayerResponse(videoId: string, watchPlayerResponse: PlayerResponse, innertubePlayers: InnertubePlayerResult): PlayerResponse {
    const candidates: PlayerCandidate[] = [];
    if (innertubePlayers.player) {
      candidates.push({
        source: innertubePlayers.sourceClient || 'stream',
        pr: innertubePlayers.player
      });
    }
    if (innertubePlayers.safari) candidates.push({ source: 'safari', pr: innertubePlayers.safari });
    if (innertubePlayers.android) candidates.push({ source: 'android', pr: innertubePlayers.android });
    candidates.push({ source: 'watch', pr: watchPlayerResponse });

    const sourceWeight: Record<string, number> = {
      'stream': 6,
      'mweb': 6,
      'web_safari': 6,
      'android_vr': 6,
      'tv_downgraded': 6,
      'safari': 4,
      'android': 4,
      'watch': 1
    };

    const score = (entry: PlayerCandidate): number[] => {
      const pr = entry.pr;
      const sd = pr?.streamingData;
      // hasCaptions 必须看 baseUrl 是否真实有效——否则 captionTracks 数组虽在但全部 baseUrl 为空时仍误判为可用
      const tracks = pr?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
      const hasCaptions = !!(tracks && tracks.length && tracks.some(t => !!t.baseUrl));
      const adaptiveCount = sd?.adaptiveFormats?.length || 0;
      const hasAdaptive = adaptiveCount > 0 ? 1 : 0;
      return [
        this.isTrustworthyPlayerResponse(pr, videoId) ? 1 : 0,
        this.hasStreamUrls(sd) ? 1 : 0,
        hasAdaptive,
        this.usableCount(sd),
        this.hasDirectUrl(sd) ? 1 : 0,
        hasCaptions ? 1 : 0,
        sourceWeight[entry.source] || 0
      ];
    };

    const compareScores = (a: number[], b: number[]): number => {
      for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return b[i] - a[i];
      return 0;
    };

    let best = candidates[0].pr!;
    let bestSource = candidates[0].source;
    let bestScore = score(candidates[0]);

    for (let i = 1; i < candidates.length; i++) {
      const s = score(candidates[i]);
      logger.info(`[STREAM_DEBUG] selectBest: ${candidates[i].source} score=[${s.join(',')}]`);
      if (compareScores(bestScore, s) > 0) {
        best = candidates[i].pr!;
        bestSource = candidates[i].source;
        bestScore = s;
      }
    }

    logger.info(`[STREAM_DEBUG] selectBest winner=${bestSource} score=[${bestScore.join(',')}]`);
    return best;
  }

  async fetchComments(videoId: string, nextPageToken: string | null = null): Promise<CommentResponse> {
    logger.debug(`[Comments] fetchComments for videoId: ${videoId}, token: ${nextPageToken ? 'provided' : 'none'}`);
    
    let continuation = nextPageToken;
    
    if (!continuation) {
      try {
        const nextResponse = await this.getInnerTubeNextResponse(videoId);
        continuation = this.findInitialCommentsToken(nextResponse);
        if (!continuation) {
          logger.warn(`[Comments] No initial comments token found for videoId: ${videoId}`);
          return { items: [], nextPageToken: null, commentCount: 0 };
        }
      } catch (e) {
        const error = e as Error;
        logger.error(`[Comments] Initial token fetch failed: ${error.message}`);
        throw error;
      }
    }

    logger.debug(`[Comments] Fetching with WEB client...`);
    const body: InnerTubeNextPayload = {
      context: this.prepareInnerTubeContext('WEB'),
      continuation: continuation || undefined
    };

    try {
      const url = `https://www.youtube.com/youtubei/v1/next?prettyPrint=false`;
      const response: http.HttpResponse = await this.client.postJson(
        url, body, this.webApiHeaders(), this.hasCookieAuthForRequests());

      if (response.responseCode === 200) {
        const ajaxJson = JSON.parse(response.result as string) as Record<string, Object>;
        const commentResponse = this.parseCommentsResponse(ajaxJson, videoId);
        logger.info(`[Comments] Successfully extracted ${commentResponse.items.length} items`);
        return commentResponse;
      } else {
        logger.error(`[Comments] Request failed with ${response.responseCode}`);
      }
    } catch (e) {
      const error = e as Error;
      logger.error(`[Comments] Fetch error: ${error.message}`);
    }

    return { items: [], nextPageToken: null, commentCount: 0 };
  }

  async fetchCommentReplies(replyContinuation: string): Promise<CommentResponse> {
    logger.debug(`[Comments] fetchCommentReplies for token: ${replyContinuation}`);
    
    const body: InnerTubeNextPayload = {
      context: this.prepareInnerTubeContext('WEB'),
      continuation: replyContinuation
    };

    try {
      const url = `https://www.youtube.com/youtubei/v1/next?prettyPrint=false`;
      const response: http.HttpResponse = await this.client.postJson(
        url, body, this.webApiHeaders(), this.hasCookieAuthForRequests());

      if (response.responseCode === 200) {
        const ajaxJson = JSON.parse(response.result as string) as Record<string, Object>;
        return this.parseCommentsResponse(ajaxJson, '');
      }
    } catch (e) {
      const error = e as Error;
      logger.warn(`[Comments] Reply fetch error: ${error.message}`);
    }
    
    return { items: [], nextPageToken: null, commentCount: 0 };
  }

  private findInitialCommentsToken(nextResponse: Record<string, Object>): string | null {
    logger.debug(`[Comments] Extracting initial token from next response`);
    try {
      const contents = this.getNestedValue(nextResponse, 'contents.twoColumnWatchNextResults.results.results.contents') as Array<Object>;
      if (!contents) {
        logger.warn(`[Comments] contents path not found in nextResponse`);
        return null;
      }

      for (const item of contents) {
        const itemSection = (item as Record<string, Object>)['itemSectionRenderer'] as Record<string, Object>;
        if (itemSection && (itemSection['targetId'] === 'comments-section' || itemSection['sectionIdentifier'] === 'comment-item-section')) {
          const sectionContents = itemSection['contents'] as Array<Object>;
          if (sectionContents && sectionContents.length > 0) {
            const firstItem = sectionContents[0] as Record<string, Object>;
            let token = this.getNestedValue(firstItem, 'continuationItemRenderer.continuationEndpoint.continuationCommand.token') as string;
            
            if (!token) {
              const lastItem = sectionContents[sectionContents.length - 1] as Record<string, Object>;
              token = this.getNestedValue(lastItem, 'continuationItemRenderer.continuationEndpoint.continuationCommand.token') as string;
            }

            if (token) {
              logger.debug(`[Comments] Successfully found continuation token: ${token}`);
              return token;
            }
          }
        }
      }
    } catch (e) {
      logger.error('[Comments] findInitialCommentsToken failed:', e);
    }
    return null;
  }

  private async getInnerTubeNextResponse(videoId: string): Promise<Record<string, Object>> {
    logger.debug(`[Comments] Fetching watch next metadata for videoId: ${videoId}`);
    // Prefer desktop WEB payload shape used by PipePipe next (request/user + originalUrl).
    const body = this.buildDesktopWebPayload(videoId);

    const response: http.HttpResponse = await this.client.postJson(
      `https://www.youtube.com/youtubei/v1/next?prettyPrint=false`,
      body,
      this.webApiHeaders(),
      this.hasCookieAuthForRequests()
    );

    if (response.responseCode !== 200) {
      throw new ExtractionException(`Fetch next response failed: ${response.responseCode}`);
    }

    const result = response.result as string;
    return JSON.parse(result) as Record<string, Object>;
  }

  private parseCommentsResponse(ajaxJson: Record<string, Object>, videoId: string): CommentResponse {
    const items: CommentItem[] = [];
    let nextPageToken: string | null = null;
    let commentCount = 0;

    try {
      const endpoints = ajaxJson['onResponseReceivedEndpoints'] as Array<Object>;
      if (!endpoints || endpoints.length === 0) {
        logger.warn(`[Comments] No onResponseReceivedEndpoints found.`);
        return { items: [], nextPageToken: null, commentCount: 0 };
      }

      const mutations = this.getNestedValue(ajaxJson, 'frameworkUpdates.entityBatchUpdate.mutations') as Array<Object>;
      
      // NewPipe strictly takes the last endpoint for comments
      const epObj = endpoints[endpoints.length - 1] as Record<string, Object>;
      
      let continuationItems = (this.getNestedValue(epObj, 'reloadContinuationItemsCommand.continuationItems') ||
                               this.getNestedValue(epObj, 'appendContinuationItemsAction.continuationItems')) as Array<Object>;

      if (!continuationItems) {
        // Alternative paths
        continuationItems = (this.getNestedValue(epObj, 'sectionListRenderer.contents') ||
                             this.getNestedValue(epObj, 'itemSectionRenderer.contents')) as Array<Object>;
      }

      if (continuationItems) {
        logger.debug(`[Comments] Found ${continuationItems.length} items in the last endpoint`);

        for (const item of continuationItems) {
          const itemObj = item as Record<string, Object>;
          
          if (itemObj['commentThreadRenderer']) {
            const comment = this.parseCommentThread(itemObj['commentThreadRenderer'] as Record<string, Object>, mutations || [], videoId);
            if (comment) items.push(comment);
          } else if (itemObj['commentRenderer']) {
            const comment = this.parseCommentRenderer(itemObj['commentRenderer'] as Record<string, Object>, mutations || [], videoId);
            if (comment) items.push(comment);
          } else if (itemObj['commentViewModel']) {
            const comment = this.parseCommentViewModel(itemObj['commentViewModel'] as Record<string, Object>, null, mutations || [], videoId);
            if (comment) items.push(comment);
          } else if (itemObj['continuationItemRenderer']) {
            const contRenderer = itemObj['continuationItemRenderer'] as Record<string, Object>;
            nextPageToken = (this.getNestedValue(contRenderer, 'continuationEndpoint.continuationCommand.token') ||
                             this.getNestedValue(contRenderer, 'button.buttonRenderer.command.continuationCommand.token')) as string;
          } else if (itemObj['commentsHeaderRenderer']) {
            const countText = this.getNestedValue(itemObj, 'commentsHeaderRenderer.countText') as Record<string, Object>;
            commentCount = this.parseMixedNumber(this.getTextFromObject(countText));
          }
        }
      }

      if (items.length === 0) {
        logger.warn(`[Comments] Parsed 0 items. Endpoint keys: ${Object.keys(epObj).join('|')}`);
      }
    } catch (e) {
      const error = e as Error;
      logger.error('[Comments] parseCommentsResponse failed:', error.message);
    }

    return { items, nextPageToken, commentCount };
  }

  private parseCommentThread(renderer: Record<string, Object>, mutations: Array<Object>, videoId: string): CommentItem | null {
    const replies = renderer['replies'] as Record<string, Object>;
    const commentRepliesRenderer = replies ? (replies['commentRepliesRenderer'] as Record<string, Object>) : null;
    
    let item: CommentItem | null = null;
    if (renderer['commentViewModel']) {
      let vm = renderer['commentViewModel'] as Record<string, Object>;
      if (vm['commentViewModel']) {
        vm = vm['commentViewModel'] as Record<string, Object>;
      }
      item = this.parseCommentViewModel(vm, commentRepliesRenderer, mutations, videoId);
    } else if (renderer['comment']) {
      const commentObj = renderer['comment'] as Record<string, Object>;
      const commentRenderer = commentObj ? commentObj['commentRenderer'] as Record<string, Object> : null;
      if (commentRenderer) item = this.parseCommentRenderer(commentRenderer, mutations, videoId);
    }
    
    if (!item) return null;

    if (commentRepliesRenderer) {
      const replyContents = commentRepliesRenderer['contents'] as Array<Object>;
      if (replyContents && replyContents.length > 0) {
        const replyContItem = replyContents[0] as Record<string, Object>;
        const contRenderer = replyContItem['continuationItemRenderer'] as Record<string, Object>;
        if (contRenderer) {
          const token = this.getNestedValue(contRenderer, 'continuationEndpoint.continuationCommand.token') as string;
          item.replyContinuation = token || '';
        }
      }
    }
    return item;
  }

  private parseCommentRenderer(renderer: Record<string, Object>, mutations: Array<Object>, videoId: string): CommentItem | null {
    try {
      const commentId = renderer['commentId'] as string;
      const authorTextObj = renderer['authorText'] as Record<string, Object>;
      const authorName = authorTextObj ? this.getTextFromObject(authorTextObj) : '';
      const authorThumbnail = renderer['authorThumbnail'] as Record<string, Object>;
      const thumbnails = authorThumbnail ? authorThumbnail['thumbnails'] as Array<Record<string, string>> : null;
      const avatarUrl = (thumbnails && thumbnails.length > 0) ? thumbnails[0]['url'] : '';
      const contentTextObj = renderer['contentText'] as Record<string, Object>;
      const commentText = contentTextObj ? this.getTextFromObject(contentTextObj) : '';
      const publishedTimeTextObj = renderer['publishedTimeText'] as Record<string, Object>;
      const publishedTimeText = publishedTimeTextObj ? this.getTextFromObject(publishedTimeTextObj) : '';
      const voteCount = renderer['voteCount'] as Record<string, Object>;
      const likeCount = voteCount ? parseInt(this.getTextFromObject(voteCount).replace(/[^0-9]/g, '')) || 0 : 0;
      const replyCount = (renderer['replyCount'] as number) || 0;
      const authorEndpoint = renderer['authorEndpoint'] as Record<string, Object>;
      const authorExternalChannelId = authorEndpoint ? this.getNestedValue(authorEndpoint, 'browseEndpoint.browseId') as string : '';

      return {
        id: commentId || Math.random().toString(36).substring(2),
        commentId: commentId,
        videoId: videoId,
        authorName: authorName,
        authorAvatarUrl: avatarUrl,
        authorThumbnailColor: '#CCCCCC',
        authorExternalChannelId: authorExternalChannelId || '',
        commentText: commentText,
        publishedTimeText: publishedTimeText,
        likeCount: likeCount,
        replyCount: replyCount,
        isHeartedByAuthor: !!(renderer['actionButtons'] && this.getNestedValue(renderer, 'actionButtons.commentActionButtonsRenderer.creatorHeart')),
        isPinned: !!renderer['pinnedCommentBadge'],
        authorIsVerified: !!renderer['authorCommentBadge'],
        authorIsCreator: !!renderer['authorIsChannelOwner'],
        hasCreatorReply: false,
        replyContinuation: ''
      };
    } catch (e) {
      return null;
    }
  }

  private parseCommentViewModel(viewModel: Record<string, Object>, commentRepliesRenderer: Record<string, Object> | null, mutations: Array<Object>, videoId: string): CommentItem | null {
    try {
      const commentKey = viewModel['commentKey'] as string;
      const toolbarStateKey = viewModel['toolbarStateKey'] as string;
      const commentPayload = this.getMutationPayloadFromEntityKey(mutations, commentKey);
      const toolbarPayload = this.getMutationPayloadFromEntityKey(mutations, toolbarStateKey);
      
      if (!commentPayload) return null;
      
      const commentEntity = commentPayload['commentEntityPayload'] as Record<string, Object>;
      const toolbarEntity = toolbarPayload ? toolbarPayload['engagementToolbarStateEntityPayload'] as Record<string, Object> : null;
      if (!commentEntity) return null;
      
      const properties = commentEntity['properties'] as Record<string, Object>;
      const author = commentEntity['author'] as Record<string, Object>;
      const toolbar = commentEntity['toolbar'] as Record<string, Object>;
      const avatar = commentEntity['avatar'] as Record<string, Object>;
      
      const commentId = properties['commentId'] as string || (viewModel['commentId'] as string);
      const authorName = author['displayName'] as string;
      const avatarSources = this.getNestedValue(avatar, 'image.sources') as Array<Record<string, string>>;
      const avatarUrl = (avatarSources && avatarSources.length > 0) ? avatarSources[0]['url'] : '';
      const content = properties['content'] as Record<string, Object>;
      const commentText = content ? (content['content'] as string) : '';
      const publishedTimeText = properties['publishedTime'] as string;
      const likeCountStr = toolbar ? toolbar['likeCountNotliked'] as string : '';
      const likeCount = this.parseMixedNumber(likeCountStr);
      const replyCountStr = toolbar ? toolbar['replyCount'] as string : '';
      const replyCount = this.parseMixedNumber(replyCountStr);
      const channelId = author['channelId'] as string || 
                       (this.getNestedValue(author, 'channelCommand.innertubeCommand.browseEndpoint.browseId') as string) ||
                       (this.getNestedValue(avatar, 'endpoint.innertubeCommand.browseEndpoint.browseId') as string);

      return {
        id: commentId || Math.random().toString(36).substring(2),
        commentId: commentId,
        videoId: videoId,
        authorName: authorName,
        authorAvatarUrl: avatarUrl,
        authorThumbnailColor: '#CCCCCC',
        authorExternalChannelId: channelId || '',
        commentText: commentText,
        publishedTimeText: publishedTimeText,
        likeCount: likeCount,
        replyCount: replyCount,
        isHeartedByAuthor: toolbarEntity ? toolbarEntity['heartState'] === 'TOOLBAR_HEART_STATE_HEARTED' : false,
        isPinned: !!viewModel['pinnedText'],
        authorIsVerified: !!(author['isVerified'] || author['isArtist']),
        authorIsCreator: !!author['isCreator'],
        hasCreatorReply: !!(commentRepliesRenderer && commentRepliesRenderer['viewRepliesCreatorThumbnail']),
        replyContinuation: ''
      };
    } catch (e) {
      return null;
    }
  }

  private parseMixedNumber(text: string): number {
    return parseMixedNumber(text);
  }

  private getTextFromObject(obj: Record<string, Object> | null): string {
    return getTextFromObject(obj as Record<string, Object>);
  }

  private getMutationPayloadFromEntityKey(mutations: Array<Object>, key: string): Record<string, Object> | null {
    if (!mutations || !key) return null;
    const mutation = mutations.find((m: Object) => {
      const mObj = m as Record<string, Object>;
      return mObj['entityKey'] === key;
    }) as Record<string, Object>;
    return mutation ? (mutation['payload'] as Record<string, Object>) : null;
  }

  private getNestedValue(obj: Object, path: string): Object | null {
    return getNestedValue(obj, path);
  }

  // ========================================================================
  // Stream extraction helpers (ported from YoutubeStreamExtractor)
  // ========================================================================

  private getStreamsFromStreamingDataKey(
    videoId: string,
    streamingData: StreamingData | undefined,
    streamingDataKey: 'formats' | 'adaptiveFormats',
    itagTypeWanted: ItagType,
    contentPlaybackNonce: string
  ): ItagInfo[] {
    const formatsList = streamingDataKey === 'formats' ? streamingData?.formats : streamingData?.adaptiveFormats;
    if (!streamingData || !formatsList) {
      return [];
    }

    const result: ItagInfo[] = [];
    const formats = formatsList || [];
    for (const formatData of formats) {
      try {
        if (!formatData.itag) continue;
        const itagItem = ItagItem.getItag(formatData.itag);
        if (itagItem.itagType === itagTypeWanted) {
          const itagInfo = this.buildAndAddItagInfoToList(videoId, formatData, itagItem, itagItem.itagType, contentPlaybackNonce);
          if (itagInfo && itagItem.itagType === ItagType.AUDIO) {
            this.extractAndSetAudioTrackInfo(formatData, itagInfo);
          }
          if (itagInfo) {
            result.push(itagInfo);
          }
        }
      } catch (e) {
        logger.warn('Failed to process format:', e);
      }
    }
    return result;
  }

  private buildAndAddItagInfoToList(
    videoId: string,
    formatData: Format,
    itagItem: ItagItem,
    itagType: ItagType,
    contentPlaybackNonce: string
  ): ItagInfo | null {
    let streamUrl: string;
    let obfuscatedSignature: string | null = null;

    if (formatData.url) {
      streamUrl = formatData.url;
    } else if (formatData.signatureCipher || formatData.cipher) {
      const cipherString = formatData.cipher || formatData.signatureCipher || '';
      const cipher = this.parseCipherParams(cipherString);
      obfuscatedSignature = cipher.get('s') || '';
      const sp = cipher.get('sp') || 'signature';
      const url = cipher.get('url');
      if (!url) return null;
      streamUrl = url + '&' + sp + '=SIGNATURE_PLACEHOLDER';
    } else {
      return null;
    }

    streamUrl += '&cpn=' + contentPlaybackNonce;

    const initRange = formatData.initRange;
    const indexRange = formatData.indexRange;
    const mimeType = formatData.mimeType || '';
    const codec = mimeType.includes('codecs') ? mimeType.split('"')[1] : '';
    const fps = formatData.fps ?? -1;

    itagItem.setBitrate(formatData.bitrate ?? 0);
    itagItem.setWidth(formatData.width ?? 0);
    itagItem.setHeight(formatData.height ?? 0);
    itagItem.setInitStart(initRange?.start ? parseInt(initRange.start, 10) : -1);
    itagItem.setInitEnd(initRange?.end ? parseInt(initRange.end, 10) : -1);
    itagItem.setIndexStart(indexRange?.start ? parseInt(indexRange.start, 10) : -1);
    itagItem.setIndexEnd(indexRange?.end ? parseInt(indexRange.end, 10) : -1);
    itagItem.setQuality(formatData.quality || '');
    itagItem.setCodec(codec);
    if (fps !== -1) {
      itagItem.setFps(fps);
    }

    if (itagType === ItagType.VIDEO || itagType === ItagType.VIDEO_ONLY) {
      itagItem.setFps(formatData.fps ?? itagItem.getFps());
    } else if (itagType === ItagType.AUDIO) {
      itagItem.setSampleRate(formatData.audioSampleRate ? parseInt(formatData.audioSampleRate, 10) : -1);
      itagItem.setAudioChannels(formatData.audioChannels ?? -1);
      if (formatData.audioQuality) {
        itagItem.setAudioQuality(formatData.audioQuality);
      }
    }

    itagItem.setContentLength(formatData.contentLength ? parseInt(formatData.contentLength, 10) : -1);
    itagItem.setApproxDurationMs(formatData.approxDurationMs ? parseInt(formatData.approxDurationMs, 10) : -1);

    const itagInfo = new ItagInfo(streamUrl, itagItem);
    if (obfuscatedSignature !== null) {
      itagInfo.setObfuscatedSignature(obfuscatedSignature);
    }

    const isOtf = formatData.type === 'FORMAT_STREAM_TYPE_OTF';
    itagInfo.setIsUrl(!isOtf);

    return itagInfo;
  }

  private extractAndSetAudioTrackInfo(formatData: Format, itagInfo: ItagInfo): void {
    if (!formatData.audioTrack) return;
    const audioTrack = formatData.audioTrack;
    if (audioTrack.id) {
      const audioTrackId = audioTrack.id;
      const displayName = (audioTrack.displayName || '').trim();
      const langPart = audioTrackId.split('.')[0];
      const audioLocale = langPart.split('-')[0];
      // Raw API text only: displayName, else track id (no synthesized "(original)").
      const audioTrackName = displayName.length > 0 ? displayName : audioTrackId;
      itagInfo.setAudioTrackInfo(audioTrackId, audioTrackName, audioLocale);
    }
  }

  private async batchDeobfuscateItagUrls(videoId: string, itagInfoList: ItagInfo[]): Promise<void> {
    if (itagInfoList.length === 0) return;

    const uniqueSigs = new Set<string>();
    const uniqueNs = new Set<string>();

    interface StreamDeobfuscationInfo {
      streamIndex: number;
      obfuscatedSignature: string | undefined;
      throttlingParam: string | undefined;
    }

    const streamInfos: StreamDeobfuscationInfo[] = [];

    for (let i = 0; i < itagInfoList.length; i++) {
      const itagInfo = itagInfoList[i];
      const url = itagInfo.getContent();
      const obfuscatedSig = itagInfo.getObfuscatedSignature();
      const throttlingParam = this.getThrottlingParamFromUrl(url);

      logger.debug(`[DEOBF] #${i} itag=${itagInfo.getItagItem().id} hasSig=${!!obfuscatedSig} hasN=${!!throttlingParam} rawUrl=${url.substring(0, 120)}`);

      streamInfos.push({ streamIndex: i, obfuscatedSignature: obfuscatedSig, throttlingParam });

      if (obfuscatedSig && obfuscatedSig.length > 0) {
        uniqueSigs.add(obfuscatedSig);
      }
      if (throttlingParam && throttlingParam.length > 0) {
        uniqueNs.add(throttlingParam);
      }
    }

    // 同时收集 manifest URL 的 n 参数，避免后续单独调用 decodeBatch
    const manifestN = this.collectManifestNParams();
    if (manifestN) {
      uniqueNs.add(manifestN);
    }

    logger.info(`[DEOBF] total=${itagInfoList.length} uniqueSigs=${uniqueSigs.size} uniqueNs=${uniqueNs.size} manifestN=${manifestN ? 'present' : 'none'}`);

    if (uniqueSigs.size === 0 && uniqueNs.size === 0) {
      logger.info('[DEOBF] no sig/n to deobfuscate, all URLs are direct');
      return;
    }

    try {
      const result = await YoutubeJavaScriptPlayerManager.deobfuscateBatch(
        Array.from(uniqueSigs), Array.from(uniqueNs), this.decoderPlayerId ?? undefined
      );

      logger.info(`[DEOBF] API returned sig=${Object.keys(result.sig).length} n=${Object.keys(result.n).length}`);

      // Log sig results
      Object.entries(result.sig).forEach((entry) => {
        const orig = entry[0];
        const decoded = entry[1];
        logger.debug(`[DEOBF] sig: ${orig.substring(0, 20)}... → ${decoded ? decoded.substring(0, 20) + '...' : 'NULL'}`);
      });
      // Log n results
      Object.entries(result.n).forEach((entry) => {
        const orig = entry[0];
        const decoded = entry[1];
        logger.debug(`[DEOBF] n: ${orig} → ${decoded ?? 'NULL'}`);
      });

      for (const info of streamInfos) {
        const itagInfo = itagInfoList[info.streamIndex];
        let updatedUrl = itagInfo.getContent();
        let sigApplied = false;
        let nApplied = false;

        if (info.obfuscatedSignature && result.sig[info.obfuscatedSignature]) {
          const deobfuscatedSig = result.sig[info.obfuscatedSignature];
          if (deobfuscatedSig) {
            updatedUrl = updatedUrl.replace('SIGNATURE_PLACEHOLDER', deobfuscatedSig);
            sigApplied = true;
          }
        }

        if (info.throttlingParam && result.n[info.throttlingParam]) {
          const deobfuscatedParam = result.n[info.throttlingParam];
          if (deobfuscatedParam) {
            // Replace the n query value even when the URL form is percent-encoded.
            // Plain string replace(decoded) fails if the URL still has %XX sequences.
            const nRe = /([?&]n=)([^&]*)/;
            if (nRe.test(updatedUrl)) {
              updatedUrl = updatedUrl.replace(nRe, `$1${encodeURIComponent(deobfuscatedParam)}`);
              nApplied = true;
            } else if (updatedUrl.includes(info.throttlingParam)) {
              updatedUrl = updatedUrl.replace(info.throttlingParam, deobfuscatedParam);
              nApplied = true;
            }
          }
        }

        logger.info(`[DEOBF] #${info.streamIndex} itag=${itagInfo.getItagItem().id} sigApplied=${sigApplied} nApplied=${nApplied} nLen=${info.throttlingParam?.length ?? 0}`);
        itagInfo.setContent(updatedUrl);
      }

      // 保存 manifest n 解密结果，供 deobfuscateManifestUrl 复用
      if (manifestN && result.n[manifestN]) {
        const decoded: string = result.n[manifestN]!;
        this.cachedManifestNResult = { original: manifestN, decoded: decoded } as ManifestNDecodeResult;
      }
    } catch (e) {
      logger.warn('batchDeobfuscateItagUrls failed:', e);
      throw new Error('Stream URL deobfuscation failed');
    }
  }

  /** 收集 streaming data 中 manifest URL 的 n 参数（路径格式 /n/XXXXX），统一到批量解密 */
  private collectManifestNParams(): string | undefined {
    const hlsUrl = this.getHlsManifestUrlFromStreamingData();
    const dashUrl = this.getDashManifestUrlFromStreamingData();
    const url = hlsUrl || dashUrl;
    if (!url) return undefined;
    // manifest URL 的 n 参数在路径中：/n/XXXXX，与 itag URL 的 n=XXXXX 格式不同
    const matcher = /\/n\/([^/]+)/.exec(url);
    return matcher ? matcher[1] : undefined;
  }

  private getThrottlingParamFromUrl(url: string): string | undefined {
    const match = url.match(/[&?]n=([^&]+)/);
    if (!match) return undefined;
    try {
      return decodeURIComponent(match[1]);
    } catch (_) {
      return match[1];
    }
  }

  private buildAudioStreamInfo(itagInfo: ItagInfo, sourceClient: string = 'android_vr'): StreamInfo {
    const itagItem = itagInfo.getItagItem();
    const mimeType = getMediaFormatMimeType(itagItem.getMediaFormat());
    const container = getMediaFormatSuffix(itagItem.getMediaFormat());

    const stream: StreamInfo = {
      url: itagInfo.getContent(),
      itag: itagItem.id,
      mimeType: mimeType,
      qualityLabel: undefined,
      audioQuality: itagItem.getAudioQuality() || undefined,
      bitrate: itagItem.getBitrate() || itagItem.getAverageBitrate(),
      contentLength: itagItem.getContentLength() > 0 ? itagItem.getContentLength() : undefined,
      hasVideo: false,
      hasAudio: true,
      deliveryMethod: DeliveryMethod.DASH,
      kind: 'audio_only',
      sourceClient: sourceClient,
      container: container,
      codecs: itagItem.getCodec(),
      initRange: itagItem.getInitStart() >= 0 ? { start: itagItem.getInitStart(), end: itagItem.getInitEnd() } : undefined,
      indexRange: itagItem.getIndexStart() >= 0 ? { start: itagItem.getIndexStart(), end: itagItem.getIndexEnd() } : undefined,
      approxDurationMs: itagItem.getApproxDurationMs() > 0 ? itagItem.getApproxDurationMs() : undefined,
      durationMs: undefined,
      isLive: undefined,
      isOtf: !itagInfo.getIsUrl(),
      audioLanguage: itagInfo.getAudioLocale(),
      audioTrackId: itagInfo.getAudioTrackId(),
      audioTrackName: itagInfo.getAudioTrackName(),
      audioTrackType: undefined,
      audioChannels: itagItem.getAudioChannels() > 0 ? itagItem.getAudioChannels() : undefined,
      audioSampleRate: itagItem.getSampleRate() > 0 ? itagItem.getSampleRate() : undefined,
      videoFps: undefined,
      codec: itagItem.getCodec(),
      width: itagItem.getWidth() > 0 ? itagItem.getWidth() : undefined,
      height: itagItem.getHeight() > 0 ? itagItem.getHeight() : undefined,
    };

    return stream;
  }

  private buildVideoStreamInfo(itagInfo: ItagInfo, areStreamsVideoOnly: boolean, sourceClient: string = 'android_vr'): StreamInfo {
    const itagItem = itagInfo.getItagItem();
    const mimeType = getMediaFormatMimeType(itagItem.getMediaFormat());
    const container = getMediaFormatSuffix(itagItem.getMediaFormat());
    const resolutionString = itagItem.getResolutionString() || '';

    const stream: StreamInfo = {
      url: itagInfo.getContent(),
      itag: itagItem.id,
      mimeType: mimeType,
      qualityLabel: resolutionString,
      audioQuality: undefined,
      bitrate: itagItem.getBitrate() || 0,
      contentLength: itagItem.getContentLength() > 0 ? itagItem.getContentLength() : undefined,
      hasVideo: true,
      hasAudio: !areStreamsVideoOnly,
      deliveryMethod: areStreamsVideoOnly ? DeliveryMethod.DASH : (itagInfo.getIsUrl() ? DeliveryMethod.PROGRESSIVE_HTTP : DeliveryMethod.DASH),
      kind: areStreamsVideoOnly ? 'video_only' : 'progressive',
      sourceClient: sourceClient,
      container: container,
      codecs: itagItem.getCodec(),
      initRange: itagItem.getInitStart() >= 0 ? { start: itagItem.getInitStart(), end: itagItem.getInitEnd() } : undefined,
      indexRange: itagItem.getIndexStart() >= 0 ? { start: itagItem.getIndexStart(), end: itagItem.getIndexEnd() } : undefined,
      approxDurationMs: itagItem.getApproxDurationMs() > 0 ? itagItem.getApproxDurationMs() : undefined,
      durationMs: undefined,
      isLive: undefined,
      isOtf: !itagInfo.getIsUrl(),
      audioLanguage: itagInfo.getAudioLocale(),
      audioTrackId: itagInfo.getAudioTrackId(),
      audioTrackName: itagInfo.getAudioTrackName(),
      audioTrackType: undefined,
      audioChannels: undefined,
      audioSampleRate: undefined,
      videoFps: itagItem.getFps() > 0 ? itagItem.getFps() : undefined,
      codec: itagItem.getCodec(),
      width: itagItem.getWidth() > 0 ? itagItem.getWidth() : undefined,
      height: itagItem.getHeight() > 0 ? itagItem.getHeight() : undefined,
    };

    return stream;
  }

  private async tryExtractHlsStreams(videoId: string): Promise<void> {
    const hlsManifestUrl = this.getHlsManifestUrlFromStreamingData();
    if (!hlsManifestUrl || hlsManifestUrl.length === 0) return;

    try {
      const deobfuscatedUrl = await this.deobfuscateManifestUrl(hlsManifestUrl);
      const response = await this.client.get(deobfuscatedUrl);
      if (response.responseCode === 200) {
        const manifestContent = response.result as string;
        const hlsResult = parseHlsMasterManifest(manifestContent, videoId);
        const videoStreams = hlsResult.videoStreams;
        const audioStreams = hlsResult.audioStreams;
        this.cachedVideoStreams.push(...videoStreams);
        this.cachedAudioStreams.push(...audioStreams);
      }
    } catch (e) {
      logger.warn('tryExtractHlsStreams failed:', e);
    }
  }

  private getHlsManifestUrlFromStreamingData(): string {
    for (const sd of [this.configuredStreamingData, this.safariStreamingData, this.androidStreamingData]) {
      if (sd && sd.hlsManifestUrl) {
        return sd.hlsManifestUrl + '?mpd_version=7';
      }
    }
    if (this.mwebHlsManifestUrl && this.mwebHlsManifestUrl.length > 0) {
      return this.mwebHlsManifestUrl.includes('?')
        ? this.mwebHlsManifestUrl
        : this.mwebHlsManifestUrl + '?mpd_version=7';
    }
    return '';
  }

  /** PipePipe getDashMpdUrl — always empty for YouTube stream path. */
  private getDashManifestUrlFromStreamingData(): string {
    return '';
  }

  /**
   * Deobfuscate n-param on manifest / serverAbr URLs.
   * PipePipe maybeDeobfuscateNParameter: query n= first, then path /n/.
   * SABR serverAbrStreamingUrl uses query form (…&n=XXXX&…).
   */
  private async deobfuscateManifestUrl(manifestUrl: string): Promise<string> {
    // 1) Query form: [?&]n=VALUE (SABR / googlevideo progressive)
    const queryMatch = /([?&])n=([^&]+)/.exec(manifestUrl);
    if (queryMatch) {
      const encryptedN = decodeURIComponent(queryMatch[2]);
      const decryptedN = await this.resolveDecryptedN(encryptedN);
      if (decryptedN) {
        const start = queryMatch.index + queryMatch[1].length + 2; // past "n="
        const end = start + queryMatch[2].length;
        const encoded = encodeURIComponent(decryptedN);
        logger.info(`[N-DEOBF] query n applied len ${encryptedN.length}->${decryptedN.length}`);
        return manifestUrl.substring(0, start) + encoded + manifestUrl.substring(end);
      }
      logger.warn(`[N-DEOBF] query n decrypt failed for len=${encryptedN.length}`);
    }

    // 2) Path form: /n/VALUE (HLS/DASH manifests)
    const pathMatch = /\/n\/([^/]+)/.exec(manifestUrl);
    if (pathMatch) {
      const encryptedN = pathMatch[1];
      const decryptedN = await this.resolveDecryptedN(encryptedN);
      if (decryptedN) {
        logger.info(`[N-DEOBF] path n applied len ${encryptedN.length}->${decryptedN.length}`);
        return manifestUrl.replace('/n/' + encryptedN, '/n/' + decryptedN);
      }
      logger.warn(`[N-DEOBF] path n decrypt failed for len=${encryptedN.length}`);
    }
    return manifestUrl;
  }

  private async resolveDecryptedN(encryptedN: string): Promise<string | undefined> {
    if (this.cachedManifestNResult && this.cachedManifestNResult.original === encryptedN) {
      return this.cachedManifestNResult.decoded;
    }
    try {
      const result = await YoutubeJavaScriptPlayerManager.deobfuscateBatch(
        [], [encryptedN], this.decoderPlayerId ?? undefined);
      const decryptedN = result.n[encryptedN];
      if (decryptedN) {
        this.cachedManifestNResult = { original: encryptedN, decoded: decryptedN } as ManifestNDecodeResult;
        return decryptedN;
      }
    } catch (e) {
      logger.warn('resolveDecryptedN failed:', e);
    }
    return undefined;
  }

  private prepareInnerTubeContext(clientType: 'WEB' | 'ANDROID' = 'ANDROID'): InnerTubeContext {
    if (clientType === 'ANDROID') {
      return {
        client: {
          clientName: ClientsConstants.ANDROID_CLIENT_NAME,
          clientVersion: ClientsConstants.ANDROID_CLIENT_VERSION,
          hl: this.client.getLocalization().getLanguageCode(),
          gl: this.client.getContentCountry().getCountryCode(),
          platform: 'MOBILE',
          utcOffsetMinutes: 0
        },
        request: { internalExperimentFlags: [] as string[], useSsl: true },
        user: { lockedSafetyMode: false }
      } as InnerTubeContext;
    }
    return {
      client: {
        clientName: 'WEB',
        clientVersion: this.getWebClientVersion(),
        hl: this.client.getLocalization().getLanguageCode(),
        gl: this.client.getContentCountry().getCountryCode(),
        platform: ClientsConstants.DESKTOP_CLIENT_PLATFORM,
        utcOffsetMinutes: 0,
        originalUrl: 'https://www.youtube.com'
      },
      request: { internalExperimentFlags: [] as string[], useSsl: true },
      user: { lockedSafetyMode: false }
    } as InnerTubeContext;
  }

  private webApiHeaders(): Record<string, string> {
    return this.webDesktopApiHeaders();
  }
}
