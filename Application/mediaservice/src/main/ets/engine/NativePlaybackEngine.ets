import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PlaybackEngine, PlaybackEngineState, PlaybackState, PlaybackErrorCategory, EngineConfig } from './PlaybackEngine';
import Logger from '../utils/Logger';

const TAG: string = '[PlayerLog][SystemAvPlaybackEngine]';

export class NativePlaybackEngine implements PlaybackEngine {
  private initialized: boolean = false;
  private player: media.AVPlayer | undefined = undefined;
  private stateCallback?: (state: PlaybackState) => void;
  private subtitleCallback?: (text: string, startTime: number, duration: number) => void;
  private surfaceId: string = '';
  private sourceUrl: string = '';
  private playbackSpeed: number = 1.0;
  private bufferingPercent: number = 0;
  private isBuffering: boolean = false;
  private isSeeking: boolean = false;
  private pendingSeekPositionMs: number = -1;
  private isLive: boolean = false;
  private isSeekable: boolean = true;
  private errorMsg: string = '';
  private lastErrorCategory: PlaybackErrorCategory = 'unknown';
  private lastErrorCode: number = 0;
  private playWhenPrepared: boolean = false;
  private pendingSeekBeforePlay: boolean = false;
  private loadToken: number = 0;
  private surfaceBoundInInitialized: boolean = false;
  private stateWaiters: Array<(state: media.AVPlayerState) => boolean> = [];
  private lastTimeEmitMs: number = 0;
  private lastErrorEmitMs: number = 0;
  private subtitleUrls: string[] = [];
  private subtitleRegistered: boolean = false;

  async initialize(_config: EngineConfig): Promise<boolean> {
    try {
      await this.ensurePlayer();
      this.initialized = true;
      this.emitCurrentState();
      return true;
    } catch (e) {
      Logger.error(TAG, `initialize failed: ${this.describeError(e)}`);
      return false;
    }
  }

  private async ensurePlayer(): Promise<media.AVPlayer> {
    if (this.player && this.player.state !== 'released') {
      return this.player;
    }

    const player = await media.createAVPlayer();
    this.player = player;
    this.registerPlayerCallbacks(player);
    return player;
  }

  private classifyError(err: BusinessError): PlaybackErrorCategory {
    const msg = (err.message || '').toLowerCase();
    const code = err.code || 0;
    // URL expired / access denied patterns (includes 410 from proxy for upstream 403)
    if (msg.includes('401') || msg.includes('403') || msg.includes('404') ||
        msg.includes('410') || msg.includes('411') ||
        msg.includes('forbidden') || msg.includes('gone') || msg.includes('unauthorized') ||
        msg.includes('not found') || msg.includes('expired')) {
      return 'url_expired';
    }
    // Network patterns
    if (msg.includes('network') || msg.includes('timeout') || msg.includes('connection') ||
        msg.includes('io ') || msg.includes('reset') || msg.includes('refused') ||
        code === 5400102 || code === 5400103 || code === 5411004) {
      return 'network';
    }
    // Format / codec patterns
    if (msg.includes('format') || msg.includes('unsupported') || msg.includes('demux') ||
        msg.includes('codec') || msg.includes('decode') || code === 5400101 || code === 5400106) {
      return 'format';
    }
    // Source / manifest errors
    if (msg.includes('source') || msg.includes('manifest') || msg.includes('parser')) {
      return 'source';
    }
    return 'unknown';
  }

  private registerPlayerCallbacks(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState) => {
      Logger.debug(TAG, `stateChange: ${state}`);
      // 先处理临时 waiters，安全替代 on/off 临时注册
      this.stateWaiters = this.stateWaiters.filter(shouldContinue => shouldContinue(state));
      if (state === 'prepared') {
        this.isBuffering = false;
        this.isSeeking = false;
        this.errorMsg = '';
        this.isSeekable = player.duration >= 0;
        if (this.playWhenPrepared && !this.pendingSeekBeforePlay) {
          this.playInternal(player);
        }
      } else if (state === 'playing') {
        this.isBuffering = false;
      } else if (state === 'completed') {
        this.playWhenPrepared = false;
      } else if (state === 'stopped' || state === 'idle') {
        this.isBuffering = false;
        this.isSeeking = false;
      }
      this.emitCurrentState();
    });

    player.on('timeUpdate', (_timeMs: number) => {
      const now = Date.now();
      if (now - this.lastTimeEmitMs < 250) return;
      this.lastTimeEmitMs = now;
      this.emitCurrentState();
    });

    player.on('durationUpdate', (_durationMs: number) => {
      this.isSeekable = player.duration >= 0;
      this.emitCurrentState();
    });

    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        this.isBuffering = true;
        Logger.debug(TAG, `bufferingUpdate: START`);
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.isBuffering = false;
        Logger.debug(TAG, `bufferingUpdate: END`);
      } else if (infoType === media.BufferingInfoType.BUFFERING_PERCENT) {
        this.bufferingPercent = value;
      }
      this.emitCurrentState();
    });

    player.on('seekDone', (timeMs: number) => {
      this.isSeeking = false;
      this.pendingSeekPositionMs = -1;
      // 如果启播前有待执行的 seek，seek 完成后再播放，避免从 0 位置闪播
      if (this.pendingSeekBeforePlay) {
        this.pendingSeekBeforePlay = false;
        if (this.playWhenPrepared) {
          this.playInternal(player);
        }
      }
      // 用 seekDone 返回的准确时间更新状态，避免 player.currentTime 延迟
      this.emitCurrentState();
    });

    player.on('videoSizeChange', (_width: number, _height: number) => {
      this.emitCurrentState();
    });

    player.on('endOfStream', () => {
      this.playWhenPrepared = false;
      this.emitCurrentState();
    });

    player.on('error', (err: BusinessError) => {
      const errMsg = `[AVPlayer] ${err.code}: ${err.message}`;
      const now = Date.now();
      if (errMsg === this.errorMsg && now - this.lastErrorEmitMs < 1000) {
        return;
      }
      this.lastErrorEmitMs = now;
      const category = this.classifyError(err);
      this.lastErrorCategory = category;
      this.lastErrorCode = err.code || 0;
      this.errorMsg = errMsg;
      this.isBuffering = false;
      this.isSeeking = false;
      this.pendingSeekPositionMs = -1;
      Logger.error(TAG, `${this.errorMsg} [category=${category}]`);
      // 重置播放器回到 idle 状态，使上层有机会重新加载
      if (player.state !== 'released') {
        player.reset().catch((e: BusinessError) => {
          Logger.warn(TAG, `reset on error failed: ${this.describeError(e)}`);
        });
        this.surfaceBoundInInitialized = false;
      }
      this.emitCurrentState();
    });

    player.on('audioInterrupt', (info: audio.InterruptEvent) => {
      Logger.info(TAG, `audioInterrupt: hintType=${info.hintType}`);
      if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE) {
        // 其他应用抢占音频焦点（如来电），暂停播放
        this.playWhenPrepared = false;
        const p = this.player;
        if (p && p.state === 'playing') {
          p.pause().catch((e: BusinessError) => {
            Logger.warn(TAG, `pause on interrupt failed: ${this.describeError(e)}`);
          });
        }
        this.emitCurrentState();
      } else if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
        // 焦点归还，自动恢复播放
        this.playWhenPrepared = true;
        const p = this.player;
        if (p && this.canPlay(p.state)) {
          this.playInternal(p);
        }
        this.emitCurrentState();
      } else if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        // 视频播放器：STOP 和 PAUSE 一样处理，只暂停不停止
        // 调 stop() 会让 AVPlayer 进入 stopped 状态，之后无法通过 play() 恢复
        this.playWhenPrepared = false;
        const p = this.player;
        if (p && p.state === 'playing') {
          p.pause().catch((e: BusinessError) => {
            Logger.warn(TAG, `pause on interrupt stop failed: ${this.describeError(e)}`);
          });
        }
        this.emitCurrentState();
      }
    });

    player.on('subtitleUpdate', (info: media.SubtitleInfo) => {
      if (info) {
        this.subtitleCallback?.(info.text ?? '', info.startTime ?? 0, info.duration ?? 0);
      } else {
        this.subtitleCallback?.('', 0, 0);
      }
    });
    this.subtitleRegistered = true;
  }

  setStateCallback(cb: (state: PlaybackState) => void): void {
    this.stateCallback = cb;
  }

  setSubtitleCallback(cb: (text: string, startTime: number, duration: number) => void): void {
    this.subtitleCallback = cb;
  }

  registerLogCallback(_cb: (level: string, tag: string, message: string) => void): void {
    // System AVPlayer logs are reported through this ArkTS wrapper.
  }

  attachSurface(surfaceId: string): void {
    this.surfaceId = surfaceId;
    const player = this.player;
    if (!player || player.state === 'released') {
      return;
    }
    if (this.canApplySurface(player.state)) {
      this.applySurface(player);
    }
  }

  private applySurface(player: media.AVPlayer): void {
    if (this.surfaceId.length === 0) return;
    if (!this.canApplySurface(player.state)) {
      Logger.debug(TAG, `surface deferred, state=${player.state}`);
      return;
    }
    try {
      player.surfaceId = this.surfaceId;
      if (player.state === 'initialized') {
        this.surfaceBoundInInitialized = true;
      }
    } catch (e) {
      Logger.error(TAG, `attachSurface failed: ${this.describeError(e)}`);
    }
  }

  detachSurface(): void {
    // AVPlayer does not expose a detach API. Keep the id so a recreated player
    // can be rebound to the latest XComponent surface.
  }

  resizeSurface(_widthPx: number, _heightPx: number): void {
    // Rendering size is controlled by XComponent layout for system AVPlayer.
  }

  updateVideoRect(_x: number, _y: number, _w: number, _h: number): void {
    // Not needed for system AVPlayer.
  }

  load(source: string, startPos: number): boolean {
    this.sourceUrl = this.normalizeSourceUrl(source);
    this.playWhenPrepared = false;
    this.pendingSeekBeforePlay = false;
    const token = ++this.loadToken;
    const startMs = Math.max(0, startPos * 1000);
    if (startMs > 0) {
      this.pendingSeekBeforePlay = true;
    }
    Logger.info(TAG, `load: startPos=${startPos.toFixed(2)}s url=${this.sourceUrl.substring(0, 120)}`);
    this.loadInternal(this.sourceUrl, startMs, token);
    return true;
  }

  private async loadInternal(url: string, startMs: number, token: number): Promise<void> {
    try {
      const player = await this.ensurePlayer();
      await this.resetForNewSource(player);
      if (token !== this.loadToken) return;

      this.isLive = this.looksLive(url);
      this.isSeekable = !this.isLive;
      this.isBuffering = true;
      this.errorMsg = '';
      this.emitCurrentState();

      await this.setSource(player, url);
      await this.waitForPrepareAllowed(player, 3000);
      this.applySurface(player);
      await this.applySubtitleTracks(player);
      await player.prepare();
      const ready = await this.waitForPlayable(player, 7000);
      if (token !== this.loadToken) return;

      if (!ready) {
        this.errorMsg = `[AVPlayer] prepare timeout, state=${player.state}`;
        this.isBuffering = false;
        this.lastErrorCategory = 'network';
        Logger.error(TAG, this.errorMsg);
        this.emitCurrentState();
        return;
      }

      // prepared 之后设置 videoScaleType。SCALED_ASPECT = 保持原始比例，短边留黑边。
      try {
        player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
      } catch (_e) {
        // 部分设备可能不支持，忽略
      }

      // AVPlayer 不支持在 prepare 时设置起播位置，必须先 prepare 再 seek
      // 如果有历史进度，立即 seek（会触发二次缓冲，但这是 AVPlayer 的限制）
      if (startMs > 0 && !this.isLive) {
        Logger.info(TAG, `Seeking to resume position: ${startMs / 1000}s`);
        this.isSeeking = true;  // 标记为 seeking 状态，UI 可显示"正在恢复播放位置"
        this.emitCurrentState();
        this.seek(startMs / 1000, false);
      } else if (this.playWhenPrepared) {
        await this.playInternal(player);
      }
    } catch (e) {
      this.errorMsg = `[AVPlayer] load failed: ${this.describeError(e)}`;
      this.isBuffering = false;
      Logger.error(TAG, this.errorMsg);
      this.emitCurrentState();
    }
  }

  private async resetForNewSource(player: media.AVPlayer): Promise<void> {
    if (player.state === 'idle') {
      return;
    }
    if (player.state === 'released') {
      this.player = undefined;
      this.surfaceBoundInInitialized = false;
      return;
    }
    try {
      await player.reset();
      this.surfaceBoundInInitialized = false;
    } catch (e) {
      Logger.warn(TAG, `reset before load failed: ${this.describeError(e)}`);
    }
  }

  private async setSource(player: media.AVPlayer, url: string): Promise<void> {
    if (this.shouldUseMediaSource(url)) {
      try {
        const source = media.createMediaSourceWithUrl(url, {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36',
          'Referer': 'https://www.youtube.com/',
        });
        await player.setMediaSource(source);
        if (await this.waitForPrepareAllowed(player, 1500)) {
          return;
        }
        Logger.warn(TAG, `setMediaSource did not reach initialized, state=${player.state}; falling back to url`);
        await this.resetForNewSource(player);
      } catch (e) {
        Logger.warn(TAG, `setMediaSource failed, falling back to url: ${this.describeError(e)}`);
        await this.resetForNewSource(player);
      }
    }

    player.url = url;
  }

  private async waitForPrepareAllowed(player: media.AVPlayer, timeoutMs: number): Promise<boolean> {
    if (this.isPrepareAllowed(player.state)) {
      return true;
    }

    return new Promise<boolean>((resolve) => {
      let done = false;
      const timer = setTimeout(() => {
        done = true;
        Logger.warn(TAG, `waitForPrepareAllowed timeout, state=${player.state}`);
        resolve(false);
      }, timeoutMs);

      const waiter = (state: media.AVPlayerState): boolean => {
        if (done) return false;
        if (this.isPrepareAllowed(state)) {
          done = true;
          clearTimeout(timer);
          resolve(true);
          return false;
        } else if (state === 'error' || state === 'released') {
          done = true;
          clearTimeout(timer);
          resolve(false);
          return false;
        }
        return true;
      };

      this.stateWaiters.push(waiter);
    });
  }

  play(): void {
    this.playWhenPrepared = true;
    const player = this.player;
    if (!player || player.state === 'released') {
      return;
    }
    if (this.canPlay(player.state)) {
      this.playInternal(player);
      return;
    }
    Logger.debug(TAG, `play deferred, state=${player.state}`);
  }

  private async playInternal(player: media.AVPlayer): Promise<void> {
    try {
      if (!this.canPlay(player.state)) {
        Logger.debug(TAG, `playInternal deferred, state=${player.state}`);
        return;
      }
      await player.play();
      this.playWhenPrepared = true;
    } catch (e) {
      Logger.error(TAG, `play failed: ${this.describeError(e)}`);
    }
  }

  pause(): void {
    this.playWhenPrepared = false;
    const player = this.player;
    if (!player || player.state !== 'playing') {
      return;
    }
    player.pause().catch((e: BusinessError) => {
      Logger.error(TAG, `pause failed: ${this.describeError(e)}`);
    });
  }

  seek(positionSec: number, keyframe: boolean = false): void {
    const player = this.player;
    if (!player || !this.canSeek(player.state) || this.isLive) {
      return;
    }
    try {
      this.isSeeking = true;
      const targetMs = Math.max(0, Math.round(positionSec * 1000));
      this.pendingSeekPositionMs = targetMs;
      const mode = keyframe ? media.SeekMode.SEEK_PREV_SYNC : media.SeekMode.SEEK_CLOSEST;
      Logger.debug(TAG, `seek: target=${positionSec.toFixed(2)}s keyframe=${keyframe}`);
      player.seek(targetMs, mode);
      this.emitCurrentState();
    } catch (e) {
      this.isSeeking = false;
      this.pendingSeekPositionMs = -1;
      Logger.error(TAG, `seek failed: ${this.describeError(e)}`);
      this.emitCurrentState();
    }
  }

  stop(): void {
    this.playWhenPrepared = false;
    const player = this.player;
    if (!player || !this.canStop(player.state)) {
      return;
    }
    player.stop().catch((e: BusinessError) => {
      Logger.error(TAG, `stop failed: ${this.describeError(e)}`);
    });
  }

  setPlaybackSpeed(speed: number): void {
    if (speed <= 0) return;
    Logger.debug(TAG, `setPlaybackSpeed: ${speed}x`);
    this.playbackSpeed = speed;
    const player = this.player;
    if (!player || !this.canSeek(player.state)) {
      return;
    }
    try {
      player.setPlaybackRate(speed);
    } catch (e) {
      Logger.warn(TAG, `setPlaybackRate failed: ${this.describeError(e)}`);
    }
    this.emitCurrentState();
  }

  switchQuality(source: string, resumePos: number): boolean {
    this.playWhenPrepared = true;
    return this.load(source, resumePos);
  }

  prebufferTargetQuality(_videoUrl: string, _audioUrl: string = ''): number {
    return 0;
  }

  switchToPrebuffered(_videoHandle: number, _audioHandle: number, _resumePos: number): boolean {
    return false;
  }

  preloadSubtitleTracks(urls: string[]): void {
    this.subtitleUrls = urls;
  }

  private async applySubtitleTracks(player: media.AVPlayer): Promise<void> {
    if (this.subtitleUrls.length === 0) return;
    for (const url of this.subtitleUrls) {
      try {
        await player.addSubtitleFromUrl(url);
        Logger.debug(TAG, `Subtitle loaded: ${url.substring(0, 80)}`);
      } catch (e) {
        Logger.warn(TAG, `addSubtitleFromUrl failed: ${this.describeError(e)}`);
      }
    }
  }

  selectSubtitleTrack(_index: number): void {
    // AVPlayer external subtitles do not support track index selection;
    // switching is done by reloading with a different URL via preloadSubtitleTracks.
  }

  setSubtitleVisible(visible: boolean): void {
    const player = this.player;
    if (!player || player.state === 'released') return;
    if (visible) {
      if (!this.subtitleRegistered) {
        player.on('subtitleUpdate', (info: media.SubtitleInfo) => {
          if (info) {
            this.subtitleCallback?.(info.text ?? '', info.startTime ?? 0, info.duration ?? 0);
          } else {
            this.subtitleCallback?.('', 0, 0);
          }
        });
        this.subtitleRegistered = true;
      }
    } else {
      player.off('subtitleUpdate');
      this.subtitleRegistered = false;
      this.subtitleCallback?.('', 0, 0);
    }
  }

  setSubtitleDelay(_delayMs: number): void {
    // System AVPlayer does not expose subtitle delay control in this API level.
  }

  getSubtitleDelay(): number {
    return 0;
  }

  setSubtitleStyle(_position: string, _fontSize: number, _color: string, _bgAlpha: number): void {
    // System AVPlayer subtitle styling is not exposed through this wrapper.
  }

  setSubtitleAutoSync(_enabled: boolean): void {
    // Not supported by system AVPlayer.
  }

  setVideoOutputEnabled(enabled: boolean): void {
    const player = this.player;
    if (!player || !this.canSeek(player.state)) {
      return;
    }
    try {
      player.setMediaMuted(media.MediaType.MEDIA_TYPE_VID, !enabled).catch((e: BusinessError) => {
        Logger.warn(TAG, `setMediaMuted video failed: ${this.describeError(e)}`);
      });
    } catch (e) {
      Logger.warn(TAG, `setVideoOutputEnabled failed: ${this.describeError(e)}`);
    }
  }

  setHwdecMode(_mode: string): void {
    // Hardware decode selection is controlled by the system AVPlayer.
  }

  getState(): PlaybackState {
    return this.buildState();
  }

  getBandwidthEstimateBps(): number {
    return 1_000_000;
  }

  destroy(): void {
    this.initialized = false;
    this.playWhenPrepared = false;
    this.loadToken++;
    this.stateWaiters = [];
    const player = this.player;
    this.player = undefined;
    if (!player || player.state === 'released') {
      return;
    }
    try {
      player.off('stateChange');
      player.off('timeUpdate');
      player.off('durationUpdate');
      player.off('bufferingUpdate');
      player.off('seekDone');
      player.off('videoSizeChange');
      player.off('endOfStream');
      player.off('error');
      player.off('audioInterrupt');
      player.off('subtitleUpdate');
      this.subtitleRegistered = false;
      this.subtitleUrls = [];
    } catch (e) {
      Logger.warn(TAG, `unregister callbacks failed: ${this.describeError(e)}`);
    }
    player.release().catch((e: BusinessError) => {
      Logger.error(TAG, `release failed: ${this.describeError(e)}`);
    });
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  private emitCurrentState(): void {
    this.stateCallback?.(this.buildState());
  }

  private buildState(): PlaybackState {
    const player = this.player;
    const avState: media.AVPlayerState = player?.state ?? 'idle';
    const isPlaying = avState === 'playing';
    const isReady = avState === 'prepared' || avState === 'playing' || avState === 'paused' || avState === 'completed';
    const durationMs = player?.duration ?? 0;
    let currentMs = player?.currentTime ?? 0;
    // seek 期间使用目标位置，避免系统播控进度条跳回旧位置
    if (this.isSeeking && this.pendingSeekPositionMs >= 0) {
      currentMs = this.pendingSeekPositionMs;
    }

    const engineState = this.mapState(avState);
    return {
      engineState: engineState,
      isPlaying: isPlaying,
      isReady: isReady,
      isBuffering: this.isBuffering,
      isSeeking: this.isSeeking,
      isEnded: avState === 'completed',
      isLive: this.isLive,
      isSeekable: this.isSeekable,
      currentTime: currentMs > 0 ? currentMs / 1000 : 0,
      duration: durationMs > 0 ? durationMs / 1000 : 0,
      playbackSpeed: this.playbackSpeed,
      bufferingPercent: this.bufferingPercent,
      uri: this.sourceUrl,
      mediaTitle: '',
      containerFormat: '',
      videoWidth: player?.width ?? 0,
      videoHeight: player?.height ?? 0,
      videoStreamCount: 0,
      audioStreamCount: 0,
      subtitleStreamCount: 0,
      errorMsg: this.errorMsg,
      errorCategory: this.errorMsg ? this.lastErrorCategory : undefined,
      errorCode: this.errorMsg ? this.lastErrorCode : undefined,
    };
  }

  private mapState(state: media.AVPlayerState): PlaybackEngineState {
    if (this.isBuffering) return 'buffering';
    if (state === 'playing') return 'playing';
    if (state === 'paused' || state === 'prepared' || state === 'completed') return 'paused';
    return 'stopped';
  }

  private canPlay(state: media.AVPlayerState): boolean {
    return state === 'prepared' || state === 'paused' || state === 'completed';
  }

  private canSeek(state: media.AVPlayerState): boolean {
    return state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed';
  }

  private canStop(state: media.AVPlayerState): boolean {
    return state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed';
  }

  private isPrepareAllowed(state: media.AVPlayerState): boolean {
    return state === 'initialized' || state === 'stopped';
  }

  private async waitForPlayable(player: media.AVPlayer, timeoutMs: number): Promise<boolean> {
    if (this.canPlay(player.state)) {
      return true;
    }

    return new Promise<boolean>((resolve) => {
      let done = false;
      const timer = setTimeout(() => {
        done = true;
        Logger.warn(TAG, `waitForPlayable timeout, state=${player.state}`);
        resolve(false);
      }, timeoutMs);

      const waiter = (state: media.AVPlayerState): boolean => {
        if (done) return false;
        if (this.canPlay(state)) {
          done = true;
          clearTimeout(timer);
          resolve(true);
          return false;
        } else if (state === 'error' || state === 'released' || state === 'idle') {
          done = true;
          clearTimeout(timer);
          resolve(false);
          return false;
        }
        return true;
      };

      this.stateWaiters.push(waiter);
    });
  }

  private canApplySurface(state: media.AVPlayerState): boolean {
    if (state === 'initialized') {
      return true;
    }
    if (!this.surfaceBoundInInitialized) {
      return false;
    }
    return state === 'prepared' || state === 'playing' || state === 'paused' ||
      state === 'completed' || state === 'stopped';
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

  private shouldUseMediaSource(url: string): boolean {
    const lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://') ||
      lower.endsWith('.mpd') || lower.includes('.mpd?') ||
      lower.endsWith('.m3u8') || lower.includes('.m3u8?');
  }

  private describeError(e: Object): string {
    const err = e as BusinessError;
    if (err && err.message) {
      return `${err.code}: ${err.message}`;
    }
    return String(e);
  }
}
