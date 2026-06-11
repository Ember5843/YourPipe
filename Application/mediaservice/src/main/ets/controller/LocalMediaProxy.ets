import { StreamInfo } from '../model/VideoData';
import Logger from '../utils/Logger';
import { localProxyServer } from '../proxy/LocalProxyServer';

const TAG: string = '[PlayerLog][LocalMediaProxy]';
const DEFAULT_USER_AGENT: string = 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36';
const ANDROID_USER_AGENT: string = 'com.google.android.youtube/21.03.36 (Linux; U; Android 16; GB) gzip';
const IOS_USER_AGENT: string = 'com.google.ios.youtube/21.03.2(iPhone16,2; U; CPU iOS 18_7_2 like Mac OS X; GB)';
const SAFARI_USER_AGENT: string = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)';
const TV_USER_AGENT: string = 'Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Safari/605.1.15';

interface LocalMediaResource {
  id?: string;
  url: string;
  mimeType?: string;
  codecs?: string;
  initRangeStart?: number;
  initRangeEnd?: number;
  indexRangeStart?: number;
  indexRangeEnd?: number;
  contentLength?: number;
  bitrate?: number;
  width?: number;
  height?: number;
  fps?: number;
  approxDurationMs?: number;
  itag?: number;
  deliveryMethod?: string;
  isOtf?: boolean;
  userAgent?: string;
  referer?: string;
  sourceClient?: string;
}

interface LocalMediaSessionInput {
  type: string;
  durationMs?: number;
  userAgent?: string;
  resource?: LocalMediaResource;
  videos?: LocalMediaResource[];
  audios?: LocalMediaResource[];
}

export class LocalMediaProxy {
  private static serverReady: boolean = false;

  private static async ensureServer(): Promise<boolean> {
    if (LocalMediaProxy.serverReady) return true;
    const ok = await localProxyServer.start();
    LocalMediaProxy.serverReady = ok;
    return ok;
  }

  static async createSingleUrlSession(url: string, metadata?: StreamInfo): Promise<string> {
    if (!await LocalMediaProxy.ensureServer()) return '';
    const ua = LocalMediaProxy.userAgentForClient(metadata?.sourceClient);
    Logger.info(TAG, `createSingleUrlSession: itag=${metadata?.itag} mimeType=${metadata?.mimeType} contentLength=${metadata?.contentLength} client=${metadata?.sourceClient}`);
    const input: LocalMediaSessionInput = {
      type: 'single',
      userAgent: ua,
      resource: {
        id: 'main',
        url,
        mimeType: metadata?.mimeType || LocalMediaProxy.guessMimeType(url),
        codecs: metadata?.codecs,
        contentLength: metadata?.contentLength,
        bitrate: metadata?.bitrate,
        width: metadata?.width,
        height: metadata?.height,
        fps: metadata?.fps,
        approxDurationMs: metadata?.approxDurationMs,
        itag: metadata?.itag,
        userAgent: ua,
        referer: LocalMediaProxy.guessReferer(url),
        sourceClient: metadata?.sourceClient,
      },
    };
    return LocalMediaProxy.createSession(JSON.stringify(input));
  }

  static async createYoutubeDualUrlSession(video: StreamInfo, audio: StreamInfo, durationMs?: number): Promise<string> {
    if (!await LocalMediaProxy.ensureServer()) return '';
    Logger.info(TAG, `createYoutubeDualUrlSession: video=[itag=${video.itag} ${video.quality} ${video.codecs}] audio=[itag=${audio.itag} ${audio.codecs}] durationMs=${durationMs}`);
    const input: LocalMediaSessionInput = {
      type: 'youtube-dual',
      userAgent: DEFAULT_USER_AGENT,
      durationMs: durationMs || video.approxDurationMs || audio.approxDurationMs || 0,
      videos: [LocalMediaProxy.fromStream(video, false)],
      audios: [LocalMediaProxy.fromStream(audio, true)],
    };
    return LocalMediaProxy.createSession(JSON.stringify(input));
  }

  static async refreshYoutubeDualUrlSession(sessionId: string, video: StreamInfo, audio: StreamInfo, durationMs?: number): Promise<string> {
    if (!await LocalMediaProxy.ensureServer()) return '';
    const input: LocalMediaSessionInput = {
      type: 'youtube-dual',
      userAgent: DEFAULT_USER_AGENT,
      durationMs: durationMs || video.approxDurationMs || audio.approxDurationMs || 0,
      videos: [LocalMediaProxy.fromStream(video, false)],
      audios: [LocalMediaProxy.fromStream(audio, true)],
    };
    const ok = localProxyServer.refreshSession(sessionId, JSON.stringify(input));
    if (!ok) return '';
    return localProxyServer.playbackUrl(sessionId);
  }

  static getPlaybackUrl(sessionId: string): string {
    return localProxyServer.playbackUrl(sessionId);
  }

  static destroySession(sessionId: string): void {
    if (!sessionId) return;
    Logger.debug(TAG, `destroySession: ${sessionId}`);
    localProxyServer.destroySession(sessionId);
  }

  static stopAll(): void {
    localProxyServer.destroyAll();
  }

  private static async createSession(inputJson: string): Promise<string> {
    try {
      return localProxyServer.createSession(inputJson);
    } catch (e) {
      Logger.error(TAG, `createSession failed: ${e}`);
      return '';
    }
  }

  private static fromStream(s: StreamInfo, isAudio: boolean): LocalMediaResource {
    const ua = LocalMediaProxy.userAgentForClient(s.sourceClient);
    return {
      id: s.itag !== undefined ? String(s.itag) : (isAudio ? 'audio' : 'video'),
      itag: s.itag,
      url: s.url,
      mimeType: s.mimeType,
      codecs: s.codecs,
      initRangeStart: s.initRangeStart,
      initRangeEnd: s.initRangeEnd,
      indexRangeStart: s.indexRangeStart,
      indexRangeEnd: s.indexRangeEnd,
      contentLength: s.contentLength,
      bitrate: s.bitrate,
      width: s.width,
      height: s.height,
      fps: s.fps,
      approxDurationMs: s.approxDurationMs,
      deliveryMethod: s.deliveryMethod,
      isOtf: s.isOtf,
      userAgent: ua,
      referer: 'https://www.youtube.com',
      sourceClient: s.sourceClient,
    };
  }

  private static userAgentForClient(sourceClient?: string): string {
    switch (sourceClient) {
      case 'android': return ANDROID_USER_AGENT;
      case 'ios': return IOS_USER_AGENT;
      case 'safari': return SAFARI_USER_AGENT;
      case 'tv': return TV_USER_AGENT;
      default: return DEFAULT_USER_AGENT;
    }
  }

  private static guessMimeType(url: string): string {
    const lower = url.toLowerCase();
    if (lower.includes('.mpd')) return 'application/dash+xml';
    if (lower.includes('.m3u8')) return 'application/vnd.apple.mpegurl';
    if (lower.includes('.webm')) return 'video/webm';
    if (lower.includes('.mp4') || lower.includes('videoplayback')) return 'video/mp4';
    return 'application/octet-stream';
  }

  private static guessReferer(url: string): string {
    if (url.includes('googlevideo.com') || url.includes('youtube.com')) {
      return 'https://www.youtube.com/';
    }
    return '';
  }
}
