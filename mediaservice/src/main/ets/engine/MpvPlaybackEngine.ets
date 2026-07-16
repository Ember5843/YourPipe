import { MdkPlayerController as MpvPlayerController, MediaStatus, MediaType, SeekFlag, PlaybackState as NativePlaybackState } from '@mediadevkit/libmdk-napi';
import type { MediaInfo } from '@mediadevkit/libmdk-napi';
import { PlaybackEngine, PlaybackEngineState, PlaybackState, PlaybackErrorCategory, EngineConfig } from './PlaybackEngine';
import Logger from '../utils/Logger';

const TAG: string = '[PlayerLog][MpvPlaybackEngine]';

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
  /** Reconciles native pause changes made directly by the OHAudio bridge. */
  private nativeStatePollTimerId: number = -1;
  private lastReportedIsPlaying: boolean = false;

  // 保存配置供 load() 方法使用
  private engineConfig: EngineConfig = {};
  /** 上次日志里的 hwdec-current，避免状态轮询刷屏 */
  private lastLoggedHwdec: string = '';
  /** Mirror of vid on/off for background audio-only only (never used on load/seek). */
  private videoOutputOn: boolean = true;

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
      const gpuApi = _config.mpvGpuApi ?? 'auto';

      // Product path: ohcodec-copy + gpu-next (native EnsureMpv also sets these).
      if (hwdecEnabled) {
        ctrl.setProperty('hwdec', 'ohcodec-copy');
        // Prefer ohcodec wrappers when multiple decoders exist for a codec.
        ctrl.setProperty('hwdec-codecs', 'h264,hevc,vp8,vp9,av1');
        Logger.info(TAG, 'Hardware decoding enabled: ohcodec-copy');
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
      Logger.info(TAG, `Demuxer readahead=${demuxerReadaheadSecs}s`);

      ctrl.setProperty('hr-seek', 'yes');
      ctrl.setProperty('hr-seek-framedrop', 'yes');

      // Cheap GPU path for rotate/fullscreen reconfig (keeps UI anim smooth):
      // bilinear scales + no dither/deband/HDR peak; audio-sync + VO framedrop
      // avoid display-resample work and backlog under brief GPU spikes.
      ctrl.setProperty('scale', 'bilinear');
      ctrl.setProperty('cscale', 'bilinear');
      ctrl.setProperty('dscale', 'bilinear');
      ctrl.setProperty('dither', 'no');
      ctrl.setProperty('deband', 'no');
      ctrl.setProperty('hdr-compute-peak', 'no');
      ctrl.setProperty('video-sync', 'audio');
      ctrl.setProperty('framedrop', 'vo');
      // Soft-decode only: skip loopfilter on non-keyframes (VP9/AV1 soft path).
      ctrl.setProperty('vd-lavc-skiploopfilter', 'nonkey');

      ctrl.setProperty('demuxer-lavf-o', 'reconnect_at_eof=1,reconnect_streamed=1,reconnect_delay_max=5');
      this.controller = ctrl;
      this.initialized = true;
      this.startNativeStateReconciliation();
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
    this.stopNativeStateReconciliation();
    this.destroyed = true;
    this.initialized = false;
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
    // The mpv wrapper has no detach API. Keep the last surface id for rebinding.
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

  updateVideoRect(_x: number, _y: number, _w: number, _h: number): void {
    // Surface sizing is handled through setVideoSurfaceSize.
  }

  load(source: string, startPos: number): boolean {
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
    this.lastKnownPositionMs = 0;
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

    try {
      ctrl.setMedia(this.sourceUrl);
      if (this.surfaceId.length > 0) {
        this.bindSurface(ctrl, this.surfaceId);
        Logger.info(TAG, `load: surface bound id=${this.surfaceId.substring(0, 24)}`);
      } else {
        Logger.warn(TAG, `load: surfaceId is empty, video may not render`);
      }
      this.preparing = true;
      // 统一策略：prepare(0) 不带 seek，交给 applyReadyActions 在 Prepared 事件后 seek。
      // 原因：
      //   - EDL + delay_open：prepare 的 seek 不会传播到 lazy 打开的子 demuxer
      //   - HLS：MPV 的 HLS demuxer 在加载 master playlist / 切 variant 时会丢弃 prepare 位置
      // 在 Ready 之后显式 seek 能保证两种 source 都从正确位置起播。
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
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    ctrl.stop();
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

  switchQuality(source: string, resumePos: number): boolean {
    return this.load(source, resumePos);
  }

  prebufferTargetQuality(_videoUrl: string, _audioUrl: string): number {
    return 0;
  }

  switchToPrebuffered(_videoHandle: number, _audioHandle: number, _resumePos: number): boolean {
    return false;
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

  setHwdecMode(_mode: string): void {}

  getState(): PlaybackState {
    return this.buildState();
  }

  getBandwidthEstimateBps(): number {
    return 1_000_000;
  }

  setStateCallback(cb: (state: PlaybackState) => void): void {
    this.stateCallback = cb;
  }

  setSubtitleCallback(cb: (text: string, startTime: number, duration: number) => void): void {
    this.subtitleCallback = cb;
  }

  registerLogCallback(_cb: (level: string, tag: string, message: string) => void): void {}

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
    const flags: number = keyframe
      ? (SeekFlag.KeyFrame | SeekFlag.FromStart)
      : SeekFlag.FromStart;
    ctrl.seek(targetMs, flags);
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
      // 起播/续播位置处理：load() 时 prepare(0)，这里在 Prepared 后统一显式 seek。
      // pendingStartMs > 0 时一定 seek（无论 EDL/HLS/普通），=0 时仅 EDL 需要 seek 以激活子 demuxer。
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
      this.handleStatusUpdate(value);
    } else if (type === 3) {
      if (value > 0) {
        this.lastDurationMs = value;
      }
    }
    this.emitCurrentState();
  }

  private handleStatusUpdate(status: number): void {
    if (this.destroyed) return;

    const wasReady: boolean = this.isReady;
    const buffering: boolean = (status & MediaStatus.Buffering) !== 0 || (status & MediaStatus.Stalled) !== 0;
    const seeking: boolean = (status & MediaStatus.Seeking) !== 0;
    const ended: boolean = (status & MediaStatus.End) !== 0;
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
      this.applyReadyActions();
    }

    Logger.debug(TAG, `status=0x${status.toString(16)} ready=${this.isReady} loaded=${this.loaded} buf=${this.isBuffering} seek=${this.isSeeking} ended=${this.isEnded} err=${this.hasError}`);
  }

  private emitCurrentState(): void {
    this.stateCallback?.(this.buildState());
  }

  private startNativeStateReconciliation(): void {
    this.stopNativeStateReconciliation();
    this.nativeStatePollTimerId = setInterval(() => {
      const ctrl = this.controller;
      if (!this.destroyed && this.sourceUrl.length > 0 && ctrl !== null) {
        const nativeIsPlaying = ctrl.getState() === NativePlaybackState.Playing;
        if (nativeIsPlaying === this.lastReportedIsPlaying) return;
        Logger.info(TAG, `native state reconciled playing=${nativeIsPlaying}`);
        this.emitCurrentState();
      }
    }, 500) as number;
  }

  private stopNativeStateReconciliation(): void {
    if (this.nativeStatePollTimerId >= 0) {
      clearInterval(this.nativeStatePollTimerId);
      this.nativeStatePollTimerId = -1;
    }
  }

  private buildState(): PlaybackState {
    const ctrl: MpvPlayerController | null = this.controller;

    // 仅从 native 读取位置和时长（事件已更新，这里做兜底补偿）
    let posMs: number = this.lastPositionMs;
    let durMs: number = this.lastDurationMs;
    // ★ isPlaying 改为从 native getState() 读取真实 mpv pause 状态。
    // 旧实现用 this.mpvPlaybackState 当做 true，但以下路径都会绕过本地变量：
    //   - OHAudio 焦点桥接：player_napi 跳过 ets 直接 set mpv pause 属性
    //   - 外部 mpv 命令 / lua 脚本等
    // Native 侧的 ctx.state 在每次 mpv pause 属性变化后由
    // UpdateStatusFromObservedProperties 自动镜像维护，是唯一真相。
    let isPlaying: boolean = false;
    if (ctrl !== null && !this.destroyed) {
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
    this.lastReportedIsPlaying = isPlaying;

    // pendingSeekMs >= 0 时优先使用跳转目标位置（直到位置事件确认追上了目标，见 onMpvEvent type=1）
    const currentMs: number = (this.pendingSeekMs >= 0) ? this.pendingSeekMs : posMs;
    const engineState = this.mapEngineState(isPlaying);

    // 从 mpv 读取当前播放流的详细信息（codec/分辨率/码率/帧率等）。
    let mediaTitle: string = '';
    let containerFormat: string = '';
    let videoWidth: number = 0;
    let videoHeight: number = 0;
    let videoStreamCount: number = 0;
    let audioStreamCount: number = 0;
    let subtitleStreamCount: number = 0;
    let videoCodec: string = '';
    let videoBitRate: number = 0;
    let frameRate: number = 0;
    let audioCodec: string = '';
    let audioBitRate: number = 0;
    let audioChannels: number = 0;
    let audioSampleRate: number = 0;
    let fileSize: number = 0;
    if (ctrl !== null && !this.destroyed && this.isReady && !this.hasError) {
      try {
        const info: MediaInfo = ctrl.getMediaInfo();
        mediaTitle = info.title ?? '';
        containerFormat = info.format ?? '';
        const v = info.video.length > 0 ? info.video[0] : null;
        if (v) {
          videoWidth = v.width;
          videoHeight = v.height;
          videoCodec = v.codec?.codec ?? '';
          videoBitRate = v.codec?.bitRate ?? 0;
          frameRate = v.codec?.frameRate ?? info.frameRate ?? 0;
        }
        const hwdec = ctrl.getProperty('hwdec-current');
        if (hwdec.length > 0 && hwdec !== this.lastLoggedHwdec) {
          this.lastLoggedHwdec = hwdec;
          const soft = hwdec === 'no' || hwdec.indexOf('ohcodec') < 0;
          Logger.info(TAG,
            `decoder: hwdec-current=${hwdec} codec=${videoCodec} ${videoWidth}x${videoHeight}` +
            `${soft ? ' (software path — thermal risk)' : ' (ohcodec hard path)'}`);
        }
        const a = info.audio.length > 0 ? info.audio[0] : null;
        if (a) {
          audioCodec = a.codec?.codec ?? '';
          audioBitRate = a.codec?.bitRate ?? 0;
          audioChannels = a.codec?.channels ?? 0;
          audioSampleRate = a.codec?.sampleRate ?? 0;
        }
        videoStreamCount = info.video.length;
        audioStreamCount = info.audio.length;
        subtitleStreamCount = info.subtitle.length;
        const fsStr = info.fileSize ?? '';
        if (fsStr.length > 0) {
          const parsed = parseInt(fsStr, 10);
          if (!isNaN(parsed)) fileSize = parsed;
        }
      } catch (e) {
        Logger.debug(TAG, `getMediaInfo failed: ${(e as Error).message}`);
      }
    }

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
    this.isBuffering = false;
    this.isSeeking = false;
    this.isEnded = false;
    this.isReady = false;
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
  }

  private describeError(err: Object): string {
    const e = err as Error;
    if (e && e.message) {
      return e.message;
    }
    return String(err);
  }
}
