import { MdkPlayerController as MpvPlayerController, MediaStatus, MediaType, SeekFlag } from '@mediadevkit/libmdk-napi';
import { PlaybackEngine, PlaybackEngineState, PlaybackState, PlaybackErrorCategory, EngineConfig } from './PlaybackEngine';
import Logger from '../utils/Logger';

const TAG: string = '[PlayerLog][MpvPlaybackEngine]';

const kStateStopped: number = 0;
const kStatePlaying: number = 1;

export class MpvPlaybackEngine implements PlaybackEngine {
  private initialized: boolean = false;
  private controller: MpvPlayerController | null = null;
  private stateCallback: ((state: PlaybackState) => void) | null = null;
  private subtitleCallback: ((text: string, startTime: number, duration: number) => void) | null = null;

  private surfaceId: string = '';
  private sourceUrl: string = '';
  private playbackSpeed: number = 1.0;

  private lastPositionMs: number = 0;
  private lastDurationMs: number = 0;
  private isBuffering: boolean = false;
  private isSeeking: boolean = false;
  private isEnded: boolean = false;
  private isReady: boolean = false;
  private hasError: boolean = false;
  private errorMsg: string = '';
  private lastErrorCategory: PlaybackErrorCategory = 'unknown';
  private mpvPlaybackState: number = kStateStopped;
  private isLive: boolean = false;
  private playWhenReady: boolean = false;
  private loaded: boolean = false;
  private preparing: boolean = false;
  private destroyed: boolean = false;
  private loadGeneration: number = 0;
  private pendingStartMs: number = -1;
  private pendingSeekMs: number = -1;
  private pendingSubtitleUrls: string[] = [];
  private subtitleLoaded: boolean = false;
  private lastKnownPositionMs: number = 0;
  private lastTimeEmitMs: number = 0;

  async initialize(_config: EngineConfig): Promise<boolean> {
    if (this.initialized && this.controller !== null) {
      return true;
    }

    try {
      this.destroyed = false;
      const ctrl: MpvPlayerController = new MpvPlayerController();
      ctrl.setEventCallback((type: number, value: number) => {
        this.onMpvEvent(ctrl, type, value);
      });
      // 启用内存缓存（不写磁盘），改善seek性能和网络波动容忍度
      ctrl.setProperty('cache', 'yes');
      ctrl.setProperty('cache-secs', '10');
      ctrl.setProperty('cache-on-disk', 'no');

      // 优化缓冲区配置以避免触发YouTube SABR限速
      // demuxer-max-bytes 从 50MB 降低到 20MB：
      //   - 避免MPV一次请求过大范围（RangeProxy已限制单次10MB）
      //   - 20MB足够缓存约2-4秒的1080p/60fps流（码率5-8Mbps）
      //   - 配合RangeProxy的10MB chunk限制，MPV最多发起2个并发请求
      ctrl.setProperty('demuxer-readahead-secs', '8');
      ctrl.setProperty('demuxer-max-bytes', '20971520'); // 20MB
      // 回放缓冲降低到5MB，减少seek时的初始请求大小
      ctrl.setProperty('demuxer-max-back-bytes', '5242880'); // 5MB

      // 精确seek，改善seek精度和用户体验
      ctrl.setProperty('hr-seek', 'yes');
      ctrl.setProperty('hr-seek-framedrop', 'no');

      // 流缓冲保持4MB
      ctrl.setProperty('stream-buffer-size', '4194304');

      // FFmpeg HTTP 读到10MB截断后自动重连续传
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
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed || widthPx <= 0 || heightPx <= 0) return;
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
    this.subtitleLoaded = false;
    this.lastPositionMs = 0;
    this.lastDurationMs = 0;
    this.lastKnownPositionMs = 0;
    this.mpvPlaybackState = kStateStopped;
    this.emitCurrentState();

    Logger.info(TAG, `load: startPos=${startPos.toFixed(2)}s url=${this.sourceUrl.substring(0, 120)}`);

    try {
      ctrl.setMedia(this.sourceUrl);
      if (this.surfaceId.length > 0) {
        this.bindSurface(ctrl, this.surfaceId);
        Logger.info(TAG, `load: surface bound id=${this.surfaceId.substring(0, 24)}`);
      } else {
        Logger.warn(TAG, `load: surfaceId is empty, video may not render`);
      }
      this.preparing = true;
      // EDL + delay_open: prepare 的 seek 可能无法传播到 lazy 打开的子 demuxer
      // 改为 prepare(0) 不 seek，交给 applyReadyActions 统一处理
      const isEdl = this.sourceUrl.startsWith('edl://');
      const startMs = this.pendingStartMs >= 0 && !isEdl ? this.pendingStartMs : 0;
      ctrl.prepare(startMs);
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
    this.mpvPlaybackState = kStateStopped;
    this.emitCurrentState();
  }

  stop(): void {
    this.playWhenReady = false;
    this.pendingStartMs = -1;
    this.pendingSeekMs = -1;
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    ctrl.stop();
    this.loaded = false;
    this.preparing = false;
    this.isReady = false;
    this.isEnded = false;
    this.isBuffering = false;
    this.isSeeking = false;
    this.mpvPlaybackState = kStateStopped;
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

  switchQuality(source: string, resumePos: number): boolean {
    return this.load(source, resumePos);
  }

  prebufferTargetQuality(_videoUrl: string, _audioUrl: string): number {
    return 0;
  }

  switchToPrebuffered(_videoHandle: number, _audioHandle: number, _resumePos: number): boolean {
    return false;
  }

  preloadSubtitleTracks(urls: string[]): void {
    this.pendingSubtitleUrls = urls.slice();
    this.subtitleLoaded = false;
    if (this.isReady) {
      this.applyPendingSubtitles();
    }
    Logger.debug(TAG, `preloadSubtitleTracks: ${urls.length} url(s)`);
  }

  selectSubtitleTrack(_index: number): void {}

  setSubtitleVisible(visible: boolean): void {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    if (visible) {
      ctrl.setActiveTracks([0], MediaType.Subtitle);
    } else {
      ctrl.setActiveTracks([], MediaType.Subtitle);
      this.subtitleCallback?.('', 0, 0);
    }
  }

  setSubtitleDelay(_delayMs: number): void {}

  getSubtitleDelay(): number {
    return 0;
  }

  setSubtitleStyle(_position: string, _fontSize: number, _color: string, _bgAlpha: number): void {}

  setSubtitleAutoSync(_enabled: boolean): void {}

  setVideoOutputEnabled(enabled: boolean): void {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed) return;
    if (enabled) {
      ctrl.setActiveTracks([0], MediaType.Video);
    } else {
      ctrl.setActiveTracks([], MediaType.Video);
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
    Logger.debug(TAG, `attachSurface: surfaceId=${surfaceId}`);
  }

  private playInternal(): void {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.destroyed || this.sourceUrl.length === 0) return;
    ctrl.play();
    this.mpvPlaybackState = kStatePlaying;
    this.isEnded = false;
    this.emitCurrentState();
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

  private applyPendingSubtitles(): void {
    const ctrl: MpvPlayerController | null = this.controller;
    if (ctrl === null || this.pendingSubtitleUrls.length === 0 || this.subtitleLoaded || this.destroyed) return;
    this.subtitleLoaded = true;
    for (const url of this.pendingSubtitleUrls) {
      ctrl.setProperty('sub-add', url);
      Logger.debug(TAG, `sub-add: ${url.substring(0, 80)}`);
    }
  }

  private applyReadyActions(): void {
    this.applyPendingSubtitles();

    // EDL + delay_open 场景：loadfile 后重新绑定 surface（surface ID 可能已变化）
    if (this.surfaceId.length > 0 && this.controller !== null) {
      this.bindSurface(this.controller, this.surfaceId);
    }

    if (!this.isLive) {
      // 优先处理用户主动的 pendingSeekMs
      if (this.pendingSeekMs >= 0) {
        this.seekInternal(this.pendingSeekMs, false);
        this.pendingSeekMs = -1;
      }
      // 起播/续播位置处理
      else if (this.pendingStartMs >= 0) {
        const isEdl = this.sourceUrl.startsWith('edl://');
        // EDL + delay_open: 即使 pendingStartMs=0 也必须 seek 以激活子 demuxer
        // 非 EDL: 仅在位置偏差>2s 时补救 seek
        if (isEdl || Math.abs(this.lastPositionMs - this.pendingStartMs) > 2000) {
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
    const invalid: boolean = (status & MediaStatus.Invalid) !== 0;
    const loading: boolean = (status & MediaStatus.Loading) !== 0;

    this.loaded = loaded || prepared;
    this.preparing = this.preparing && !prepared && !invalid;
    this.isReady = prepared;
    this.isBuffering = (buffering || this.preparing || loading) && !seeking && !prepared;
    this.isEnded = ended;

    if (ended) {
      this.playWhenReady = false;
      this.mpvPlaybackState = kStateStopped;
    }

    if (this.isSeeking && !seeking) {
      this.isSeeking = false;
      // pendingSeekMs 不清除，由 onMpvEvent type=1 的位置事件确认后清除
    } else if (seeking) {
      this.isSeeking = true;
    }

    if (invalid && !this.hasError) {
      this.hasError = true;
      this.errorMsg = '[mpv] playback error';
      this.lastErrorCategory = 'network';
      this.mpvPlaybackState = kStateStopped;
      this.playWhenReady = false;
      Logger.error(TAG, `playback error: status=0x${status.toString(16)}`);
    } else if (!invalid && this.hasError && (loading || loaded || prepared)) {
      this.hasError = false;
      this.errorMsg = '';
      this.lastErrorCategory = 'unknown';
    }

    // 不读 ctrl.isPlaying() —— 该调用异步滞后，本地 mpvPlaybackState 是权威来源

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

  private buildState(): PlaybackState {
    const ctrl: MpvPlayerController | null = this.controller;

    // 仅从 native 读取位置和时长（事件已更新，这里做兜底补偿）
    // 不读 ctrl.getState() —— isPlaying 由本地 mpvPlaybackState 权威决定
    let posMs: number = this.lastPositionMs;
    let durMs: number = this.lastDurationMs;
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
    }

    // isPlaying 由调用 play()/pause() 时设置的本地 mpvPlaybackState 权威决定
    const isPlaying: boolean = this.mpvPlaybackState === kStatePlaying;

    // pendingSeekMs >= 0 时优先使用跳转目标位置（直到位置事件确认追上了目标，见 onMpvEvent type=1）
    const currentMs: number = (this.pendingSeekMs >= 0) ? this.pendingSeekMs : posMs;
    const engineState = this.mapEngineState(isPlaying);

    return {
      engineState: engineState,
      isPlaying: isPlaying,
      isReady: this.isReady,
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
      mediaTitle: '',
      containerFormat: '',
      videoWidth: 0,
      videoHeight: 0,
      videoStreamCount: 0,
      audioStreamCount: 0,
      subtitleStreamCount: 0,
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
    return lower.includes('/manifest/') || lower.includes('live');
  }

  private resetLocalState(clearSurface: boolean): void {
    if (clearSurface) {
      this.surfaceId = '';
    }
    this.sourceUrl = '';
    this.lastPositionMs = 0;
    this.lastDurationMs = 0;
    this.isBuffering = false;
    this.isSeeking = false;
    this.isEnded = false;
    this.isReady = false;
    this.hasError = false;
    this.errorMsg = '';
    this.lastErrorCategory = 'unknown';
    this.mpvPlaybackState = kStateStopped;
    this.playWhenReady = false;
    this.loaded = false;
    this.preparing = false;
    this.pendingStartMs = -1;
    this.pendingSeekMs = -1;
    this.pendingSubtitleUrls = [];
    this.subtitleLoaded = false;
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
