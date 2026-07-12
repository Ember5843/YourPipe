/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0
 */

import { VideoData, StreamInfo } from '../model/VideoData';
import { PlayerModel, StreamCategories, CurrentStreams, VideoEntry } from '../model/PlayerModel';
import { PlaybackEngine, PlaybackState, EngineConfig } from '../engine/PlaybackEngine';
import { MpvPlaybackEngine } from '../engine/MpvPlaybackEngine';
import { VideoHwCaps } from '../engine/VideoHwCaps';
import { LocalMediaProxy } from './LocalMediaProxy';
import { AvSessionManager } from '../common/AvSessionManager';
import { BackgroundTaskManager } from '../common/BackgroundTaskManager';
import { PlaybackPreferences } from '../common/PlaybackPreferences';
import { common } from '@kit.AbilityKit';
import { PlayerStateRelay, ProgressSubscriber } from '../state/PlayerStateRelay';
import { PlayerStateMachine, StateChangeListener } from '../state/PlayerStateMachine';
import { PlayerState } from '../state/PlayerState';
import { PlayerUiViewModel } from '../state/PlayerUiViewModel';
import Logger from '../utils/Logger';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';

export interface NativeLogBridgeFns {
  start: () => void;
  stop: () => void;
}

interface HlsVariant {
  url: string;
  height: number;
  bandwidth: number;
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

  private errorListeners: ((errorMsg: string) => void)[] = [];
  private waitingForBufferListeners: ((isWaiting: boolean) => void)[] = [];
  private seekableRangesListeners: (() => void)[] = [];

  private currentLocalMediaSessionId: string = '';
  private pendingDestroySessionId: string = '';
  private pendingStartFromSec: number = 0;

  /** 上一次 updateVideoSource 处理过的 source 引用，用于幂等去重。 */
  private lastUpdatedSourceRef: VideoData | null = null;
  /** 上一次 updateVideoSource 处理过的 videoId，用于幂等去重（引用比较在 @State/@Link 下不可靠）。 */
  private lastUpdatedVideoId: string = '';

  // Error recovery state
  private errorRetryCount: number = 0;
  private isRecovering: boolean = false;
  private readonly MAX_ERROR_RETRIES = 2;
  private lastKnownGoodPosition: number = 0;

  // Audio focus state
  private systemPausedByFocus: boolean = false;
  private duckActive: boolean = false;
  private savedVolume: number = 100;
  public onRequestRefreshStreams?: (videoId: string, resumePos: number) => Promise<VideoData | null>;
  public onErrorNeedsUserAction?: (errorMsg: string) => void;

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
  public subscribeEnded(listener: () => void): void {
    this.stateRelay.subscribeEnded(listener);
  }
  public unsubscribeEnded(listener: () => void): void {
    this.stateRelay.unsubscribeEnded(listener);
  }

  public addErrorListener(listener: (errorMsg: string) => void): void { this.errorListeners.push(listener); }
  public removeErrorListener(listener: (errorMsg: string) => void): void { this.errorListeners = this.errorListeners.filter(l => l !== listener); }
  public addWaitingForBufferListener(listener: (isWaiting: boolean) => void): void { this.waitingForBufferListeners.push(listener); }
  public removeWaitingForBufferListener(listener: (isWaiting: boolean) => void): void { this.waitingForBufferListeners = this.waitingForBufferListeners.filter(l => l !== listener); }
  public addSeekableRangesListener(listener: () => void): void { this.seekableRangesListeners.push(listener); }
  public removeSeekableRangesListener(listener: () => void): void { this.seekableRangesListeners = this.seekableRangesListeners.filter(l => l !== listener); }

  public getStreamCategories(): StreamCategories { return this.vm.playerModel.getStreamCategories(); }
  public getCurrentStreams(): CurrentStreams { return this.vm.playerModel.getCurrentStreams(); }
  public updateVideoStream(stream: StreamInfo): void { this.vm.playerModel.updateVideoStream(stream); }
  public updateAudioStream(stream: StreamInfo | undefined): void { this.vm.playerModel.updateAudioStream(stream); }
  public setCurIndex(curIndex: number): void { this.curIndex = curIndex; }
  public setIsPlaying(isPlaying: boolean): void { this.vm.isPlaying = isPlaying; }

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
    let audio: StreamInfo | undefined = undefined;
    if (entry.requiresSeparateAudio) {
      const cats = this.vm.playerModel.getStreamCategories();
      audio = this.selectBestCompatibleAudio(entry.stream, cats.audio);
    }
    await this.switchQuality(entry.stream, audio);
  }

  public setRefreshHandler(handler: (videoId: string, resumePos: number) => Promise<VideoData | null>): void {
    this.onRequestRefreshStreams = handler;
  }

  public setPendingStartFromSec(sec: number): void {
    this.pendingStartFromSec = sec > 0 ? sec : 0;
    Logger.debug(TAG, `Pending start position set to ${this.pendingStartFromSec}s`);
  }

  public async initPlaybackEngine(): Promise<void> {
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

    await this.avSessionManager.init();
    this.avSessionManager.onPlayCommand = () => {
      this.syncPlay();
      this.refreshPlaybackState();
    };
    this.avSessionManager.onPauseCommand = () => {
      this.syncPause();
      this.refreshPlaybackState();
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
      this.playbackEngine.stop();
      this.refreshPlaybackState();
    };
    this.avSessionManager.onCastStateChange = (isCasting: boolean, deviceName: string) => {
      this.vm.isCasting = isCasting;
      this.vm.castDeviceName = deviceName;
      this.onCastStateChange?.(isCasting, deviceName);
    };

    this.avSessionManager.onSystemPause = () => {
      Logger.info(TAG, 'System interrupt → pause');
      this.systemPausedByFocus = true;
      this.playbackEngine.pause();
      this.refreshPlaybackState();
    };
    this.avSessionManager.onSystemResume = () => {
      if (this.systemPausedByFocus) {
        Logger.info(TAG, 'System interrupt resolved → resume');
        this.systemPausedByFocus = false;
        this.playbackEngine.play();
        this.refreshPlaybackState();
      }
    };
    this.avSessionManager.onSystemDuck = () => {
      if (!this.duckActive) {
        this.duckActive = true;
        this.savedVolume = this.playbackEngine.getVolume();
        this.playbackEngine.setVolume(this.savedVolume * 0.2);
        Logger.info(TAG, `System duck → volume ${this.savedVolume} → ${this.savedVolume * 0.2}`);
      }
    };
    this.avSessionManager.onSystemUnduck = () => {
      if (this.duckActive) {
        this.duckActive = false;
        this.playbackEngine.setVolume(this.savedVolume);
        Logger.info(TAG, `System unduck → volume restored to ${this.savedVolume}`);
      }
    };

    const ok = await this.playbackEngine.initialize(AvPlayerController.engineConfigProvider?.() ?? {});
    if (ok) {
      this.playbackEngine.setStateCallback((state: PlaybackState) => this.onPlaybackStateChange(state));
      this.playbackEngine.setSubtitleCallback((text: string, _startTime: number, _duration: number) => {
        this.vm.subtitleText = text;
      });
      if (this.surfaceID.length > 0) {
        this.playbackEngine.attachSurface(this.surfaceID);
      }
    }
    if (!ok) {
      this.stateMachine.transition(PlayerState.ERROR);
    }
  }

  public async initAVPlayer(): Promise<void> {
    await this.initPlaybackEngine();
  }

  public async updateVideoSource(newSource: VideoData): Promise<void> {
    if (this.stateMachine.isOneOf(PlayerState.RELEASED)) return;

    if (!newSource.streams || newSource.streams.length === 0) {
      Logger.debug(TAG, `updateVideoSource ignored: no streams videoId=${newSource.videoId || 'N/A'}`);
      return;
    }

    // 幂等：PlayerSession 与 AVPlayer.onSourceChange 会先后推同一个 source，
    // 如果 controller 第二次仍跑完整 load 流程会让 MPV 重新建立 timeline / decoder，
    // 直播场景下还会因为 length=0 的 EDL 被 MPV 立刻判 EOF 触发自动 skip。
    // 注意：ArkUI 的 @State/@Link 传递会破坏对象引用一致性，故按 videoId 去重。
    const newVideoId = newSource.videoId || '';
    if (newVideoId.length > 0 && this.lastUpdatedVideoId === newVideoId) {
      Logger.debug(TAG, `updateVideoSource ignored: same videoId=${newVideoId}`);
      return;
    }
    this.lastUpdatedVideoId = newVideoId;
    this.lastUpdatedSourceRef = newSource;

    this.resetPlaybackState();
    this.deferCurrentSessionDestroy();
    this.curSource = newSource;
    this.curIndex = newSource.index;
    // 用视频原始分辨率给引擎播种 surface 几何：load() 在 aboutToAppear 阶段就跑，
    // 早于 NodeContainer.onAreaChange / onSurfaceChanged，UI 喂不进尺寸会导致
    // mpv video chain 初始化报 "Failed to get height and width"。视频原生尺寸不依赖布局，
    // 设给 NativeWindow buffer geometry 足以让 chain 起来，之后 onAreaChange 再用真实像素精修。
    if (newSource.width && newSource.height && newSource.width > 0 && newSource.height > 0) {
      this.playbackEngine.resizeSurface(newSource.width, newSource.height);
    }
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
    if (this.stateMachine.isOneOf(PlayerState.RELEASED, PlayerState.IDLE)) return;

    if (!this.stateMachine.transition(PlayerState.LOADING)) {
      // 极端情况：转换被拒绝（例如 ERROR 之外的非法源状态），强制对齐到 LOADING
      Logger.warn(TAG, `LOADING transition rejected from ${this.stateMachine.currentState}, forcing`);
      this.stateMachine.forceTransition(PlayerState.LOADING);
    }

    // Live streams: use HLS manifest URL directly, skip local proxy
    if (newSource.isLive && newSource.hlsUrl) {
      Logger.info(TAG, `Live stream detected, using HLS manifest directly: ${this.describePlaybackUrl(newSource.hlsUrl)}`);
      const playbackUrl = await this.resolveManifestPlaybackUrl(newSource.hlsUrl, true);
      if (!playbackUrl) {
        this.setError('[PLAYER] LOCAL_PROXY_FAILED');
        return;
      }
      this.updateAvSessionMetadata();
      this.vm.isBuffering = true;
      this.playbackEngine.load(playbackUrl, 0);
      if (newSource.play || newSource.auto) {
        this.avSessionManager.activateForPlayback();
        this.playbackEngine.play();
      }
      return;
    }

    const current = this.vm.playerModel.getCurrentStreams();
    const playbackUrl = await this.resolveManifestPlaybackUrl(
      await this.createPlaybackUrl(current.video, current.audio),
      newSource.isLive === true
    );
    if (!playbackUrl) {
      this.setError('[PLAYER] LOCAL_PROXY_FAILED');
      return;
    }

    this.updateAvSessionMetadata();
    this.vm.isBuffering = true;
    this.vm.currentSubtitleUrl = '';
    const startPos = this.pendingStartFromSec;
    this.pendingStartFromSec = 0;
    Logger.info(TAG,
      `load mpv: ${current.video?.height}p codec=${current.video?.codecs} ` +
      `hw=${VideoHwCaps.isCodecHardwareFriendly(current.video?.codecs)}`);
    this.playbackEngine.load(playbackUrl, startPos);
    if (newSource.play || newSource.auto) {
      this.avSessionManager.activateForPlayback();
      this.playbackEngine.play();
    }
  }

  public async switchQuality(videoStream: StreamInfo, audioStream?: StreamInfo): Promise<void> {
    if (!this.isActive() || !videoStream) return;
    const wasPlaying = this.vm.isPlaying;
    const resumePos = this.vm.currentTime;
    const effectiveAudio = this.isSeparatedDash(videoStream, audioStream) ? this.ensureCompatibleAudio(videoStream, audioStream) : undefined;

    this.vm.playerModel.updateVideoStream(videoStream);
    this.vm.playerModel.updateAudioStream(effectiveAudio);

    const playbackUrl = await this.createPlaybackUrl(videoStream, effectiveAudio);
    if (!playbackUrl) {
      this.setError('[PLAYER] LOCAL_PROXY_FAILED');
      return;
    }

    Logger.info(TAG,
      `switchQuality: ${videoStream.height}p codec=${videoStream.codecs} itag=${videoStream.itag} ` +
      `hw=${VideoHwCaps.isCodecHardwareFriendly(videoStream.codecs)} pos=${resumePos.toFixed(2)}s`);
    // Manual quality switch always allowed (including 4K VP9/AV1). Engine is mpv.
    this.playbackEngine.load(playbackUrl, resumePos);
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
    this.systemPausedByFocus = false;
    if (this.vm.isEnded) {
      this.playbackEngine.seek(0, true);
      this.vm.isEnded = false;
    }
    // Activate AudioSession with PAUSE_OTHERS before playing,
    // so our stream PAUSEs (not STOPs) background audio.
    this.avSessionManager.activateForPlayback();
    this.playbackEngine.play();
  }

  public syncPause(): void {
    if (!this.isActive()) return;
    this.systemPausedByFocus = false;
    this.playbackEngine.pause();
    // Release focus so background audio can resume.
    this.avSessionManager.deactivateForPause();
  }

  public syncStop(): void {
    if (!this.isActive()) return;
    this.systemPausedByFocus = false;
    this.playbackEngine.stop();
    this.avSessionManager.deactivateForPause();
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
    if (this.videoOutputEnabled === enabled) return;
    if (!this.stateMachine.isOneOf(PlayerState.READY, PlayerState.PLAYING, PlayerState.PAUSED,
      PlayerState.BUFFERING, PlayerState.COMPLETED)) {
      return;
    }
    this.videoOutputEnabled = enabled;
    this.playbackEngine.setVideoOutputEnabled(enabled);
    Logger.info(TAG, `setVideoOutputEnabled=${enabled}`);
  }


  public async checkCastState(): Promise<void> {
    await this.avSessionManager.checkCastState();
  }

  public releaseVideo(_index: number): void {
    if (this.stateMachine.isOneOf(PlayerState.RELEASED)) return;
    if (!this.stateMachine.transition(PlayerState.RELEASED)) {
      this.stateMachine.forceTransition(PlayerState.RELEASED);
    }
    Logger.debug(TAG, 'releaseVideo: destroy playback engine and LocalMediaProxy session');
    this.playbackEngine.destroy();
    this.destroyCurrentLocalSession();
    this.avSessionManager.destroy();
    this.detachBackgroundTaskListener();
    this.resetPlaybackState();
    this.lastUpdatedSourceRef = null;
    this.lastUpdatedVideoId = '';
    this.errorListeners = [];
    this.waitingForBufferListeners = [];
    this.seekableRangesListeners = [];
    this.vm.playerModel = new PlayerModel();
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
    if (video.requiresSeparateAudio) {
      audio = this.selectBestCompatibleAudio(video.stream, categories.audio);
    }
    this.vm.playerModel.updateVideoStream(video.stream);
    this.vm.playerModel.updateAudioStream(audio);

    const label = `${video.resolutionLabel} [${video.stream.itag}]`;
    if (video.deliveryMethod === 'DASH') {
      Logger.info(TAG, `Selected DASH separated: video=${label}${audio ? ` audio=${audio.quality} [${audio.itag}]` : ' (no audio)'}`);
    } else if (video.deliveryMethod === 'HLS') {
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
    const underCap = streams.filter(s => (s.height || this.heightFromQuality(s.quality)) <= maxHeight);
    // Prefer hardware-decodable codecs when the device reports capability.
    // Avoid auto-picking 4K VP9 on devices without VP9 hardware (soft-decode heat).
    const hwFriendly = underCap.filter(s => VideoHwCaps.isCodecHardwareFriendly(s.codecs));
    const pool = hwFriendly.length > 0
      ? hwFriendly
      : (underCap.length > 0 ? underCap : streams);
    return pool.slice().sort((a: StreamInfo, b: StreamInfo): number => {
      const h = (b.height || this.heightFromQuality(b.quality)) - (a.height || this.heightFromQuality(a.quality));
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
    // Prefer hard-decode-friendly codecs at the target height.
    // Skip VP9/AV1 when OHOS reports no hardware capability for that MIME.
    const underCap = entries.filter(e => e.height <= maxHeight);
    const hwFriendly = underCap.filter(e => VideoHwCaps.isCodecHardwareFriendly(e.stream.codecs));
    const pool = hwFriendly.length > 0
      ? hwFriendly
      : (underCap.length > 0 ? underCap : entries);
    const selected = pool.slice().sort((a: VideoEntry, b: VideoEntry): number => {
      const h = b.height - a.height;
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
        `selectBestVideoEntry: ${selected.resolutionLabel} codec=${selected.stream.codecs} ` +
        `itag=${selected.stream.itag} hwFriendly=${VideoHwCaps.isCodecHardwareFriendly(selected.stream.codecs)} ` +
        `caps[avc=${caps.avc},hevc=${caps.hevc},vp9=${caps.vp9},av1=${caps.av1}]`);
    }
    return selected;
  }

  private resolveMaxHeight(targetQuality: string): number {
    const cap: Record<string, number> = {
      'best': 9999,
      '1080p': 1080,
      '720p': 720,
      '480p': 480,
      '360p': 360,
      '240p': 240,
      '144p': 144
    };
    const requested = cap[targetQuality] ?? 9999;
    return requested;
  }

  private heightFromQuality(quality?: string): number {
    if (!quality) return 0;
    const match = quality.match(/(\d{3,4})p/);
    return match ? Number(match[1]) : 0;
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

  private async createPlaybackUrl(video?: StreamInfo, audio?: StreamInfo): Promise<string> {
    if (!video || !video.url) return '';

    // Defer old session destroy: mark stale, save for cleanup after new source is READY
    this.deferCurrentSessionDestroy();

    if (this.isRemoteManifestUrl(video.url)) {
      Logger.debug(TAG, `createPlaybackUrl: using remote manifest directly`);
      return video.url;
    }

    switch ((video.deliveryMethod || '').toUpperCase()) {
      case 'HLS':
        Logger.info(TAG, `createPlaybackUrl: HLS variant direct url=${this.describePlaybackUrl(video.url)}`);
        return video.url;

      case 'DASH':
        if (audio && this.isSeparatedDash(video, audio)) {
          return await this.buildDualEdlUrl(video, audio);
        }
        return await this.buildSingleProxyUrl(video);

      case 'PROGRESSIVE_HTTP':
      default:
        return await this.buildSingleProxyUrl(video);
    }
  }

  private async buildSingleProxyUrl(video: StreamInfo): Promise<string> {
    const sessionId = await LocalMediaProxy.createSingleUrlSession(video.url, video);
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

  private async buildDualEdlUrl(video: StreamInfo, audio: StreamInfo): Promise<string> {
    const durationMs = this.resolveDurationMs(video, audio);
    if (durationMs <= 0) {
      Logger.error(TAG, `buildDualEdlUrl: dual stream with unknown duration, refusing to build EDL`);
      return '';
    }
    Logger.info(TAG, `buildDualEdlUrl: video=[itag=${video.itag} ${video.quality} ${video.codecs}] audio=[itag=${audio.itag} ${audio.codecs}] durationMs=${durationMs}`);

    const sessionId = await LocalMediaProxy.createYoutubeDualUrlSession(video, audio, durationMs);
    const playbackUrl = LocalMediaProxy.getPlaybackUrl(sessionId);
    if (!playbackUrl.startsWith('http://127.0.0.1:')) {
      Logger.error(TAG, `buildDualEdlUrl: invalid playbackUrl="${playbackUrl}" sessionId=${sessionId}`);
      LocalMediaProxy.destroySession(sessionId);
      return '';
    }
    this.currentLocalMediaSessionId = sessionId;

    // 设置 URL 刷新回调：当 proxy 检测到 411 时，重新提取流 URL 并更新 session
    LocalMediaProxy.setSessionRefreshCallback(sessionId, async (): Promise<boolean> => {
      try {
        Logger.info(TAG, `URL refresh triggered for session=${sessionId}`);
        const videoId: string | undefined = this.curSource.videoId;
        if (!videoId || !this.onRequestRefreshStreams) {
          Logger.warn(TAG, `URL refresh: missing videoId or refresh callback`);
          return false;
        }
        const refreshed: VideoData | null = await this.onRequestRefreshStreams(videoId, this.playbackEngine.getState().currentTime);
        if (!refreshed?.streams) {
          Logger.warn(TAG, `URL refresh: failed to get new streams`);
          return false;
        }
        const newVideo: StreamInfo | undefined = refreshed.streams.find((s: StreamInfo) => s.itag === video.itag);
        const newAudio: StreamInfo | undefined = refreshed.streams.find((s: StreamInfo) => s.itag === audio.itag);
        if (!newVideo || !newAudio) {
          Logger.warn(TAG, `URL refresh: failed to find matching itags video=${video.itag} audio=${audio.itag}`);
          return false;
        }
        const ok: string = await LocalMediaProxy.refreshYoutubeDualUrlSession(sessionId, newVideo, newAudio, durationMs);
        if (!ok) {
          Logger.warn(TAG, `URL refresh: refreshYoutubeDualUrlSession failed`);
          return false;
        }
        Logger.info(TAG, `URL refresh succeeded for session=${sessionId}`);
        return true;
      } catch (e) {
        Logger.error(TAG, `URL refresh error: ${e}`);
        return false;
      }
    });

    const baseUrl = playbackUrl;
    const vUrl = `${baseUrl}/video/0`;
    const aUrl = `${baseUrl}/audio/0`;
    const durationSec = (durationMs / 1000).toFixed(3);

    const vCodec = this.codecToMpv(video.codecs || '');
    const vw = video.width || 0;
    const vh = video.height || 0;
    const vfps = video.fps || 0;
    const vbr = video.bitrate || 0;
    const aCodec = this.codecToMpv(audio.codecs || '');
    const abr = audio.bitrate || 0;

    const parts: string[] = [];
    parts.push('!new_stream', '!no_clip', '!no_chapters');
    let vDelay = `!delay_open,media_type=video,codec=${vCodec}`;
    if (vw > 0) vDelay += `,w=${vw}`;
    if (vh > 0) vDelay += `,h=${vh}`;
    if (vfps > 0) vDelay += `,fps=${vfps}`;
    parts.push(vDelay);
    if (vbr > 0) parts.push(`!track_meta,title=${video.quality || 'video'},byterate=${Math.floor(vbr / 8)}`);
    parts.push(`${vUrl},length=${durationSec}`);
    parts.push('!new_stream', '!no_clip', '!no_chapters');
    parts.push(`!delay_open,media_type=audio,codec=${aCodec}`);
    if (abr > 0) parts.push(`!track_meta,title=${audio.quality || 'audio'},byterate=${Math.floor(abr / 8)}`);
    parts.push(`${aUrl},length=${durationSec}`);

    const edlUrl = 'edl://' + parts.join(';') + ';';
    Logger.info(TAG, `buildDualEdlUrl: edl=${edlUrl.substring(0, 300)}`);
    return edlUrl;
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
    if (this.currentLocalMediaSessionId) {
      this.pendingDestroySessionId = this.currentLocalMediaSessionId;
      LocalMediaProxy.markSessionStale(this.currentLocalMediaSessionId);
      this.currentLocalMediaSessionId = '';
    }
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
    if (!this.currentLocalMediaSessionId) return;
    LocalMediaProxy.destroySession(this.currentLocalMediaSessionId);
    this.currentLocalMediaSessionId = '';
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
      const variants = this.parseHlsVariants(text, url);
      if (variants.length === 0) {
        return url;
      }
      const prefs = PlaybackPreferences.snapshot();
      const maxHeight = this.resolveMaxHeight(prefs.mobileQuality || '480p');
      const selected = variants
        .filter(v => (v.height || 0) <= maxHeight)
        .sort((a: HlsVariant, b: HlsVariant): number => (b.height || 0) - (a.height || 0) ||
          (b.bandwidth || 0) - (a.bandwidth || 0))[0]
        || variants.sort((a: HlsVariant, b: HlsVariant): number => (a.height || 0) - (b.height || 0))[0];
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
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        header: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36',
          'Referer': 'https://www.youtube.com/',
        },
        connectTimeout: 8000,
        readTimeout: 10000,
      });
      Logger.info(TAG, `manifest fetchText: code=${response.responseCode} resultType=${typeof response.result} len=${typeof response.result === 'string' ? response.result.length : 0}`);
      return typeof response.result === 'string' ? response.result : '';
    } catch (e) {
      Logger.warn(TAG, `manifest fetchText error: ${e}`);
      return '';
    } finally {
      request.destroy();
    }
  }

  private parseHlsVariants(text: string, baseUrl: string): HlsVariant[] {
    const lines = text.split(/\r?\n/);
    const variants: HlsVariant[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      const next = this.nextHlsUri(lines, i + 1);
      if (!next) continue;
      variants.push({
        url: this.resolveUrl(baseUrl, next),
        height: this.extractHlsHeight(line),
        bandwidth: this.extractHlsNumber(line, 'BANDWIDTH')
      });
    }
    return variants;
  }

  private nextHlsUri(lines: string[], start: number): string {
    for (let i = start; i < lines.length; i++) {
      const value = lines[i].trim();
      if (!value || value.startsWith('#')) continue;
      return value;
    }
    return '';
  }

  private extractHlsHeight(line: string): number {
    const match = line.match(/RESOLUTION=\d+x(\d+)/i);
    return match ? Number(match[1]) : 0;
  }

  private extractHlsNumber(line: string, key: string): number {
    const match = line.match(new RegExp(`${key}=(\\d+)`, 'i'));
    return match ? Number(match[1]) : 0;
  }

  private resolveUrl(baseUrl: string, uri: string): string {
    if (/^https?:\/\//i.test(uri)) return uri;
    const queryIndex = baseUrl.indexOf('?');
    const cleanBase = queryIndex >= 0 ? baseUrl.substring(0, queryIndex) : baseUrl;
    if (uri.startsWith('/')) {
      const origin = cleanBase.match(/^(https?:\/\/[^/]+)/i);
      return origin ? origin[1] + uri : uri;
    }
    const slash = cleanBase.lastIndexOf('/');
    return slash >= 0 ? cleanBase.substring(0, slash + 1) + uri : uri;
  }

  private isSeparatedDash(videoStream: StreamInfo, audioStream?: StreamInfo): boolean {
    if (!audioStream || !audioStream.url) return false;
    const categories = this.vm.playerModel.categorizedStreams;
    if (categories.video.length === 0 || categories.audio.length === 0) return false;
    const kind = videoStream.kind?.toLowerCase() || '';
    const delivery = videoStream.deliveryMethod?.toUpperCase() || '';
    return kind === 'video_only' || delivery === 'DASH' || videoStream.initRangeStart !== undefined;
  }

  private selectBestCompatibleAudio(videoStream: StreamInfo, audioStreams: StreamInfo[]): StreamInfo | undefined {
    const candidates = this.compatibleAudioCandidates(videoStream, audioStreams);
    if (candidates.length === 0) return undefined;
    return candidates.slice().sort((a: StreamInfo, b: StreamInfo): number => (b.bitrate || 0) - (a.bitrate || 0))[0];
  }

  private ensureCompatibleAudio(videoStream: StreamInfo, requestedAudio?: StreamInfo): StreamInfo | undefined {
    if (requestedAudio && this.isAudioCompatibleWithVideo(videoStream, requestedAudio)) {
      return requestedAudio;
    }
    return this.selectBestCompatibleAudio(videoStream, this.vm.playerModel.categorizedStreams.audio) || requestedAudio;
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

    if (state.isPlaying && !this.vm.isPlaying) {
      this.errorRetryCount = 0;
    }

    if (state.currentTime > 0) {
      this.lastKnownGoodPosition = state.currentTime;
    } else if (this.vm.currentTime > 0 && state.errorMsg) {
      this.lastKnownGoodPosition = this.vm.currentTime;
    }

    const prevDuration = this.vm.durationTime;

    // 更新 ViewModel 字段（ArkTS 自动推送到绑定的 UI）
    this.vm.isPlaying = state.isPlaying;
    this.vm.isBuffering = state.isBuffering;
    this.vm.isReady = state.isReady;
    this.vm.isSeeking = state.isSeeking;
    this.vm.isEnded = state.isEnded;
    this.vm.currentTime = state.currentTime;
    this.vm.duration = state.duration;
    this.vm.durationTime = state.duration;
    this.vm.playbackSpeed = state.playbackSpeed;
    this.vm.cachedPercent = state.bufferingPercent;
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
    const prevErrorMsg = this.vm.errorMsg;
    this.vm.errorMsg = state.errorMsg;

    if (prevDuration === 0 && this.vm.durationTime > 0) {
      this.updateAvSessionMetadata();
    }

    // 委托给 PlayerStateRelay：状态机 + AVSession + 节流进度
    this.stateRelay.onStateChange(state);

    // 新源 Prepared 后回收旧 session，避免 in-flight 请求 404
    if (state.isReady && this.pendingDestroySessionId) {
      LocalMediaProxy.destroySession(this.pendingDestroySessionId);
      this.pendingDestroySessionId = '';
    }

    // 错误监听（手动，需要特殊处理）
    const errorChanged = prevErrorMsg !== state.errorMsg;
    if (errorChanged && state.errorMsg) {
      this.errorListeners.forEach(l => l(this.vm.errorMsg));
      if (!this.isRecovering) {
        this.handlePlaybackError(state);
      }
    }
  }

  private resetPlaybackState(): void {
    this.vm.reset();
    this.videoOutputEnabled = true;
    this.lastKnownGoodPosition = 0;
    this.waitingForBufferListeners.forEach(l => l(false));
    this.errorListeners.forEach(l => l(''));
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
        if (category === 'url_expired') {
          await this.refreshAndReplay(resumePos);
        } else if (this.errorRetryCount > 1) {
          await this.refreshAndReplay(resumePos);
        } else {
          this.retryPlayback(resumePos);
        }
      } finally {
        this.isRecovering = false;
      }
      return;
    }

    this.errorRetryCount = 0;
    this.onErrorNeedsUserAction?.(this.vm.errorMsg);
  }

  private async retryPlayback(resumePos: number): Promise<void> {
    Logger.debug(TAG, `retryPlayback at ${resumePos.toFixed(2)}s`);
    const current = this.vm.playerModel.getCurrentStreams();
    const playbackUrl = await this.createPlaybackUrl(current.video, current.audio);
    if (!playbackUrl) {
      this.setError('[PLAYER] RETRY_FAILED');
      return;
    }
    this.playbackEngine.load(playbackUrl, resumePos);
    if (this.vm.isPlaying) {
      this.playbackEngine.play();
    }
  }

  private async refreshAndReplay(resumePos: number): Promise<void> {
    const videoId = this.curSource.videoId;
    if (!videoId || !this.onRequestRefreshStreams) {
      Logger.warn(TAG, 'Cannot refresh: no videoId or no refresh handler');
      this.retryPlayback(resumePos);
      return;
    }
    try {
      const refreshed = await this.onRequestRefreshStreams(videoId, resumePos);
      if (!refreshed || !refreshed.streams || refreshed.streams.length === 0) {
        Logger.warn(TAG, 'Refresh returned no streams, falling back to retry');
        this.retryPlayback(resumePos);
        return;
      }
      Logger.info(TAG, `Streams refreshed, ${refreshed.streams.length} streams available`);
      this.curSource = refreshed;
      this.vm.playerModel.classifyStreams(refreshed.streams);
      if (!this.selectInitialStreams(refreshed.isLive === true)) {
        this.setError('[PLAYER] REFRESH_NO_STREAM');
        return;
      }
      const current = this.vm.playerModel.getCurrentStreams();
      const playbackUrl = await this.createPlaybackUrl(current.video, current.audio);
      if (!playbackUrl) {
        this.setError('[PLAYER] REFRESH_PROXY_FAILED');
        return;
      }
      this.playbackEngine.load(playbackUrl, resumePos);
      if (this.vm.isPlaying) {
        this.playbackEngine.play();
      }
    } catch (e) {
      Logger.error(TAG, `refreshAndReplay failed: ${e}`);
      this.retryPlayback(resumePos);
    }
  }

  private async switchToProgressiveFallback(resumePos: number): Promise<void> {
    const categories = this.vm.playerModel.categorizedStreams;
    if (categories.progressive.length > 0) {
      const progressive = this.selectBestProgressive(categories.progressive);
      this.vm.playerModel.updateVideoStream(progressive);
      this.vm.playerModel.updateAudioStream(undefined);
      Logger.info(TAG, `Switched to progressive fallback: ${progressive.quality} [${progressive.itag}]`);
      const playbackUrl = await this.createPlaybackUrl(progressive, undefined);
      if (playbackUrl) {
        this.playbackEngine.load(playbackUrl, resumePos);
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
    this.errorListeners.forEach(l => l(error));
    Logger.error(TAG, error);
  }

  private updateAvSessionMetadata(): void {
    const title = this.toPlainText(this.curSource.description) || this.toPlainText(this.curSource.name) || 'YourPipe';
    this.avSessionManager.setMetadata(title, this.curSource.author || '', this.vm.durationTime, this.curSource.thumbnailUrl);
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
