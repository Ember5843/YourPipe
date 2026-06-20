import { YTCoreLogger } from '../common/YTCoreLogger';
import {
  fixThumbnailUrl,
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
import { SafariPlayerClient } from './clients/SafariPlayerClient';
import { AndroidPlayerClient } from './clients/AndroidPlayerClient';
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
 * InnerTube player response result
 */
export interface InnertubePlayerResult {
  android: PlayerResponse | undefined;
  safari: PlayerResponse | undefined;
  androidCpn: string | undefined;
  safariCpn: string | undefined;
}

/** Cached manifest n-decryption result */
interface ManifestNDecodeResult {
  original: string;
  decoded: string;
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
 * Android client context (contains client, request, user)
 */
export interface AndroidClientContext {
  client: InnerTubeClientContext;
  request: InnerTubeRequest;
  user: InnerTubeUser;
}

/**
 * InnerTube base request payload
 */
export interface InnerTubeBasePayload {
  context: InnerTubeContext;
  videoId: string;
  contentCheckOk: boolean;
  racyCheckOk: boolean;
  cpn: string;
}

/**
 * WEB embedded request payload
 */
export interface WebEmbeddedPayload extends InnerTubeBasePayload {
  thirdParty: ThirdParty;
  request: InnerTubeRequest;
  user: InnerTubeUser;
}

/**
 * Android request payload
 */
export interface AndroidPayload {
  context: AndroidClientContext;
  playerRequest: AndroidPlayerRequest;
  disablePlayerResponse: boolean;
}

/**
 * iOS request payload
 */
export interface IosPayload extends InnerTubeBasePayload {
}

/**
 * Third party embed info
 */
export interface ThirdParty {
  embedUrl: string;
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
 * Android player request
 */
export interface AndroidPlayerRequest {
  videoId: string;
  cpn: string;
  contentCheckOk: boolean;
  racyCheckOk: boolean;
}

/**
 * Android player response wrapper
 */
export interface AndroidReelResponse {
  playerResponse?: PlayerResponse;
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

  // Cached Android visitorData
  private androidVisitorData: string | undefined = undefined;


  // Localization settings
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
    await this.client.initialize();
    logger.info('Initialized');
  }

  /**
   * Get HTTP client
   */
  getHttpClient(): YouTubeHttpClient {
    return this.client;
  }

  /**
   * Extract video info (Main entry)
   * @param videoId YouTube video ID
   * @returns VideoInfo
   */
  async extractVideoInfo(videoId: string): Promise<VideoInfo> {
    logger.info(`Extracting video info for: ${videoId}`);

    // 1. Fetch watch page HTML
    const html = await this.fetchWatchPage(videoId);

    // 2. Extract player response
    const playerResponse = this.extractPlayerResponse(html);

    // 2.5 Check playability status (登录态下跳过，由 extractVideoStreams 中 InnerTube 客户端决定)
    const authManager = AuthSessionManager.getInstance();
    const hasCookieAuth = authManager?.isSignedIn() === true && !!(authManager?.getCookieString());
    const watchStatus = playerResponse.playabilityStatus?.status?.toUpperCase();
    if (!hasCookieAuth || watchStatus !== 'LOGIN_REQUIRED') {
      this.checkPlayabilityStatus(playerResponse.playabilityStatus);
    }

    // 3. Extract metadata
    const videoInfo = this.extractMetadata(videoId, playerResponse);

    // 4. Save raw player response
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

    const reason = this.extractTextFromRuns(playabilityStatus.errorScreen?.playerErrorMessageRenderer?.reason);
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
      const cleanUrl = baseUrl
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

  // Multi-client streaming data cache (aligned with PipePipe)
  private safariStreamingData: StreamingData | undefined;
  private androidStreamingData: StreamingData | undefined;
  // Cache the full InnerTube /player responses so callers (e.g. extractVideoStreams)
  // can pick the best PlayerResponse for fields the watch HTML lacks (captions, etc.)
  private cachedInnertubePlayers: InnertubePlayerResult | undefined;
  private safariCpn: string | undefined;
  private androidCpn: string | undefined;

  /**
   * Ensure streams are cached. If not, fetch and cache them.
   * Ported from org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamExtractor.ensureStreamsAreCached
   */
  async ensureStreamsAreCached(videoId: string, html: string, watchPlayerResponse: PlayerResponse): Promise<void> {
    if (this.streamsCachedVideoId === videoId && this.cachedAudioStreams.length + this.cachedVideoOnlyStreams.length > 0) {
      return;
    }

    this.cachedManifestNResult = null;

    const innertubePlayers = await this.fetchInnertubePlayer(html, videoId);
    this.cachedInnertubePlayers = innertubePlayers;

    // 用主客户端的 playabilityStatus 覆盖 watch 页面（登录态下的匿名检查不可靠）
    const authManager = AuthSessionManager.getInstance();
    const hasCookieAuth = authManager?.isSignedIn() === true && !!(authManager?.getCookieString());
    const primaryPr = hasCookieAuth ? innertubePlayers.safari : innertubePlayers.android;
    if (primaryPr?.playabilityStatus) {
      this.checkPlayabilityStatus(primaryPr.playabilityStatus);
    } else if (!this.cachedAudioStreams.length && !this.cachedVideoOnlyStreams.length) {
      // 主客户端无响应 + 还没有缓存的流 → 保底抛异常（否则后面会出 SABR-only 检测）
      logger.warn('[STREAM_DEBUG] Primary InnerTube client returned no playabilityStatus and no cached streams');
    }

    // Extract streaming data from used clients (Safari when logged in, Android otherwise)
    this.safariStreamingData = innertubePlayers.safari?.streamingData;
    this.androidStreamingData = innertubePlayers.android?.streamingData;
    this.safariCpn = innertubePlayers.safariCpn;
    this.androidCpn = innertubePlayers.androidCpn;

    // Primary streaming data and cpn (Safari preferred when logged in, Android otherwise)
    const primarySd = this.safariStreamingData ?? this.androidStreamingData;
    const primaryCpn = this.safariCpn ?? this.androidCpn ?? '';
    const primarySourceClient = this.safariStreamingData ? 'safari' : 'android_vr';

    const allItagInfos: ItagInfo[] = [];

    // Collect audio streams
    const audioStreams = this.getStreamsFromStreamingDataKey(videoId, primarySd, 'adaptiveFormats', ItagType.AUDIO, primaryCpn);
    allItagInfos.push(...audioStreams);
    const videoStartIndex = allItagInfos.length;

    // Collect video streams (progressive)
    const videoStreams = this.getStreamsFromStreamingDataKey(videoId, primarySd, 'formats', ItagType.VIDEO, primaryCpn);
    allItagInfos.push(...videoStreams);
    const videoOnlyStartIndex = allItagInfos.length;

    // Collect video-only streams
    const videoOnlyStreams = this.getStreamsFromStreamingDataKey(videoId, primarySd, 'adaptiveFormats', ItagType.VIDEO_ONLY, primaryCpn);
    allItagInfos.push(...videoOnlyStreams);

    // Batch deobfuscate ALL streams
    await this.batchDeobfuscateItagUrls(videoId, allItagInfos);

    // Build audio streams
    this.cachedAudioStreams = [];
    for (let i = 0; i < videoStartIndex; i++) {
      const stream = this.buildAudioStreamInfo(allItagInfos[i], primarySourceClient);
      if (!containSimilarStream(stream, this.cachedAudioStreams)) {
        this.cachedAudioStreams.push(stream);
      }
    }
    this.cachedAudioStreams.sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0));

    // Build video streams
    this.cachedVideoStreams = [];
    for (let i = videoStartIndex; i < videoOnlyStartIndex; i++) {
      const stream = this.buildVideoStreamInfo(allItagInfos[i], false, primarySourceClient);
      if (!containSimilarStream(stream, this.cachedVideoStreams)) {
        this.cachedVideoStreams.push(stream);
      }
    }

    // Build video-only streams
    this.cachedVideoOnlyStreams = [];
    for (let i = videoOnlyStartIndex; i < allItagInfos.length; i++) {
      const stream = this.buildVideoStreamInfo(allItagInfos[i], true, primarySourceClient);
      if (!containSimilarStream(stream, this.cachedVideoOnlyStreams)) {
        this.cachedVideoOnlyStreams.push(stream);
      }
    }

    // HLS fallback if no streams
    if (this.cachedAudioStreams.length === 0 && this.cachedVideoOnlyStreams.length === 0) {
      await this.tryExtractHlsStreams(videoId);
    }

    // Mirror PipePipe line 1405: SABR check after HLS fallback, skip for live streams
    const isLive = watchPlayerResponse.videoDetails?.isLiveContent === true;
    if (!isLive && this.isSabrOnlyResponse(innertubePlayers)
      && this.getHlsManifestUrlFromStreamingData().length === 0) {
      throw new ContentNotSupportedException(
        'YouTube returned SABR-only streaming data without usable stream URLs. '
        + 'Try logging in to get HLS fallback streams.'
      );
    }

    this.streamsCachedVideoId = videoId;
  }

  /**
   * Detect SABR-only responses where the primary client's adaptive formats have no url/cipher.
   * Mirrors PipePipe: only the primary client is checked.
   * Unlogged → Android, logged in (cookie) → Safari.
   */
  private isSabrOnlyResponse(players: InnertubePlayerResult): boolean {
    const authManager = AuthSessionManager.getInstance();
    const hasCookieAuth = authManager?.isSignedIn() === true && !!(authManager?.getCookieString());

    // Primary client mirrors PipePipe's selection logic
    const primarySd = hasCookieAuth
      ? players.safari?.streamingData
      : players.android?.streamingData;

    if (!primarySd) {
      return false;
    }
    const adaptive = primarySd.adaptiveFormats;
    if (!adaptive || adaptive.length === 0) {
      return false;
    }
    for (const fmt of adaptive) {
      if (fmt.url || fmt.signatureCipher || fmt.cipher) {
        return false;
      }
    }
    return true;
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
   * Extract video streams
   * @param videoId video ID
   * @returns VideoInfo with streams
   */
  async extractVideoStreams(videoId: string): Promise<VideoInfo> {
    logger.info(`Extracting video streams for: ${videoId}`);

    const authManager = AuthSessionManager.getInstance();
    const hasCookieAuth = authManager?.isSignedIn() === true && !!(authManager?.getCookieString());

    // 同时发起 watch 页面请求和（非登录态下）visitorData 请求
    const watchPagePromise = this.fetchWatchPage(videoId);
    const visitorPromise = !hasCookieAuth ? this.getAndroidVisitorData() : Promise.resolve(undefined);

    const html = await watchPagePromise;
    const androidVisitor = await visitorPromise;

    const watchPlayerResponse = this.extractPlayerResponse(html);

    const watchStatus = watchPlayerResponse.playabilityStatus?.status?.toUpperCase();
    if (!hasCookieAuth || watchStatus !== 'LOGIN_REQUIRED') {
      this.checkPlayabilityStatus(watchPlayerResponse.playabilityStatus);
    } else {
      logger.info(`[STREAM_DEBUG] Logged-in user, skipping playability check on anonymous watch page (status=${watchStatus})`);
    }

    // 元数据提取和流提取可以并行——extractMetadata 只读 watchPlayerResponse，
    // ensureStreamsAreCached 也依赖 html + watchPlayerResponse，两者无竞态。
    const [videoInfo] = await Promise.all([
      Promise.resolve().then(() => {
        const meta = this.extractMetadata(videoId, watchPlayerResponse);
        meta.playerResponse = watchPlayerResponse;
        return meta;
      }),
      this.ensureStreamsAreCached(videoId, html, watchPlayerResponse).then(() => {
        // 字幕提取和 deobfuscateManifestUrl 可以等流提取完成后再做，
        // 但为了保持代码最小改动，放在这里继续做
      })
    ]);

    videoInfo.streams = [
      ...this.cachedAudioStreams,
      ...this.cachedVideoStreams,
      ...this.cachedVideoOnlyStreams,
    ];

    // 字幕提取——不阻塞播放启动，但当前接口合约要求一并返回
    let captionsSource: PlayerResponse = watchPlayerResponse;
    if (this.cachedInnertubePlayers) {
      const bestPr = this.selectBestPlayerResponse(videoId, watchPlayerResponse, this.cachedInnertubePlayers);
      const bestTracks = this.extractSubtitleTracks(bestPr);
      if (bestTracks.length > 0) {
        videoInfo.subtitleTracks = bestTracks;
        captionsSource = bestPr;
      } else {
        videoInfo.subtitleTracks = this.extractSubtitleTracks(watchPlayerResponse);
      }
    } else {
      videoInfo.subtitleTracks = this.extractSubtitleTracks(watchPlayerResponse);
    }
    videoInfo.playerResponse = captionsSource;
    logger.info(`[SUBTITLE_EXTRACT] final tracks=${videoInfo.subtitleTracks.length} source=${captionsSource === watchPlayerResponse ? 'watch' : 'best-pr'}`);

    const hlsRaw = this.getHlsManifestUrlFromStreamingData();
    if (hlsRaw) {
      videoInfo.hlsUrl = await this.deobfuscateManifestUrl(hlsRaw);
    }
    const dashRaw = this.getDashManifestUrlFromStreamingData();
    if (dashRaw) {
      videoInfo.dashMpdUrl = await this.deobfuscateManifestUrl(dashRaw);
    }

    return videoInfo;
  }

  async fetchPlaybackExtras(videoId: string, playerResponse?: PlayerResponse): Promise<VideoInfo> {
    logger.info(`Fetching playback extras for: ${videoId}`);
    const baseInfo = new VideoInfo(videoId);
    const settledResults = await Promise.allSettled([
      this.fetchNextResponse(videoId),
      this.fetchDislikeCount(videoId)
    ]);
    const nextResult = settledResults[0];
    const rydResult = settledResults[1];

    const nextResponse: NextResponse | null = nextResult.status === 'fulfilled' ? nextResult.value as NextResponse : null;
    if (nextResult.status === 'rejected') {
      logger.warn('Failed to fetch next response:', nextResult.reason);
    }

    if (rydResult.status === 'fulfilled' && (rydResult.value as number) >= 0) {
      baseInfo.dislikeCount = rydResult.value as number;
    }

    if (nextResponse) {
      this.enrichFromNextResponse(baseInfo, nextResponse, playerResponse);
    }

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

  private async getAndroidVisitorData(): Promise<string | undefined> {
    if (this.androidVisitorData) return this.androidVisitorData;

    const payload: AndroidVisitorPayload = {
      context: {
        client: {
          clientName: ClientsConstants.ANDROID_CLIENT_NAME,
          clientVersion: ClientsConstants.ANDROID_CLIENT_VERSION,
          clientScreen: 'WATCH',
          androidSdkVersion: ClientsConstants.ANDROID_SDK_VERSION,
          osName: 'Android',
          osVersion: ClientsConstants.ANDROID_OS_VERSION,
          hl: this.hl,
          gl: this.gl,
          platform: 'MOBILE',
          utcOffsetMinutes: 0
        },
        request: { internalExperimentFlags: [], useSsl: true },
        user: { lockedSafetyMode: false }
      }
    };

    const headers: Record<string, string> = {
      'User-Agent': ClientsConstants.ANDROID_USER_AGENT,
      'Content-Type': 'application/json',
      'X-Goog-Api-Format-Version': '2'
    };

    const url = 'https://youtubei.googleapis.com/youtubei/v1/visitor_id?prettyPrint=false';

    try {
      const response = await this.client.postJson(url, payload, headers);
      if (response.responseCode === 200) {
        const respObj = JSON.parse(response.result as string) as AndroidVisitorResponse;
        const visitor = respObj.responseContext?.visitorData;
        if (visitor) {
          this.androidVisitorData = visitor;
          return visitor;
        }
      }
    } catch (e) {
      logger.warn('Failed to get Android visitorData:', e);
    }
    return undefined;
  }

  /**
   * Fetch the primary InnerTube player response.
   * Mirrors PipePipe exactly: unlogged → Android only, logged in (cookie) → Safari only.
   */
  private async fetchInnertubePlayer(html: string, videoId: string): Promise<InnertubePlayerResult> {
    // Extract player metadata locally from ytcfg (mirrors yt-dlp's extract_ytcfg + _extract_signature_timestamp)
    const ytcfg = this.parseYtcfgSet(html);
    let localSts: number | undefined;
    let playerId: string | null = null;

    if (ytcfg) {
      // STS: yt-dlp reads ytcfg.STS as integer — direct field access
      const stsValue = ytcfg['STS'];
      if (typeof stsValue === 'number') {
        localSts = stsValue;
      }
      // PLAYER_JS_URL: yt-dlp reads ytcfg.PLAYER_JS_URL as string
      const playerJsUrl = ytcfg['PLAYER_JS_URL'];
      if (typeof playerJsUrl === 'string') {
        playerId = this.extractPlayerIdFromUrl(playerJsUrl);
      }
    }

    if (localSts !== undefined || playerId) {
      const meta: PlayerMetadata = {
        playerId: playerId ?? '',
        signatureTimestamp: localSts ?? 0,
      };
      PipePipeApiDecoder.setLocalMetadata(meta);
      logger.info(`[METADATA] local extraction OK: playerId=${meta.playerId || '(missing)'} sts=${meta.signatureTimestamp || '(missing)'}`);
    } else {
      logger.warn('[METADATA] ytcfg did not contain STS or PLAYER_JS_URL — decode will use API fallback');
    }

    const htmlVisitorData = this.parseYtcfgValue(html, 'VISITOR_DATA');
    const androidVisitor = await this.getAndroidVisitorData();
    const visitorData = androidVisitor || htmlVisitorData;

    const result: InnertubePlayerResult = {
      android: undefined, safari: undefined,
      androidCpn: undefined, safariCpn: undefined
    };

    const authManager = AuthSessionManager.getInstance();
    const hasCookieAuth = authManager?.isSignedIn() === true && !!(authManager?.getCookieString());
    logger.info(`[STREAM_DEBUG] cookie_auth=${hasCookieAuth} → primary client: ${hasCookieAuth ? 'Safari' : 'Android'}`);

    const ctx: ClientFetchContext = {
      videoId: videoId,
      hl: this.hl,
      gl: this.gl,
      visitorData: visitorData,
      signatureTimestamp: localSts
    };

    if (hasCookieAuth) {
      // Logged in: Safari client
      try {
        const safariResult = await SafariPlayerClient.fetch(ctx, this.client);
        if (safariResult?.playerResponse) {
          const sd = safariResult.streamingData;
          logger.info(`[STREAM_DEBUG] Safari: status=${safariResult.playerResponse.playabilityStatus?.status}, formats=${sd?.formats?.length || 0}, adaptive=${sd?.adaptiveFormats?.length || 0}`);
          result.safari = safariResult.playerResponse;
          result.safariCpn = safariResult.cpn;
        }
      } catch (e) {
        logger.warn('Safari fetch error:', e);
      }
    } else {
      // Unlogged: Android client
      try {
        const androidResult = await AndroidPlayerClient.fetch(ctx, this.client);
        if (androidResult?.playerResponse) {
          const sd = androidResult.streamingData;
          logger.info(`[STREAM_DEBUG] Android: status=${androidResult.playerResponse.playabilityStatus?.status}, formats=${sd?.formats?.length || 0}, adaptive=${sd?.adaptiveFormats?.length || 0}`);
          result.android = androidResult.playerResponse;
          result.androidCpn = androidResult.cpn;
        }
      } catch (e) {
        logger.warn('Android fetch error:', e);
      }
    }

    return result;
  }

  /** 获取 next 端点响应（对标 PipePipe nextDataCall） */
  private async fetchNextResponse(videoId: string): Promise<NextResponse | null> {
    const url = `${ClientsConstants.YOUTUBEI_V1_URL}next?prettyPrint=false`;
    interface NextClientPayload {
      clientName: string;
      clientVersion: string;
      hl: string;
      gl: string;
    }
    interface NextContextPayload {
      client: NextClientPayload;
    }
    interface NextRequestPayload {
      context: NextContextPayload;
      videoId: string;
      contentCheckOk: boolean;
      racyCheckOk: boolean;
    }
    const payload: NextRequestPayload = {
      context: {
        client: {
          clientName: ClientsConstants.WEB_CLIENT_NAME,
          clientVersion: ClientsConstants.WEB_HARDCODED_CLIENT_VERSION,
          hl: this.hl,
          gl: this.gl,
        }
      },
      videoId: videoId,
      contentCheckOk: true,
      racyCheckOk: true,
    };
    try {
      const resp = await this.client.postJson(url, payload);
      if (resp.responseCode === 200) {
        return JSON.parse(resp.result as string) as NextResponse;
      }
    } catch (e) {
      logger.warn('fetchNextResponse failed:', e);
    }
    return null;
  }

  /** 从 RYD API 获取点踩数（对标 PipePipe dislikeCall） */
  private async fetchDislikeCount(videoId: string): Promise<number> {
    const url = `https://returnyoutubedislikeapi.com/votes?videoId=${videoId}`;
    const httpRequest = http.createHttp();
    try {
      const resp = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
      });
      if (resp.responseCode === 200) {
        const body = typeof resp.result === 'string'
          ? resp.result
          : this.arrayBufferToString(resp.result as ArrayBuffer);
        interface DislikeData {
          dislikes?: number;
        }
        const data = JSON.parse(body) as DislikeData;
        return data.dislikes ?? -1;
      }
    } catch (e) {
      logger.warn('fetchDislikeCount failed:', e);
    } finally {
      httpRequest.destroy();
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
    // uploaderUrl: channelId already in videoInfo, build URL
    if (videoInfo.channelId) {
      videoInfo.uploaderUrl = `https://www.youtube.com/channel/${videoInfo.channelId}`;
    }
    // uploaderAvatarUrl: last thumbnail in owner.thumbnail.thumbnails
    const thumbs = owner.thumbnail?.thumbnails || [];
    if (thumbs.length > 0) {
      videoInfo.uploaderAvatarUrl = thumbs[thumbs.length - 1].url;
    }
    // uploaderSubscriberCount: subscriberCountText
    const subText = this.extractNextText(owner.subscriberCountText);
    if (subText) {
      videoInfo.uploaderSubscriberCount = parseSubscriberCount(subText);
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
      item.thumbnailUrl = thumbs[thumbs.length - 1].url;
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
      item.thumbnailUrl = src[src.length - 1].url;
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
    if (innertubePlayers.safari) candidates.push({ source: 'safari', pr: innertubePlayers.safari });
    if (innertubePlayers.android) candidates.push({ source: 'android', pr: innertubePlayers.android });
    candidates.push({ source: 'watch', pr: watchPlayerResponse });

    const hasCookieAuth = AuthSessionManager.getInstance()?.isSignedIn() === true
      && !!(AuthSessionManager.getInstance()?.getCookieString());
    const sourceWeight: Record<string, number> = hasCookieAuth
      ? { 'safari': 5, 'ios': 4, 'android': 3, 'watch': 1 }
      : { 'android': 5, 'ios': 4, 'safari': 3, 'watch': 1 };

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
      const response: http.HttpResponse = await this.client.postJson(url, body, this.webApiHeaders());

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
      const response: http.HttpResponse = await this.client.postJson(url, body, this.webApiHeaders());

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
    const body: InnerTubeNextPayload = {
      context: this.prepareInnerTubeContext('WEB'),
      videoId: videoId
    };

    const response: http.HttpResponse = await this.client.postJson(
      `https://www.youtube.com/youtubei/v1/next?prettyPrint=false`,
      body,
      this.webApiHeaders()
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
      const displayName = audioTrack.displayName || '';
      const langPart = audioTrackId.split('.')[0];
      const audioLocale = langPart.split('-')[0];
      const isDefault = displayName.includes('original') || displayName.includes('yokuqala');
      const audioTrackName = isDefault ? langPart + ' (original)' : langPart;
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
        Array.from(uniqueSigs), Array.from(uniqueNs)
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
            updatedUrl = updatedUrl.replace(info.throttlingParam, deobfuscatedParam);
            nApplied = true;
          }
        }

        logger.debug(`[DEOBF] #${info.streamIndex} sigApplied=${sigApplied} nApplied=${nApplied} finalUrl=${updatedUrl.substring(0, 120)}`);
        itagInfo.setContent(updatedUrl);
      }

      // 保存 manifest n 解密结果，供 deobfuscateManifestUrl 复用
      if (manifestN && result.n[manifestN]) {
        const decoded: string = result.n[manifestN]!;
        this.cachedManifestNResult = { original: manifestN, decoded: decoded } as ManifestNDecodeResult;
      }
    } catch (e) {
      logger.warn('batchDeobfuscateItagUrls failed:', e);
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
    return match ? match[1] : undefined;
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
    for (const sd of [this.safariStreamingData, this.androidStreamingData]) {
      if (sd && sd.hlsManifestUrl) {
        return sd.hlsManifestUrl + '?mpd_version=7';
      }
    }
    return '';
  }

  private getDashManifestUrlFromStreamingData(): string {
    // 对齐 PipePipe YoutubeStreamExtractor.getDashMpdUrl (708)：safari → android
    for (const sd of [this.safariStreamingData, this.androidStreamingData]) {
      if (sd && sd.dashManifestUrl) {
        return sd.dashManifestUrl + '?mpd_version=7';
      }
    }
    return '';
  }

  private arrayBufferToString(buffer: ArrayBuffer): string {
    const bytes = new Uint8Array(buffer);
    let result = '';
    for (let i = 0; i < bytes.length; i++) {
      result += String.fromCharCode(bytes[i]);
    }
    return result;
  }

  private async deobfuscateManifestUrl(manifestUrl: string): Promise<string> {
    const matcher = /\/n\/([^/]+)/.exec(manifestUrl);
    if (matcher) {
      const encryptedN = matcher[1];

      // 优先使用批量解密时已缓存的结果
      if (this.cachedManifestNResult && this.cachedManifestNResult.original === encryptedN) {
        return manifestUrl.replace('/n/' + encryptedN, '/n/' + this.cachedManifestNResult.decoded);
      }

      // 未命中缓存（极少见：manifest n 与 itag n 完全无交集），单独请求
      try {
        const result = await YoutubeJavaScriptPlayerManager.deobfuscateBatch(
          [], [encryptedN]
        );
        const decryptedN = result.n[encryptedN];
        if (decryptedN) {
          return manifestUrl.replace('/n/' + encryptedN, '/n/' + decryptedN);
        }
      } catch (e) {
        logger.warn('deobfuscateManifestUrl failed:', e);
      }
    }
    return manifestUrl;
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
        clientVersion: ClientsConstants.WEB_HARDCODED_CLIENT_VERSION,
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
    return {
      'Content-Type': 'application/json',
      'X-YouTube-Client-Name': ClientsConstants.WEB_CLIENT_ID,
      'X-YouTube-Client-Version': ClientsConstants.WEB_HARDCODED_CLIENT_VERSION,
      'Origin': 'https://www.youtube.com',
      'Referer': 'https://www.youtube.com/'
    };
  }
}
