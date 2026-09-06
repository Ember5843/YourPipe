import { MpvPlayerController, MediaStatus, PlaybackState as NativePlaybackState,
  setHttpProxyEnv } from '@yourpipe/libmpv-napi';
import type { MediaInfo } from '@yourpipe/libmpv-napi';
import { PlaybackEngine, PlaybackEngineState, PlaybackState, PlaybackErrorCategory, PlaybackStats,
  EngineConfig } from './PlaybackEngine';
import Logger from '../utils/Logger';
import { VideoHwCaps } from './VideoHwCaps';
import { HttpProxyOptions } from 'youtube_core';

const TAG: string = '[PlayerLog][MpvPlaybackEngine]';

/** buildState 的 MediaInfo 派生字段缓存快照（ArkTS 要求显式声明类型）。 */
interface MediaInfoSnapshot {
  mediaTitle: string;
  containerFormat: string;
  videoWidth: number;
  videoHeight: number;
  videoStreamCount: number;
  audioStreamCount: number;
  subtitleStreamCount: number;
  videoCodec: string;
  videoBitRate: number;
  frameRate: number;
  audioCodec: string;
  audioBitRate: number;
  audioChannels: number;
  audioSampleRate: number;
  fileSize: number;
}

export class MpvPlaybackEngine implements PlaybackEngine {
  private initialized: boolean = false;
  private controller: MpvPlayerController | null = null;
  private stateCallback: ((state: PlaybackState) => void) | null = null;
  private subtitleCallback: ((text: string, startTime: number, duration: number) => void) | null = null;

  private surfaceId: string = '';
  /** 最近一次已知的 surface 像素尺寸；bindSurface 后据此立即设置几何，避免 mpv video chain 拿不到宽高 */
  private surfaceWidthPx: number = 0;
  private surfaceHeightPx: number = 0;
  private sourceUrl: string = '';
  private playbackSpeed: number = 1.0;

  private lastPositionMs: number = 0;
  private lastDurationMs: number = 0;
  private seekableRanges: number[][] = [];
  private isBuffering: boolean = false;
  private isSeeking: boolean = false;
  private isEnded: boolean = false;
  private isReady: boolean = false;
  private isBuffered: boolean = false;
  private hasError: boolean = false;
  private errorMsg: string = '';
  private lastErrorCategory: PlaybackErrorCategory = 'unknown';
  private isLive: boolean = false;
  private playWhenReady: boolean = false;
  private loaded: boolean = false;
  private preparing: boolean = false;
  private destroyed: boolean = false;
  private loadGeneration: number = 0;
  private pendingStartMs: number = -1;
  private pendingSeekMs: number = -1;
  private pendingSubtitleUrl: string = '';
  private currentSubtitleUrl: string = '';
  private lastKnownPositionMs: number = 0;
  private lastTimeEmitMs: number = 0;
  /**
   * Native getPosition()/getDuration() keep reporting the outgoing file for a short window after
   * setMedia(). Do not expose that timeline as the newly loaded source until MPV reports Prepared.
   */
  private acceptsNativeTimeline: boolean = false;

  // 保存配置供 load() 方法使用
  private engineConfig: EngineConfig = {};
  /** 上次日志里的 hwdec-current，避免状态轮询刷屏 */
  private lastLoggedHwdec: string = '';
  /** Mirror of vid on/off for background audio-only only (never used on load/seek). */
  private videoOutputOn: boolean = true;
  /** MediaInfo 快照的节流刷新时间戳（0 = 立即刷新） */
  private lastMediaInfoAtMs: number = 0;
  /** getMediaInfo 派生字段的缓存快照；见 buildState 的 2s 节流 */
  private mediaSnapshot: MediaInfoSnapshot = {
    mediaTitle: '',
    containerFormat: '',
    videoWidth: 0,
    videoHeight: 0,
    videoStreamCount: 0,
    audioStreamCount: 0,
    subtitleStreamCount: 0,
    videoCodec: '',
    videoBitRate: 0,
    frameRate: 0,
    audioCodec: '',
    audioBitRate: 0,
    audioChannels: 0,
    audioSampleRate: 0,
    fileSize: 0
  };

  async initialize(_config: EngineConfig): Promise<boolean> {
    if (this.initialized && this.controller !== null) {
      return true;
    }

    try {
      this.destroyed = false;
      // 保存配置供后续使用
      this.engineConfig = _config;

      const ctrl: MpvPlayerController = new MpvPlayerController();
      ctrl.setEventCallback((type: number, value: number) => {
        this.onMpvEvent(ctrl, type, value);
      });

      // 从 EngineConfig 读取用户配置（如果有），否则使用默认值
      const hwdecEnabled = _config.mpvHwdecEnabled ?? true;
      const cacheSecs = _config.mpvCacheSecs ?? 10;
      const demuxerReadaheadSecs = _config.mpvDemuxerReadaheadSecs ?? 8;
      // Injected in MB by entry (PlaybackConfig.demuxerMaxBytes labels).
      const demuxerMaxBytesMb = _config.mpvDemuxerMaxBytes ?? 20;
      const gpuApi = _config.mpvGpuApi ?? 'auto';

      // Product path: ohcodec-copy + gpu-next (native EnsureMpv also sets these).
      if (hwdecEnabled) {
        ctrl.setProperty('hwdec', 'ohcodec-copy');
        // Whitelist comes from the native probe (single source of truth; native
        // EnsureMpv applies the same string at mpv_create).
        const whitelist = VideoHwCaps.hwdecCodecsWhitelist();
        ctrl.setProperty('hwdec-codecs', whitelist);
        Logger.info(TAG, `Hardware decoding enabled: ohcodec-copy hwdec-codecs=${whitelist}`);
      } else {
        ctrl.setProperty('hwdec', 'no');
        Logger.info(TAG, 'Hardware decoding disabled');
      }

      if (gpuApi !== 'auto') {
        ctrl.setProperty('gpu-api', gpuApi);
        Logger.info(TAG, `GPU API set to: ${gpuApi}`);
      }

      ctrl.setProperty('cache', 'yes');
      ctrl.setProperty('cache-secs', `${cacheSecs}`);
      ctrl.setProperty('cache-on-disk', 'no');
      Logger.info(TAG, `Memory cache configured: ${cacheSecs}s`);

      ctrl.setProperty('demuxer-readahead-secs', `${demuxerReadaheadSecs}`);
      ctrl.setProperty('demuxer-max-bytes', `${demuxerMaxBytesMb * 1024 * 1024}`);
      Logger.info(TAG, `Demuxer readahead=${demuxerReadaheadSecs}s max-bytes=${demuxerMaxBytesMb}MiB`);

      ctrl.setProperty('hr-seek', 'yes');
      ctrl.setProperty('hr-seek-framedrop', 'yes');

      // Cheap GPU path (bilinear scales, no dither/deband/hdr-compute-peak,
      // video-sync=audio, framedrop=vo, vd-lavc-skiploopfilter=nonkey) is owned
      // by native EnsureMpv — engine setProperty runs after mpv_create, so it
      // would only ever rewrite the same values. Do not duplicate it here.

      ctrl.setProperty('demuxer-lavf-o', 'reconnect_at_eof=1,reconnect_streamed=1,reconnect_delay_max=5');
      this.controller = ctrl;
      this.initialized = true;
      if (this.surfaceId.length > 0) {
        this.bindSurface(ctrl, this.surfaceId);
      }
      Logger.info(TAG, `initialize: playerId=${ctrl.playerId}`);
      this.emitCurrentState();
      return true;
    } catch (err) {
      Logger.error(TAG, `initialize failed: ${this.describeError(err)}`);
      return false;
    }
  }

  destroy(): void {
    this.destroyed = true;
    this.initialized = false;
    this.acceptsNativeTimeline = false;
    this.loadGeneration++;
    const ctrl: MpvPlayerController | null = this.controller;
    this.controller = null;
    if (ctrl !== null) {
      try {
        ctrl.dispose();
        Logger.info(TAG, `destroy: playerId=${ctrl.playerId}`);
      } catch (err) {
        Logger.warn(TAG, `dispose failed: ${this.describeError(err)}`);
      }
    }
    this.resetLocalState(true);
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  attachSurface(surfaceId: string): void {
    this.surfaceId = surfaceId;
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    Logger.info(TAG, `attachSurface: surfaceId=${surfaceId.substring(0, 24)}`);
    this.bindSurface(ctrl, surfaceId);
  }

  detachSurface(): void {
    // The native wrapper has no detach API. Stop the media first, then forget the
    // old XComponent so a later page cannot accidentally bind a destroyed surface.
    this.surfaceId = '';
    this.surfaceWidthPx = 0;
    this.surfaceHeightPx = 0;
  }

  resizeSurface(widthPx: number, heightPx: number): void {
    if (widthPx <= 0 || heightPx <= 0) return;
    // 先缓存：即使引擎尚未 active（surface 比 controller 早就绪），下次 bindSurface 也能立即套用几何
    this.surfaceWidthPx = widthPx;
    this.surfaceHeightPx = heightPx;
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    ctrl.setVideoSurfaceSize(widthPx, heightPx);
    Logger.debug(TAG, `resizeSurface: ${widthPx}x${heightPx}px`);
  }

  /**
   * Apply the app proxy to MPV-direct network fetches (HLS master/segment
   * playlists, sub-add subtitle downloads). There is no libmpv `network-proxy`
   * property; the vendored FFmpeg http protocol honors the process-level
   * http_proxy env, so this installs it natively via setHttpProxyEnv. http kind
   * talks to the upstream proxy directly (URL may carry user:pass auth); socks5
   * routes through the loopback HTTP CONNECT bridge (127.0.0.1) which owns the
   * native SOCKS5 tunnel. Loopback / exclusion targets stay direct (empty
   * proxy URL); the native side also pins 127.0.0.1,localhost into no_proxy so
   * the LocalProxyServer path is never affected.
   */
  private applyNetworkProxy(url: string): void {
    try {
      const snap = HttpProxyOptions.getSnapshot();
      let proxyUrl = '';
      if (HttpProxyOptions.isActive(snap) && !HttpProxyOptions.shouldBypass(url, snap)) {
        if (snap.kind === 'http') {
          const auth = snap.username
            ? `${encodeURIComponent(snap.username)}:${encodeURIComponent(snap.password || '')}@`
            : '';
          proxyUrl = `http://${auth}${snap.host.trim()}:${snap.port}`;
        } else if (snap.kind === 'socks5') {
          const localPort = snap.socks5LocalPort;
          if (localPort && localPort > 0) {
            proxyUrl = `http://127.0.0.1:${localPort}`;
          }
        }
      }
      setHttpProxyEnv(proxyUrl);
      if (proxyUrl.length > 0) {
        Logger.info(TAG, `http_proxy env on kind=${snap.kind} url=${proxyUrl.length > 8 ? proxyUrl.substring(0, 8) + '***' : proxyUrl}`);
      }
    } catch (e) {
      Logger.warn(TAG, `applyNetworkProxy failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /**
   * Re-apply the app proxy env for the currently loaded source. The socks5
   * bridge re-listens on a NEW ephemeral port after a self-heal, while the
   * process env installed at load() still points at the dead port; entry pings
   * this from the bridge port-change hook so in-flight live HLS fetches move
   * to the new port. No-op when nothing is loaded.
   * （网络功能，非播放行为 — 回退 0.5.9 播放器时保留）
   */
  refreshNetworkProxy(): void {
    if (this.destroyed || this.sourceUrl.length === 0) {
      return;
    }
    this.applyNetworkProxy(this.sourceUrl);
  }

  load(source: string, startPos: number, audioUrl: string = ''): boolean {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return false;

    const generation = ++this.loadGeneration;
    this.sourceUrl = this.normalizeSourceUrl(source);
    this.isLive = this.looksLive(this.sourceUrl);
    this.playWhenReady = false;
    this.loaded = false;
    this.preparing = false;
    this.isReady = false;
    this.isEnded = false;
    this.hasError = false;
    this.errorMsg = '';
    this.lastErrorCategory = 'unknown';
    this.isBuffering = true;
    this.isSeeking = false;
    this.pendingStartMs = !this.isLive ? Math.max(0, Math.round(startPos * 1000)) : 0;
    this.pendingSeekMs = -1;
    this.lastPositionMs = 0;
    this.lastDurationMs = 0;
    this.seekableRanges = [];
    this.lastKnownPositionMs = 0;
    this.acceptsNativeTimeline = false;
    // 新源：作废 MediaInfo 快照，下一次 buildState 立即刷新
    this.lastMediaInfoAtMs = 0;
    this.mediaSnapshot.videoWidth = 0;
    this.mediaSnapshot.videoHeight = 0;
    this.mediaSnapshot.videoCodec = '';
    this.mediaSnapshot.audioCodec = '';
    this.emitCurrentState();

    Logger.info(TAG, `load: startPos=${startPos.toFixed(2)}s isLive=${this.isLive} url=${this.sourceUrl.substring(0, 120)}`);

    // HLS (live or DVR replay): reconnect_at_eof 会让 FFmpeg 在每个 segment EOF 时死循环重连
    // 同一 URL，而非让 HLS demuxer 正常切换到下一个 segment。HLS 流必须禁用。
    const isHls = this.looksHls(this.sourceUrl);
    const isLocalDash = this.sourceUrl.startsWith('http://127.0.0.1:')
      && this.sourceUrl.indexOf('/manifest.mpd') >= 0;
    if (isLocalDash) {
      // A static MPD and each DASH fragment are finite resources. Their EOF is the normal
      // resource boundary; reconnect_at_eof loops on the MPD forever before opening init/media.
      ctrl.setProperty('demuxer-lavf-o',
        'reconnect_at_eof=0,reconnect_streamed=0,reconnect_delay_max=3');
      ctrl.setProperty('demuxer-readahead-secs', `${this.engineConfig.mpvDemuxerReadaheadSecs ?? 8}`);
      ctrl.setProperty('cache-secs', `${this.engineConfig.mpvCacheSecs ?? 10}`);
      Logger.info(TAG, 'Local DASH: EOF reconnect disabled');
    } else if (isHls) {
      ctrl.setProperty('demuxer-lavf-o', 'reconnect_delay_max=3');
      // HLS 需要更大的缓冲，使用用户配置的 2-3 倍
      const hlsReadaheadMultiplier = 3;
      const hlsCacheMultiplier = 2;
      const baseReadahead = this.engineConfig.mpvDemuxerReadaheadSecs ?? 8;
      const baseCache = this.engineConfig.mpvCacheSecs ?? 10;
      ctrl.setProperty('demuxer-readahead-secs', `${baseReadahead * hlsReadaheadMultiplier}`);
      ctrl.setProperty('cache-secs', `${baseCache * hlsCacheMultiplier}`);
    } else {
      ctrl.setProperty('demuxer-lavf-o', 'reconnect_at_eof=1,reconnect_streamed=1,reconnect_delay_max=5');
      ctrl.setProperty('demuxer-readahead-secs', `${this.engineConfig.mpvDemuxerReadaheadSecs ?? 8}`);
      ctrl.setProperty('cache-secs', `${this.engineConfig.mpvCacheSecs ?? 10}`);
    }

    // HLS / any direct MPV network fetch must honor the app proxy. Local loopback
    // (edl / local DASH sessions) is bypassed by shouldBypass and by the native
    // no_proxy pin, so this never affects the LocalProxyServer path. Called
    // before setMedia so every direct open (incl. later sub-add fetches, which
    // share the process env) sees the proxy.
    this.applyNetworkProxy(this.sourceUrl);

    // External audio track for split HLS (live/post-live): the audio rendition
    // playlist rides mpv audio-files, which mpv opens as part of the load, so
    // audio is ready together with the first frame instead of joining seconds
    // later (yt-dlp+mpv pattern). Use change-list: 'append' takes one raw item
    // with NO separator parsing — plain set shreds these URLs on their literal
    // ',' and ':' — and 'clr' drops leftovers from a previous live source.
    ctrl.command(['change-list', 'audio-files', 'clr', '']);
    if (audioUrl.length > 0) {
      ctrl.command(['change-list', 'audio-files', 'append', audioUrl]);
      Logger.info(TAG, `load: external audio=${audioUrl.substring(0, 60)}`);
    }

    try {
      const isEdl = this.sourceUrl.startsWith('edl://');
      const directStartMs = isEdl ? 0 : this.pendingStartMs;
      ctrl.setMedia(this.sourceUrl, directStartMs);
      if (!isEdl) {
        // mpv's per-file start option performs the initial demuxer seek before the first frame.
        // Keep pendingStartMs only for legacy EDL sources whose lazy child demuxer needs a
        // post-Prepared seek.
        this.pendingStartMs = -1;
      }
      if (this.surfaceId.length > 0) {
        this.bindSurface(ctrl, this.surfaceId);
        Logger.info(TAG, `load: surface bound id=${this.surfaceId.substring(0, 24)}`);
      } else {
        Logger.warn(TAG, `load: surfaceId is empty, video may not render`);
      }
      this.preparing = true;
      // The actual source is already loading with a per-file start option. prepare(0) is retained
      // only as a compatibility signal for the legacy controller wrapper; it does not seek to 0.
      ctrl.prepare(0);
      if (generation !== this.loadGeneration || this.destroyed) {
        return false;
      }
      return true;
    } catch (err) {
      if (generation !== this.loadGeneration || this.destroyed) {
        return false;
      }
      this.preparing = false;
      this.isBuffering = false;
      this.hasError = true;
      this.lastErrorCategory = 'source';
      this.errorMsg = `[mpv] load failed: ${this.describeError(err)}`;
      Logger.error(TAG, this.errorMsg);
      this.emitCurrentState();
      return false;
    }
  }

  play(): void {
    this.playWhenReady = true;
    if (!this.isReady) {
      this.emitCurrentState();
      return;
    }
    this.playInternal();
  }

  pause(): void {
    this.playWhenReady = false;
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    ctrl.pause();
    this.emitCurrentState();
  }

  stop(): void {
    this.playWhenReady = false;
    this.pendingStartMs = -1;
    this.pendingSeekMs = -1;
    this.acceptsNativeTimeline = false;
    this.seekableRanges = [];
    this.loadGeneration++;
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl !== null && !this.destroyed) {
      try {
        ctrl.stop();
      } catch (err) {
        Logger.warn(TAG, `stop failed: ${this.describeError(err)}`);
      }
    }
    // Keep the native controller initialized, but expose an empty media session
    // to the controller/UI. This is intentionally different from destroy().
    this.resetLocalState(false);
    this.emitCurrentState();
  }

  seek(positionSec: number, keyframe: boolean): void {
    if (this.isLive || this.destroyed) return;

    const targetMs: number = Math.max(0, Math.round(positionSec * 1000));
    this.pendingSeekMs = targetMs;
    this.isSeeking = true;

    if (!this.isReady) {
      Logger.debug(TAG, `seek deferred: target=${positionSec.toFixed(2)}s keyframe=${keyframe}`);
      this.emitCurrentState();
      return;
    }

    this.seekInternal(targetMs, keyframe);
  }

  setPlaybackSpeed(speed: number): void {
    if (speed <= 0) return;
    this.playbackSpeed = speed;
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl !== null && !this.destroyed) ctrl.setPlaybackRate(speed);
    this.emitCurrentState();
  }

  setVolume(volume: number): void {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl !== null && !this.destroyed) ctrl.setVolume(volume);
  }

  getVolume(): number {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return 100;
    const raw: string = ctrl.getProperty('volume');
    const vol: number = parseFloat(raw);
    return isNaN(vol) ? 100 : vol;
  }

  setSubtitle(url: string): void {
    this.pendingSubtitleUrl = url;
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    if (!this.isReady) {
      Logger.debug(TAG, `setSubtitle: deferred url=${url.length > 0 ? url.substring(0, 60) : '(none)'}`);
      return;
    }
    this.applyPendingSubtitle();
  }

  /**
   * Background audio-only only. Never call around load/seek.
   * false → vid=no; true → vid=auto. No pause, no resync seek.
   */
  setVideoOutputEnabled(enabled: boolean): void {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    const force = enabled !== this.videoOutputOn;
    this.videoOutputOn = enabled;
    // Always push property: after load, media defaults may ignore prior vid=no.
    if (enabled) {
      ctrl.setProperty('vid', 'auto');
      if (force) {
        Logger.info(TAG, 'video output ON (vid=auto)');
      }
    } else {
      ctrl.setProperty('vid', 'no');
      if (force) {
        Logger.info(TAG, 'video output OFF (vid=no)');
      }
    }
  }

  getState(): PlaybackState {
    return this.buildState();
  }

  getPlaybackStats(): PlaybackStats {
    const empty: PlaybackStats = {
      cacheSpeedBps: 0,
      demuxerCacheDurationSec: 0,
      droppedFrames: 0,
      decoderDroppedFrames: 0
    };
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) {
      return empty;
    }
    return {
      cacheSpeedBps: this.parseStatsNumber(ctrl.getProperty('cache-speed')),
      demuxerCacheDurationSec: this.parseStatsNumber(ctrl.getProperty('demuxer-cache-duration')),
      droppedFrames: this.parseStatsNumber(ctrl.getProperty('dropped-frame-count')),
      decoderDroppedFrames: this.parseStatsNumber(ctrl.getProperty('decoder-dropped-frame-count'))
    };
  }

  isDirectNetworkSource(): boolean {
    // Loopback proxy sessions (single/dual/SABR: http://127.0.0.1:..., legacy
    // EDL: edl://) are fed by the local proxy; everything else (live HLS
    // manifests) is fetched by FFmpeg directly from the network.
    if (this.sourceUrl.length === 0) return false;
    return !this.sourceUrl.startsWith('http://127.0.0.1:')
      && !this.sourceUrl.startsWith('edl://');
  }

  private parseStatsNumber(raw: string): number {
    const value: number = Number(raw);
    return isNaN(value) ? 0 : value;
  }

  setStateCallback(cb: (state: PlaybackState) => void): void {
    this.stateCallback = cb;
  }

  setSubtitleCallback(cb: (text: string, startTime: number, duration: number) => void): void {
    this.subtitleCallback = cb;
  }

  private bindSurface(ctrl: MpvPlayerController, surfaceId: string): void {
    if (surfaceId.length === 0) return;
    ctrl.setVideoSurfaceId(surfaceId);
    // 绑定后立即套用已知几何：mpv 的 ohos vo 在 video chain 初始化时需要宽高，
    // 否则报 "Failed to get height and width" 且无画面。typeNode 方案下 onSurfaceCreated
    // 可能早于 onSurfaceChanged，UI 层首次回调时尺寸常为 0，故由引擎用缓存兜底。
    if (this.surfaceWidthPx > 0 && this.surfaceHeightPx > 0) {
      ctrl.setVideoSurfaceSize(this.surfaceWidthPx, this.surfaceHeightPx);
      Logger.debug(TAG, `bindSurface: id=${surfaceId.substring(0, 24)} geometry=${this.surfaceWidthPx}x${this.surfaceHeightPx}`);
    } else {
      Logger.warn(TAG, `bindSurface: id=${surfaceId.substring(0, 24)} but no known geometry yet`);
    }
  }

  private playInternal(): void {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed || this.sourceUrl.length === 0) return;
    ctrl.play();
    this.isEnded = false;
  }

  private seekInternal(targetMs: number, keyframe: boolean): void {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed || this.isLive) return;
    ctrl.seek(targetMs);
    Logger.debug(TAG, `seek: target=${(targetMs / 1000).toFixed(2)}s keyframe=${keyframe}`);
    this.emitCurrentState();
  }

  private applyPendingSubtitle(): void {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    const target = this.pendingSubtitleUrl;
    if (target === this.currentSubtitleUrl) return;
    if (this.currentSubtitleUrl.length > 0) {
      ctrl.command(['sub-remove']);
      this.subtitleCallback?.('', 0, 0);
    }
    if (target.length > 0) {
      ctrl.command(['sub-add', target, 'select']);
      Logger.debug(TAG, `sub-add: ${target.substring(0, 80)}`);
    }
    this.currentSubtitleUrl = target;
  }

  private applyReadyActions(): void {
    this.applyPendingSubtitle();

    // EDL + delay_open 场景：loadfile 后重新绑定 surface（surface ID 可能已变化）
    if (this.surfaceId.length > 0 && this.controller !== null) {
      this.bindSurface(this.controller, this.surfaceId);
    }

    // Re-apply audio-only / video-off preference after new media is prepared.
    if (!this.videoOutputOn && this.controller !== null) {
      this.controller.setProperty('vid', 'no');
      Logger.info(TAG, 'video output re-OFF after ready (vid=no)');
    }

    if (!this.isLive) {
      // 优先处理用户主动的 pendingSeekMs
      if (this.pendingSeekMs >= 0) {
        this.seekInternal(this.pendingSeekMs, false);
        this.pendingSeekMs = -1;
      }
      // Normal sources consumed pendingStartMs in loadfile's per-file start option. Only legacy EDL
      // sources retain it because delay_open requires a seek after the child demuxer is prepared.
      else if (this.pendingStartMs >= 0) {
        const isEdl = this.sourceUrl.startsWith('edl://');
        if (this.pendingStartMs > 0 || isEdl) {
          Logger.info(TAG, `startup seek: target=${this.pendingStartMs}ms${isEdl ? ' (edl)' : ''}`);
          this.seekInternal(this.pendingStartMs, false);
        }
        this.pendingStartMs = -1;
      }
    }

    if (this.playWhenReady) {
      this.playInternal();
    }
  }

  private onMpvEvent(ctrl: MpvPlayerController, type: number, value: number): void {
    if (this.destroyed || ctrl !== this.controller) return;

    if (type === 1) {
      if (!this.acceptsNativeTimeline) {
        Logger.debug(TAG, `ignored outgoing position during source load value=${value}ms`);
        return;
      }
      // 位置更新事件：缩小容差到500ms（MPV内部seek已经较准）
      if (this.pendingSeekMs >= 0) {
        const diff = Math.abs(value - this.pendingSeekMs);
        if (value > 0 && diff < 500) {  // 500ms容差，更精确
          this.pendingSeekMs = -1;
          this.isSeeking = false;
          Logger.debug(TAG, `seek confirmed: target=${this.pendingSeekMs}ms actual=${value}ms`);
        }
      }
      this.lastPositionMs = value;
      if (value > 0) {
        this.lastKnownPositionMs = value;
      }

      // 添加节流，避免高频emit（100ms节流）
      const now = Date.now();
      if (now - this.lastTimeEmitMs < 100) return;
      this.lastTimeEmitMs = now;
    } else if (type === 2) {
      const wasAcceptingNativeTimeline = this.acceptsNativeTimeline;
      this.handleStatusUpdate(value);
      if (!wasAcceptingNativeTimeline && this.acceptsNativeTimeline) {
        // Cache state can arrive before Prepared. Pull the latest snapshot once the new source
        // owns the native timeline so a short, already-buffered item still paints its cache bar.
        this.updateSeekableRanges(ctrl.getSeekableRangesJson());
      }
    } else if (type === 3) {
      if (!this.acceptsNativeTimeline) {
        Logger.debug(TAG, `ignored outgoing duration during source load value=${value}ms`);
        return;
      }
      if (value > 0) {
        this.lastDurationMs = value;
      }
    } else if (type === 4) {
      if (!this.acceptsNativeTimeline) {
        return;
      }
      if (!this.updateSeekableRanges(ctrl.getSeekableRangesJson())) {
        return;
      }
    }
    this.emitCurrentState();
  }

  private updateSeekableRanges(json: string): boolean {
    try {
      const parsed = JSON.parse(json) as number[][];
      if (!Array.isArray(parsed)) {
        return this.replaceSeekableRanges([]);
      }
      const next: number[][] = [];
      for (const range of parsed) {
        if (!Array.isArray(range) || range.length < 2) continue;
        const start = Number(range[0]);
        const end = Number(range[1]);
        if (Number.isFinite(start) && Number.isFinite(end) && start >= 0 && end > start) {
          next.push([start, end]);
        }
      }
      return this.replaceSeekableRanges(next);
    } catch (err) {
      Logger.warn(TAG, `seekable ranges parse failed: ${this.describeError(err)}`);
      return this.replaceSeekableRanges([]);
    }
  }

  private replaceSeekableRanges(next: number[][]): boolean {
    if (this.areSeekableRangesEqual(this.seekableRanges, next)) {
      return false;
    }
    this.seekableRanges = next;
    return true;
  }

  private areSeekableRangesEqual(left: number[][], right: number[][]): boolean {
    if (left.length !== right.length) return false;
    for (let i = 0; i < left.length; i++) {
      if (left[i].length < 2 || right[i].length < 2 ||
        left[i][0] !== right[i][0] || left[i][1] !== right[i][1]) {
        return false;
      }
    }
    return true;
  }

  private handleStatusUpdate(status: number): void {
    if (this.destroyed) return;

    const wasReady: boolean = this.isReady;
    const buffering: boolean = (status & MediaStatus.Buffering) !== 0 || (status & MediaStatus.Stalled) !== 0;
    const seeking: boolean = (status & MediaStatus.Seeking) !== 0;
    const ended: boolean = this.acceptsNativeTimeline && (status & MediaStatus.End) !== 0;
    const prepared: boolean = (status & MediaStatus.Prepared) !== 0;
    const loaded: boolean = (status & MediaStatus.Loaded) !== 0;
    const buffered: boolean = (status & MediaStatus.Buffered) !== 0;
    const invalid: boolean = (status & MediaStatus.Invalid) !== 0;
    const loading: boolean = (status & MediaStatus.Loading) !== 0;

    this.loaded = loaded || prepared;
    this.preparing = this.preparing && !prepared && !invalid;
    this.isReady = prepared;
    this.isBuffered = buffered;
    this.isBuffering = buffering || loading || this.preparing;
    this.isEnded = ended;

    if (seeking) {
      this.isSeeking = true;
    } else if (this.isSeeking) {
      this.isSeeking = false;
    }

    if (ended) {
      this.playWhenReady = false;
    }

    if (invalid && !this.hasError) {
      this.hasError = true;
      this.errorMsg = '[mpv] playback error';
      this.lastErrorCategory = 'network';
        this.playWhenReady = false;
      Logger.error(TAG, `playback error: status=0x${status.toString(16)}`);
    } else if (!invalid && this.hasError && (loading || loaded || prepared)) {
      this.hasError = false;
      this.errorMsg = '';
      this.lastErrorCategory = 'unknown';
    }

    if (!wasReady && this.isReady) {
      this.preparing = false;
      this.isBuffering = false;
      this.acceptsNativeTimeline = true;
      this.applyReadyActions();
    }

    Logger.debug(TAG, `status=0x${status.toString(16)} ready=${this.isReady} loaded=${this.loaded} buf=${this.isBuffering} seek=${this.isSeeking} ended=${this.isEnded} err=${this.hasError}`);
  }

  private emitCurrentState(): void {
    this.stateCallback?.(this.buildState());
  }

  /** Refresh the cached MediaInfo snapshot (throttled by buildState). */
  private refreshMediaInfoSnapshot(ctrl: MpvPlayerController): void {
    const snap = this.mediaSnapshot;
    try {
      const info: MediaInfo = ctrl.getMediaInfo();
      snap.mediaTitle = info.title ?? '';
      snap.containerFormat = info.format ?? '';
      const v = info.video.length > 0 ? info.video[0] : null;
      if (v) {
        snap.videoWidth = v.width;
        snap.videoHeight = v.height;
        snap.videoCodec = v.codec?.codec ?? '';
        snap.videoBitRate = v.codec?.bitRate ?? 0;
        snap.frameRate = v.codec?.frameRate ?? info.frameRate ?? 0;
      }
      const hwdec = ctrl.getProperty('hwdec-current');
      if (hwdec.length > 0 && hwdec !== this.lastLoggedHwdec) {
        this.lastLoggedHwdec = hwdec;
        const soft = hwdec === 'no' || hwdec.indexOf('ohcodec') < 0;
        Logger.info(TAG,
          `decoder: hwdec-current=${hwdec} codec=${snap.videoCodec} ${snap.videoWidth}x${snap.videoHeight}` +
          `${soft ? ' (software path — thermal risk)' : ' (ohcodec hard path)'}`);
      }
      const a = info.audio.length > 0 ? info.audio[0] : null;
      if (a) {
        snap.audioCodec = a.codec?.codec ?? '';
        snap.audioBitRate = a.codec?.bitRate ?? 0;
        snap.audioChannels = a.codec?.channels ?? 0;
        snap.audioSampleRate = a.codec?.sampleRate ?? 0;
      }
      snap.videoStreamCount = info.video.length;
      snap.audioStreamCount = info.audio.length;
      // Native never reports subtitle tracks; keep the count at 0.
      snap.subtitleStreamCount = 0;
      const fsStr = info.fileSize ?? '';
      const parsed = parseInt(fsStr, 10);
      snap.fileSize = (fsStr.length > 0 && !isNaN(parsed)) ? parsed : 0;
    } catch (e) {
      Logger.debug(TAG, `getMediaInfo failed: ${(e as Error).message}`);
    }
  }

  private buildState(): PlaybackState {
    const ctrl: MpvPlayerController | null = this.controller;

    // 仅从 native 读取位置和时长（事件已更新，这里做兜底补偿）
    let posMs: number = this.lastPositionMs;
    let durMs: number = this.lastDurationMs;
    // isPlaying 从 native getState() 读取真实 mpv pause 状态：native 侧的
    // ctx.state 在每次 mpv pause 属性变化后由 HandleObservedProperty 自动镜像
    // 维护（type-2 事件推送同步触发本地状态刷新），是唯一真相。
    let isPlaying: boolean = false;
    if (ctrl !== null && !this.destroyed && this.acceptsNativeTimeline) {
      const nativePos: number = ctrl.getPosition();
      const nativeDur: number = ctrl.getDuration();
      if (nativePos > 0) {
        posMs = nativePos;
        this.lastPositionMs = nativePos;
        this.lastKnownPositionMs = nativePos;
      }
      if (nativeDur > 0) {
        durMs = nativeDur;
        this.lastDurationMs = nativeDur;
      }
      // 无源时 native 返回 Stopped，避免误判为"正在播放"
      isPlaying = this.sourceUrl.length > 0 && ctrl.getState() === NativePlaybackState.Playing;
    }

    // pendingSeekMs >= 0 时优先使用跳转目标位置（直到位置事件确认追上了目标，见 onMpvEvent type=1）
    const currentMs: number = (this.pendingSeekMs >= 0) ? this.pendingSeekMs : posMs;
    const engineState = this.mapEngineState(isPlaying);

    // 从 mpv 读取当前播放流的详细信息（codec/分辨率/码率/帧率等）。
    // 这些信息在单文件播放期内基本不变，每 2s 节流刷新一次快照，
    // 避免每次状态 emit（约 10Hz）都打穿 ~25 次 NAPI 属性读取。
    if (ctrl !== null && !this.destroyed && this.isReady && !this.hasError) {
      const nowMs = Date.now();
      if (nowMs - this.lastMediaInfoAtMs >= 2000) {
        this.lastMediaInfoAtMs = nowMs;
        this.refreshMediaInfoSnapshot(ctrl);
      }
    }
    const snap = this.mediaSnapshot;
    const mediaTitle: string = snap.mediaTitle;
    const containerFormat: string = snap.containerFormat;
    const videoWidth: number = snap.videoWidth;
    const videoHeight: number = snap.videoHeight;
    const videoStreamCount: number = snap.videoStreamCount;
    const audioStreamCount: number = snap.audioStreamCount;
    const subtitleStreamCount: number = snap.subtitleStreamCount;
    const videoCodec: string = snap.videoCodec;
    const videoBitRate: number = snap.videoBitRate;
    const frameRate: number = snap.frameRate;
    const audioCodec: string = snap.audioCodec;
    const audioBitRate: number = snap.audioBitRate;
    const audioChannels: number = snap.audioChannels;
    const audioSampleRate: number = snap.audioSampleRate;
    const fileSize: number = snap.fileSize;

    return {
      engineState: engineState,
      isPlaying: isPlaying,
      isReady: this.isReady,
      isBuffered: this.isBuffered,
      isBuffering: this.isBuffering,
      isSeeking: this.isSeeking,
      isEnded: this.isEnded,
      isLive: this.isLive,
      isSeekable: !this.isLive && durMs > 0,
      currentTime: currentMs > 0 ? currentMs / 1000 : 0,
      duration: durMs > 0 ? durMs / 1000 : 0,
      playbackSpeed: this.playbackSpeed,
      bufferingPercent: 0,
      seekableRanges: this.seekableRanges,
      uri: this.sourceUrl,
      mediaTitle: mediaTitle,
      containerFormat: containerFormat,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      videoStreamCount: videoStreamCount,
      audioStreamCount: audioStreamCount,
      subtitleStreamCount: subtitleStreamCount,
      videoCodec: videoCodec,
      videoBitRate: videoBitRate,
      frameRate: frameRate,
      audioCodec: audioCodec,
      audioBitRate: audioBitRate,
      audioChannels: audioChannels,
      audioSampleRate: audioSampleRate,
      fileSize: fileSize,
      errorMsg: this.errorMsg,
      errorCategory: this.hasError ? this.lastErrorCategory : undefined,
      errorCode: this.hasError ? -1 : undefined,
    };
  }

  private mapEngineState(isPlaying: boolean): PlaybackEngineState {
    if (this.isBuffering) return 'buffering';
    if (isPlaying) return 'playing';
    if (this.isReady) return 'paused';
    return 'stopped';
  }

  private normalizeSourceUrl(source: string): string {
    if (source.startsWith('/')) {
      return `file://${source}`;
    }
    return source;
  }

  private looksLive(url: string): boolean {
    const lower: string = url.toLowerCase();
    if (lower.includes('127.0.0.1') || lower.includes('localhost')) {
      return false;
    }
    // 显式点播标记（VOD / DVR / CLEAN 都是可 seek 的录播）
    if (lower.includes('playlist_type/vod') || lower.includes('playlist_type=vod') ||
        lower.includes('playlist_type/dvr') || lower.includes('playlist_type=dvr') ||
        lower.includes('playlist_type/clean') || lower.includes('playlist_type=clean')) {
      return false;
    }
    // 显式直播标记
    if (lower.includes('playlist_type/live') || lower.includes('playlist_type=live') ||
        lower.includes('yt_live_broadcast')) {
      return true;
    }
    // 兜底：YouTube live manifest 路径形如 /api/manifest/hls_variant/.../live/1/...
    // 注意：用 '/live/' 而非裸 'live'，避免误命中 'keepalive' 等子串
    if (lower.includes('/manifest/') && lower.includes('/live/')) {
      return true;
    }
    return false;
  }

  private looksHls(url: string): boolean {
    const lower: string = url.toLowerCase();
    if (lower.includes('127.0.0.1') || lower.includes('localhost')) {
      return false;
    }
    return lower.includes('.m3u8') || lower.includes('/hls_playlist/') ||
      lower.includes('application/vnd.apple.mpegurl');
  }

  private resetLocalState(clearSurface: boolean): void {
    if (clearSurface) {
      this.surfaceId = '';
    }
    this.sourceUrl = '';
    this.lastLoggedHwdec = '';
    this.lastPositionMs = 0;
    this.lastDurationMs = 0;
    this.seekableRanges = [];
    this.isBuffering = false;
    this.isSeeking = false;
    this.isEnded = false;
    this.isReady = false;
    this.isBuffered = false;
    this.hasError = false;
    this.errorMsg = '';
    this.lastErrorCategory = 'unknown';
    this.playWhenReady = false;
    this.loaded = false;
    this.preparing = false;
    this.pendingStartMs = -1;
    this.pendingSeekMs = -1;
    this.pendingSubtitleUrl = '';
    this.currentSubtitleUrl = '';
    this.lastKnownPositionMs = 0;
    this.lastTimeEmitMs = 0;
    this.acceptsNativeTimeline = false;
    this.isLive = false;
  }

  private describeError(err: Object): string {
    const e = err as Error;
    if (e && e.message) {
      return e.message;
    }
    return String(err);
  }
}
