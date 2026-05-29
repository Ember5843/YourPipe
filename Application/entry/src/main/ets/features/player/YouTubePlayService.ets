import { AppLog } from '../../common/AppLog';
import { media } from '@kit.MediaKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  YouTubeExtractor,
  VideoInfo,
  StreamInfo as YouTubeStreamInfo,
  CommentItem,
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
  ExtractionException
} from 'youtube_core';
import { StreamInfo, SubtitleTrackInfo } from 'mediaservice';
import { SearchLocaleManager } from '../../common/SearchLocaleManager';

const logger = AppLog.getInstance('YouTubePlayService');

const TAG: string = '[PlayerLog][YouTubePlayService]';

export interface YouTubePlayResult {
  success: boolean;
  videoInfo?: VideoInfo;
  playerStreams?: StreamInfo[];
  subtitleTracks?: SubtitleTrackInfo[];
  mediaSource?: media.MediaSource;
  error?: string | Resource;
  errorCode?: YouTubeErrorCode;
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
  private isInitializing: boolean = false;

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  static getInstance(context: common.UIAbilityContext): YouTubePlayService {
    if (!YouTubePlayService.instance) {
      YouTubePlayService.instance = new YouTubePlayService(context);
    }
    return YouTubePlayService.instance;
  }

  async initialize(): Promise<void> {
    if (this.extractor) return;
    if (this.isInitializing) {
      while (this.isInitializing) await this.sleep(100);
      return;
    }
    this.isInitializing = true;
    try {
      this.extractor = new YouTubeExtractor(this.context);
      await this.extractor.initialize();
      logger.info(`${TAG} YouTubePlayService initialized`);
    } catch (e) {
      this.extractor = undefined;
      logger.error(`${TAG} initialize failed: ${(e as Error).message || e}`);
    } finally {
      this.isInitializing = false;
    }
  }

  /**
   * 获取视频评论
   */
  async fetchComments(videoId: string, nextPageToken: string | null = null): Promise<CommentResponse> {
    if (!this.extractor) await this.initialize();
    return await this.extractor!.fetchComments(videoId, nextPageToken);
  }

  /**
   * 获取评论回复
   */
  async fetchCommentReplies(replyContinuation: string): Promise<CommentResponse> {
    if (!this.extractor) await this.initialize();
    return await this.extractor!.fetchCommentReplies(replyContinuation);
  }

  async refreshStreams(videoId: string): Promise<YouTubePlayResult> {
    logger.info(`${TAG} refreshStreams() called for ${videoId}`);
    if (!this.extractor) await this.initialize();

    try {
      const videoInfo = await this.extractor!.extractVideoStreams(videoId);
      if (videoInfo.streams.length === 0) {
        return { success: false, videoInfo: videoInfo, error: 'No streams available', errorCode: YouTubeErrorCode.NO_STREAMS };
      }

      const playerStreams: StreamInfo[] = videoInfo.streams.map((stream: YouTubeStreamInfo): StreamInfo => ({
        url: stream.url,
        itag: stream.itag,
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
        initRangeStart: stream.initRange?.start,
        initRangeEnd: stream.initRange?.end,
        indexRangeStart: stream.indexRange?.start,
        indexRangeEnd: stream.indexRange?.end,
        contentLength: stream.contentLength,
        approxDurationMs: stream.approxDurationMs,
        isOtf: stream.isOtf,
        sourceClient: stream.sourceClient,
      }));

      const subtitleTracks: SubtitleTrackInfo[] = videoInfo.subtitleTracks.map((track): SubtitleTrackInfo => ({
        url: track.url,
        languageCode: track.languageCode,
        name: track.name,
        kind: track.kind,
        isAutoGenerated: track.isAutoGenerated
      }));

      return {
        success: true,
        videoInfo: videoInfo,
        playerStreams: playerStreams,
        subtitleTracks: subtitleTracks
      };
    } catch (e) {
      return { success: false, error: (e as Error).message, errorCode: YouTubeErrorCode.UNKNOWN_ERROR };
    }
  }

  async fetchPlaybackExtras(videoId: string): Promise<VideoInfo | null> {
    if (!this.extractor) await this.initialize();
    try {
      return await this.extractor!.fetchPlaybackExtras(videoId);
    } catch (e) {
      logger.warn(`${TAG} fetchPlaybackExtras failed: ${(e as Error).message || e}`);
      return null;
    }
  }

  async fetchPlaybackExtrasFor(videoInfo: VideoInfo): Promise<VideoInfo | null> {
    if (!this.extractor) await this.initialize();
    try {
      return await this.extractor!.fetchPlaybackExtras(videoInfo.videoId, videoInfo.playerResponse);
    } catch (e) {
      logger.warn(`${TAG} fetchPlaybackExtrasFor failed: ${(e as Error).message || e}`);
      return null;
    }
  }

  async play(videoIdOrUrl: string): Promise<YouTubePlayResult> {
    logger.info(`${TAG} play() called for ${videoIdOrUrl}`);
    if (!this.extractor) await this.initialize();

    // Sync localization settings from AppStorage before extracting streams
    if (this.extractor) {
      const uiConfig = AppStorage.get('uiConfig') as Record<string, string> | undefined;
      if (uiConfig) {
        this.extractor.hl = SearchLocaleManager.resolveSearchLanguage();
        this.extractor.gl = SearchLocaleManager.resolveSearchCountry();
      }
    }

    const videoId = this.extractVideoId(videoIdOrUrl);
    if (!videoId) return { success: false, error: $r('app.string.yt_error_invalid_video_id'), errorCode: YouTubeErrorCode.INVALID_INPUT };

    try {
      logger.info(`${TAG} 开始提取视频流及元数据 (包含 Player JS 和解密)...`);
      const extractStartMs = Date.now();
      const videoInfo = await this.extractor!.extractVideoStreams(videoId);
      const extractElapsed = Date.now() - extractStartMs;
      logger.info(`${TAG} 提取完成 elapsed=${extractElapsed}ms streams=${videoInfo.streams.length} subtitles=${videoInfo.subtitleTracks.length} isLive=${videoInfo.isLive}`);
      if (videoInfo.streams.length === 0) {
        const errorCode = this.determineNoStreamsErrorCode(videoInfo);
        logger.warn(`${TAG} 无可用流 errorCode=${errorCode} ageRestricted=${videoInfo.isAgeRestricted} requiresLogin=${videoInfo.requiresLogin}`);
        return { success: false, videoInfo: videoInfo, error: this.getErrorMessage(errorCode, videoInfo), errorCode: errorCode };
      }

      const playerStreams: StreamInfo[] = videoInfo.streams.map((stream: YouTubeStreamInfo): StreamInfo => ({
        url: stream.url,
        itag: stream.itag,
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
        approxDurationMs: stream.approxDurationMs,
        isOtf: stream.isOtf,
        sourceClient: stream.sourceClient,
      }));

      const subtitleTracks: SubtitleTrackInfo[] = videoInfo.subtitleTracks.map((track): SubtitleTrackInfo => ({
        url: track.url,
        languageCode: track.languageCode,
        name: track.name,
        kind: track.kind,
        isAutoGenerated: track.isAutoGenerated
      }));

      logger.info(`${TAG} 流摘要: video_only=${playerStreams.filter(s => s.kind === 'video_only').length} audio_only=${playerStreams.filter(s => s.kind === 'audio_only').length} progressive=${playerStreams.filter(s => s.kind === 'progressive' || s.kind === '').length} subtitles=${subtitleTracks.length}`);
      return {
        success: true,
        videoInfo: videoInfo,
        playerStreams: playerStreams,
        subtitleTracks: subtitleTracks
      };
    } catch (e) {
      const errorCode = this.analyzeErrorCode(e as Error);
      logger.error(`${TAG} play() extraction exception: errorCode=${errorCode} message=${(e as Error).message}`);
      return { success: false, error: this.getErrorMessage(errorCode, undefined, e as Error), errorCode: errorCode };
    }
  }

  /**
   * 简单的字符串转 Base64 (ArkTS 环境)
   */
  private toBase64(str: string): string {
    const helper = new util.Base64Helper();
    const textEncoder = new util.TextEncoder();
    // 为 UTF-8 编码分配足够的空间（最大 3 字节/字符）
    const buffer = new Uint8Array(str.length * 3);
    const result = textEncoder.encodeInto(str, buffer);
    // 只转换实际写入的部分
    return helper.encodeToStringSync(buffer.subarray(0, result.written));
  }

  private determineNoStreamsErrorCode(videoInfo: VideoInfo): YouTubeErrorCode {
    if (videoInfo.isAgeRestricted) return YouTubeErrorCode.AGE_RESTRICTED;
    if (videoInfo.requiresLogin) return YouTubeErrorCode.LOGIN_REQUIRED;
    return YouTubeErrorCode.NO_STREAMS;
  }

  private analyzeErrorCode(error: Error): YouTubeErrorCode {
    return YouTubeErrorCode.UNKNOWN_ERROR;
  }

  private getErrorMessage(errorCode: YouTubeErrorCode, videoInfo?: VideoInfo, error?: Error): string | Resource {
    return error?.message || $r('app.string.yt_error_playback_failed');
  }

  private extractVideoId(input: string): string | undefined {
    if (!input) return undefined;
    const trimmed = input.trim();
    if (trimmed.length === 11) return trimmed;
    const match = trimmed.match(/(?:v=|\/)([a-zA-Z0-9_-]{11})(?:&|\?|$)/);
    return match ? match[1] : undefined;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  clearCache(): void {
    if (this.extractor) this.extractor.clearCache();
  }
}
