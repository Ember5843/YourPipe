import { StreamInfo } from '../model/VideoData';
import Logger from '../utils/Logger';
import { localProxyServer } from '../proxy/LocalProxyServer';
import { makeEmptySession, StreamResource } from '../proxy/SessionStore';
import { sabrSessionStore } from '../sabr/SabrSessionStore';
import { SabrTrackBuffer } from '../sabr/SabrTrackBuffer';
import { YoutubeSabrFormatMeta, YoutubeSabrInfo } from 'youtube_core';

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

  /**
   * SABR dual session: attach UMP session buffers to local proxy paths
   * /session/{id}/video/0 and /audio/0 for EDL playback.
   */
  static async createSabrDualSession(
    video: StreamInfo,
    audio: StreamInfo,
    durationMs?: number,
    useAuth: boolean = false
  ): Promise<string> {
    if (!await LocalMediaProxy.ensureServer()) return '';
    const info: YoutubeSabrInfo | undefined = video.sabrInfo || audio.sabrInfo;
    if (!info || !info.serverAbrStreamingUrl) {
      Logger.error(TAG, 'createSabrDualSession: missing sabrInfo/serverAbrStreamingUrl');
      return '';
    }
    const videoItag = video.itag;
    const audioItag = audio.itag;
    if (videoItag === undefined || audioItag === undefined) {
      Logger.error(TAG, 'createSabrDualSession: missing itags');
      return '';
    }
    let videoFmt: YoutubeSabrFormatMeta | undefined = info.findFormatByItag(videoItag);
    // Same itag can exist for multiple languages — must match audioTrackId.
    let audioFmt: YoutubeSabrFormatMeta | undefined =
      info.findFormatByItagAndTrack(audioItag, audio.audioTrackId);
    if (!videoFmt) {
      videoFmt = {
        itag: videoItag,
        mimeType: video.mimeType,
        bitrate: video.bitrate,
        width: video.width,
        height: video.height,
        isAudio: false,
        isVideo: true,
        qualityLabel: video.quality,
        codecs: video.codecs,
        approxDurationMs: video.approxDurationMs
      };
    }
    // Always pin selected track identity onto the format meta used for SABR POSTs.
    if (!audioFmt) {
      audioFmt = {
        itag: audioItag,
        mimeType: audio.mimeType,
        bitrate: audio.bitrate,
        isAudio: true,
        isVideo: false,
        codecs: audio.codecs,
        audioTrackId: audio.audioTrackId,
        audioTrackName: audio.audioTrackName,
        isOriginalAudio: (audio.audioTrackType || '').toLowerCase() === 'original',
        approxDurationMs: audio.approxDurationMs
      };
    } else if (audio.audioTrackId && audioFmt.audioTrackId !== audio.audioTrackId) {
      // Defensive: itag-only fallback returned a different language track.
      audioFmt = {
        itag: audioFmt.itag,
        mimeType: audio.mimeType || audioFmt.mimeType,
        bitrate: audio.bitrate ?? audioFmt.bitrate,
        width: audioFmt.width,
        height: audioFmt.height,
        lastModified: audioFmt.lastModified,
        xtags: audioFmt.xtags,
        isAudio: true,
        isVideo: false,
        qualityLabel: audioFmt.qualityLabel,
        codecs: audio.codecs || audioFmt.codecs,
        audioTrackId: audio.audioTrackId,
        audioTrackName: audio.audioTrackName || audioFmt.audioTrackName,
        isOriginalAudio: (audio.audioTrackType || '').toLowerCase() === 'original'
          || audioFmt.isOriginalAudio,
        initializationUrl: audioFmt.initializationUrl,
        initRangeStart: audioFmt.initRangeStart,
        initRangeEnd: audioFmt.initRangeEnd,
        contentLength: audio.contentLength ?? audioFmt.contentLength,
        approxDurationMs: audio.approxDurationMs ?? audioFmt.approxDurationMs,
        drc: audioFmt.drc
      };
    }
    Logger.info(TAG, `createSabrDualSession: video=${videoItag} audio=${audioItag} `
      + `track=${audio.audioTrackId || audioFmt.audioTrackId || '-'} `
      + `name=${audio.audioTrackName || audioFmt.audioTrackName || '-'} durationMs=${durationMs}`);
    try {
      const lease = sabrSessionStore.acquire(info, audioFmt, videoFmt, useAuth);
      const dur = durationMs || video.approxDurationMs || audio.approxDurationMs || 0;
      const videoBuf = new SabrTrackBuffer(lease, false, dur);
      const audioBuf = new SabrTrackBuffer(lease, true, dur);
      // Warm once (serialized pump), then attach buffers — avoid dual parallel rn=1.
      await videoBuf.ensureReady();
      await audioBuf.ensureReady();

      const session = makeEmptySession('');
      session.type = 'sabr-dual';
      session.durationMs = durationMs || video.approxDurationMs || audio.approxDurationMs || 0;
      session.hasAudio = true;
      session.videos = [LocalMediaProxy.toStreamResource(video, false)];
      session.audios = [LocalMediaProxy.toStreamResource(audio, true)];
      session.video = session.videos[0];
      session.audio = session.audios[0];
      session.sabrLeaseKey = lease.key;
      session.sabrVideoBuffer = videoBuf;
      session.sabrAudioBuffer = audioBuf;
      // release is handled in LocalProxyServer.destroySession via sabrLeaseKey
      return localProxyServer.addPreparedSession(session);
    } catch (e) {
      Logger.error(TAG, `createSabrDualSession failed: ${e}`);
      return '';
    }
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

  static getDashManifestUrl(sessionId: string): string {
    return localProxyServer.dashManifestUrl(sessionId);
  }

  static destroySession(sessionId: string): void {
    if (!sessionId) return;
    Logger.debug(TAG, `destroySession: ${sessionId}`);
    localProxyServer.destroySession(sessionId);
  }

  static markSessionStale(sessionId: string): void {
    if (!sessionId) return;
    Logger.debug(TAG, `markSessionStale: ${sessionId}`);
    localProxyServer.markSessionStale(sessionId);
  }

  static stopAll(): void {
    localProxyServer.destroyAll();
  }

  static setSessionRefreshCallback(sessionId: string, callback: () => Promise<boolean>): void {
    localProxyServer.setSessionRefreshCallback(sessionId, callback);
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

  private static toStreamResource(s: StreamInfo, isAudio: boolean): StreamResource {
    const r = LocalMediaProxy.fromStream(s, isAudio);
    return {
      id: r.id || (isAudio ? 'audio' : 'video'),
      url: r.url || '',
      mimeType: r.mimeType || '',
      codecs: r.codecs || '',
      initRangeStart: r.initRangeStart !== undefined ? String(r.initRangeStart) : '',
      initRangeEnd: r.initRangeEnd !== undefined ? String(r.initRangeEnd) : '',
      indexRangeStart: r.indexRangeStart !== undefined ? String(r.indexRangeStart) : '',
      indexRangeEnd: r.indexRangeEnd !== undefined ? String(r.indexRangeEnd) : '',
      userAgent: r.userAgent || DEFAULT_USER_AGENT,
      referer: r.referer || 'https://www.youtube.com',
      contentLength: r.contentLength || 0,
      bitrate: r.bitrate || 0,
      width: r.width || 0,
      height: r.height || 0,
      fps: r.fps || 0,
      approxDurationMs: r.approxDurationMs || 0,
      isAudio: isAudio,
      isYoutubePlayback: true,
      isOtf: !!r.isOtf,
      sourceClient: r.sourceClient || '',
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
