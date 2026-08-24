/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0
 */

import { VideoData, StreamInfo } from '../model/VideoData';
import { PlayerModel, StreamCategories, CurrentStreams, VideoEntry } from '../model/PlayerModel';
import { PlaybackEngine, PlaybackState, PlaybackStats, EngineConfig } from '../engine/PlaybackEngine';
import { MpvPlaybackEngine } from '../engine/MpvPlaybackEngine';
import { VideoHwCaps } from '../engine/VideoHwCaps';
import { LocalMediaProxy } from './LocalMediaProxy';
import { AvSessionManager } from '../common/AvSessionManager';
import { BackgroundTaskManager } from '../common/BackgroundTaskManager';
import { PlaybackPreferences } from '../common/PlaybackPreferences';
import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { PlayerStateRelay, ProgressSubscriber, PlaybackStateSubscriber } from '../state/PlayerStateRelay';
import { PlayerStateMachine, StateChangeListener } from '../state/PlayerStateMachine';
import { PlayerState } from '../state/PlayerState';
import { PlayerUiViewModel } from '../state/PlayerUiViewModel';
import Logger from '../utils/Logger';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { HttpDownloader, parseHlsMasterManifest } from 'youtube_core';

export interface NativeLogBridgeFns {
  start: () => void;
  stop: () => void;
}

const TAG: string = '[PlayerLog][AvPlayerController]';

@Observed
export class AvPlayerController {
  @Track public vm: PlayerUiViewModel = new PlayerUiViewModel();
  /** Surface 句柄；由 UI 在 XComponent.onLoad 写入，非响应式状态。 */
  public surfaceID: string = '';
  public onCastStateChange: ((isCasting: boolean, deviceName: string) => void) | undefined = undefined;
  public onNextCommand: (() => void) | undefined = undefined;
  public onPreviousCommand: (() => void) | undefined = undefined;

  // 静态配置回调，由 entry 层注入
  private static engineConfigProvider: (() => EngineConfig) | null = null;

  public static setEngineConfigProvider(provider: () => EngineConfig): void {
    AvPlayerController.engineConfigProvider = provider;
  }

  private curIndex: number = 0;
  private curSource: VideoData;
  private playbackEngine: PlaybackEngine = new MpvPlaybackEngine();
  private avSessionManager: AvSessionManager = AvSessionManager.getInstance();
  private stateMachine: PlayerStateMachine = new PlayerStateMachine();
  private stateRelay: PlayerStateRelay = new PlayerStateRelay();
  private backgroundTaskListener: StateChangeListener | null = null;
  private backgroundTaskActive: boolean = false;
  private engineInitPromise: Promise<boolean> | null = null;
  private mediaInitPromise: Promise<void> | null = null;
  /** Invalidates every async source/proxy operation from a closed media session. */
  private mediaSessionGeneration: number = 0;

  private errorListeners: Set<(errorMsg: string) => void> = new Set();
  private waitingForBufferListeners: Set<(isWaiting: boolean) => void> = new Set();
  private seekableRangesListeners: Set<() => void> = new Set();

  private currentLocalMediaSessionId: string = '';
  private pendingDestroySessionId: string = '';
  /** EDL dual-track playback uses a second (audio) single-url session beside the main one. */
  private currentEdlAudioSessionId: string = '';
  private pendingDestroyEdlAudioSessionId: string = '';
  /** Prevent outgoing MPV snapshots from being routed into a newly-created local media session. */
  private localTimelineAwaitingReady: boolean = false;
  private localTimelineExpectedStartMs: number = 0;
  private localTimelineMismatchLogged: boolean = false;
  private pendingStartFromSec: number = 0;
  private startupAttemptId: string = '';
  private startupStartedAt: number = 0;
  private startupFileLoadedLogged: boolean = false;
  private startupPlaybackRestartLogged: boolean = false;
  private startupFirstFrameLogged: boolean = false;
  private avSessionArtworkPublished: boolean = false;

  // Error recovery state
  private errorRetryCount: number = 0;
  private isRecovering: boolean = false;
  private readonly MAX_ERROR_RETRIES = 2;
  private lastKnownGoodPosition: number = 0;
  /**
   * Quality/audio switch in flight: keep spinner on while proxy rebuilds + engine reloads.
   * loadStarted becomes true only after createPlaybackUrl finishes and load() is called,
   * so stale engine snapshots cannot clear the spinner early.
   */
  private qualitySwitchPending: boolean = false;
  private qualitySwitchLoadStarted: boolean = false;

  // Audio focus state (player-side handler for system hints — scheme A)
  /** Temporary focus loss (PAUSE): auto-resume on RESUME. */
  private systemPausedByFocus: boolean = false;
  /** Permanent focus loss (STOP): do not auto-resume. */
  private systemStoppedByFocus: boolean = false;
  private duckActive: boolean = false;
  /** Snapshot for diagnostics / future UI; system owns duck gain on AudioSession path. */
  private savedVolume: number = 100;
  public onErrorNeedsUserAction?: (errorMsg: string) => void;
  /**
   * 同 URL 快速重试耗尽后的升级钩子:由 entry(PlayerSession)注入,
   * 重新提取当前视频的新鲜流 URL 并原地重载(对齐 PipePipe
   * setRecovery+reloadPlayQueueManager / SmartTube reloadVideo ——
   * 媒体层瞬时错误永不跳下一首)。
   */
  public onRetryWithFreshStreams?: (resumePosSec: number) => void;

  getLastKnownGoodPosition(): number {
    return this.lastKnownGoodPosition;
  }

  get playerState(): PlayerState {
    return this.stateMachine.currentState;
  }

  getPlayerStateMachine(): PlayerStateMachine {
    return this.stateMachine;
  }

  addStateListener(listener: StateChangeListener): void {
    this.stateMachine.addListener(listener);
  }

  removeStateListener(listener: StateChangeListener): void {
    this.stateMachine.removeListener(listener);
  }

  isActive(): boolean {
    return this.stateMachine.currentState !== PlayerState.RELEASED
      && this.stateMachine.currentState !== PlayerState.IDLE;
  }

  getPlaybackState(): PlaybackState {
    return this.playbackEngine.getState();
  }

  /** Live playback statistics (Stats-for-Nerds style); all zeros until the engine is initialized. */
  getPlaybackStats(): PlaybackStats {
    if (!this.playbackEngine.isInitialized()) {
      return {
        cacheSpeedBps: 0,
        demuxerCacheDurationSec: 0,
        droppedFrames: 0,
        decoderDroppedFrames: 0
      };
    }
    return this.playbackEngine.getPlaybackStats();
  }

  refreshPlaybackState(): void {
    if (this.stateMachine.isOneOf(PlayerState.RELEASED, PlayerState.IDLE)) {
      return;
    }
    this.onPlaybackStateChange(this.playbackEngine.getState());
  }

  constructor(curSource: VideoData) {
    this.curSource = curSource;
    if (curSource.streams) {
      this.vm.playerModel.classifyStreams(curSource.streams);
    }
  }

  /**
   * 订阅节流后的进度更新（currentTime 高频变动，通过此接口而非 @Track 绑定）
   */
  public subscribeProgress(listener: ProgressSubscriber): void {
    this.stateRelay.subscribeProgress(listener);
  }
  public unsubscribeProgress(listener: ProgressSubscriber): void {
    this.stateRelay.unsubscribeProgress(listener);
  }

  public subscribePlaybackState(listener: PlaybackStateSubscriber): void {
    this.stateRelay.subscribePlaybackState(listener);
  }

  public unsubscribePlaybackState(listener: PlaybackStateSubscriber): void {
    this.stateRelay.unsubscribePlaybackState(listener);
  }
  public subscribeEnded(listener: () => void): void {
    this.stateRelay.subscribeEnded(listener);
  }
  public unsubscribeEnded(listener: () => void): void {
    this.stateRelay.unsubscribeEnded(listener);
  }

  public addErrorListener(listener: (errorMsg: string) => void): void { this.errorListeners.add(listener); }
  public removeErrorListener(listener: (errorMsg: string) => void): void { this.errorListeners.delete(listener); }
  public getUserVisibleError(): string { return this.vm.userVisibleErrorMsg; }
  public addWaitingForBufferListener(listener: (isWaiting: boolean) => void): void { this.waitingForBufferListeners.add(listener); }
  public removeWaitingForBufferListener(listener: (isWaiting: boolean) => void): void { this.waitingForBufferListeners.delete(listener); }
  public addSeekableRangesListener(listener: () => void): void { this.seekableRangesListeners.add(listener); }
  public removeSeekableRangesListener(listener: () => void): void { this.seekableRangesListeners.delete(listener); }

  public getStreamCategories(): StreamCategories { return this.vm.playerModel.getStreamCategories(); }
  public getCurrentStreams(): CurrentStreams { return this.vm.playerModel.getCurrentStreams(); }
  public updateVideoStream(stream: StreamInfo): void { this.vm.playerModel.updateVideoStream(stream); }
  public updateAudioStream(stream: StreamInfo | undefined): void { this.vm.playerModel.updateAudioStream(stream); }
  public setCurIndex(curIndex: number): void { this.curIndex = curIndex; }
  public setIsPlaying(isPlaying: boolean): void { this.vm.isPlaying = isPlaying; }

  public setStartupAttempt(attemptId: string, startedAt: number): void {
    this.startupAttemptId = attemptId;
    this.startupStartedAt = startedAt;
    this.startupFileLoadedLogged = false;
    this.startupPlaybackRestartLogged = false;
    this.startupFirstFrameLogged = false;
  }

  public getMergedVideoList(): VideoEntry[] {
    // Full quality list — manual switch is always allowed (including 4K VP9/AV1).
    // Auto-start still prefers hardware-friendly codecs via selectBestVideoEntry.
    return this.vm.playerModel.getMergedVideoList();
  }

  public getCurrentVideoIndex(): number {
    const list = this.getMergedVideoList();
    const cur = this.vm.playerModel.getCurrentStreams().video;
    return cur ? list.findIndex(e => e.stream === cur) : -1;
  }

  public async switchToVideoEntry(entry: VideoEntry): Promise<void> {
    // 点击瞬间就亮转圈（不要等选 audio / createPlaybackUrl）
    this.beginSourceSwitchUi();
    let audio: StreamInfo | undefined = undefined;
    if (this.requiresSeparateAudio(entry.stream)) {
      const cats = this.vm.playerModel.getStreamCategories();
      // Keep current audio track when switching video quality.
      const curAudio = this.vm.playerModel.getCurrentStreams().audio;
      const currentTrackId = (curAudio?.audioTrackId || curAudio?.audioLanguage || '').trim();
      if (currentTrackId.length > 0) {
        const sameTrack = cats.audio.filter((s: StreamInfo) => {
          const id = (s.audioTrackId || s.audioLanguage || '').trim();
          return id === currentTrackId;
        });
        audio = this.selectBestCompatibleAudio(entry.stream, sameTrack.length > 0 ? sameTrack : cats.audio);
      } else {
        audio = this.selectBestCompatibleAudio(entry.stream, cats.audio);
      }
    }
    await this.switchQuality(entry.stream, audio);
  }

  /**
   * Live quality management: entry pushes background-parsed HLS variants here
   * after playback already started. Never blocks the startup path.
   */
  public addLiveHlsVariants(variants: StreamInfo[]): void {
    if (!this.isActive() || this.curSource?.isLive !== true || variants.length === 0) {
      return;
    }
    this.vm.playerModel.mergeLiveHlsVariants(variants, this.curSource?.hlsUrl || '');
    Logger.info(TAG, `live HLS variants merged count=${variants.length}`);
  }

  public getAudioStreamList(): StreamInfo[] {
    const all = this.vm.playerModel.getAudioStreamList();
    const video = this.vm.playerModel.getCurrentStreams().video;
    const groups: Map<string, StreamInfo[]> = new Map();
    for (const stream of all) {
      // audioTrackId is the stable identity for original/dubbed tracks. Fall back to
      // locale/name only for older responses which do not expose an id.
      const key = (stream.audioTrackId || stream.audioLanguage || stream.audioTrackName || 'default').trim();
      const group = groups.get(key) || [];
      group.push(stream);
      groups.set(key, group);
    }
    const representatives: StreamInfo[] = [];
    groups.forEach((group: StreamInfo[]) => {
      const selected = video
        ? this.selectBestCompatibleAudio(video, group)
        : group.slice().sort((a: StreamInfo, b: StreamInfo): number =>
          this.audioFormatPriority(b) - this.audioFormatPriority(a))[0];
      if (selected) {
        representatives.push(selected);
      }
    });
    return representatives;
  }

  public getCurrentAudioIndex(): number {
    const list = this.getAudioStreamList();
    const current = this.vm.playerModel.getCurrentStreams().audio;
    if (!current) {
      return 0;
    }
    const currentKey = (current.audioTrackId || current.audioLanguage
      || current.audioTrackName || 'default').trim();
    const index = list.findIndex((stream: StreamInfo) =>
      (stream.audioTrackId || stream.audioLanguage || stream.audioTrackName || 'default').trim() === currentKey);
    return index >= 0 ? index : 0;
  }

  /** Switch to a specific audio stream (by list index); keeps video + resume position. */
  public async switchToAudioIndex(index: number): Promise<void> {
    if (!this.isActive()) {
      return;
    }
    const list = this.getAudioStreamList();
    if (index < 0 || index >= list.length) {
      return;
    }
    const audio = list[index];
    const video = this.vm.playerModel.getCurrentStreams().video;
    if (!video || !audio) {
      return;
    }
    const cur = this.vm.playerModel.getCurrentStreams().audio;
    if (cur && cur.itag === audio.itag
      && (cur.audioTrackId || '') === (audio.audioTrackId || '')
      && (cur.bitrate || 0) === (audio.bitrate || 0)) {
      return;
    }
    // Honor exact user pick: do not re-rank by language. Compatibility may still
    // reject container mismatch and fall back inside switchQuality.
    Logger.info(TAG, `switchToAudioIndex: ${index} `
      + `${audio.audioTrackName || audio.audioLanguage || '-'} itag=${audio.itag} `
      + `track=${audio.audioTrackId || '-'}`);
    this.beginSourceSwitchUi();
    await this.switchQuality(video, audio);
  }

  /** Menu click → immediate spinner; cleared when new source is ready or switch fails. */
  private beginSourceSwitchUi(): void {
    this.qualitySwitchPending = true;
    this.qualitySwitchLoadStarted = false;
    this.vm.isSourceSwitching = true;
    this.vm.isBuffering = true;
  }

  private endSourceSwitchUi(keepBuffering: boolean = false): void {
    this.qualitySwitchPending = false;
    this.qualitySwitchLoadStarted = false;
    this.vm.isSourceSwitching = false;
    if (!keepBuffering) {
      this.vm.isBuffering = false;
    }
  }

  public setPendingStartFromSec(sec: number): void {
    this.pendingStartFromSec = sec > 0 ? sec : 0;
    Logger.debug(TAG, `Pending start position set to ${this.pendingStartFromSec}s`);
  }

  public async initPlaybackEngine(): Promise<void> {
    const requestedGeneration = this.mediaSessionGeneration;
    if (this.mediaInitPromise) {
      await this.mediaInitPromise;
      if (this.isMediaSessionCurrent(requestedGeneration)
        && this.stateMachine.isOneOf(PlayerState.IDLE)) {
        await this.initPlaybackEngine();
      }
      return;
    }
    if (this.stateMachine.isOneOf(PlayerState.LOADING, PlayerState.READY,
      PlayerState.PLAYING, PlayerState.PAUSED, PlayerState.BUFFERING)) {
      Logger.debug(TAG, 'initPlaybackEngine skipped: media session already initialized');
      return;
    }
    let task: Promise<void>;
    task = this.initializeMediaSession().finally(() => {
      if (this.mediaInitPromise === task) {
        this.mediaInitPromise = null;
      }
    });
    this.mediaInitPromise = task;
    await task;
  }

  private async initializeMediaSession(): Promise<void> {
    // 先检查引擎是否已初始化，避免从 LOADING 等状态尝试非法转换
    if (this.stateMachine.isOneOf(PlayerState.INITIALIZING, PlayerState.LOADING, PlayerState.READY,
      PlayerState.PLAYING, PlayerState.PAUSED, PlayerState.BUFFERING)) {
      Logger.debug(TAG, 'initPlaybackEngine skipped: engine already initialized');
      return;
    }
    if (!this.stateMachine.transition(PlayerState.INITIALIZING)) {
      Logger.warn(TAG, `initPlaybackEngine skipped: invalid state ${this.stateMachine.currentState}`);
      return;
    }

    // 初始化状态路由层
    this.stateRelay.setStateMachine(this.stateMachine);
    this.stateRelay.setAvSession(this.avSessionManager);

    // 注册后台任务监听器：进入活跃播放状态启动 ContinuousTask，回到 IDLE/RELEASED 时停止。
    this.attachBackgroundTaskListener();

    const generation = this.mediaSessionGeneration;
    await this.avSessionManager.init();
    if (!this.isMediaSessionCurrent(generation)) {
      return;
    }
    this.configureAvSessionCallbacks();

    const ok = await this.ensurePlaybackEngineInitialized();
    if (!this.isMediaSessionCurrent(generation)) {
      return;
    }
    if (!ok) {
      this.stateMachine.transition(PlayerState.ERROR);
    }
  }

  /** Startup-only warmup: initialize MPV without AVSession or background-task registration. */
  public async prewarmPlaybackEngine(): Promise<void> {
    const ok = await this.ensurePlaybackEngineInitialized();
    if (!ok) {
      throw new Error('MPV prewarm failed');
    }
  }

  private configureAvSessionCallbacks(): void {
    this.avSessionManager.onPlayCommand = () => {
      this.syncPlay();
    };
    this.avSessionManager.onPauseCommand = () => {
      this.syncPause();
    };
    this.avSessionManager.onSeekCommand = (positionSec: number) => {
      this.playbackEngine.seek(positionSec, false);
    };
    this.avSessionManager.onFastForwardCommand = (skipIntervalSec?: number) => {
      const skip = skipIntervalSec ?? 15;
      const newTime = Math.min(this.vm.durationTime || Infinity, this.vm.currentTime + skip);
      this.playbackEngine.seek(newTime, false);
      if (!this.vm.isPlaying) {
        this.playbackEngine.play();
      }
    };
    this.avSessionManager.onRewindCommand = (skipIntervalSec?: number) => {
      const skip = skipIntervalSec ?? 15;
      const newTime = Math.max(0, this.vm.currentTime - skip);
      this.playbackEngine.seek(newTime, false);
      if (!this.vm.isPlaying) {
        this.playbackEngine.play();
      }
    };
    this.avSessionManager.onNextCommand = () => {
      this.onNextCommand?.();
    };
    this.avSessionManager.onPreviousCommand = () => {
      this.onPreviousCommand?.();
    };
    this.avSessionManager.onStopCommand = () => {
      this.syncStop();
    };
    this.avSessionManager.onCastStateChange = (isCasting: boolean, deviceName: string) => {
      this.vm.isCasting = isCasting;
      this.vm.castDeviceName = deviceName;
      this.onCastStateChange?.(isCasting, deviceName);
    };

    // Scheme A: single player entry for all system audio-focus hints.
    this.avSessionManager.onAudioFocusHint = (hint) => {
      this.handleAudioFocusHint(hint);
    };
  }

  private async ensurePlaybackEngineInitialized(): Promise<boolean> {
    if (this.playbackEngine.isInitialized()) {
      return true;
    }
    if (this.engineInitPromise) {
      return await this.engineInitPromise;
    }
    const task = this.playbackEngine.initialize(AvPlayerController.engineConfigProvider?.() ?? {});
    this.engineInitPromise = task;
    try {
      const ok = await task;
      if (ok) {
        this.playbackEngine.setStateCallback((state: PlaybackState) => this.onPlaybackStateChange(state));
        this.playbackEngine.setSubtitleCallback((text: string, _startTime: number, _duration: number) => {
          this.vm.subtitleText = text;
        });
        if (this.surfaceID.length > 0) {
          this.playbackEngine.attachSurface(this.surfaceID);
        }
      }
      return ok;
    } finally {
      if (this.engineInitPromise === task) {
        this.engineInitPromise = null;
      }
    }
  }

  public async initAVPlayer(): Promise<void> {
    await this.initPlaybackEngine();
  }

  public async updateVideoSource(newSource: VideoData): Promise<void> {
    if (this.stateMachine.isOneOf(PlayerState.RELEASED)) return;
    const generation = this.mediaSessionGeneration;

    if (!newSource.streams || newSource.streams.length === 0) {
      Logger.debug(TAG, `updateVideoSource ignored: no streams videoId=${newSource.videoId || 'N/A'}`);
      return;
    }

    // Source submission has a single writer (PlayerSession.play()); duplicate
    // suppression lives there. A submission here always means a real load.
    this.resetPlaybackState();
    this.deferCurrentSessionDestroy();
    this.curSource = newSource;
    this.curIndex = newSource.index;
    // 不要用视频原生分辨率播种 ohos-surface-size。
    // 该属性必须等于 XComponent 布局像素（AVPlayer onAreaChange → resizeSurface）。
    // 用 stream WxH 会在小窗阶段把 VO 配成「片源分辨率」而非「窗口像素」，
    // 画面被软缩放/压小，全屏 onAreaChange 才纠正——表现为小窗糊、全屏立刻清晰。
    // video chain 缺宽高时依赖：① 上次布局缓存 ② XComponent onAreaChange →
    // setVideoSurfaceSize（产品路径）。③ libmpv_napi 的 native OnSurfaceChanged 属
    // MpvPlayerView/libraryname 备路，产品内联 XComponent（无 libraryname）不触发。
    // 切勿用片源尺寸顶替布局尺寸。
    this.vm.subtitleTracks = newSource.subtitleTracks || [];
    // 优先从 newSource 的流信息中恢复 duration，避免后续 resolveDurationMs 取到 0
    if (newSource.streams && newSource.streams.length > 0) {
      const ms = newSource.streams[0].approxDurationMs || 0;
      if (ms > 0) {
        this.vm.durationTime = ms / 1000;
      }
    }

    Logger.info(TAG, `updateVideoSource: videoId=${newSource.videoId || 'N/A'} streams=${newSource.streams?.length || 0} isLive=${newSource.isLive} subtitles=${newSource.subtitleTracks?.length || 0} pendingStart=${this.pendingStartFromSec}s`);

    const prefs = PlaybackPreferences.snapshot();
    const searchLanguage = prefs.searchLanguage;
    this.vm.playerModel.classifyStreams(newSource.streams, searchLanguage);

    if (!this.selectInitialStreams(newSource.isLive === true)) {
      Logger.warn(TAG, `selectInitialStreams failed: no supported stream found`);
      this.setError('[API] NO_SUPPORTED_STREAM');
      return;
    }

    await this.initPlaybackEngine();
    if (!this.isMediaSessionCurrent(generation)
      || this.stateMachine.isOneOf(PlayerState.RELEASED, PlayerState.IDLE)) return;

    if (!this.stateMachine.transition(PlayerState.LOADING)) {
      // 极端情况：转换被拒绝（例如 ERROR 之外的非法源状态），强制对齐到 LOADING
      Logger.warn(TAG, `LOADING transition rejected from ${this.stateMachine.currentState}, forcing`);
      this.stateMachine.forceTransition(PlayerState.LOADING);
    }

    // Live streams: use HLS manifest URL directly, skip local proxy
    if (newSource.isLive && newSource.hlsUrl) {
      Logger.info(TAG, `Live stream detected, using HLS manifest directly: ${this.describePlaybackUrl(newSource.hlsUrl)}`);
      const playbackUrl = await this.resolveManifestPlaybackUrl(newSource.hlsUrl, true);
      if (!this.isMediaSessionCurrent(generation)) return;
      if (!playbackUrl) {
        this.setError('[PLAYER] LOCAL_PROXY_FAILED');
        return;
      }
      this.updateAvSessionMetadata(false);
      this.vm.isBuffering = true;
      this.loadPlaybackSource(playbackUrl, 0, generation);
      if (newSource.play || newSource.auto) {
        this.avSessionManager.activateForPlayback();
        this.playbackEngine.play();
      }
      return;
    }

    const current = this.vm.playerModel.getCurrentStreams();
    const playbackUrl = await this.resolveManifestPlaybackUrl(
      await this.createPlaybackUrl(current.video, current.audio, generation),
      newSource.isLive === true
    );
    if (!this.isMediaSessionCurrent(generation)) return;
    if (!playbackUrl) {
      this.setError('[PLAYER] LOCAL_PROXY_FAILED');
      return;
    }

    this.updateAvSessionMetadata(false);
    this.vm.isBuffering = true;
    this.vm.currentSubtitleUrl = '';
    const startPos = this.pendingStartFromSec;
    this.pendingStartFromSec = 0;
    Logger.info(TAG,
      `load mpv: ${current.video?.height}p codec=${current.video?.codecs} ` +
      `hw=${VideoHwCaps.isCodecHardwareFriendly(current.video?.codecs)}`);
    this.loadPlaybackSource(playbackUrl, startPos, generation);
    if (newSource.play || newSource.auto) {
      this.avSessionManager.activateForPlayback();
      this.playbackEngine.play();
    }
  }

  public async switchQuality(videoStream: StreamInfo, audioStream?: StreamInfo): Promise<void> {
    if (!this.isActive() || !videoStream) return;
    const generation = this.mediaSessionGeneration;
    const wasPlaying = this.vm.isPlaying;
    const resumePos = this.vm.currentTime;
    const effectiveAudio = this.isSeparatedDash(videoStream, audioStream) ? this.ensureCompatibleAudio(videoStream, audioStream) : undefined;

    this.vm.playerModel.updateVideoStream(videoStream);
    this.vm.playerModel.updateAudioStream(effectiveAudio);
    // createPlaybackUrl 前保持转圈（SIDX/SABR 重建可能数秒）
    if (!this.qualitySwitchPending) {
      this.beginSourceSwitchUi();
    } else {
      this.vm.isSourceSwitching = true;
      this.vm.isBuffering = true;
    }

    const playbackUrl = await this.createPlaybackUrl(videoStream, effectiveAudio, generation);
    if (!this.isMediaSessionCurrent(generation)) {
      this.endSourceSwitchUi(false);
      return;
    }
    if (!playbackUrl) {
      this.endSourceSwitchUi(false);
      this.setError('[PLAYER] LOCAL_PROXY_FAILED');
      return;
    }

    Logger.info(TAG,
      `switchQuality: ${videoStream.height}p codec=${videoStream.codecs} itag=${videoStream.itag} ` +
      `hw=${VideoHwCaps.isCodecHardwareFriendly(videoStream.codecs)} pos=${resumePos.toFixed(2)}s`);
    // Manual quality switch always allowed (including 4K VP9/AV1). Engine is mpv.
    this.qualitySwitchLoadStarted = true;
    this.vm.isSourceSwitching = true;
    this.vm.isBuffering = true;
    // Live HLS variants (and the Auto master entry) start at the live edge:
    // a resumed offset can fall outside the DVR window of the new playlist.
    const isHlsSwitch = ((videoStream.deliveryMethod || '').toUpperCase() === 'HLS')
      || ((videoStream.kind || '').toLowerCase() === 'manifest_hls');
    const loaded = this.loadPlaybackSource(playbackUrl, isHlsSwitch ? 0 : resumePos, generation);
    if (!loaded) {
      this.endSourceSwitchUi(false);
      return;
    }
    if (wasPlaying) {
      this.playbackEngine.play();
    }
  }

  public setPlaybackSpeed(speed: number): void {
    if (!this.isActive() || speed <= 0) return;
    this.vm.playbackSpeed = speed;
    this.playbackEngine.setPlaybackSpeed(speed);
  }

  public resizeSurface(widthPx: number, heightPx: number): void {
    // 不门控 isActive：引擎层会缓存几何，供 LOADING 阶段 bindSurface 时套用，
    // 否则 mpv video chain 初始化拿不到宽高（typeNode surface 早于引擎就绪）。
    this.playbackEngine.resizeSurface(widthPx, heightPx);
  }

  public setSurfaceID(surfaceID: string): void {
    if (!surfaceID || this.surfaceID === surfaceID) return;
    this.surfaceID = surfaceID;
    // 不门控 isActive：始终把 surfaceId 透传给引擎缓存，使引擎 initialize()/load() 时能据此重绑，
    // 避免 typeNode surface 早于引擎就绪导致的丢绑、无画面。
    this.playbackEngine.attachSurface(surfaceID);
  }

  public syncPlay(): void {
    if (!this.isActive()) return;
    this.clearFocusInterruptFlags('user_play');
    if (this.vm.isEnded) {
      this.playbackEngine.seek(0, true);
      this.vm.isEnded = false;
    }
    // Activate the default MEDIA AudioSession before play so other media yields focus.
    this.avSessionManager.activateForPlayback();
    this.playbackEngine.play();
  }

  public syncPause(): void {
    if (!this.isActive()) return;
    this.clearFocusInterruptFlags('user_pause');
    this.playbackEngine.pause();
    // Release focus so background audio can resume.
    this.avSessionManager.deactivateForPause();
  }

  public syncStop(): void {
    if (!this.isActive()) return;
    this.clearFocusInterruptFlags('user_stop');
    this.playbackEngine.stop();
    this.avSessionManager.deactivateForPause();
  }

  /**
   * Player-side audio focus handler (scheme A).
   * Stable log prefix for filtering: [AudioFocus]
   *
   * PAUSE  → temporary: freeze timeline, auto-resume on RESUME
   * STOP   → permanent: freeze timeline, no auto-resume
   * DUCK   → lower volume (~20%), keep playing
   * UNDUCK → restore volume
   * RESUME → only after temporary PAUSE; re-activate session then play
   */
  private handleAudioFocusHint(hint: audio.AudioSessionStateChangeHint): void {
    const name = AvSessionManager.focusHintName(hint);
    switch (hint) {
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_PAUSE:
        this.systemPausedByFocus = true;
        this.systemStoppedByFocus = false;
        this.playbackEngine.pause();
        Logger.info(TAG, `[AudioFocus] action=pause kind=temporary hint=${name}`);
        break;
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_STOP:
        this.systemPausedByFocus = false;
        this.systemStoppedByFocus = true;
        this.playbackEngine.pause();
        // Permanent loss: release session so other apps can keep focus.
        this.avSessionManager.deactivateForPause();
        Logger.info(TAG, `[AudioFocus] action=pause kind=permanent hint=${name}`);
        break;
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_RESUME:
        if (this.systemStoppedByFocus) {
          Logger.info(TAG, `[AudioFocus] action=ignore_resume reason=permanent_stop hint=${name}`);
          break;
        }
        if (!this.systemPausedByFocus) {
          Logger.info(TAG, `[AudioFocus] action=ignore_resume reason=not_system_paused hint=${name}`);
          break;
        }
        this.systemPausedByFocus = false;
        // Docs: after temporary PAUSE, re-activate session before resuming.
        this.avSessionManager.activateForPlayback();
        this.playbackEngine.play();
        Logger.info(TAG, `[AudioFocus] action=resume hint=${name}`);
        break;
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_DUCK:
        // AudioSession path: system FORCE-ducks stream gain (~20%). Do NOT also
        // set mpv volume — double duck (0.2×0.2) sounds like mute.
        if (!this.duckActive) {
          this.duckActive = true;
          this.savedVolume = this.playbackEngine.getVolume();
          Logger.info(TAG,
            `[AudioFocus] action=duck mode=system_gain mpvVolume=${this.savedVolume} (no setVolume)`);
        } else {
          Logger.info(TAG, `[AudioFocus] action=duck_skip already_active mpvVolume=${this.playbackEngine.getVolume()}`);
        }
        break;
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_UNDUCK:
        // System restores stream gain; keep mpv volume unchanged.
        if (this.duckActive) {
          this.duckActive = false;
          Logger.info(TAG,
            `[AudioFocus] action=unduck mode=system_gain mpvVolume=${this.playbackEngine.getVolume()} saved=${this.savedVolume}`);
        } else {
          Logger.info(TAG, `[AudioFocus] action=unduck_skip not_active`);
        }
        break;
      default:
        Logger.info(TAG, `[AudioFocus] action=unhandled hint=${name} raw=${hint}`);
        break;
    }
  }

  private clearFocusInterruptFlags(reason: string): void {
    if (this.systemPausedByFocus || this.systemStoppedByFocus) {
      Logger.info(TAG,
        `[AudioFocus] action=clear_flags reason=${reason} temp=${this.systemPausedByFocus} perm=${this.systemStoppedByFocus}`);
    }
    this.systemPausedByFocus = false;
    this.systemStoppedByFocus = false;
  }

  public syncSeek(seekTime: number): void {
    if (this.isActive()) this.playbackEngine.seek(seekTime / 1000, false);
  }

  public syncSeekFast(seekTime: number): void {
    if (this.isActive()) this.playbackEngine.seek(seekTime / 1000, true);
  }

  public syncSeekExact(seekTime: number): void {
    if (this.isActive()) this.playbackEngine.seek(seekTime / 1000, false);
  }

  private videoOutputEnabled: boolean = true;

  public setVideoOutputEnabled(enabled: boolean): void {
    // Always remember desired flag (session audio-only survives load/LOADING).
    const changed = this.videoOutputEnabled !== enabled;
    this.videoOutputEnabled = enabled;
    if (!this.stateMachine.isOneOf(PlayerState.READY, PlayerState.PLAYING, PlayerState.PAUSED,
      PlayerState.BUFFERING, PlayerState.COMPLETED)) {
      if (changed) {
        Logger.info(TAG, `setVideoOutputEnabled=${enabled} (deferred until ready)`);
      }
      return;
    }
    this.playbackEngine.setVideoOutputEnabled(enabled);
    if (changed) {
      Logger.info(TAG, `setVideoOutputEnabled=${enabled}`);
    }
  }

  /** Re-apply session video on/off after load/ready (new media defaults to vid on). */
  private applyVideoOutputPreference(): void {
    if (!this.stateMachine.isOneOf(PlayerState.READY, PlayerState.PLAYING, PlayerState.PAUSED,
      PlayerState.BUFFERING, PlayerState.COMPLETED)) {
      return;
    }
    this.playbackEngine.setVideoOutputEnabled(this.videoOutputEnabled);
  }


  public async checkCastState(): Promise<void> {
    await this.avSessionManager.checkCastState();
  }

  /**
   * Close one media session while retaining the initialized MPV controller.
   * All source/proxy work from the previous generation becomes invalid immediately.
   */
  public closeMediaSession(clearSurface: boolean = false): void {
    this.mediaSessionGeneration++;
    Logger.info(TAG, `closeMediaSession generation=${this.mediaSessionGeneration} clearSurface=${clearSurface}`);
    this.playbackEngine.stop();
    this.destroyAllLocalSessions();
    this.detachBackgroundTaskListener();
    this.clearAvSessionCallbacks();
    this.avSessionManager.destroy();
    this.stateRelay.resetMediaSession();
    if (!this.stateMachine.isOneOf(PlayerState.IDLE)) {
      this.stateMachine.forceTransition(PlayerState.IDLE);
    }
    this.resetPlaybackState();
    this.vm.playerModel = new PlayerModel();
    this.curSource = {
      name: this.curSource.name, description: '', time: '00:00', auto: false, head: this.curSource.head,
      likeCount: '0', commentCount: '0', shareCount: '0', play: false, index: 0
    };
    this.curIndex = 0;
    this.pendingStartFromSec = 0;
    this.startupAttemptId = '';
    this.startupStartedAt = 0;
    this.startupFileLoadedLogged = false;
    this.startupPlaybackRestartLogged = false;
    this.startupFirstFrameLogged = false;
    this.avSessionArtworkPublished = false;
    this.errorRetryCount = 0;
    this.isRecovering = false;
    this.lastKnownGoodPosition = 0;
    this.systemPausedByFocus = false;
    this.systemStoppedByFocus = false;
    this.duckActive = false;
    this.savedVolume = 100;
    this.videoOutputEnabled = true;
    this.playbackEngine.setVideoOutputEnabled(true);
    if (clearSurface) {
      this.surfaceID = '';
      this.playbackEngine.detachSurface();
    }
  }

  public releaseVideo(_index: number): void {
    if (this.stateMachine.isOneOf(PlayerState.RELEASED)) return;
    this.closeMediaSession(true);
    if (!this.stateMachine.transition(PlayerState.RELEASED)) {
      this.stateMachine.forceTransition(PlayerState.RELEASED);
    }
    Logger.debug(TAG, 'releaseVideo: destroy playback engine and LocalMediaProxy session');
    this.playbackEngine.destroy();
    this.engineInitPromise = null;
    this.errorListeners.clear();
    this.waitingForBufferListeners.clear();
    this.seekableRangesListeners.clear();
  }

  public switchSubtitle(url: string): void {
    if (url === this.vm.currentSubtitleUrl) return;
    this.vm.currentSubtitleUrl = url;
    if (url.length === 0) {
      this.vm.subtitleText = '';
    }
    this.playbackEngine.setSubtitle(url);
  }

  public getNativeLogBridgeFns(_onLog: (level: string, tag: string, message: string) => void): NativeLogBridgeFns {
    return { start: () => {}, stop: () => {} };
  }

  private selectInitialStreams(isLive: boolean): boolean {
    const categories = this.vm.playerModel.categorizedStreams;
    if (isLive) {
      const manifest = this.selectManifestByCap(categories.hlsManifest.length > 0 ? categories.hlsManifest : categories.dashManifest, true);
      if (manifest) {
        this.vm.playerModel.updateVideoStream(manifest);
        this.vm.playerModel.updateAudioStream(undefined);
        Logger.info(TAG, `Selected live manifest: ${this.describePlaybackUrl(manifest.url)}`);
        return true;
      }
    }

    const merged = this.vm.playerModel.getMergedVideoList();
    const video = this.selectBestVideoEntry(merged);
    if (!video) {
      const manifest = this.selectManifestByCap(categories.hlsManifest.length > 0 ? categories.hlsManifest : categories.dashManifest, false);
      if (manifest) {
        this.vm.playerModel.updateVideoStream(manifest);
        this.vm.playerModel.updateAudioStream(undefined);
        Logger.info(TAG, `Selected fallback manifest: ${this.describePlaybackUrl(manifest.url)}`);
        return true;
      }
      return false;
    }

    let audio: StreamInfo | undefined = undefined;
    if (this.requiresSeparateAudio(video.stream)) {
      audio = this.selectBestCompatibleAudio(video.stream, categories.audio);
    }
    this.vm.playerModel.updateVideoStream(video.stream);
    this.vm.playerModel.updateAudioStream(audio);

    const label = `${video.stream.quality || '-'} [${video.stream.itag}]`;
    const delivery = (video.stream.deliveryMethod || '').toUpperCase();
    if (delivery === 'SABR') {
      Logger.info(TAG, `Selected SABR: video=${label}${audio
        ? ` audio=${audio.audioTrackName || audio.audioLanguage || audio.codecs} [${audio.itag}] track=${audio.audioTrackId || '-'}`
        : ' (no audio)'}`);
    } else if (delivery === 'DASH') {
      Logger.info(TAG, `Selected DASH separated: video=${label}${audio
        ? ` audio=${audio.audioTrackName || audio.quality} [${audio.itag}] track=${audio.audioTrackId || '-'}`
        : ' (no audio)'}`);
    } else if (delivery === 'HLS') {
      Logger.info(TAG, `Selected HLS variant: ${label}`);
    } else {
      Logger.info(TAG, `Selected progressive: ${label}`);
    }
    return true;
  }

  private selectBestVideo(streams: StreamInfo[], live: boolean): StreamInfo | undefined {
    const prefs = PlaybackPreferences.snapshot();
    const targetQuality = live ? prefs.mobileQuality : prefs.defaultQuality;
    const maxHeight = this.resolveMaxHeight(targetQuality);
    const underCap = streams.filter(s => this.resolutionLabelHeight(s) <= maxHeight);
    // Prefer hardware-decodable codecs when the device reports capability.
    // Avoid auto-picking 4K VP9 on devices without VP9 hardware (soft-decode heat).
    const hwFriendly = underCap.filter(s => VideoHwCaps.isCodecHardwareFriendly(s.codecs));
    const pool = hwFriendly.length > 0
      ? hwFriendly
      : (underCap.length > 0 ? underCap : streams);
    return pool.slice().sort((a: StreamInfo, b: StreamInfo): number => {
      const h = this.resolutionLabelHeight(b) - this.resolutionLabelHeight(a);
      if (h !== 0) return h;
      const codec = this.codecPriority(b) - this.codecPriority(a);
      if (codec !== 0) return codec;
      return (b.bitrate || 0) - (a.bitrate || 0);
    })[0];
  }

  private selectBestProgressive(streams: StreamInfo[]): StreamInfo {
    const selected = this.selectBestVideo(streams, false);
    return selected || streams[0];
  }

  private selectManifestByCap(streams: StreamInfo[], live: boolean): StreamInfo | undefined {
    if (!streams || streams.length === 0) return undefined;
    const selected = this.selectBestVideo(streams, live);
    return selected || streams[0];
  }

  private selectBestVideoEntry(entries: VideoEntry[]): VideoEntry | undefined {
    if (!entries || entries.length === 0) {
      return undefined;
    }
    const prefs = PlaybackPreferences.snapshot();
    const maxHeight = this.resolveMaxHeight(prefs.defaultQuality);
    // Prefer hard-decode-friendly codecs at the target quality label.
    // Skip VP9/AV1 when OHOS reports no hardware capability for that MIME.
    const underCap = entries.filter(e => this.resolutionLabelHeight(e.stream) <= maxHeight);
    const hwFriendly = underCap.filter(e => VideoHwCaps.isCodecHardwareFriendly(e.stream.codecs));
    const pool = hwFriendly.length > 0
      ? hwFriendly
      : (underCap.length > 0 ? underCap : entries);
    const selected = pool.slice().sort((a: VideoEntry, b: VideoEntry): number => {
      const h = this.resolutionLabelHeight(b.stream) - this.resolutionLabelHeight(a.stream);
      if (h !== 0) {
        return h;
      }
      const codec = this.codecPriority(b.stream) - this.codecPriority(a.stream);
      if (codec !== 0) {
        return codec;
      }
      return (b.stream.bitrate || 0) - (a.stream.bitrate || 0);
    })[0];
    if (selected) {
      const caps = VideoHwCaps.get();
      Logger.info(TAG,
        `selectBestVideoEntry: ${selected.stream.quality || '-'} codec=${selected.stream.codecs} ` +
        `itag=${selected.stream.itag} hwFriendly=${VideoHwCaps.isCodecHardwareFriendly(selected.stream.codecs)} ` +
        `caps[avc=${caps.avc},hevc=${caps.hevc},vp9=${caps.vp9},av1=${caps.av1}]`);
    }
    return selected;
  }

  private resolveMaxHeight(targetQuality: string): number {
    const m = /^(\d+)p/.exec(targetQuality);
    return m ? parseInt(m[1], 10) : 9999;
  }

  /**
   * Numeric resolution for quality matching, PipePipe parity: the itag-table
   * label (`stream.quality` = youtube_core `qualityLabel`, e.g. '1080p',
   * '720p60', '1080p HFR') is authoritative — fps/HFR/HDR suffixes are
   * ignored. The real coded height (e.g. 1080x1920 portrait) must NOT drive
   * selection, or a '1080p' cap would exclude a portrait video's own 1080p
   * itag and fall through to 480p. Falls back to the coded height only when
   * no label exists (HLS variants already carry '1080p' labels).
   */
  private resolutionLabelHeight(stream: StreamInfo): number {
    const label = stream.quality || '';
    const m = label.match(/^(\d+)p/i);
    if (m) {
      return parseInt(m[1], 10);
    }
    return stream.height || 0;
  }

  private requiresSeparateAudio(stream: StreamInfo): boolean {
    return (stream.hasVideo === true && stream.hasAudio !== true)
      || stream.kind?.toLowerCase() === 'video_only';
  }

  private codecPriority(stream: StreamInfo): number {
    // Device-aware: hardware-capable codecs rank above soft-only ones.
    // Base order: HEVC > H.264 > VP9 > AV1; then boost if HW is available.
    const c = (stream.codecs || '').toLowerCase();
    let base = 0;
    if (c.startsWith('hvc1') || c.startsWith('hev1')) base = 50;
    else if (c.startsWith('avc1') || c.startsWith('avc3')) base = 40;
    else if (c.startsWith('vp9') || c.startsWith('vp09')) base = 30;
    else if (c.startsWith('av01')) base = 20;
    if (VideoHwCaps.isCodecHardwareFriendly(stream.codecs)) {
      base += 100;
    }
    return base;
  }

  private codecToMpv(codec: string): string {
    const c = codec.toLowerCase();
    if (c.startsWith('avc1')) return 'h264';
    if (c.startsWith('hev1') || c.startsWith('hvc1')) return 'hevc';
    if (c.startsWith('vp09') || c.startsWith('vp9')) return 'vp9';
    if (c.startsWith('av01')) return 'av1';
    if (c.startsWith('mp4a')) return 'aac';
    if (c.startsWith('opus')) return 'opus';
    if (c.startsWith('vorbis')) return 'vorbis';
    if (c.startsWith('ac-3') || c.startsWith('ac3')) return 'ac3';
    if (c.startsWith('ec-3') || c.startsWith('eac3')) return 'eac3';
    if (c.startsWith('dts')) return 'dts';
    if (c.startsWith('flac')) return 'flac';
    if (c.startsWith('theora')) return 'theora';
    if (c.startsWith('wmapro')) return 'wmapro';
    return 'null';
  }

  private async createPlaybackUrl(video?: StreamInfo, audio?: StreamInfo,
    generation: number = this.mediaSessionGeneration): Promise<string> {
    if (!video || !this.isMediaSessionCurrent(generation)) return '';

    // Defer old session destroy: mark stale, save for cleanup after new source is READY
    this.deferCurrentSessionDestroy();

    const delivery = (video.deliveryMethod || '').toUpperCase();
    const kind = (video.kind || '').toLowerCase();
    if (delivery === 'SABR' || kind === 'sabr') {
      if (audio) {
        return await this.buildSabrDualEdlUrl(video, audio, generation);
      }
      Logger.error(TAG, 'createPlaybackUrl: SABR requires paired audio stream');
      return '';
    }

    if (!video.url) return '';

    if (this.isRemoteManifestUrl(video.url)) {
      Logger.debug(TAG, `createPlaybackUrl: using remote manifest directly`);
      return video.url;
    }

    switch (delivery) {
      case 'HLS':
        Logger.info(TAG, `createPlaybackUrl: HLS variant direct url=${this.describePlaybackUrl(video.url)}`);
        return video.url;

      case 'DASH':
        if (audio && this.isSeparatedDash(video, audio)) {
          return await this.buildDualEdlUrl(video, audio, generation);
        }
        return await this.buildSingleProxyUrl(video, generation);

      case 'PROGRESSIVE_HTTP':
      default:
        return await this.buildSingleProxyUrl(video, generation);
    }
  }

  private async buildSingleProxyUrl(video: StreamInfo, generation: number): Promise<string> {
    const sessionId = await LocalMediaProxy.createSingleUrlSession(video.url, video);
    if (!this.isMediaSessionCurrent(generation)) {
      LocalMediaProxy.destroySession(sessionId);
      return '';
    }
    const playbackUrl = LocalMediaProxy.getPlaybackUrl(sessionId);
    if (!playbackUrl.startsWith('http://127.0.0.1:')) {
      Logger.error(TAG, `buildSingleProxyUrl: invalid url sessionId=${sessionId}`);
      LocalMediaProxy.destroySession(sessionId);
      return '';
    }
    this.currentLocalMediaSessionId = sessionId;
    Logger.debug(TAG, `buildSingleProxyUrl: itag=${video.itag} url=${playbackUrl}`);
    return playbackUrl;
  }

  private async buildSabrDualEdlUrl(video: StreamInfo, audio: StreamInfo,
    generation: number): Promise<string> {
    let resolvedDuration = this.resolveDurationMs(video, audio);
    if (resolvedDuration <= 0) {
      const vMeta = video.sabrInfo?.findFormatByItag(video.itag ?? -1)?.approxDurationMs ?? 0;
      const aMeta = audio.sabrInfo?.findFormatByItag(audio.itag ?? -1)?.approxDurationMs ?? 0;
      resolvedDuration = vMeta > 0 ? vMeta : aMeta;
    }
    if (resolvedDuration <= 0) {
      Logger.error(TAG, 'buildSabrDualEdlUrl: unknown duration, refusing EDL');
      return '';
    }
    Logger.info(TAG, `buildSabrDualEdlUrl: video=[itag=${video.itag}] audio=[itag=${audio.itag}] durationMs=${resolvedDuration}`);
    try {
      const sessionId = await LocalMediaProxy.createSabrDualSession(video, audio, resolvedDuration, false);
      if (!this.isMediaSessionCurrent(generation)) {
        LocalMediaProxy.destroySession(sessionId);
        return '';
      }
      const playbackUrl = LocalMediaProxy.getPlaybackUrl(sessionId);
      if (!playbackUrl.startsWith('http://127.0.0.1:')) {
        Logger.error(TAG, `buildSabrDualEdlUrl: invalid playbackUrl sessionId=${sessionId}`);
        LocalMediaProxy.destroySession(sessionId);
        return '';
      }
      this.currentLocalMediaSessionId = sessionId;
      // SABR is exposed as a synthetic DASH manifest with exact init/media segment URLs.
      // MPV remains the DASH demuxer/player; the proxy owns segment demand, seeks and EOF.
      return playbackUrl;
    } catch (e) {
      Logger.error(TAG, `buildSabrDualEdlUrl failed: ${e}`);
      return '';
    }
  }

  /**
   * Dual adaptive VOD via MPV-native EDL (pre-SABR production pattern, cf97a08):
   * two open-range single-url sessions + edl:// !new_stream/!delay_open.
   * Production path for direct-link clients (android_vr / tv_downgraded) —
   * bypasses the SIDX / DASH-demuxer stack (MPV DASH is not used for these).
   * buildDualDashUrl below is retained only as reference for a static-DASH rollback.
   */
  private async buildDualEdlUrl(video: StreamInfo, audio: StreamInfo,
    generation: number = this.mediaSessionGeneration): Promise<string> {
    const durationMs = this.resolveDurationMs(video, audio);
    if (durationMs <= 0) {
      Logger.error(TAG, 'buildDualEdlUrl: dual stream with unknown duration, refusing');
      return '';
    }
    const videoSessionId = await LocalMediaProxy.createSingleUrlSession(video.url, video);
    if (!videoSessionId) {
      Logger.error(TAG, 'buildDualEdlUrl: video session unavailable');
      return '';
    }
    const audioSessionId = await LocalMediaProxy.createSingleUrlSession(audio.url, audio);
    if (!audioSessionId) {
      Logger.error(TAG, 'buildDualEdlUrl: audio session unavailable');
      LocalMediaProxy.destroySession(videoSessionId);
      return '';
    }
    if (!this.isMediaSessionCurrent(generation)) {
      LocalMediaProxy.destroySession(videoSessionId);
      LocalMediaProxy.destroySession(audioSessionId);
      return '';
    }
    const videoUrl = LocalMediaProxy.getPlaybackUrl(videoSessionId);
    const audioUrl = LocalMediaProxy.getPlaybackUrl(audioSessionId);
    if (!videoUrl.startsWith('http://127.0.0.1:') || !audioUrl.startsWith('http://127.0.0.1:')) {
      Logger.error(TAG, `buildDualEdlUrl: invalid track urls video=${videoSessionId} audio=${audioSessionId}`);
      LocalMediaProxy.destroySession(videoSessionId);
      LocalMediaProxy.destroySession(audioSessionId);
      return '';
    }
    this.currentLocalMediaSessionId = videoSessionId;
    this.currentEdlAudioSessionId = audioSessionId;

    const durationSec = (durationMs / 1000).toFixed(3);
    const parts: string[] = [];
    // Video track
    parts.push('!new_stream', '!no_clip', '!no_chapters');
    let vDelay = `!delay_open,media_type=video,codec=${this.codecToMpv(video.codecs || '')}`;
    if ((video.width || 0) > 0) vDelay += `,w=${video.width}`;
    if ((video.height || 0) > 0) vDelay += `,h=${video.height}`;
    if ((video.fps || 0) > 0) vDelay += `,fps=${video.fps}`;
    parts.push(vDelay);
    if ((video.bitrate || 0) > 0) {
      // YouTube bitrate is bit/s; byterate must be byte/s and fit mpv's int32 EDL parser.
      parts.push(`!track_meta,title=${edlMeta(video.quality || 'video')},byterate=${Math.floor((video.bitrate || 0) / 8)}`);
    }
    parts.push(`${videoUrl},length=${durationSec}`);
    // Audio track
    parts.push('!new_stream', '!no_clip', '!no_chapters');
    parts.push(`!delay_open,media_type=audio,codec=${this.codecToMpv(audio.codecs || '')}`);
    if ((audio.bitrate || 0) > 0) {
      parts.push(`!track_meta,title=${edlMeta(audio.quality || 'audio')},byterate=${Math.floor((audio.bitrate || 0) / 8)}`);
    }
    parts.push(`${audioUrl},length=${durationSec}`);

    const edlUrl = 'edl://' + parts.join(';') + ';';
    Logger.info(TAG, `buildDualEdlUrl: video=[itag=${video.itag} ${video.quality} ${video.codecs}] audio=[itag=${audio.itag} ${audio.codecs}] durationMs=${durationMs}`);
    Logger.debug(TAG, `buildDualEdlUrl: edl=${edlUrl}`);
    return edlUrl;
  }

  /** Static-DASH variant retained for reference/rollback; not on the production path. */
  private async buildDualDashUrl(video: StreamInfo, audio: StreamInfo,
    generation: number): Promise<string> {
    const durationMs = this.resolveDurationMs(video, audio);
    if (durationMs <= 0) {
      Logger.error(TAG, `buildDualDashUrl: dual stream with unknown duration, refusing`);
      return '';
    }
    if (!this.hasSegmentBase(video) || !this.hasSegmentBase(audio)) {
      Logger.error(TAG, `buildDualDashUrl: missing init/index range video=${video.itag} audio=${audio.itag}, DASH-only mode`);
      return '';
    }
    Logger.info(TAG, `buildDualDashUrl: video=[itag=${video.itag} ${video.quality} ${video.codecs}] audio=[itag=${audio.itag} ${audio.codecs}] durationMs=${durationMs}`);

    const sessionId = await LocalMediaProxy.createYoutubeDualUrlSession(
      video, audio, durationMs, this.startupAttemptId);
    if (!this.isMediaSessionCurrent(generation)) {
      LocalMediaProxy.destroySession(sessionId);
      return '';
    }
    const manifestUrl = LocalMediaProxy.getDashManifestUrl(sessionId);
    if (!manifestUrl.startsWith('http://127.0.0.1:')) {
      Logger.error(TAG, `buildDualDashUrl: static DASH unavailable sessionId=${sessionId}`);
      LocalMediaProxy.destroySession(sessionId);
      return '';
    }
    this.currentLocalMediaSessionId = sessionId;
    Logger.info(TAG, `buildDualDashUrl: using static DASH manifest=${manifestUrl}`);
    return manifestUrl;
  }

  private hasSegmentBase(stream: StreamInfo): boolean {
    const initStart = stream.initRangeStart;
    const initEnd = stream.initRangeEnd;
    const indexStart = stream.indexRangeStart;
    const indexEnd = stream.indexRangeEnd;
    return !stream.isOtf
      && initStart !== undefined && initEnd !== undefined && initStart >= 0 && initEnd >= initStart
      && indexStart !== undefined && indexEnd !== undefined && indexStart >= 0 && indexEnd >= indexStart;
  }

  /**
   * Defer current session destroy: mark stale so new requests get 410 Gone,
   * save session id for cleanup after new source reaches READY state.
   */
  private deferCurrentSessionDestroy(): void {
    if (this.pendingDestroySessionId) {
      // Previous pending session not yet destroyed (e.g. rapid switching)
      LocalMediaProxy.destroySession(this.pendingDestroySessionId);
    }
    if (this.pendingDestroyEdlAudioSessionId) {
      LocalMediaProxy.destroySession(this.pendingDestroyEdlAudioSessionId);
    }
    if (this.currentLocalMediaSessionId) {
      this.pendingDestroySessionId = this.currentLocalMediaSessionId;
      LocalMediaProxy.markSessionStale(this.currentLocalMediaSessionId);
      this.currentLocalMediaSessionId = '';
    }
    if (this.currentEdlAudioSessionId) {
      this.pendingDestroyEdlAudioSessionId = this.currentEdlAudioSessionId;
      LocalMediaProxy.markSessionStale(this.currentEdlAudioSessionId);
      this.currentEdlAudioSessionId = '';
    }
    this.localTimelineAwaitingReady = false;
    this.localTimelineExpectedStartMs = 0;
    this.localTimelineMismatchLogged = false;
  }

  /**
   * Bind SABR player-time feedback to this load's intended starting point. MPV reuses one native
   * controller, so callbacks between setMedia() and Prepared can still describe the outgoing file.
   */
  private loadPlaybackSource(playbackUrl: string, startPosSec: number,
    generation: number = this.mediaSessionGeneration): boolean {
    if (!this.isMediaSessionCurrent(generation)) return false;
    const expectedStartMs = Math.max(0, Math.round(startPosSec * 1000));
    this.localTimelineAwaitingReady = this.currentLocalMediaSessionId.length > 0;
    this.localTimelineExpectedStartMs = expectedStartMs;
    this.localTimelineMismatchLogged = false;
    if (this.currentLocalMediaSessionId) {
      LocalMediaProxy.updatePlaybackPosition(this.currentLocalMediaSessionId, expectedStartMs);
      Logger.info(TAG, `local timeline armed session=${this.currentLocalMediaSessionId} ` +
        `startMs=${expectedStartMs}`);
    }
    const loaded = this.playbackEngine.load(playbackUrl, startPosSec);
    if (!loaded) {
      this.localTimelineAwaitingReady = false;
      Logger.warn(TAG, `local timeline disarmed: engine rejected load startMs=${expectedStartMs}`);
    }
    return loaded;
  }

  private resolveDurationMs(video: StreamInfo, audio?: StreamInfo): number {
    const fromStream = (video.approxDurationMs && video.approxDurationMs > 0)
      ? video.approxDurationMs
      : (audio?.approxDurationMs && audio.approxDurationMs > 0)
        ? audio.approxDurationMs
        : 0;
    if (fromStream > 0) return fromStream;
    const fromMeta = Math.round((this.vm.durationTime || 0) * 1000);
    if (fromMeta > 0) return fromMeta;
    // 最后 fallback：从流的 contentLength / bitrate 估算（秒转毫秒）
    const estimateFromBitrate = (s: StreamInfo): number => {
      const bitrate = s.bitrate ?? 0;
      const contentLength = s.contentLength ?? 0;
      if (bitrate > 0 && contentLength > 0) {
        return Math.round((contentLength * 8.0 / bitrate) * 1000.0);
      }
      return 0;
    };
    const estimated = estimateFromBitrate(video) || (audio ? estimateFromBitrate(audio) : 0);
    return estimated > 0 ? estimated : 0;
  }

  private destroyCurrentLocalSession(): void {
    if (this.currentLocalMediaSessionId) {
      LocalMediaProxy.destroySession(this.currentLocalMediaSessionId);
    }
    this.currentLocalMediaSessionId = '';
    if (this.currentEdlAudioSessionId) {
      LocalMediaProxy.destroySession(this.currentEdlAudioSessionId);
    }
    this.currentEdlAudioSessionId = '';
    this.localTimelineAwaitingReady = false;
    this.localTimelineExpectedStartMs = 0;
    this.localTimelineMismatchLogged = false;
  }

  private destroyAllLocalSessions(): void {
    this.destroyCurrentLocalSession();
    if (this.pendingDestroySessionId) {
      LocalMediaProxy.destroySession(this.pendingDestroySessionId);
      this.pendingDestroySessionId = '';
    }
    if (this.pendingDestroyEdlAudioSessionId) {
      LocalMediaProxy.destroySession(this.pendingDestroyEdlAudioSessionId);
      this.pendingDestroyEdlAudioSessionId = '';
    }
  }

  private isMediaSessionCurrent(generation: number): boolean {
    return generation === this.mediaSessionGeneration
      && !this.stateMachine.isOneOf(PlayerState.RELEASED);
  }

  private clearAvSessionCallbacks(): void {
    this.avSessionManager.onPlayCommand = undefined;
    this.avSessionManager.onPauseCommand = undefined;
    this.avSessionManager.onSeekCommand = undefined;
    this.avSessionManager.onFastForwardCommand = undefined;
    this.avSessionManager.onRewindCommand = undefined;
    this.avSessionManager.onNextCommand = undefined;
    this.avSessionManager.onPreviousCommand = undefined;
    this.avSessionManager.onStopCommand = undefined;
    this.avSessionManager.onCastStateChange = undefined;
    this.avSessionManager.onAudioFocusHint = undefined;
  }

  private isRemoteManifestUrl(url: string): boolean {
    return /\.mpd($|[?#])/i.test(url) || /\.m3u8($|[?#])/i.test(url);
  }

  private async resolveManifestPlaybackUrl(url: string, isLive: boolean): Promise<string> {
    if (!url || !isLive || !/\.m3u8($|[?#])/i.test(url)) {
      return url;
    }
    try {
      const text = await this.fetchText(url);
      if (!text.includes('#EXT-X-STREAM-INF')) {
        return url;
      }
      // HLS 解析统一走 youtube_core HlsManifestParser（本类只保留 HTTP 拉取，
      // 网络层归收到 youtube_core 属后续 P4 项）。
      const variants = parseHlsMasterManifest(text, this.curSource?.videoId || '')
        .videoStreams.filter((s) => !!s.url);
      if (variants.length === 0) {
        return url;
      }
      const prefs = PlaybackPreferences.snapshot();
      const maxHeight = this.resolveMaxHeight(prefs.mobileQuality || '480p');
      const selected = variants
        .filter((s) => (s.height || 0) <= maxHeight)
        .sort((a, b) => (b.height || 0) - (a.height || 0))[0]
        || variants.sort((a, b) => (a.height || 0) - (b.height || 0))[0];
      Logger.info(TAG, `Selected HLS live variant: ${selected.height || 0}p ${this.describePlaybackUrl(selected.url)}`);
      return selected.url;
    } catch (e) {
      Logger.warn(TAG, `resolveManifestPlaybackUrl failed, using original manifest: ${e}`);
      return url;
    }
  }

  private async fetchText(url: string): Promise<string> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        header: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36',
          'Referer': 'https://www.youtube.com/',
        },
        connectTimeout: 8000,
        readTimeout: 10000,
      };
      HttpDownloader.applyProxyToOptions(options, url);
      const response = await request.request(url, options);
      Logger.info(TAG, `manifest fetchText: code=${response.responseCode} resultType=${typeof response.result} len=${typeof response.result === 'string' ? response.result.length : 0}`);
      return typeof response.result === 'string' ? response.result : '';
    } catch (e) {
      Logger.warn(TAG, `manifest fetchText error: ${e}`);
      return '';
    } finally {
      request.destroy();
    }
  }

  private isSeparatedDash(videoStream: StreamInfo, audioStream?: StreamInfo): boolean {
    if (!audioStream) return false;
    const delivery = videoStream.deliveryMethod?.toUpperCase() || '';
    if (delivery === 'SABR' || (videoStream.kind?.toLowerCase() === 'sabr')) {
      return !!audioStream.sabrInfo || !!videoStream.sabrInfo;
    }
    if (!audioStream.url) return false;
    const categories = this.vm.playerModel.categorizedStreams;
    if (categories.video.length === 0 || categories.audio.length === 0) return false;
    const kind = videoStream.kind?.toLowerCase() || '';
    return kind === 'video_only' || delivery === 'DASH' || videoStream.initRangeStart !== undefined;
  }

  /**
   * Auto-pick audio for video: filter compatible candidates by the user's
   * preferred audio language (PlaybackPreferences.searchLanguage), then
   * prefer the original track and higher bitrate within that group; fall
   * back to all candidates when the preferred language is unavailable.
   * UI lists every stream; this only chooses the default.
   */
  private selectBestCompatibleAudio(videoStream: StreamInfo, audioStreams: StreamInfo[]): StreamInfo | undefined {
    const candidates = this.compatibleAudioCandidates(videoStream, audioStreams);
    if (candidates.length === 0) {
      return undefined;
    }
    const prefs = PlaybackPreferences.snapshot();
    const langMatched = this.filterAudioStreamsByLanguage(candidates, prefs.searchLanguage);
    const pool = langMatched.length > 0 ? langMatched : candidates;
    const isOriginal = (s: StreamInfo): boolean => {
      const type = (s.audioTrackType || '').toUpperCase();
      const name = (s.audioTrackName || '').toLowerCase();
      return type === 'ORIGINAL'
        || name.indexOf('original') >= 0
        || name.indexOf('default') >= 0;
    };
    return pool.slice().sort((a: StreamInfo, b: StreamInfo): number => {
      const oa = isOriginal(a) ? 1 : 0;
      const ob = isOriginal(b) ? 1 : 0;
      if (oa !== ob) {
        return ob - oa;
      }
      return this.audioFormatPriority(b) - this.audioFormatPriority(a);
    })[0];
  }

  /**
   * Filter audio streams by the preferred audio language, aligned with the
   * PipePipe `ListHelper.filterAudioStreamsByLanguage` semantics:
   *  - "original" (or empty): prefer tracks explicitly flagged original /
   *    default, then tracks that carry no track-id / language metadata.
   *  - explicit code (e.g. "zh", "en"): match StreamInfo.audioLanguage first,
   *    then the language prefix of audioTrackId, then the track name.
   * Returns an empty array when nothing matches so callers can fall back to
   * the full candidate set.
   */
  private filterAudioStreamsByLanguage(audioStreams: StreamInfo[], preferredLanguage: string): StreamInfo[] {
    if (!audioStreams || audioStreams.length === 0) {
      return [];
    }
    const pref = (preferredLanguage || '').trim().toLowerCase();
    if (pref === '' || pref === 'original') {
      const originalStreams = audioStreams.filter((s: StreamInfo) => {
        const name = (s.audioTrackName || '').toLowerCase();
        const type = (s.audioTrackType || '').toLowerCase();
        return name.indexOf('original') >= 0
          || name.indexOf('default') >= 0
          || type === 'original';
      });
      if (originalStreams.length > 0) {
        return originalStreams;
      }
      const noTrackInfo = audioStreams.filter((s: StreamInfo) =>
        (s.audioTrackId || '') === '' && (s.audioLanguage || '') === '');
      return noTrackInfo;
    }
    const matched = audioStreams.filter((s: StreamInfo) => {
      const lang = (s.audioLanguage || '').toLowerCase();
      if (lang === pref) {
        return true;
      }
      const trackId = s.audioTrackId || '';
      if (trackId) {
        const code = trackId.split('.')[0].split('-')[0].toLowerCase();
        if (code === pref) {
          return true;
        }
      }
      return (s.audioTrackName || '').toLowerCase() === pref;
    });
    return matched;
  }

  private audioFormatPriority(stream: StreamInfo): number {
    const codecs = (stream.codecs || '').toLowerCase();
    const mime = (stream.mimeType || '').toLowerCase();
    // Prefer the broadly compatible regular AAC stream over ultra-low HE-AAC variants.
    // For a WebM video, compatibleAudioCandidates filters this group to Opus first.
    let score = 0;
    if (stream.itag === 140) score += 1000000;
    else if (codecs.includes('mp4a') || mime.includes('audio/mp4')) score += 500000;
    else if (codecs.includes('opus') || mime.includes('audio/webm')) score += 300000;
    if (stream.itag === 599 || stream.itag === 600) score -= 200000;
    return score + (stream.bitrate || 0);
  }

  private ensureCompatibleAudio(videoStream: StreamInfo, requestedAudio?: StreamInfo): StreamInfo | undefined {
    if (requestedAudio && this.isAudioCompatibleWithVideo(videoStream, requestedAudio)) {
      return requestedAudio;
    }
    // Container mismatch: stay on same track id if another itag of that track is compatible.
    if (requestedAudio) {
      const trackId = (requestedAudio.audioTrackId || '').trim();
      if (trackId.length > 0) {
        const sameTrack = this.vm.playerModel.categorizedStreams.audio.filter((s: StreamInfo) =>
          (s.audioTrackId || '') === trackId
        );
        const sameCompat = this.selectBestCompatibleAudio(videoStream, sameTrack);
        if (sameCompat) {
          Logger.info(TAG, `ensureCompatibleAudio: remapped to same track=${trackId} itag=${sameCompat.itag}`);
          return sameCompat;
        }
      }
    }
    const fallback = this.selectBestCompatibleAudio(videoStream, this.vm.playerModel.categorizedStreams.audio);
    if (requestedAudio && fallback
      && ((requestedAudio.audioTrackId || '') !== (fallback.audioTrackId || '')
        || requestedAudio.itag !== fallback.itag)) {
      Logger.warn(TAG, `ensureCompatibleAudio: fell back from `
        + `${requestedAudio.audioTrackName || requestedAudio.audioTrackId || '-'}[${requestedAudio.itag}] `
        + `to ${fallback.audioTrackName || fallback.audioTrackId || '-'}[${fallback.itag}]`);
    }
    return fallback || requestedAudio;
  }

  private compatibleAudioCandidates(videoStream: StreamInfo, audioStreams: StreamInfo[]): StreamInfo[] {
    if (this.isMp4Video(videoStream)) {
      const mp4 = audioStreams.filter(s => this.isMp4Audio(s));
      return mp4.length > 0 ? mp4 : audioStreams;
    }
    if (this.isWebmVideo(videoStream)) {
      const webm = audioStreams.filter(s => this.isWebmAudio(s));
      return webm.length > 0 ? webm : audioStreams;
    }
    return audioStreams;
  }

  private isAudioCompatibleWithVideo(videoStream: StreamInfo, audioStream: StreamInfo): boolean {
    if (this.isMp4Video(videoStream)) return this.isMp4Audio(audioStream);
    if (this.isWebmVideo(videoStream)) return this.isWebmAudio(audioStream);
    return true;
  }

  private isMp4Video(stream: StreamInfo): boolean {
    const mime = (stream.mimeType || '').toLowerCase();
    const codecs = (stream.codecs || '').toLowerCase();
    return mime.includes('video/mp4') || codecs.includes('avc1') || codecs.includes('avc3') || codecs.includes('av01');
  }

  private isWebmVideo(stream: StreamInfo): boolean {
    const mime = (stream.mimeType || '').toLowerCase();
    const codecs = (stream.codecs || '').toLowerCase();
    return mime.includes('video/webm') || codecs.includes('vp9') || codecs.includes('vp09');
  }

  private isMp4Audio(stream: StreamInfo): boolean {
    const mime = (stream.mimeType || '').toLowerCase();
    const codecs = (stream.codecs || '').toLowerCase();
    return mime.includes('audio/mp4') || codecs.includes('mp4a');
  }

  private isWebmAudio(stream: StreamInfo): boolean {
    const mime = (stream.mimeType || '').toLowerCase();
    const codecs = (stream.codecs || '').toLowerCase();
    return mime.includes('audio/webm') || codecs.includes('opus') || codecs.includes('vorbis');
  }

  private onPlaybackStateChange(state: PlaybackState): void {
    if (!this.isActive()) return;

    if (this.startupAttemptId.length > 0 && state.isReady && !this.startupFileLoadedLogged) {
      this.startupFileLoadedLogged = true;
      Logger.info(TAG, `[STARTUP] attempt=${this.startupAttemptId} stage=file_loaded ` +
        `elapsed=${Date.now() - this.startupStartedAt}ms`);
    }
    if (this.startupAttemptId.length > 0 && state.isBuffered && !this.startupPlaybackRestartLogged) {
      this.startupPlaybackRestartLogged = true;
      Logger.info(TAG, `[STARTUP] attempt=${this.startupAttemptId} stage=playback_restart ` +
        `elapsed=${Date.now() - this.startupStartedAt}ms`);
    }
    // TTFF closing marker: playback state reports playing and the timeline has
    // advanced past 0 — the first frame has been decoded and presented.
    if (this.startupAttemptId.length > 0 && !this.startupFirstFrameLogged
      && state.isPlaying && state.currentTime > 0) {
      this.startupFirstFrameLogged = true;
      Logger.info(TAG, `[STARTUP] attempt=${this.startupAttemptId} stage=first_frame ` +
        `elapsed=${Date.now() - this.startupStartedAt}ms ttff=${Date.now() - this.startupStartedAt}ms`);
    }

    if (state.isPlaying && !this.vm.isPlaying) {
      this.errorRetryCount = 0;
    }

    if (state.currentTime > 0) {
      this.lastKnownGoodPosition = state.currentTime;
    } else if (this.vm.currentTime > 0 && state.errorMsg) {
      this.lastKnownGoodPosition = this.vm.currentTime;
    }

    const prevDuration = this.vm.durationTime;
    const seekableRangesChanged = !this.areSeekableRangesEqual(this.vm.seekableRanges, state.seekableRanges);

    // 更新 ViewModel 字段（ArkTS 自动推送到绑定的 UI）
    this.vm.isPlaying = state.isPlaying;
    // 切清晰度/音轨：代理重建 + 新 load 完成前强制转圈；勿被旧源 snapshot 清掉
    if (this.qualitySwitchPending) {
      const hardError = !!(state.errorMsg && state.errorMsg.length > 0);
      if (hardError) {
        this.endSourceSwitchUi(false);
        this.vm.isBuffering = state.isBuffering;
      } else if (this.qualitySwitchLoadStarted && state.isReady && !state.isBuffering) {
        // 新源已就绪且不再缓冲
        this.endSourceSwitchUi(false);
      } else {
        this.vm.isSourceSwitching = true;
        this.vm.isBuffering = true;
      }
    } else {
      this.vm.isBuffering = state.isBuffering;
      this.vm.isSourceSwitching = false;
    }
    this.vm.isReady = state.isReady;
    this.vm.isSeeking = state.isSeeking;
    this.vm.isEnded = state.isEnded;
    this.vm.currentTime = state.currentTime;
    this.vm.durationTime = state.duration;
    this.vm.playbackSpeed = state.playbackSpeed;
    this.vm.cachedPercent = state.bufferingPercent;
    this.vm.seekableRanges = state.seekableRanges;
    this.vm.mediaTitle = state.mediaTitle;
    this.vm.containerFormat = state.containerFormat;
    this.vm.videoWidth = state.videoWidth;
    this.vm.videoHeight = state.videoHeight;
    this.vm.videoStreamCount = state.videoStreamCount;
    this.vm.audioStreamCount = state.audioStreamCount;
    this.vm.subtitleStreamCount = state.subtitleStreamCount;
    this.vm.videoCodec = state.videoCodec;
    this.vm.videoBitRate = state.videoBitRate;
    this.vm.frameRate = state.frameRate;
    this.vm.audioCodec = state.audioCodec;
    this.vm.audioBitRate = state.audioBitRate;
    this.vm.audioChannels = state.audioChannels;
    this.vm.audioSampleRate = state.audioSampleRate;
    this.vm.fileSize = state.fileSize;
    if (seekableRangesChanged || prevDuration !== state.duration) {
      this.seekableRangesListeners.forEach(listener => listener());
    }
    this.updateLocalTimelineFromState(state);
    const prevErrorMsg = this.vm.errorMsg;
    this.vm.errorMsg = state.errorMsg;

    if (prevDuration === 0 && this.vm.durationTime > 0) {
      this.updateAvSessionMetadata(false);
    }

    // 委托给 PlayerStateRelay：状态机 + AVSession + 节流进度
    this.stateRelay.onStateChange(state);

    // 新源 Prepared 后回收旧 session，避免 in-flight 请求 404
    if (state.isReady && this.pendingDestroySessionId) {
      LocalMediaProxy.destroySession(this.pendingDestroySessionId);
      this.pendingDestroySessionId = '';
    }
    if (state.isReady && this.pendingDestroyEdlAudioSessionId) {
      LocalMediaProxy.destroySession(this.pendingDestroyEdlAudioSessionId);
      this.pendingDestroyEdlAudioSessionId = '';
    }

    // 仅音频等：load 后引擎可能回到默认 vid=auto，就绪时重放期望值
    if (state.isReady) {
      this.applyVideoOutputPreference();
      if (!this.avSessionArtworkPublished) {
        this.avSessionArtworkPublished = true;
        this.updateAvSessionMetadata(true);
      }
    }

    // 错误监听（手动，需要特殊处理）
    const errorChanged = prevErrorMsg !== state.errorMsg;
    if (errorChanged && state.errorMsg && !this.isRecovering) {
      // MPV/FFmpeg may emit several Invalid states while probing or while an
      // automatic retry is in progress. Do not turn those diagnostics into UI.
      this.handlePlaybackError(state);
    }
    if (!state.errorMsg && (state.isReady || state.isPlaying)) {
      this.publishUserVisibleError('');
    }
  }

  private updateLocalTimelineFromState(state: PlaybackState): void {
    const sessionId = this.currentLocalMediaSessionId;
    if (!sessionId) return;

    const actualMs = Math.max(0, Math.round(state.currentTime * 1000));
    if (this.localTimelineAwaitingReady) {
      if (!state.isReady) return;

      // A resumed DASH seek can settle on a nearby segment boundary. A large difference here is
      // an outgoing-file snapshot, not a valid position for the new media generation.
      const toleranceMs = 30000;
      const differenceMs = Math.abs(actualMs - this.localTimelineExpectedStartMs);
      if (differenceMs > toleranceMs) {
        LocalMediaProxy.updatePlaybackPosition(sessionId, this.localTimelineExpectedStartMs);
        if (!this.localTimelineMismatchLogged) {
          this.localTimelineMismatchLogged = true;
          Logger.warn(TAG, `ignored cross-source timeline session=${sessionId} actualMs=${actualMs} ` +
            `expectedMs=${this.localTimelineExpectedStartMs}`);
        }
        return;
      }

      this.localTimelineAwaitingReady = false;
      Logger.info(TAG, `local timeline ready session=${sessionId} actualMs=${actualMs} ` +
        `expectedMs=${this.localTimelineExpectedStartMs}`);
    }

    // Zero is written explicitly when the load is armed. Ignore later transient zero snapshots so
    // buffering/reconfiguration cannot rewind SABR's request player time.
    if (actualMs > 0) {
      LocalMediaProxy.updatePlaybackPosition(sessionId, actualMs);
    }
  }

  private resetPlaybackState(): void {
    this.vm.reset();
    this.seekableRangesListeners.forEach(listener => listener());
    // Keep videoOutputEnabled: session audio-only must survive source switch.
    this.lastKnownGoodPosition = 0;
    this.waitingForBufferListeners.forEach(l => l(false));
    this.publishUserVisibleError('');
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

  private async handlePlaybackError(state: PlaybackState): Promise<void> {
    if (!this.isActive() || this.isRecovering) return;
    const category = state.errorCategory || 'unknown';
    // 使用 lastKnownGoodPosition 而非 this.currentTime，
    // 因为 error 回调中 player.reset() 会将 currentTime 清零
    const resumePos = this.lastKnownGoodPosition > 0 ? this.lastKnownGoodPosition : this.vm.currentTime;

    Logger.info(TAG, `handlePlaybackError category=${category} retryCount=${this.errorRetryCount} resumePos=${resumePos.toFixed(2)}s`);

    if ((category === 'network' || category === 'url_expired') && this.errorRetryCount < this.MAX_ERROR_RETRIES) {
      this.isRecovering = true;
      this.errorRetryCount++;
      try {
        await this.sleep(800);
        if (!this.isActive()) return;
        this.retryPlayback(resumePos);
      } finally {
        this.isRecovering = false;
      }
      return;
    }

    // 同 URL 快速重试已耗尽:升级给 entry 做"重新提取新鲜流 URL + 原地重载"
    // (PipePipe reloadPlayQueueManager 语义),而不是直接报错/放弃。
    if (this.onRetryWithFreshStreams) {
      Logger.info(TAG, `handlePlaybackError: escalate to fresh-stream retry resumePos=${resumePos.toFixed(2)}s`);
      this.errorRetryCount = 0;
      this.onRetryWithFreshStreams(resumePos);
      return;
    }

    this.errorRetryCount = 0;
    this.publishUserVisibleError(this.vm.errorMsg || '[PLAYER] PLAYBACK_FAILED');
    this.onErrorNeedsUserAction?.(this.vm.errorMsg);
  }

  private async retryPlayback(resumePos: number): Promise<void> {
    Logger.debug(TAG, `retryPlayback at ${resumePos.toFixed(2)}s`);
    const generation = this.mediaSessionGeneration;
    const current = this.vm.playerModel.getCurrentStreams();
    const playbackUrl = await this.createPlaybackUrl(current.video, current.audio, generation);
    if (!this.isMediaSessionCurrent(generation)) return;
    if (!playbackUrl) {
      this.setError('[PLAYER] RETRY_FAILED');
      return;
    }
    this.loadPlaybackSource(playbackUrl, resumePos, generation);
    if (this.vm.isPlaying) {
      this.playbackEngine.play();
    }
  }

  private async switchToProgressiveFallback(resumePos: number): Promise<void> {
    const generation = this.mediaSessionGeneration;
    const categories = this.vm.playerModel.categorizedStreams;
    if (categories.progressive.length > 0) {
      const progressive = this.selectBestProgressive(categories.progressive);
      this.vm.playerModel.updateVideoStream(progressive);
      this.vm.playerModel.updateAudioStream(undefined);
      Logger.info(TAG, `Switched to progressive fallback: ${progressive.quality} [${progressive.itag}]`);
      const playbackUrl = await this.createPlaybackUrl(progressive, undefined, generation);
      if (!this.isMediaSessionCurrent(generation)) return;
      if (playbackUrl) {
        this.loadPlaybackSource(playbackUrl, resumePos, generation);
        if (this.vm.isPlaying) {
          this.playbackEngine.play();
        }
        return;
      }
    }
    // If no progressive available, retry current source
    this.retryPlayback(resumePos);
  }

  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  private setError(error: string): void {
    this.vm.errorMsg = error;
    this.publishUserVisibleError(error);
    Logger.error(TAG, error);
  }

  private publishUserVisibleError(error: string): void {
    if (this.vm.userVisibleErrorMsg === error) return;
    this.vm.userVisibleErrorMsg = error;
    this.errorListeners.forEach(l => l(error));
  }

  private updateAvSessionMetadata(includeArtwork: boolean): void {
    const title = this.toPlainText(this.curSource.description) || this.toPlainText(this.curSource.name) || 'YourPipe';
    this.avSessionManager.setMetadata(title, this.curSource.author || '', this.vm.durationTime,
      this.curSource.thumbnailUrl, includeArtwork);
  }

  private toPlainText(value: ResourceStr): string {
    if (typeof value === 'string') return value;
    return '';
  }

  private describePlaybackUrl(url: string): string {
    const query = url.indexOf('?');
    const visible = query >= 0 ? url.substring(0, query) : url;
    return visible.length > 160 ? visible.substring(0, 160) + '...' : visible;
  }

  private attachBackgroundTaskListener(): void {
    if (this.backgroundTaskListener) return;
    const listener = new BackgroundTaskStateListener(this);
    this.backgroundTaskListener = listener;
    this.stateMachine.addListener(listener);
  }

  private detachBackgroundTaskListener(): void {
    if (this.backgroundTaskListener) {
      this.stateMachine.removeListener(this.backgroundTaskListener);
      this.backgroundTaskListener = null;
    }
    if (this.backgroundTaskActive) {
      const ctx = AppStorage.get<common.UIAbilityContext>('context');
      this.backgroundTaskActive = false;
      if (ctx) BackgroundTaskManager.stopContinuousTask(ctx);
    }
  }

  // 由 BackgroundTaskStateListener 调用，集中管理后台任务的开关。
  public _bgTaskOnStateChange(to: PlayerState): void {
    const ctx = AppStorage.get<common.UIAbilityContext>('context');
    if (!ctx) return;
    const isActive = to === PlayerState.PLAYING || to === PlayerState.PAUSED || to === PlayerState.BUFFERING
      || to === PlayerState.READY || to === PlayerState.LOADING;
    if (isActive && !this.backgroundTaskActive) {
      this.backgroundTaskActive = true;
      BackgroundTaskManager.startContinuousTask(ctx);
    } else if ((to === PlayerState.IDLE || to === PlayerState.RELEASED) && this.backgroundTaskActive) {
      this.backgroundTaskActive = false;
      BackgroundTaskManager.stopContinuousTask(ctx);
    }
  }
}

class BackgroundTaskStateListener implements StateChangeListener {
  private readonly owner: AvPlayerController;
  constructor(owner: AvPlayerController) {
    this.owner = owner;
  }
  onStateChange(_from: PlayerState, to: PlayerState): void {
    this.owner._bgTaskOnStateChange(to);
  }
}

/** EDL directive values must not contain the ';' / ',' separators. */
function edlMeta(text: string): string {
  return text.replace(/[;,]/g, '_');
}
