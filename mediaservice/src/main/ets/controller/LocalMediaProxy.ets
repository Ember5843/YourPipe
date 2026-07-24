import { StreamInfo } from '../model/VideoData';
import Logger from '../utils/Logger';
import { localProxyServer } from '../proxy/LocalProxyServer';
import { makeEmptySession, StreamResource } from '../proxy/SessionStore';
import { sabrSessionStore } from '../sabr/SabrSessionStore';
import { SabrTrackBuffer } from '../sabr/SabrTrackBuffer';
import { YoutubeSabrFormatMeta, YoutubeSabrInfo } from 'youtube_core';
import { fetchYoutubeRangeBytes } from '../proxy/RangeProxy';
import { parseYoutubeDashIndex, YoutubeDashSegment } from '../proxy/YoutubeDashIndex';
import { VideoHwCaps } from '../engine/VideoHwCaps';

const TAG: string = '[PlayerLog][LocalMediaProxy]';
// PipePipe-aligned UAs (must match extractor ClientsConstants / YoutubeParsingHelper).
const DEFAULT_USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
  + 'Chrome/134.0.0.0 Safari/537.36,gzip(gfe)';
const ANDROID_USER_AGENT: string = 'com.google.android.youtube/21.03.36 (Linux; U; Android 16; GB) gzip';
const ANDROID_VR_USER_AGENT: string =
  'com.google.android.apps.youtube.vr.oculus/1.65.10 '
  + '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
const IOS_USER_AGENT: string = 'com.google.ios.youtube/20.03.02(iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X; GB)';
const SAFARI_USER_AGENT: string =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) '
  + 'Version/15.5 Safari/605.1.15,gzip(gfe)';
const MWEB_USER_AGENT: string =
  'Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 '
  + '(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)';
const TV_DOWNGRADED_USER_AGENT: string = 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version';
const TV_USER_AGENT: string =
  'Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) '
  + 'Version/15.4 Safari/605.1.15';

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
  private static serverStartPromise: Promise<boolean> | undefined = undefined;
  /**
   * Startup auth gate (P0-2): entry registers a hook that resolves once the
   * pending DASH PoToken injection finished. Demand-side SIDX fetches await it
   * so upstream URLs are never consumed before pot= lands, while playback
   * source submission itself no longer blocks on the WebView mint.
   */
  private static startupUrlGate: (() => Promise<void>) | null = null;
  /** In-memory SIDX prefetch cache (P0-3), keyed by stream URL. Process-local,
   * disposable — nothing persists, so no recovery-action wiring is required. */
  private static sidxPrefetchCache: Map<string, YoutubeDashSegment[]> = new Map();
  private static sidxPrefetchInflight: Map<string, Promise<boolean>> = new Map();
  private static readonly SIDX_PREFETCH_CACHE_CAP: number = 8;

  static setStartupUrlGate(gate: (() => Promise<void>) | null): void {
    LocalMediaProxy.startupUrlGate = gate;
  }

  private static sidxCacheSet(url: string, segments: YoutubeDashSegment[]): void {
    if (LocalMediaProxy.sidxPrefetchCache.size >= LocalMediaProxy.SIDX_PREFETCH_CACHE_CAP) {
      const oldest = LocalMediaProxy.sidxPrefetchCache.keys().next();
      if (!oldest.done) {
        LocalMediaProxy.sidxPrefetchCache.delete(oldest.value);
      }
    }
    LocalMediaProxy.sidxPrefetchCache.set(url, segments);
  }

  /**
   * P0-3: fire-and-forget SIDX prefetch for the most likely initial DASH
   * tracks. Runs ungated (a missing pot only risks a prefetch-side 403, which
   * the demand path simply refetches); overlaps the range RTT with PoToken
   * minting and source bookkeeping.
   */
  static prefetchLikelyDashSidx(streams: StreamInfo[], attemptId: string = ''): void {
    const candidates = streams.filter((s: StreamInfo) => !!s.url
      && s.deliveryMethod !== 'SABR' && s.kind !== 'sabr'
      && s.indexRangeStart !== undefined && s.indexRangeEnd !== undefined);
    if (candidates.length === 0) return;
    const videos = candidates.filter((s: StreamInfo) => s.hasVideo);
    const audios = candidates.filter((s: StreamInfo) => !s.hasVideo && s.hasAudio);
    const hwVideos = videos.filter((s: StreamInfo) => VideoHwCaps.isCodecHardwareFriendly(s.codecs));
    const vpool = (hwVideos.length > 0 ? hwVideos : videos)
      .slice().sort((a: StreamInfo, b: StreamInfo) => (b.height || 0) - (a.height || 0));
    const picked: StreamInfo[] = [];
    const seenHeights = new Set<number>();
    for (const s of vpool) {
      const h = s.height || 0;
      if (h > 1080) continue; // 4K SIDX prefetch is unlikely to match the default pick
      if (seenHeights.has(h)) continue;
      seenHeights.add(h);
      picked.push(s);
      if (picked.length >= 3) break;
    }
    const apool = audios.slice().sort((a: StreamInfo, b: StreamInfo) => (b.bitrate || 0) - (a.bitrate || 0));
    if (apool.length > 0) {
      picked.push(apool[0]);
    }
    Logger.info(TAG, `[STARTUP] attempt=${attemptId || '-'} stage=sidx_prefetch_start count=${picked.length}`);
    for (const s of picked) {
      const key = s.url;
      if (LocalMediaProxy.sidxPrefetchCache.has(key) || LocalMediaProxy.sidxPrefetchInflight.has(key)) {
        continue;
      }
      const resource = LocalMediaProxy.toStreamResource(s, !s.hasVideo);
      const task: Promise<boolean> = LocalMediaProxy.prepareDashSegmentsRequired(resource, true);
      LocalMediaProxy.sidxPrefetchInflight.set(key, task);
      task.then((ok: boolean) => {
        if (ok && resource.dashSegments && resource.dashSegments.length > 0) {
          LocalMediaProxy.sidxCacheSet(key, resource.dashSegments);
          Logger.info(TAG, `[STARTUP] attempt=${attemptId || '-'} stage=sidx_prefetch_done itag=${s.itag}`);
        }
      }).catch((e: Error) => {
        Logger.warn(TAG, `sidx prefetch failed itag=${s.itag}: ${e.message || e}`);
      }).finally(() => {
        LocalMediaProxy.sidxPrefetchInflight.delete(key);
      });
    }
  }

  static async warmup(): Promise<boolean> {
    if (LocalMediaProxy.serverReady || localProxyServer.isRunning()) {
      LocalMediaProxy.serverReady = true;
      return true;
    }
    if (LocalMediaProxy.serverStartPromise) {
      return LocalMediaProxy.serverStartPromise;
    }
    const startedAt = Date.now();
    LocalMediaProxy.serverStartPromise = localProxyServer.start().then((ok: boolean) => {
      LocalMediaProxy.serverReady = ok;
      Logger.info(TAG, `proxy warmup elapsed=${Date.now() - startedAt}ms ok=${ok}`);
      return ok;
    }).catch((e: Error) => {
      LocalMediaProxy.serverReady = false;
      Logger.warn(TAG, `proxy warmup failed elapsed=${Date.now() - startedAt}ms: ${e.message || e}`);
      return false;
    }).finally(() => {
      LocalMediaProxy.serverStartPromise = undefined;
    });
    return LocalMediaProxy.serverStartPromise;
  }

  private static async ensureServer(): Promise<boolean> {
    const first = await LocalMediaProxy.warmup();
    if (first) return true;
    Logger.warn(TAG, 'proxy startup retry after warmup failure');
    return LocalMediaProxy.warmup();
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

  static async createYoutubeDualUrlSession(
    video: StreamInfo,
    audio: StreamInfo,
    durationMs?: number,
    attemptId: string = ''
  ): Promise<string> {
    if (!await LocalMediaProxy.ensureServer()) return '';
    const sidxStartedAt = Date.now();
    Logger.info(TAG, `createYoutubeDualUrlSession: video=[itag=${video.itag} ${video.quality} ${video.codecs}] audio=[itag=${audio.itag} ${audio.codecs}] durationMs=${durationMs}`);
    const session = makeEmptySession('');
    session.type = 'youtube-dual';
    session.durationMs = durationMs || video.approxDurationMs || audio.approxDurationMs || 0;
    session.hasAudio = true;
    session.videos = [LocalMediaProxy.toStreamResource(video, false)];
    session.audios = [LocalMediaProxy.toStreamResource(audio, true)];
    session.video = session.videos[0];
    session.audio = session.audios[0];
    // MPV/FFmpeg seek needs SegmentTemplate timeline from SIDX. SegmentBase is rejected
    // (whole-file range → 403). Retry SIDX briefly — first probe often 403 then succeeds.
    const prepared = await Promise.all([
      LocalMediaProxy.prepareDashSegmentsRequired(session.video),
      LocalMediaProxy.prepareDashSegmentsRequired(session.audio),
    ]);
    if (!prepared[0] || !prepared[1]) {
      Logger.error(TAG, `createYoutubeDualUrlSession: SIDX required for both tracks, abort`);
      return '';
    }
    Logger.info(TAG, `SIDX prepared elapsed=${Date.now() - sidxStartedAt}ms video=${video.itag} audio=${audio.itag}`);
    Logger.info(TAG, `[STARTUP] attempt=${attemptId || '-'} stage=sidx_init `
      + `elapsed=${Date.now() - sidxStartedAt}ms video=${video.itag} audio=${audio.itag}`);
    return localProxyServer.addPreparedSession(session);
  }

  /** Required SIDX → SegmentTemplate timeline. Retries transient 403.
   * skipGate: prefetch path only — demand fetches must pass the pot gate. */
  private static async prepareDashSegmentsRequired(resource: StreamResource, skipGate: boolean = false): Promise<boolean> {
    const start = Number(resource.indexRangeStart);
    const end = Number(resource.indexRangeEnd);
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < start) {
      Logger.error(TAG, `prepareDashSegments: missing indexRange itag=${resource.id}`);
      return false;
    }
    // P0-3: warm prefetch cache hit — no network on the demand path.
    const cached = LocalMediaProxy.sidxPrefetchCache.get(resource.url);
    if (cached && cached.length > 0) {
      resource.dashSegments = cached;
      Logger.info(TAG, `SIDX prefetch hit itag=${resource.id} segments=${cached.length}`);
      return true;
    }
    // A prefetch for the same URL may still be in flight — join it instead of
    // issuing a duplicate range request.
    const inflight = LocalMediaProxy.sidxPrefetchInflight.get(resource.url);
    if (inflight) {
      await inflight.catch(() => false);
      const joined = LocalMediaProxy.sidxPrefetchCache.get(resource.url);
      if (joined && joined.length > 0) {
        resource.dashSegments = joined;
        Logger.info(TAG, `SIDX prefetch joined itag=${resource.id} segments=${joined.length}`);
        return true;
      }
    }
    // P0-2: demand-side barrier — wait for the pending pot injection so the
    // first upstream fetch consumes URLs that already carry pot=.
    if (!skipGate && LocalMediaProxy.startupUrlGate) {
      const gateStartedAt = Date.now();
      try {
        await LocalMediaProxy.startupUrlGate();
        Logger.info(TAG, `[STARTUP] stage=pot_gate_ready itag=${resource.id} elapsed=${Date.now() - gateStartedAt}ms`);
      } catch (e) {
        Logger.warn(TAG, `startup url gate failed itag=${resource.id}: ${e}`);
      }
    }
    // Fresh authenticated TVHTML5 URLs can return 403 while the googlevideo
    // edge authorization propagates. Keep increasing rn until the URL becomes
    // readable, bounded by elapsed time so a genuinely invalid URL cannot hang.
    // Every other client retains the existing four-attempt policy.
    // With pot= now injected by YouTubePlayService, 403s are rare; keep a short
    // budget so genuinely invalid URLs fail fast instead of hanging 10s.
    const isTvDowngraded = resource.sourceClient === 'tv_downgraded';
    const retryStartedAt = Date.now();
    const tvRetryBudgetMs = 4000;
    let attempt = 0;
    while (isTvDowngraded ? Date.now() - retryStartedAt < tvRetryBudgetMs : attempt < 4) {
      try {
        if (attempt > 0) {
          const retryDelayMs = isTvDowngraded ? 250 : 250 * attempt;
          await new Promise<void>((resolve) => setTimeout(resolve, retryDelayMs));
        }
        const bytes = await fetchYoutubeRangeBytes(resource, start, end);
        resource.dashSegments = parseYoutubeDashIndex(bytes, start);
        if (resource.dashSegments.length > 0) {
          // Reuse for a later quality switch onto the same URL.
          LocalMediaProxy.sidxCacheSet(resource.url, resource.dashSegments);
        }
        Logger.info(TAG, `prepared DASH SIDX itag=${resource.id} segments=${resource.dashSegments.length} `
          + `range=${start}-${end} attempt=${attempt + 1}`);
        return true;
      } catch (e) {
        resource.dashSegments = undefined;
        Logger.warn(TAG, `DASH SIDX attempt=${attempt + 1} elapsed=${Date.now() - retryStartedAt}ms `
          + `itag=${resource.id}: ${e}`);
        attempt++;
      }
    }
    return false;
  }

  /**
   * SABR dual session: attach UMP session buffers to local proxy paths
   * /session/{id}/sabr/{video|audio}/… for static DASH segment playback.
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

  static updatePlaybackPosition(sessionId: string, positionMs: number): void {
    localProxyServer.updateSabrPlayHead(sessionId, positionMs);
  }

  static markSessionStale(sessionId: string): void {
    if (!sessionId) return;
    Logger.debug(TAG, `markSessionStale: ${sessionId}`);
    localProxyServer.markSessionStale(sessionId);
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
    // Keys match youtube_core YoutubePlayerClientKey / StreamInfo.sourceClient.
    switch (sourceClient) {
      case 'android':
      case 'ANDROID':
        return ANDROID_USER_AGENT;
      case 'android_vr':
      case 'ANDROID_VR':
        // RangeProxy overrides ANDROID_VR to getAndroidUserAgent for videoplayback;
        // keep extraction UA for non-range uses / logging.
        return ANDROID_VR_USER_AGENT;
      case 'ios':
      case 'IOS':
        return IOS_USER_AGENT;
      case 'web_safari':
      case 'safari':
        return SAFARI_USER_AGENT;
      case 'mweb':
      case 'MWEB':
        return MWEB_USER_AGENT;
      case 'tv_downgraded':
      case 'TVHTML5':
        return TV_DOWNGRADED_USER_AGENT;
      case 'tv':
      case 'TVHTML5_SIMPLY_EMBEDDED_PLAYER':
        return TV_USER_AGENT;
      default:
        return DEFAULT_USER_AGENT;
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
