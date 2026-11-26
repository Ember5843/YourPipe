/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0
 */

import { VideoData, StreamInfo } from '../model/VideoData';
import { PlayerModel, StreamCategories, CurrentStreams, VideoEntry } from '../model/PlayerModel';
import { PlaybackEngine, PlaybackState, PlaybackStats, EngineConfig, PlaybackErrorCategory } from '../engine/PlaybackEngine';
import { MpvPlaybackEngine } from '../engine/MpvPlaybackEngine';
import { registerDirectStream, registerHlsStream, unregisterStream } from '@yourpipe/libmpv-napi';
import type { NativeDirectStreamSpec, NativeHlsStreamSpec } from '@yourpipe/libmpv-napi';
import { VideoHwCaps } from '../engine/VideoHwCaps';
import { LocalMediaProxy } from './LocalMediaProxy';
import { AvSessionManager } from '../common/AvSessionManager';
import { BackgroundTaskManager } from '../common/BackgroundTaskManager';
import { PlaybackPreferences } from '../common/PlaybackPreferences';
import { ContextProvider } from '../common/ContextProvider';
import { proxyTrafficMeter } from '../proxy/ProxyTrafficMeter';
import { audio } from '@kit.AudioKit';
import { PlayerStateRelay, ProgressSubscriber, PlaybackStateSubscriber } from '../state/PlayerStateRelay';
import { normalizePlaybackTimeline } from '../state/PlaybackTimeline';
import { PlayerStateMachine, StateChangeListener } from '../state/PlayerStateMachine';
import { PlayerState } from '../state/PlayerState';
import { PlayerUiViewModel } from '../state/PlayerUiViewModel';
import Logger from '../utils/Logger';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { HttpDownloader, parseHlsMasterManifest, StreamInfo as ParsedHlsStreamInfo } from 'youtube_core';
import { SubtitleCue, parseVttSubtitles, parseJson3Subtitles, findActiveSubtitleText } from '../subtitle/VttSubtitleParser';

export type SubtitleErrorKind = 'rate_limited' | 'unavailable';
export type SubtitleErrorListener = (kind: SubtitleErrorKind) => void;
export type SubtitlePoTokenProvider = (videoId: string) => Promise<string | undefined>;

interface TextFetchResult {
  statusCode: number;
  body: string;
}

interface SubtitleFormatAttempt {
  cues: SubtitleCue[];
  statusCode: number;
  networkError: boolean;
}

interface SubtitleTrackFetchResult {
  cues: SubtitleCue[];
  rateLimited: boolean;
  networkError: boolean;
}

/** Live/post-live HLS track pair: video variant playlist + audio rendition playlist. */
interface HlsTrackPair {
  videoUrl: string;
  audioUrl: string;
  /** itag of the picked video variant — identity for menu highlight across master re-fetches. */
  itag?: number;
  videoBitrate?: number;
  audioBitrate?: number;
}

const TAG: string = '[PlayerLog][AvPlayerController]';

class PreparedPlaybackSource {
  url: string = '';
  mediaGeneration: number = 0;
  switchGeneration: number = 0;
  sessionId: string = '';
  audioSessionId: string = '';
  streamUrls: string[] = [];
  hlsAudioUrl: string = '';
  liveItag?: number;
  videoBitrate: number = 0;
}

@Observed
export class AvPlayerController {
  @Track public vm: PlayerUiViewModel = new PlayerUiViewModel();
  /** Surface 句柄；由 UI 在 XComponent.onLoad 写入，非响应式状态。 */
  public surfaceID: string = '';
  public onNextCommand: (() => void) | undefined = undefined;
  public onPreviousCommand: (() => void) | undefined = undefined;

  // 静态配置回调，由 entry 层注入
  private static engineConfigProvider: (() => EngineConfig) | null = null;
  /** 字幕认证头提供者：用于 tlang 自动翻译等需要登录态风控的轨道。 */
  private static subtitleAuthHeaderProvider: (() => Promise<Record<string, string>>) | null = null;
  /** 字幕 PoToken 提供者：仅命中 exp=xpe/xpv 或首次 0-cue 时按需调用，不阻塞常规播放。 */
  private static subtitlePoTokenProvider: SubtitlePoTokenProvider | undefined = undefined;

  public static setEngineConfigProvider(provider: () => EngineConfig): void {
    AvPlayerController.engineConfigProvider = provider;
  }

  public static setSubtitleAuthHeaderProvider(provider: () => Promise<Record<string, string>>): void {
    AvPlayerController.subtitleAuthHeaderProvider = provider;
  }

  public static setSubtitlePoTokenProvider(fn: SubtitlePoTokenProvider | undefined): void {
    AvPlayerController.subtitlePoTokenProvider = fn;
  }

  private curIndex: number = 0;
  private curSource: VideoData;
  /** External audio (HLS audio rendition playlist) for the current source, '' when none. */
  private currentHlsAudioUrl: string = '';
  /** itag of the live HLS variant currently playing; used to highlight the merged quality menu. */
  private livePlayingVariantItag: number | undefined = undefined;
  /** Parsed cues of the currently selected primary subtitle track (ArkUI overlay, not mpv-burned). */
  private subtitleCues: SubtitleCue[] = [];
  /** Guards async primary subtitle loads against stale completions (track switch / new source). */
  private subtitleLoadSeq: number = 0;
  /** Parsed cues of the currently selected secondary (bilingual) subtitle track. */
  private secondarySubtitleCues: SubtitleCue[] = [];
  /** Active secondary subtitle track index in vm.subtitleTracks (-1 = off). */
  private secondarySubtitleIndex: number = -1;
  /** Guards async secondary subtitle loads against stale completions. */
  private secondarySubtitleLoadSeq: number = 0;
  /** 8-entry in-memory LRU cache of parsed cues keyed by canonical track URL. */
  private static readonly SUBTITLE_CACHE_MAX_ENTRIES: number = 8;
  private subtitleCueCache: Map<string, SubtitleCue[]> = new Map<string, SubtitleCue[]>();
  /** Non-blocking subtitle load failure listener (429 rate-limit vs unavailable). */
  private subtitleErrorListener: SubtitleErrorListener | undefined = undefined;
  private mpvEngine: MpvPlaybackEngine = new MpvPlaybackEngine();
  private playbackEngine: PlaybackEngine = this.mpvEngine;
  private surfaceWidthPx: number = 0;
  private surfaceHeightPx: number = 0;
  private currentStreamUrls: string[] = [];
  private pendingDestroyStreamUrls: string[] = [];
  private avSessionManager: AvSessionManager = AvSessionManager.getInstance();
  private stateMachine: PlayerStateMachine = new PlayerStateMachine();
  private stateRelay: PlayerStateRelay = new PlayerStateRelay();
  private backgroundTaskListener: StateChangeListener | null = null;
  private backgroundTaskActive: boolean = false;
  private backgroundTaskStopTimer: number = -1;
  private static readonly BG_TASK_PAUSE_GRACE_MS: number = 20000;
  private engineInitPromise: Promise<boolean> | null = null;
  private mediaInitPromise: Promise<void> | null = null;
  /** Invalidates every async source/proxy operation from a closed media session. */
  private mediaSessionGeneration: number = 0;
  private sourceSwitchGeneration: number = 0;
  private latestPlaybackState?: PlaybackState;
  private transportIntentRevision: number = 0;
  private transportIntentPlaying: boolean = false;

  private errorListeners: Set<(errorMsg: string) => void> = new Set();
  private waitingForBufferListeners: Set<(isWaiting: boolean) => void> = new Set();
  private seekableRangesListeners: Set<() => void> = new Set();

  private currentLocalMediaSessionId: string = '';
  private pendingDestroySessionId: string = '';
  /** In-flight SABR lease key before LocalProxyServer registers the session (aborted on cancel). */
  private pendingSabrLeaseKey: string = '';
  /** EDL dual-track playback uses a second (audio) single-url session beside the main one. */
  private currentEdlAudioSessionId: string = '';
  private pendingDestroyEdlAudioSessionId: string = '';
  /** Prevent outgoing MPV snapshots from being routed into a newly-created local media session. */
  private localTimelineAwaitingReady: boolean = false;
  private localTimelineExpectedStartMs: number = 0;
  private localTimelineMismatchLogged: boolean = false;
  private pendingStartFromSec: number = 0;
  /** Shorts 单条循环意图；引擎重建/换源时由 MpvPlaybackEngine.load 重新应用。 */
  private fileLoopEnabled: boolean = false;
  /** Shorts 静音态与静音前音量（退出 Shorts 时恢复）。 */
  private muted: boolean = false;
  private volumeBeforeMute: number = 100;
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
  private playbackLoadSeq: number = 0;
  private prematureEofHandledSeq: number = -1;
  private prematureEofCount: number = 0;
  private prematureEofLastPosSec: number = -1;
  private prematureEofStableSinceMs: number = 0;

  // Playback stall watchdog (pure in-memory state)
  /** Tick interval for the stall watchdog timer. */
  private static readonly STALL_TICK_MS = 5000;
  /** A playback window is stalled when the position advances less than this over STALL_DETECT_MS. */
  private static readonly STALL_MIN_PROGRESS_SEC = 1;
  private static readonly STALL_DETECT_MS = 20000;
  private static readonly STARTUP_STALL_DETECT_MS = 35000;
  private stallWatchdogTimer: number = -1;
  private stallBaselinePosSec: number = -1;
  private stallBaselineAtMs: number = 0;
  private startupStallSinceMs: number = 0;
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
    return this.latestPlaybackState ?? this.playbackEngine.getState();
  }

  private statsObservationRefCount: number = 0;

  /**
   * Ref-counted lease for high-frequency MPV stats observation (frame count,
   * avsync, measured FPS, cache-speed). Keeps MPV's event loop quiet when no
   * stats UI is open.
   */
  public acquireStatsObservation(): void {
    this.statsObservationRefCount++;
    if (this.statsObservationRefCount === 1) {
      this.playbackEngine.setStatsObservationEnabled(true);
    }
  }

  public releaseStatsObservation(): void {
    if (this.statsObservationRefCount <= 0) {
      return;
    }
    this.statsObservationRefCount--;
    if (this.statsObservationRefCount === 0) {
      this.playbackEngine.setStatsObservationEnabled(false);
    }
  }

  /** Live playback statistics (Stats-for-Nerds style); all zeros until the engine is initialized. */
  getPlaybackStats(): PlaybackStats {
    if (!this.playbackEngine.isInitialized()) {
      return {
        cacheSpeedBps: 0,
        demuxerCacheDurationSec: 0,
        droppedFrames: 0,
        decoderDroppedFrames: 0,
        totalFrames: 0,
        avSyncMs: undefined,
        measuredFps: 0,
        bufferedBytes: 0,
        activeAudioFilters: '',
        transportKind: '',
        networkSpeedBps: 0
      };
    }
    // Unified 5s sliding-window inbound network speed (bytes/sec):
    // - ypstream:// (Direct VOD + Live HLS): native C++ NativeHttpTransport 5s meter (stats.networkSpeedBps)
    // - Local proxy (SABR / fallback RangeProxy): proxyTrafficMeter 5s meter
    // - Direct FFmpeg fallback (DVR HLS / local): MPV cache-speed
    const stats = this.playbackEngine.getPlaybackStats();
    if (stats.networkSpeedBps === undefined) {
      stats.networkSpeedBps = this.playbackEngine.isDirectNetworkSource()
        ? stats.cacheSpeedBps
        : proxyTrafficMeter.getRateBps();
    }
    return stats;
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
  public updateVideoStream(stream: StreamInfo): void {
    this.vm.playerModel.updateVideoStream(stream);
    this.syncCurrentStreamMeta();
  }
  public updateAudioStream(stream: StreamInfo | undefined): void {
    this.vm.playerModel.updateAudioStream(stream);
    this.syncCurrentStreamMeta();
  }
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
    this.vm.playerModel.mergeLiveHlsVariants(variants);
    // Point the menu selection at the variant actually playing (matched by itag —
    // the merged URLs come from a different master fetch and never string-match).
    // A user pick made before the merge landed is already a merged entry; keep it.
    const merged = this.vm.playerModel.getMergedVideoList();
    const cur = this.vm.playerModel.getCurrentStreams().video;
    if (!merged.some((e: VideoEntry) => e.stream === cur)) {
      const playing = merged.find((e: VideoEntry) =>
        e.stream.itag !== undefined && e.stream.itag === this.livePlayingVariantItag);
      if (playing) {
        this.vm.playerModel.updateVideoStream(playing.stream);
        this.syncCurrentStreamMeta();
      }
    }
    Logger.info(TAG, `live HLS variants merged count=${variants.length} playingItag=${this.livePlayingVariantItag ?? '-'}`);
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
      && !!cur.isDrc === !!audio.isDrc
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

  /** Startup-only warmup: initialize configured playback engine without AVSession or background-task registration. */
  public async prewarmPlaybackEngine(): Promise<void> {
    const ok = await this.ensurePlaybackEngineInitialized();
    if (!ok) {
      throw new Error('Playback engine prewarm failed');
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

    // Scheme A: single player entry for all system audio-focus hints.
    this.avSessionManager.onAudioFocusHint = (hint) => {
      this.handleAudioFocusHint(hint);
    };
    this.avSessionManager.onOutputDeviceDisconnected = (deviceName: string, deviceType) => {
      if (this.isActive() && (this.vm.isPlaying
        || this.stateMachine.isOneOf(PlayerState.PLAYING, PlayerState.BUFFERING))) {
        Logger.info(TAG, `[StateTrace] [AudioRoute] auto-pause on output disconnect type=${deviceType} name=${deviceName || '-'}`);
        this.syncPause();
      }
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
        // 字幕文本唯一写入口是覆盖层（switchSubtitle/updateSubtitleOverlayText）；
        // 不再注册引擎 subtitleCallback，mpv 也不会再 sub-add 烧录。
        if (this.surfaceID.length > 0) {
          if (this.surfaceWidthPx > 0 && this.surfaceHeightPx > 0) {
            this.playbackEngine.resizeSurface(this.surfaceWidthPx, this.surfaceHeightPx);
          }
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
    const submitStartedAt = Date.now();
    Logger.info(TAG, `[TTFF] submit_start videoId=${newSource.videoId || 'N/A'} `
      + `streams=${newSource.streams?.length || 0} live=${newSource.isLive === true}`);

    if (!newSource.streams || newSource.streams.length === 0) {
      Logger.debug(TAG, `updateVideoSource ignored: no streams videoId=${newSource.videoId || 'N/A'}`);
      return;
    }

    // Source submission has a single writer (PlayerSession.play()); duplicate
    // suppression lives there. A submission here always means a real load.
    this.resetPlaybackState();
    this.deferCurrentSessionDestroy();
    this.livePlayingVariantItag = undefined;
    this.subtitleCues = [];
    this.subtitleLoadSeq++;
    this.secondarySubtitleCues = [];
    this.secondarySubtitleIndex = -1;
    this.secondarySubtitleLoadSeq++;
    this.curSource = newSource;
    this.curIndex = newSource.index;
    // 直播禁用倍速：上一个点播残留的倍速不带入直播。mpv speed 跨 loadfile
    // 持久，vm.reset() 只清 UI，引擎值会在下次状态同步回流，必须重置引擎。
    if (newSource.isLive === true) {
      this.playbackEngine.setPlaybackSpeed(1.0);
    }
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
    Logger.info(TAG, `[TTFF] select_streams elapsed=${Date.now() - submitStartedAt}ms`);

    await this.initPlaybackEngine();
    Logger.info(TAG, `[TTFF] engine_ready elapsed=${Date.now() - submitStartedAt}ms`);
    if (!this.isMediaSessionCurrent(generation)
      || this.stateMachine.isOneOf(PlayerState.RELEASED, PlayerState.IDLE)) return;

    this.applyAudioPreferences();

    if (!this.stateMachine.transition(PlayerState.LOADING)) {
      // 极端情况：转换被拒绝（例如 ERROR 之外的非法源状态），强制对齐到 LOADING
      Logger.warn(TAG, `LOADING transition rejected from ${this.stateMachine.currentState}, forcing`);
      this.stateMachine.forceTransition(PlayerState.LOADING);
    }

    // Live streams: resolve one video variant + its audio rendition from the HLS
    // master and play them through native C++20 HlsLiveStream (ypstream://) with
    // concurrent segment prefetching & async playlist refresh.
    if (newSource.isLive && newSource.hlsUrl) {
      const candidate = new PreparedPlaybackSource();
      candidate.mediaGeneration = generation;
      candidate.switchGeneration = ++this.sourceSwitchGeneration;
      try {
        const maxHeight = this.resolveMaxHeight(prefs.defaultQuality || 'best');
        const hls = await this.resolveLiveHlsStreams(maxHeight);
        if (!this.isPreparedSourceCurrent(candidate)) return;
        Logger.info(TAG, `[TTFF] hls_variant_ready elapsed=${Date.now() - submitStartedAt}ms `
          + `selected=${hls?.videoUrl ? 'yes' : 'master-fallback'} itag=${hls?.itag ?? '-'}`);
        this.applyLiveHlsCandidate(hls, newSource.hlsUrl, undefined, 0, candidate);
        Logger.info(TAG, `Live stream: variant=${this.describePlaybackUrl(candidate.url)} `
          + `proto=${candidate.url.startsWith('ypstream://') ? 'ypstream-hls' : 'ffmpeg-hls'} `
          + `audio=${candidate.hlsAudioUrl ? 'external' : (hls ? 'muxed/none' : 'master-fallback')}`);
        this.updateAvSessionMetadata(false);
        this.vm.isBuffering = true;
        this.loadPlaybackSource(candidate.url, 0, generation, candidate);
        Logger.info(TAG, `[TTFF] load_submitted elapsed=${Date.now() - submitStartedAt}ms live=true`);
        const shouldAutoPlayLive = Boolean(newSource.play || newSource.auto);
        this.transportIntentPlaying = shouldAutoPlayLive;
        this.transportIntentRevision++;
        if (shouldAutoPlayLive) {
          this.avSessionManager.activateForPlayback();
          this.playbackEngine.play();
        }
      } finally {
        this.destroyPreparedSource(candidate);
      }
      return;
    }

    const current = this.vm.playerModel.getCurrentStreams();
    const sourceGeneration = this.sourceSwitchGeneration + 1;
    const playbackUrl = await this.createPlaybackUrl(current.video, current.audio, generation);
    if (sourceGeneration !== this.sourceSwitchGeneration) return;
    if (!this.isMediaSessionCurrent(generation)) return;
    Logger.info(TAG, `[TTFF] url_ready elapsed=${Date.now() - submitStartedAt}ms `
      + `kind=${current.video?.kind || '-'} delivery=${current.video?.deliveryMethod || '-'} `
      + `ok=${playbackUrl.length > 0}`);
    if (!playbackUrl) {
      this.setError('[PLAYER] LOCAL_PROXY_FAILED');
      return;
    }

    this.updateAvSessionMetadata(false);
    this.vm.isBuffering = true;
    this.vm.currentSubtitleUrl = '';
    this.vm.secondarySubtitleIndex = -1;
    this.vm.secondarySubtitleUrl = '';
    this.vm.secondarySubtitleText = '';
    this.secondarySubtitleIndex = -1;
    this.secondarySubtitleCues = [];
    this.secondarySubtitleLoadSeq++;
    const startPos = this.pendingStartFromSec;
    this.pendingStartFromSec = 0;
    Logger.info(TAG,
      `load mpv: ${current.video?.height}p codec=${current.video?.codecs} ` +
      `hw=${VideoHwCaps.isCodecHardwareFriendly(current.video?.codecs)} ` +
      `proto=${playbackUrl.includes('ypstream://') ? 'ypstream' : 'legacy'}`);
    this.loadPlaybackSource(playbackUrl, startPos, generation);
    Logger.info(TAG, `[TTFF] load_submitted elapsed=${Date.now() - submitStartedAt}ms live=false`);
    const shouldAutoPlay = Boolean(newSource.play || newSource.auto);
    this.transportIntentPlaying = shouldAutoPlay;
    this.transportIntentRevision++;
    if (shouldAutoPlay) {
      this.avSessionManager.activateForPlayback();
      this.playbackEngine.play();
    }
  }

  public async switchQuality(videoStream: StreamInfo, audioStream?: StreamInfo): Promise<void> {
    if (!this.isActive() || !videoStream) return;
    const generation = this.mediaSessionGeneration;
    const switchGeneration = ++this.sourceSwitchGeneration;
    const intentRevision = this.transportIntentRevision;
    const wasPlaying = this.vm.isPlaying;
    const resumePos = this.vm.currentTime;
    const effectiveAudio = this.isSeparatedDash(videoStream, audioStream) ? this.ensureCompatibleAudio(videoStream, audioStream) : undefined;

    // createPlaybackUrl 前保持转圈（SIDX/SABR 重建可能数秒）
    if (!this.qualitySwitchPending) {
      this.beginSourceSwitchUi();
    } else {
      this.vm.isSourceSwitching = true;
      this.vm.isBuffering = true;
    }

    // Live HLS variants (and the Auto master entry) start at the live edge:
    // a resumed offset can fall outside the DVR window of the new playlist.
    const isHlsSwitch = ((videoStream.deliveryMethod || '').toUpperCase() === 'HLS')
      || ((videoStream.kind || '').toLowerCase() === 'manifest_hls');
    const isLiveHlsSwitch = isHlsSwitch && this.curSource?.isLive === true;

    const candidate = new PreparedPlaybackSource();
    candidate.mediaGeneration = generation;
    candidate.switchGeneration = switchGeneration;
    try {
    if (isLiveHlsSwitch) {
      // 直播切档：重解析 master（音频 rendition 只存在于 master），选中的
      // variant 按 itag 身份匹配（URL 每次响应重签，不能精确匹配），
      // 新鲜签发的 variant playlist + 外挂音频 rendition 通过原生 HlsLiveStream 在直播边缘重启。
      const maxHeight = this.resolveMaxHeight(PlaybackPreferences.snapshot().defaultQuality || 'best');
      const hls = await this.resolveLiveHlsStreams(maxHeight, videoStream);
      if (!this.isPreparedSourceCurrent(candidate)) return;
      this.applyLiveHlsCandidate(hls, videoStream.url, videoStream.itag, videoStream.bitrate ?? 0, candidate);
    } else {
      candidate.url = await this.preparePlaybackUrl(videoStream, effectiveAudio, generation, candidate);
    }
    if (!this.isPreparedSourceCurrent(candidate)) return;
    if (!candidate.url) {
      this.endSourceSwitchUi(false);
      this.setError('[PLAYER] LOCAL_PROXY_FAILED');
      return;
    }

    Logger.info(TAG,
      `switchQuality: ${videoStream.height}p codec=${videoStream.codecs} itag=${videoStream.itag} ` +
      `hw=${VideoHwCaps.isCodecHardwareFriendly(videoStream.codecs)} pos=${resumePos.toFixed(2)}s`);
    this.qualitySwitchLoadStarted = true;
    this.vm.isSourceSwitching = true;
    this.vm.isBuffering = true;
    const loaded = this.loadPlaybackSource(candidate.url, isHlsSwitch ? 0 : resumePos, generation, candidate);
    if (!loaded) {
      this.endSourceSwitchUi(false);
      return;
    }
    this.vm.playerModel.updateVideoStream(videoStream);
    this.vm.playerModel.updateAudioStream(effectiveAudio);
    this.syncCurrentStreamMeta();
    if (intentRevision === this.transportIntentRevision ? wasPlaying : this.transportIntentPlaying) {
      this.playbackEngine.play();
    }
    } catch (e) {
      if (this.isPreparedSourceCurrent(candidate)) {
        this.endSourceSwitchUi(false);
        this.setError('[PLAYER] LOCAL_PROXY_FAILED');
      }
      Logger.warn(TAG, `source preparation failed switch=${switchGeneration}: ${(e as Error).message}`);
    } finally {
      this.destroyPreparedSource(candidate);
    }
  }

  public setPlaybackSpeed(speed: number): void {
    if (!this.isActive() || speed <= 0) return;
    // 直播禁用倍速：UI 入口已隐藏，这里兜底钳制到 1x
    const applied = this.curSource.isLive === true ? 1.0 : speed;
    this.vm.playbackSpeed = applied;
    this.playbackEngine.setPlaybackSpeed(applied);
  }

  /**
   * Shorts 单条循环开关。只影响 mpv `loop-file`，不改播放状态、不影响长视频。
   * 退出 Shorts 页必须显式关闭，否则后续长视频会在片尾无限重播。
   */
  public setFileLoop(enabled: boolean): void {
    if (this.fileLoopEnabled === enabled) return;
    this.fileLoopEnabled = enabled;
    this.playbackEngine.setFileLoop(enabled);
    Logger.info(TAG, `setFileLoop enabled=${enabled}`);
  }

  /**
   * 静音开关（Shorts 顶栏）。mpv volume 跨 load 保持，因此静音态需要在
   * 退出 Shorts 时显式解除；进入时按需重新设置。
   */
  public setMuted(muted: boolean): void {
    if (this.muted === muted) return;
    this.muted = muted;
    if (muted) {
      const current = this.playbackEngine.getVolume();
      this.volumeBeforeMute = current > 0 ? current : 100;
      this.playbackEngine.setVolume(0);
    } else {
      this.playbackEngine.setVolume(this.volumeBeforeMute > 0 ? this.volumeBeforeMute : 100);
    }
    Logger.info(TAG, `setMuted muted=${muted} volumeBeforeMute=${this.volumeBeforeMute}`);
  }

  public isMuted(): boolean {
    return this.muted;
  }

  /**
   * 从 PlaybackPreferences.snapshot() 同步全部音频增强参数（响度均衡、音画延迟）到引擎。
   * 可在播放过程中安全热更新，无需重启播放。
   */
  public applyAudioPreferences(): void {
    if (this.stateMachine.isOneOf(PlayerState.RELEASED)) return;
    const prefs = PlaybackPreferences.snapshot();
    this.playbackEngine.setAudioFilters(prefs.audioNormalizeEnabled);
    this.playbackEngine.setAudioDelayMs(prefs.audioDelayMs);
  }

  /**
   * 运行时热切换 MPV 音频滤镜（响度均衡）。
   */
  public setAudioFilters(normalize: boolean): void {
    if (this.stateMachine.isOneOf(PlayerState.RELEASED)) return;
    this.playbackEngine.setAudioFilters(normalize);
  }

  /**
   * 运行时热调整 MPV 音画延迟（毫秒，自动钳制到 -1000..1000）。
   */
  public setAudioDelayMs(delayMs: number): void {
    if (this.stateMachine.isOneOf(PlayerState.RELEASED)) return;
    this.playbackEngine.setAudioDelayMs(delayMs);
  }

  public resizeSurface(widthPx: number, heightPx: number): void {
    this.surfaceWidthPx = widthPx;
    this.surfaceHeightPx = heightPx;
    // 不门控 isActive：引擎层会缓存几何，供 LOADING 阶段 bindSurface 时套用，
    // 否则 mpv video chain 初始化拿不到宽高（typeNode surface 早于引擎就绪）。
    this.playbackEngine.resizeSurface(widthPx, heightPx);
    this.logDiagSnapshot(`surface-size:${widthPx}x${heightPx}`);
  }

  public setSurfaceID(surfaceID: string): void {
    if (!surfaceID || this.surfaceID === surfaceID) return;
    this.surfaceID = surfaceID;
    // 不门控 isActive：始终把 surfaceId 透传给引擎缓存，使引擎 initialize()/load() 时能据此重绑，
    // 避免 typeNode surface 早于引擎就绪导致的丢绑、无画面。
    this.playbackEngine.attachSurface(surfaceID);
    this.logDiagSnapshot('surface-bind');
  }

  public syncPlay(): void {
    if (!this.isActive()) return;
    this.transportIntentRevision++;
    this.transportIntentPlaying = true;
    this.clearFocusInterruptFlags('user_play');
    if (this.vm.isEnded) {
      this.playbackEngine.seek(0, true);
      this.vm.isEnded = false;
    }
    // Activate the default MEDIA AudioSession before play so other media yields focus.
    this.avSessionManager.activateForPlayback();
    this.playbackEngine.play();
    this.logDiagSnapshot('sync-play');
  }

  public syncPause(): void {
    if (!this.isActive()) return;
    this.transportIntentRevision++;
    this.transportIntentPlaying = false;
    this.clearFocusInterruptFlags('user_pause');
    this.playbackEngine.pause();
    // Release focus so background audio can resume.
    this.avSessionManager.deactivateForPause();
    this.logDiagSnapshot('sync-pause');
  }

  public syncStop(): void {
    if (!this.isActive()) return;
    this.transportIntentRevision++;
    this.transportIntentPlaying = false;
    this.sourceSwitchGeneration++;
    this.endSourceSwitchUi(false);
    this.clearFocusInterruptFlags('user_stop');
    this.playbackEngine.stop();
    this.avSessionManager.deactivateForPause();
    this.logDiagSnapshot('sync-stop');
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
    Logger.info(TAG, `[StateTrace] [AudioFocus] handleHint=${name} state=${this.stateMachine.currentState} `
      + `intentPlaying=${this.transportIntentPlaying} isPlaying=${this.vm.isPlaying} `
      + `sessionActive=${this.avSessionManager.isSessionActive()}`);
    this.logDiagSnapshot(`focus-in:${name}`);
    switch (hint) {
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_PAUSE:
        this.transportIntentRevision++;
        this.transportIntentPlaying = false;
        this.systemPausedByFocus = true;
        this.systemStoppedByFocus = false;
        this.playbackEngine.pause();
        Logger.info(TAG, `[AudioFocus] action=pause kind=temporary hint=${name}`);
        this.logDiagSnapshot(`focus-pause:${name}`);
        break;
      case audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_STOP:
        this.transportIntentRevision++;
        this.transportIntentPlaying = false;
        // 遵从系统接口：STOP = 永久失去音频焦点。必须停，并且**不能**自行重新
        // 激活会话去抢焦点——那会打断正在放音的其它应用。只有系统后续的
        // RESUME 提示、或用户主动按播放，才允许恢复。
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
        this.transportIntentRevision++;
        this.transportIntentPlaying = true;
        this.avSessionManager.activateForPlayback();
        this.playbackEngine.play();
        Logger.info(TAG, `[AudioFocus] action=resume hint=${name}`);
        this.logDiagSnapshot(`focus-resume:${name}`);
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
        // Unrecognized hints (e.g. raw=3 seen alongside session deactivation)
        // need no action; keep them observable at DEBUG without INFO noise.
        Logger.debug(TAG, `[AudioFocus] action=unhandled hint=${name} raw=${hint}`);
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
    this.syncSeekExact(seekTime);
  }

  public syncSeekFast(seekTime: number): void {
    this.resetStallBaselineTo(seekTime / 1000);
    if (this.isActive()) this.playbackEngine.seek(seekTime / 1000, true);
  }

  public syncSeekExact(seekTime: number): void {
    this.resetStallBaselineTo(seekTime / 1000);
    if (this.isActive()) this.playbackEngine.seek(seekTime / 1000, false);
  }

  private videoOutputEnabled: boolean = true;
  /** Timestamp when video output was turned off (vid=no); used to resync non-seekable live streams on resume. */
  private videoOutputDisabledAtMs: number = 0;

  /**
   * 诊断快照：把「焦点标志 / 会话状态 / 引擎状态 / 播放位置 / 音量 / 视频输出
   * 开关 / surface 绑定」放在同一行里对照。
   *
   * <p>「暂停恢复后无声」和「有声无画」这两类问题单看任何一个标志位都无法
   * 归因——必须能看到同一时刻的完整状态链。统一前缀 `[Diag]` 便于过滤。
   */
  private logDiagSnapshot(tag: string): void {
    // 引擎状态与会话激活都是**异步**的（play() 的状态回调、activate 的 await）。
    // 同步打快照会读到旧值（play 之后仍显示 paused）——延迟一拍再打。
    setTimeout(() => this.logDiagSnapshotNow(tag), 80);
  }

  private logDiagSnapshotNow(tag: string): void {
    try {
      const state = this.playbackEngine.getState();
      const stats = this.playbackEngine.getPlaybackStats();
      Logger.info(TAG, `[Diag][${tag}] engine=${state.engineState} `
        + `play=${state.isPlaying ? 1 : 0} ready=${state.isReady ? 1 : 0} `
        + `buf=${state.isBuffering ? 1 : 0} end=${state.isEnded ? 1 : 0} `
        + `pos=${state.currentTime.toFixed(2)}s `
        + `vstr=${state.videoStreamCount} astr=${state.audioStreamCount} `
        + `size=${state.videoWidth}x${state.videoHeight} `
        + `vol=${this.playbackEngine.getVolume()} duck=${this.duckActive ? 1 : 0} `
        + `focus=t${this.systemPausedByFocus ? 1 : 0}/p${this.systemStoppedByFocus ? 1 : 0} `
        + `appFg=${this.isAppForeground() ? 1 : 0} `
        + `session=${this.avSessionManager.isSessionActive() ? 'active' : 'inactive'} `
        + `vidOut=${this.videoOutputEnabled ? 1 : 0} `
        + `surface=${this.surfaceID.length > 0 ? 'bound' : 'none'} `
        + `dropped=${stats.droppedFrames} cache=${stats.demuxerCacheDurationSec.toFixed(1)}s`);
    } catch (e) {
      Logger.warn(TAG, `[Diag][${tag}] snapshot failed: ${(e as Error).message}`);
    }
  }

  /**
   * 应用是否在前台（entry 注入）。
   *
   * <p>**只用于诊断**，不参与任何播放决策：系统发来的焦点提示怎么处理，一律
   * 按系统接口的语义来（STOP = 永久失去焦点，停，且不自行抢回）。这个状态
   * 只是让日志能回答「STOP 是不是迟到了」——系统切后台后通常延迟几秒才发
   * STOP，这段时间里用户可能已经切回前台。
   */
  private appForegroundProvider?: () => boolean;

  setAppForegroundProvider(provider: () => boolean): void {
    this.appForegroundProvider = provider;
  }

  private isAppForeground(): boolean {
    if (!this.appForegroundProvider) {
      return true;
    }
    try {
      return this.appForegroundProvider();
    } catch (_e) {
      return true;
    }
  }

  public setVideoOutputEnabled(enabled: boolean): void {
    // Always remember desired flag (session audio-only survives load/LOADING).
    const wasEnabled = this.videoOutputEnabled;
    const changed = wasEnabled !== enabled;
    this.videoOutputEnabled = enabled;
    if (!enabled) {
      if (wasEnabled || this.videoOutputDisabledAtMs === 0) {
        this.videoOutputDisabledAtMs = Date.now();
      }
    }
    const inActivePlayback = this.stateMachine.isOneOf(PlayerState.READY, PlayerState.PLAYING,
      PlayerState.PAUSED, PlayerState.BUFFERING, PlayerState.COMPLETED);
    if (!inActivePlayback) {
      if (enabled) {
        this.videoOutputDisabledAtMs = 0;
      }
      if (changed) {
        Logger.info(TAG, `setVideoOutputEnabled=${enabled} (deferred until ready)`);
      }
      return;
    }
    this.playbackEngine.setVideoOutputEnabled(enabled);
    if (changed) {
      Logger.info(TAG, `setVideoOutputEnabled=${enabled}`);
      this.logDiagSnapshot(`video-output:${enabled ? 'on' : 'off'}`);
    }
    // Non-seekable live HLS streams cannot execute MPV's initiate_refresh_seek()
    // when vid flips no -> auto after long background audio-only playback, leaving
    // the video track stuck on stale pre-background frames (or 404/EOF on split A/V)
    // while audio keeps playing. Resync cleanly to the live edge on foreground return.
    if (enabled && !wasEnabled) {
      const offMs = this.videoOutputDisabledAtMs > 0 ? (Date.now() - this.videoOutputDisabledAtMs) : 0;
      this.videoOutputDisabledAtMs = 0;
      if (this.curSource?.isLive === true && this.curSource.hlsUrl) {
        Logger.info(TAG, `live video resume after ${(offMs / 1000).toFixed(1)}s vid=no — resyncing to live edge`);
        void this.retryPlayback(0);
      }
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


  /**
   * Close one media session while retaining the initialized MPV controller.
   * All source/proxy work from the previous generation becomes invalid immediately.
   */
  public closeMediaSession(clearSurface: boolean = false): void {
    this.mediaSessionGeneration++;
    this.sourceSwitchGeneration++;
    this.latestPlaybackState = undefined;
    this.transportIntentPlaying = false;
    this.transportIntentRevision++;
    this.videoOutputDisabledAtMs = 0;
    Logger.info(TAG, `closeMediaSession generation=${this.mediaSessionGeneration} clearSurface=${clearSurface}`);
    this.playbackEngine.stop();
    if (this.pendingSabrLeaseKey) {
      LocalMediaProxy.abortSabrLease(this.pendingSabrLeaseKey);
      this.pendingSabrLeaseKey = '';
    }
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
    this.stopStallWatchdog();
    this.systemPausedByFocus = false;
    this.systemStoppedByFocus = false;
    this.duckActive = false;
    this.savedVolume = 100;
    this.videoOutputEnabled = true;
    this.mpvEngine.setVideoOutputEnabled(true);
    this.mpvEngine.setPlaybackSpeed(1.0);
    if (clearSurface) {
      this.surfaceID = '';
      this.mpvEngine.detachSurface();
    }
  }

  public releaseVideo(_index: number): void {
    if (this.stateMachine.isOneOf(PlayerState.RELEASED)) return;
    this.closeMediaSession(true);
    if (!this.stateMachine.transition(PlayerState.RELEASED)) {
      this.stateMachine.forceTransition(PlayerState.RELEASED);
    }
    Logger.debug(TAG, 'releaseVideo: destroy playback engines and LocalMediaProxy session');
    this.mpvEngine.destroy();
    this.engineInitPromise = null;
    this.errorListeners.clear();
    this.waitingForBufferListeners.clear();
    this.seekableRangesListeners.clear();
    this.subtitleErrorListener = undefined;
    this.subtitleCueCache.clear();
  }

  public setSubtitleErrorListener(fn: SubtitleErrorListener | undefined): void {
    this.subtitleErrorListener = fn;
  }

  private notifySubtitleError(kind: SubtitleErrorKind): void {
    const listener = this.subtitleErrorListener;
    if (!listener) {
      return;
    }
    try {
      listener(kind);
    } catch (e) {
      Logger.warn(TAG, `subtitle error listener failed: ${(e as Error).message || e}`);
    }
  }

  /**
   * Subtitle selection renders through the ArkUI overlay (vm.subtitleText),
   * not mpv's burned-in libass path: timedtext is fetched and parsed app-side
   * (preferring fmt=json3 with automatic fmt=vtt fallback + 8-entry LRU cache
   * + on-demand subtitle PoToken fallback) so position/size stay configurable
   * and rendering never touches the video pipeline.
   */
  public switchSubtitle(url: string): void {
    if (url === this.vm.currentSubtitleUrl) return;
    this.vm.currentSubtitleUrl = url;
    this.subtitleCues = [];
    this.subtitleLoadSeq++;
    this.vm.subtitleText = '';
    if (url.length === 0) return;
    const cacheKey = this.canonicalizeSubtitleUrl(url);
    const cached = this.getCachedSubtitleCues(cacheKey);
    if (cached) {
      this.subtitleCues = cached;
      this.updateSubtitleOverlayText(this.vm.currentTime);
      Logger.info(TAG, `subtitle overlay cache hit: cues=${cached.length} url=${url.substring(0, 60)}`);
      return;
    }
    this.loadSubtitleOverlay(url, this.subtitleLoadSeq, false);
  }

  /**
   * Select secondary (bilingual) subtitle track by index in vm.subtitleTracks.
   * Pass index < 0 (or out of bounds) to disable the secondary subtitle track.
   */
  public selectSecondarySubtitle(index: number): void {
    if (index < 0 || index >= this.vm.subtitleTracks.length) {
      this.clearSecondarySubtitleState();
      return;
    }
    const track = this.vm.subtitleTracks[index];
    const url = track?.url || '';
    if (url.length === 0) {
      this.clearSecondarySubtitleState();
      return;
    }
    if (index === this.secondarySubtitleIndex && url === this.vm.secondarySubtitleUrl
      && this.secondarySubtitleCues.length > 0) {
      return;
    }
    this.secondarySubtitleIndex = index;
    this.vm.secondarySubtitleIndex = index;
    this.vm.secondarySubtitleUrl = url;
    this.secondarySubtitleCues = [];
    this.secondarySubtitleLoadSeq++;
    this.vm.secondarySubtitleText = '';
    const cacheKey = this.canonicalizeSubtitleUrl(url);
    const cached = this.getCachedSubtitleCues(cacheKey);
    if (cached) {
      this.secondarySubtitleCues = cached;
      this.updateSubtitleOverlayText(this.vm.currentTime);
      Logger.info(TAG, `secondary subtitle cache hit: idx=${index} cues=${cached.length} url=${url.substring(0, 60)}`);
      return;
    }
    this.loadSecondarySubtitleOverlay(url, index, this.secondarySubtitleLoadSeq, false);
  }

  public getSecondarySubtitleIndex(): number {
    return this.secondarySubtitleIndex;
  }

  /** Immediately recompute primary and secondary subtitle text at currentTime (works when paused). */
  public refreshSubtitleOverlay(): void {
    this.updateSubtitleOverlayText(this.vm.currentTime);
  }

  private clearSecondarySubtitleState(): void {
    this.secondarySubtitleIndex = -1;
    this.secondarySubtitleCues = [];
    this.secondarySubtitleLoadSeq++;
    this.vm.secondarySubtitleIndex = -1;
    this.vm.secondarySubtitleUrl = '';
    this.vm.secondarySubtitleText = '';
  }

  private canonicalizeSubtitleUrl(url: string): string {
    return url
      .replace(/([?&])fmt=[^&]*/g, '$1')
      .replace(/([?&])xosf=[^&]*/g, '$1')
      .replace(/([?&])pot=[^&]*/g, '$1')
      .replace(/([?&])potc=[^&]*/g, '$1')
      .replace(/&&+/g, '&')
      .replace(/\?&/, '?')
      .replace(/&$/, '')
      .replace(/\?$/, '');
  }

  private setQueryParam(url: string, key: string, value: string): string {
    const encoded = encodeURIComponent(value);
    const re = new RegExp(`([?&])${key}=[^&]*`, 'g');
    if (re.test(url)) {
      return url.replace(re, `$1${key}=${encoded}`);
    }
    const sep = url.includes('?') ? '&' : '?';
    return `${url}${sep}${key}=${encoded}`;
  }

  private buildSubtitleFormatUrl(url: string, fmt: 'json3' | 'vtt'): string {
    const cleaned = url
      .replace(/([?&])xosf=[^&]*/g, '$1')
      .replace(/&&+/g, '&')
      .replace(/\?&/, '?')
      .replace(/&$/, '')
      .replace(/\?$/, '');
    return this.setQueryParam(cleaned, 'fmt', fmt);
  }

  private needsSubtitlePoToken(url: string): boolean {
    return /[?&]exp=[^&]*(?:xpe|xpv)/i.test(url);
  }

  private appendSubtitlePoToken(url: string, token: string): string {
    let out = this.setQueryParam(url, 'pot', token);
    out = this.setQueryParam(out, 'potc', '1');
    out = this.setQueryParam(out, 'c', 'WEB');
    return out;
  }

  private getCachedSubtitleCues(cacheKey: string): SubtitleCue[] | undefined {
    const cached = this.subtitleCueCache.get(cacheKey);
    if (!cached) {
      return undefined;
    }
    // Refresh recency for LRU eviction.
    this.subtitleCueCache.delete(cacheKey);
    this.subtitleCueCache.set(cacheKey, cached);
    return cached;
  }

  private putCachedSubtitleCues(cacheKey: string, cues: SubtitleCue[]): void {
    if (cues.length === 0) {
      return;
    }
    if (this.subtitleCueCache.has(cacheKey)) {
      this.subtitleCueCache.delete(cacheKey);
    }
    this.subtitleCueCache.set(cacheKey, cues);
    while (this.subtitleCueCache.size > AvPlayerController.SUBTITLE_CACHE_MAX_ENTRIES) {
      const oldest = this.subtitleCueCache.keys().next();
      if (oldest.done) {
        break;
      }
      this.subtitleCueCache.delete(oldest.value);
    }
  }

  private async tryFetchSubtitleFormat(url: string, fmt: 'json3' | 'vtt'): Promise<SubtitleFormatAttempt> {
    const targetUrl = this.buildSubtitleFormatUrl(url, fmt);
    try {
      const res = await this.fetchTextWithStatus(targetUrl);
      if (res.statusCode === 429) {
        return { cues: [], statusCode: 429, networkError: false };
      }
      if (res.statusCode !== 200 || res.body.trim().length === 0) {
        return { cues: [], statusCode: res.statusCode, networkError: false };
      }
      const cues = fmt === 'json3' ? parseJson3Subtitles(res.body) : parseVttSubtitles(res.body);
      return { cues: cues, statusCode: 200, networkError: false };
    } catch {
      return { cues: [], statusCode: 0, networkError: true };
    }
  }

  private async tryFetchJson3ThenVtt(url: string): Promise<SubtitleTrackFetchResult> {
    const json3Res = await this.tryFetchSubtitleFormat(url, 'json3');
    if (json3Res.cues.length > 0) {
      return { cues: json3Res.cues, rateLimited: false, networkError: false };
    }
    if (json3Res.statusCode === 429) {
      return { cues: [], rateLimited: true, networkError: false };
    }
    Logger.debug(TAG, `subtitle json3 yielded 0 cues (status=${json3Res.statusCode}), falling back to vtt`);
    const vttRes = await this.tryFetchSubtitleFormat(url, 'vtt');
    if (vttRes.cues.length > 0) {
      return { cues: vttRes.cues, rateLimited: false, networkError: false };
    }
    return {
      cues: [],
      rateLimited: vttRes.statusCode === 429,
      networkError: vttRes.networkError || json3Res.networkError
    };
  }

  private async fetchAndParseSubtitleTrack(trackUrl: string): Promise<SubtitleTrackFetchResult> {
    const cacheKey = this.canonicalizeSubtitleUrl(trackUrl);
    const cached = this.getCachedSubtitleCues(cacheKey);
    if (cached) {
      return { cues: cached, rateLimited: false, networkError: false };
    }

    const potProvider = AvPlayerController.subtitlePoTokenProvider;
    const videoId = this.curSource.videoId || '';
    let attemptedPot = false;
    let workingUrl = trackUrl;

    if (this.needsSubtitlePoToken(trackUrl) && potProvider && videoId.length > 0) {
      attemptedPot = true;
      try {
        const token = await potProvider(videoId);
        if (token && token.length > 0) {
          workingUrl = this.appendSubtitlePoToken(trackUrl, token);
          Logger.info(TAG, `subtitle PoToken attached proactively (exp=xpe/xpv) video=${videoId}`);
        }
      } catch (e) {
        Logger.warn(TAG, `subtitle proactive PoToken mint failed: ${(e as Error).message || e}`);
      }
    }

    let result = await this.tryFetchJson3ThenVtt(workingUrl);

    if (result.cues.length === 0 && !result.rateLimited && !result.networkError
      && !attemptedPot && potProvider && videoId.length > 0) {
      attemptedPot = true;
      try {
        const token = await potProvider(videoId);
        if (token && token.length > 0) {
          Logger.info(TAG, `subtitle 0-cue fallback: retrying once with PoToken video=${videoId}`);
          const potUrl = this.appendSubtitlePoToken(trackUrl, token);
          result = await this.tryFetchJson3ThenVtt(potUrl);
        }
      } catch (e) {
        Logger.warn(TAG, `subtitle fallback PoToken mint failed: ${(e as Error).message || e}`);
      }
    }

    if (result.cues.length > 0) {
      this.putCachedSubtitleCues(cacheKey, result.cues);
    }
    return result;
  }

  /** Primary subtitle fetch + parse with one bounded retry on transient network error; stale completions are dropped by seq/url. */
  private loadSubtitleOverlay(url: string, seq: number, isRetry: boolean): void {
    this.fetchAndParseSubtitleTrack(url).then((res: SubtitleTrackFetchResult) => {
      if (seq !== this.subtitleLoadSeq || url !== this.vm.currentSubtitleUrl) return;
      if (res.cues.length > 0) {
        this.subtitleCues = res.cues;
        this.updateSubtitleOverlayText(this.vm.currentTime);
        Logger.info(TAG, `subtitle overlay loaded: cues=${this.subtitleCues.length} retry=${isRetry} url=${url.substring(0, 60)}`);
        return;
      }
      if (res.networkError && !res.rateLimited && !isRetry) {
        Logger.warn(TAG, `subtitle overlay network failure, retrying once: url=${url.substring(0, 60)}`);
        setTimeout(() => {
          if (seq !== this.subtitleLoadSeq || url !== this.vm.currentSubtitleUrl) return;
          this.loadSubtitleOverlay(url, seq, true);
        }, 2000);
        return;
      }
      const kind: SubtitleErrorKind = res.rateLimited ? 'rate_limited' : 'unavailable';
      Logger.warn(TAG, `subtitle overlay failed (${kind}), resetting selection: retry=${isRetry} url=${url.substring(0, 60)}`);
      this.resetFailedSubtitleSelection(url);
      this.notifySubtitleError(kind);
    }).catch((e: Error) => {
      if (seq !== this.subtitleLoadSeq || url !== this.vm.currentSubtitleUrl) return;
      if (!isRetry) {
        Logger.warn(TAG, `subtitle overlay load failed, retrying once: ${e.message || e}`);
        setTimeout(() => {
          if (seq !== this.subtitleLoadSeq || url !== this.vm.currentSubtitleUrl) return;
          this.loadSubtitleOverlay(url, seq, true);
        }, 2000);
      } else {
        Logger.error(TAG, `subtitle overlay load failed after retry: ${e.message || e}`);
        this.resetFailedSubtitleSelection(url);
        this.notifySubtitleError('unavailable');
      }
    });
  }

  /** Secondary subtitle fetch + parse with independent seq guard and shared LRU/json3/vtt/PoToken pipeline. */
  private loadSecondarySubtitleOverlay(url: string, index: number, seq: number, isRetry: boolean): void {
    this.fetchAndParseSubtitleTrack(url).then((res: SubtitleTrackFetchResult) => {
      if (seq !== this.secondarySubtitleLoadSeq || url !== this.vm.secondarySubtitleUrl) return;
      if (res.cues.length > 0) {
        this.secondarySubtitleCues = res.cues;
        this.updateSubtitleOverlayText(this.vm.currentTime);
        Logger.info(TAG, `secondary subtitle loaded: idx=${index} cues=${this.secondarySubtitleCues.length} retry=${isRetry} url=${url.substring(0, 60)}`);
        return;
      }
      if (res.networkError && !res.rateLimited && !isRetry) {
        Logger.warn(TAG, `secondary subtitle network failure, retrying once: idx=${index} url=${url.substring(0, 60)}`);
        setTimeout(() => {
          if (seq !== this.secondarySubtitleLoadSeq || url !== this.vm.secondarySubtitleUrl) return;
          this.loadSecondarySubtitleOverlay(url, index, seq, true);
        }, 2000);
        return;
      }
      const kind: SubtitleErrorKind = res.rateLimited ? 'rate_limited' : 'unavailable';
      Logger.warn(TAG, `secondary subtitle failed (${kind}), resetting selection: idx=${index} retry=${isRetry}`);
      this.resetFailedSecondarySubtitleSelection(url);
      this.notifySubtitleError(kind);
    }).catch((e: Error) => {
      if (seq !== this.secondarySubtitleLoadSeq || url !== this.vm.secondarySubtitleUrl) return;
      if (!isRetry) {
        Logger.warn(TAG, `secondary subtitle load failed, retrying once: ${e.message || e}`);
        setTimeout(() => {
          if (seq !== this.secondarySubtitleLoadSeq || url !== this.vm.secondarySubtitleUrl) return;
          this.loadSecondarySubtitleOverlay(url, index, seq, true);
        }, 2000);
      } else {
        Logger.error(TAG, `secondary subtitle load failed after retry: ${e.message || e}`);
        this.resetFailedSecondarySubtitleSelection(url);
        this.notifySubtitleError('unavailable');
      }
    });
  }

  /** 字幕加载失败后复位选中态（仅当失败 URL 仍是当前选中时）。 */
  private resetFailedSubtitleSelection(url: string): void {
    if (url === this.vm.currentSubtitleUrl) {
      this.vm.currentSubtitleUrl = '';
      this.subtitleCues = [];
      this.vm.subtitleText = '';
    }
  }

  /** 副字幕加载失败后复位选中态（仅当失败 URL 仍是当前副轨时）。 */
  private resetFailedSecondarySubtitleSelection(url: string): void {
    if (url === this.vm.secondarySubtitleUrl) {
      this.secondarySubtitleIndex = -1;
      this.secondarySubtitleCues = [];
      this.vm.secondarySubtitleIndex = -1;
      this.vm.secondarySubtitleUrl = '';
      this.vm.secondarySubtitleText = '';
    }
  }

  /**
   * AI 翻译/生成字幕入口：字幕内容已由应用侧生成（VTT 文本），跳过网络
   * fetch 直接进 overlay 管线。trackKey（如 ai://<videoId>/<lang>）占用
   * currentSubtitleUrl，菜单选中态与 seq 防串扰逻辑因此原样复用。
   * 与 switchSubtitle 不同，同名 key 也会重载内容（双语切换/重试重推）。
   * 同 key 重推（P3 ASR 每 ~400ms 的增量刷新）不清空 vm.subtitleText：
   * 清空会闪一空帧再等 ~100ms time-pos 驱动重写，表现为字幕闪烁；
   * 新 cue 列表同步就位后，下一个 time-pos tick 自然刷新文本。
   */
  public switchSubtitleText(trackKey: string, vttText: string): void {
    const trackChanged = this.vm.currentSubtitleUrl !== trackKey;
    this.vm.currentSubtitleUrl = trackKey;
    this.subtitleCues = [];
    this.subtitleLoadSeq++;
    if (trackChanged) {
      this.vm.subtitleText = '';
    }
    if (trackKey.length === 0 || vttText.length === 0) return;
    this.subtitleCues = parseVttSubtitles(vttText);
    this.updateSubtitleOverlayText(this.vm.currentTime);
    Logger.info(TAG, `subtitle overlay (generated) loaded: cues=${this.subtitleCues.length} key=${trackKey.substring(0, 60)}`);
  }

  /**
   * ASR PCM tap 已随播放器回退移除（vendored libmpv 回到 0.5.9，无 asrtap
   * 导出）。P3 实时识别整体为 [DISABLED] 状态，入口本已注释；此处不再保留
   * 透传方法。重新启用 P3 需要先恢复 libmpv_napi 的 tap 支持。
   */

  /** Driven by engine time-pos updates (~100ms) or refreshSubtitleOverlay(); cheap enough per tick. */
  private updateSubtitleOverlayText(positionSec: number): void {
    // 正值延迟 = 字幕延后显示 → 用更早的播放位置查找（mpv sub-delay 语义）
    const offsetMs = PlaybackPreferences.snapshot().subtitleOffsetMs;
    const lookupMs = Math.round(positionSec * 1000) - offsetMs;
    if (this.vm.currentSubtitleUrl.length > 0) {
      const text = findActiveSubtitleText(this.subtitleCues, lookupMs);
      if (text !== this.vm.subtitleText) {
        this.vm.subtitleText = text;
      }
    } else if (this.vm.subtitleText.length > 0) {
      this.vm.subtitleText = '';
    }
    if (this.secondarySubtitleIndex >= 0 && this.vm.secondarySubtitleUrl.length > 0) {
      const secondaryText = findActiveSubtitleText(this.secondarySubtitleCues, lookupMs);
      if (secondaryText !== this.vm.secondarySubtitleText) {
        this.vm.secondarySubtitleText = secondaryText;
      }
    } else if (this.vm.secondarySubtitleText.length > 0) {
      this.vm.secondarySubtitleText = '';
    }
  }

  private selectInitialStreams(isLive: boolean): boolean {
    const categories = this.vm.playerModel.categorizedStreams;
    if (isLive) {
      const manifest = this.selectManifestByCap(categories.hlsManifest.length > 0 ? categories.hlsManifest : categories.dashManifest);
      if (manifest) {
        this.vm.playerModel.updateVideoStream(manifest);
        this.vm.playerModel.updateAudioStream(undefined);
        this.syncCurrentStreamMeta();
        Logger.info(TAG, `Selected live manifest: ${this.describePlaybackUrl(manifest.url)}`);
        return true;
      }
    }

    const merged = this.vm.playerModel.getMergedVideoList();
    const video = this.selectBestVideoEntry(merged);
    if (!video) {
      const manifest = this.selectManifestByCap(categories.hlsManifest.length > 0 ? categories.hlsManifest : categories.dashManifest);
      if (manifest) {
        this.vm.playerModel.updateVideoStream(manifest);
        this.vm.playerModel.updateAudioStream(undefined);
        this.syncCurrentStreamMeta();
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
    this.syncCurrentStreamMeta();

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

  private selectBestVideo(streams: StreamInfo[]): StreamInfo | undefined {
    const prefs = PlaybackPreferences.snapshot();
    // 直播与点播一致，统一跟随设置里的默认清晰度偏好。
    const maxHeight = this.resolveMaxHeight(prefs.defaultQuality);
    const underCap = streams.filter(s => this.resolutionLabelHeight(s) <= maxHeight);
    // hwFriendly 是同高度内的排序权重，不是全局过滤：>1080p 的流基本只有
    // VP9/AV1，全局剔除会让用户设置的 2K/4K/8K 上限永远封顶在 1080p H.264。
    const pool = underCap.length > 0 ? underCap : streams;
    return pool.slice().sort((a: StreamInfo, b: StreamInfo): number => {
      const h = this.resolutionLabelHeight(b) - this.resolutionLabelHeight(a);
      if (h !== 0) return h;
      const hw = Number(VideoHwCaps.isCodecHardwareFriendly(b.codecs))
        - Number(VideoHwCaps.isCodecHardwareFriendly(a.codecs));
      if (hw !== 0) return hw;
      const codec = this.codecPriority(b) - this.codecPriority(a);
      if (codec !== 0) return codec;
      return (b.bitrate || 0) - (a.bitrate || 0);
    })[0];
  }

  private selectBestProgressive(streams: StreamInfo[]): StreamInfo {
    const selected = this.selectBestVideo(streams);
    return selected || streams[0];
  }

  private selectManifestByCap(streams: StreamInfo[]): StreamInfo | undefined {
    if (!streams || streams.length === 0) return undefined;
    const selected = this.selectBestVideo(streams);
    return selected || streams[0];
  }

  private selectBestVideoEntry(entries: VideoEntry[]): VideoEntry | undefined {
    if (!entries || entries.length === 0) {
      return undefined;
    }
    const prefs = PlaybackPreferences.snapshot();
    const maxHeight = this.resolveMaxHeight(prefs.defaultQuality);
    // hwFriendly 是同高度内的排序权重，不是全局过滤：>1080p 的流基本只有
    // VP9/AV1，全局剔除会让用户设置的 2K/4K/8K 上限永远封顶在 1080p H.264。
    const underCap = entries.filter(e => this.resolutionLabelHeight(e.stream) <= maxHeight);
    const pool = underCap.length > 0 ? underCap : entries;
    const selected = pool.slice().sort((a: VideoEntry, b: VideoEntry): number => {
      const h = this.resolutionLabelHeight(b.stream) - this.resolutionLabelHeight(a.stream);
      if (h !== 0) {
        return h;
      }
      const hw = Number(VideoHwCaps.isCodecHardwareFriendly(b.stream.codecs))
        - Number(VideoHwCaps.isCodecHardwareFriendly(a.stream.codecs));
      if (hw !== 0) {
        return hw;
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

  /**
   * Live HLS resolution: one master GET, pick a video variant (by explicit
   * picked variant, else highest ≤ targetHeight) and pair it with the master's
   * audio rendition playlist (EXT-X-MEDIA), played as mpv external audio.
   * YouTube live masters are split A/V (video-only variants); muxed masters
   * have no renditions and the variant alone already carries audio.
   * Returns null when the master cannot be fetched/parsed (caller falls back).
   */
  private async resolveLiveHlsStreams(targetHeight: number, picked?: StreamInfo): Promise<HlsTrackPair | null> {
    const masterUrl = this.curSource?.hlsUrl || '';
    if (!masterUrl) return null;
    const masterStartedAt = Date.now();
    const text = await this.fetchText(masterUrl);
    Logger.info(TAG, `[TTFF] hls_master elapsed=${Date.now() - masterStartedAt}ms len=${text.length}`);
    if (!text.includes('#EXT-X-STREAM-INF')) return null;
    // HLS 解析统一走 youtube_core HlsManifestParser（本类只保留 HTTP 拉取，
    // 网络层归收到 youtube_core 属后续 P4 项）。
    const parsed = parseHlsMasterManifest(text, this.curSource?.videoId || '');
    const variants = parsed.videoStreams.filter((s) => !!s.url);
    if (variants.length === 0) return null;
    let selected = picked ? this.matchLiveHlsVariant(variants, picked) : undefined;
    if (!selected) {
      if (picked) {
        Logger.warn(TAG, `resolveLiveHlsStreams: picked variant not in fresh master `
          + `(itag=${picked.itag ?? '-'} quality=${picked.quality || '-'}), falling back to ${targetHeight}p cap`);
      }
      selected = variants
        .filter((s) => (s.height || 0) <= targetHeight)
        .sort((a, b) => (b.height || 0) - (a.height || 0))[0]
        || variants.slice().sort((a, b) => (a.height || 0) - (b.height || 0))[0];
    }
    // Audio pick: highest-bandwidth rendition (audio-only variants carry
    // BANDWIDTH; EXT-X-MEDIA renditions have none and keep manifest order,
    // where YouTube lists the default/original first).
    const audio = parsed.audioStreams.slice()
      .sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0))[0];
    Logger.info(TAG, `resolveLiveHlsStreams: ${selected.height || 0}p itag=${selected.itag ?? '-'} variants=${variants.length} audioRenditions=${parsed.audioStreams.length}`);
    const pair: HlsTrackPair = {
      videoUrl: selected.url,
      audioUrl: audio?.url || '',
      itag: selected.itag,
      videoBitrate: selected.bitrate,
      audioBitrate: audio?.bitrate,
    };
    return pair;
  }

  /**
   * Variant identity across master re-fetches. Live master responses re-sign
   * every variant URL per request (expire/ei/sig rotate), so full-URL equality
   * between two fetches never holds. itag is the stable identity (parser
   * extracts it from the `/itag/<n>/` path segment); exact URL and
   * height+fps are fallbacks for non-YouTube / unsigned masters.
   */
  private matchLiveHlsVariant(variants: ParsedHlsStreamInfo[], picked: StreamInfo): ParsedHlsStreamInfo | undefined {
    if (picked.itag !== undefined) {
      const byItag = variants.find((s) => s.itag === picked.itag);
      if (byItag) return byItag;
    }
    if (picked.url) {
      const byUrl = variants.find((s) => s.url === picked.url);
      if (byUrl) return byUrl;
    }
    const height = picked.height || 0;
    if (height > 0) {
      return variants.find((s) => (s.height || 0) === height
        && (s.videoFps || 0) === (picked.fps || 0));
    }
    return undefined;
  }

  /**
   * 桥自愈换端口后由 entry 触发：把 MPV 直连抓取（直播 HLS 等）的
   * http_proxy 进程 env 重指到桥的新端口。loopback 源仍保持直连（bypass）。
   */
  refreshNetworkProxy(): void {
    this.mpvEngine.refreshNetworkProxy();
  }

  public notifyNetworkChanged(): void {
    this.mpvEngine.notifyNetworkChanged();
  }

  private async fetchTextWithStatus(url: string): Promise<TextFetchResult> {
    const request = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36',
        'Referer': 'https://www.youtube.com/',
      };
      // tlang 自动翻译字幕受 YouTube 风控保护，需要登录态头（Cookie + SAPISIDHASH）。
      // 参照 PipePipe SubtitleDeduplicator.downloadRemoteText 行为。
      if (url.includes('tlang=') && AvPlayerController.subtitleAuthHeaderProvider) {
        try {
          const authHeaders = await AvPlayerController.subtitleAuthHeaderProvider();
          const keys = Object.keys(authHeaders);
          for (let i = 0; i < keys.length; i++) {
            const key = keys[i];
            const value = authHeaders[key];
            if (value && value.length > 0) {
              headers[key] = value;
            }
          }
          Logger.debug(TAG, `subtitle fetchText: attached auth headers for tlang url`);
        } catch (e) {
          Logger.warn(TAG, `subtitle auth header provider failed: ${(e as Error).message || e}`);
        }
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 10000,
      };
      HttpDownloader.applyProxyToOptions(options, url);
      const response = await request.request(url, options);
      const body = typeof response.result === 'string' ? response.result : '';
      Logger.info(TAG, `manifest fetchText: code=${response.responseCode} len=${body.length}`);
      return { statusCode: response.responseCode, body: body };
    } catch (e) {
      Logger.warn(TAG, `manifest fetchText error: ${e}`);
      throw e as Error;
    } finally {
      request.destroy();
    }
  }

  private async fetchText(url: string): Promise<string> {
    const res = await this.fetchTextWithStatus(url);
    if (res.statusCode !== 200) {
      throw new Error(`HTTP ${res.statusCode} len=${res.body.length}`);
    }
    return res.body;
  }

  private async createPlaybackUrl(video?: StreamInfo, audio?: StreamInfo,
    generation: number = this.mediaSessionGeneration): Promise<string> {
    const candidate = new PreparedPlaybackSource();
    candidate.mediaGeneration = generation;
    candidate.switchGeneration = ++this.sourceSwitchGeneration;
    try {
      candidate.url = await this.preparePlaybackUrl(video, audio, generation, candidate);
      if (!candidate.url || !this.isPreparedSourceCurrent(candidate)) return '';
      this.commitPreparedSource(candidate);
      return candidate.url;
    } finally {
      this.destroyPreparedSource(candidate);
    }
  }

  private isPreparedSourceCurrent(candidate: PreparedPlaybackSource): boolean {
    return this.isMediaSessionCurrent(candidate.mediaGeneration) &&
      candidate.switchGeneration === this.sourceSwitchGeneration;
  }

  private destroyPreparedSource(candidate: PreparedPlaybackSource): void {
    if (candidate.sessionId) LocalMediaProxy.destroySession(candidate.sessionId);
    if (candidate.audioSessionId) LocalMediaProxy.destroySession(candidate.audioSessionId);
    for (let i = 0; i < candidate.streamUrls.length; i++) {
      unregisterStream(candidate.streamUrls[i]);
    }
    candidate.sessionId = '';
    candidate.audioSessionId = '';
    candidate.streamUrls = [];
  }

  private commitPreparedSource(candidate: PreparedPlaybackSource): void {
    this.deferCurrentSessionDestroy();
    this.currentLocalMediaSessionId = candidate.sessionId;
    this.currentEdlAudioSessionId = candidate.audioSessionId;
    this.currentStreamUrls = candidate.streamUrls;
    this.currentHlsAudioUrl = candidate.hlsAudioUrl;
    this.livePlayingVariantItag = candidate.liveItag;
    candidate.sessionId = '';
    candidate.audioSessionId = '';
    candidate.streamUrls = [];
  }

  private registerNativeDirectTrack(stream: StreamInfo): string {
    const spec: NativeDirectStreamSpec = {
      url: stream.url,
      contentLength: stream.contentLength,
      initRangeStart: stream.initRangeStart,
      initRangeEnd: stream.initRangeEnd,
      indexRangeStart: stream.indexRangeStart,
      indexRangeEnd: stream.indexRangeEnd,
      bitrate: stream.bitrate,
      itag: stream.itag,
      headers: this.curSource?.headers,
    };
    return registerDirectStream(spec);
  }

  private registerNativeHlsTrack(url: string, bitrate?: number, itag?: number, isAudio: boolean = false): string {
    if (!url) return '';
    const spec: NativeHlsStreamSpec = {
      url: url,
      bitrate: bitrate,
      itag: itag,
      isAudio: isAudio,
      headers: this.curSource?.headers,
    };
    return registerHlsStream(spec);
  }

  private applyLiveHlsCandidate(
    hls: HlsTrackPair | null,
    fallbackUrl: string,
    fallbackItag: number | undefined,
    fallbackBitrate: number,
    candidate: PreparedPlaybackSource
  ): void {
    candidate.liveItag = hls?.itag ?? fallbackItag;
    candidate.videoBitrate = hls?.videoBitrate ?? fallbackBitrate;
    if (hls && hls.videoUrl) {
      const nativeVideoUrl = this.registerNativeHlsTrack(hls.videoUrl, hls.videoBitrate, hls.itag, false);
      if (nativeVideoUrl.startsWith('ypstream://')) {
        candidate.streamUrls.push(nativeVideoUrl);
        candidate.url = nativeVideoUrl;
      } else {
        candidate.url = hls.videoUrl;
      }
      if (hls.audioUrl) {
        const nativeAudioUrl = this.registerNativeHlsTrack(hls.audioUrl, hls.audioBitrate, hls.itag, true);
        if (nativeAudioUrl.startsWith('ypstream://')) {
          candidate.streamUrls.push(nativeAudioUrl);
          candidate.hlsAudioUrl = nativeAudioUrl;
        } else {
          candidate.hlsAudioUrl = hls.audioUrl;
        }
      } else {
        candidate.hlsAudioUrl = '';
      }
      return;
    }
    // Master fallback (could not fetch/parse master): pass directly to FFmpeg HLS demuxer.
    candidate.url = fallbackUrl;
    candidate.hlsAudioUrl = '';
  }

  private isHlsAudioRendition(audio: StreamInfo | undefined): boolean {
    if (!audio || !audio.url) return false;
    const delivery = (audio.deliveryMethod || '').toUpperCase();
    const kind = (audio.kind || '').toLowerCase();
    return delivery === 'HLS' || kind === 'manifest_hls'
      || audio.url.includes('.m3u8') || audio.url.includes('/manifest/hls_');
  }

  private async preparePlaybackUrl(video: StreamInfo | undefined, audio: StreamInfo | undefined,
    generation: number, candidate: PreparedPlaybackSource): Promise<string> {
    if (!video || !this.isMediaSessionCurrent(generation)) return '';
    candidate.videoBitrate = video.bitrate ?? 0;

    const delivery = (video.deliveryMethod || '').toUpperCase();
    const kind = (video.kind || '').toLowerCase();
    // Local file (downloaded/imported media): MPV opens the sandbox path directly.
    // No LocalMediaProxy session and no network — the raw path goes to load()
    // (normalizeSourceUrl turns an absolute path into file://; the native
    // ResolveMediaUri maps it back to a real path for mpv's loadfile).
    if (delivery === 'LOCAL_FILE' || kind === 'local_file' || video.url.startsWith('file://')) {
      Logger.info(TAG, `createPlaybackUrl: local file direct url=${this.describePlaybackUrl(video.url)}`);
      return video.url;
    }
    if (delivery === 'SABR' || kind === 'sabr') {
      if (audio) {
        return await this.buildSabrDualEdlUrl(video, audio, generation, candidate);
      }
      Logger.error(TAG, 'createPlaybackUrl: SABR requires paired audio stream');
      return '';
    }

    if (!video.url) return '';

    if (delivery === 'HLS' || kind === 'manifest_hls') {
      // Post-live DVR / non-live HLS: variant playlist direct; attach paired audio
      // ONLY when it is actually an HLS audio rendition (never a DASH videoplayback URL).
      candidate.hlsAudioUrl = this.isHlsAudioRendition(audio) ? (audio?.url || '') : '';
      Logger.info(TAG, `createPlaybackUrl: HLS variant url=${this.describePlaybackUrl(video.url)} extAudio=${candidate.hlsAudioUrl.length > 0}`);
      return video.url;
    }

    if (this.isRemoteManifestUrl(video.url)) {
      Logger.debug(TAG, `createPlaybackUrl: using remote manifest directly`);
      return video.url;
    }

    switch (delivery) {
      case 'DASH':
        if (audio && this.isSeparatedDash(video, audio)) {
          return await this.buildDualEdlUrl(video, audio, generation, candidate);
        }
        return await this.buildSingleProxyUrl(video, generation, candidate);

      case 'PROGRESSIVE_HTTP':
      default:
        return await this.buildSingleProxyUrl(video, generation, candidate);
    }
  }

  private async buildSingleProxyUrl(video: StreamInfo, generation: number, candidate: PreparedPlaybackSource): Promise<string> {
    const nativeStreamUrl = this.registerNativeDirectTrack(video);
    if (nativeStreamUrl.startsWith('ypstream://')) {
      candidate.streamUrls.push(nativeStreamUrl);
      Logger.info(TAG, `buildSingleProxyUrl: ypstream itag=${video.itag} url=${nativeStreamUrl}`);
      return nativeStreamUrl;
    }
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
    candidate.sessionId = sessionId;
    Logger.debug(TAG, `buildSingleProxyUrl: itag=${video.itag} url=${playbackUrl}`);
    return playbackUrl;
  }

  private async buildSabrDualEdlUrl(video: StreamInfo, audio: StreamInfo,
    generation: number, candidate: PreparedPlaybackSource): Promise<string> {
    let resolvedDuration = this.resolveDurationMs(video, audio);
    if (resolvedDuration <= 0) {
      const vMeta = video.sabrInfo?.findFormatByItag(video.itag ?? -1)?.approxDurationMs ?? 0;
      const aMeta = audio.sabrInfo?.findFormatByItag(audio.itag ?? -1)?.approxDurationMs ?? 0;
      resolvedDuration = vMeta > 0 ? vMeta : aMeta;
    }
    const isPostLive = video.sabrInfo?.isPostLive === true || audio.sabrInfo?.isPostLive === true;
    if (resolvedDuration <= 0 && !isPostLive) {
      Logger.error(TAG, 'buildSabrDualEdlUrl: unknown duration, refusing EDL');
      return '';
    }
    Logger.info(TAG, `buildSabrDualEdlUrl: video=[itag=${video.itag}] audio=[itag=${audio.itag}] durationMs=${resolvedDuration} postLive=${isPostLive}`);
    let acquiredLeaseKey = '';
    try {
      const sessionId = await LocalMediaProxy.createSabrDualSession(
        video, audio, resolvedDuration, false, (leaseKey: string) => {
          acquiredLeaseKey = leaseKey;
          if (this.isMediaSessionCurrent(generation)) {
            this.pendingSabrLeaseKey = leaseKey;
          } else {
            LocalMediaProxy.abortSabrLease(leaseKey);
          }
        });
      if (this.pendingSabrLeaseKey === acquiredLeaseKey) {
        this.pendingSabrLeaseKey = '';
      }
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
      candidate.sessionId = sessionId;
      // SABR is exposed as a synthetic DASH manifest with exact init/media segment URLs.
      // MPV remains the DASH demuxer/player; the proxy owns segment demand, seeks and EOF.
      return playbackUrl;
    } catch (e) {
      if (acquiredLeaseKey && this.pendingSabrLeaseKey === acquiredLeaseKey) {
        this.pendingSabrLeaseKey = '';
      }
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
    generation: number, candidate: PreparedPlaybackSource): Promise<string> {
    const durationMs = this.resolveDurationMs(video, audio);
    if (durationMs <= 0) {
      Logger.error(TAG, 'buildDualEdlUrl: dual stream with unknown duration, refusing');
      return '';
    }
    let videoUrl = this.registerNativeDirectTrack(video);
    let audioUrl = videoUrl.startsWith('ypstream://') ? this.registerNativeDirectTrack(audio) : '';
    if (videoUrl.startsWith('ypstream://') && audioUrl.startsWith('ypstream://')) {
      candidate.streamUrls.push(videoUrl, audioUrl);
    } else {
      if (videoUrl.startsWith('ypstream://')) unregisterStream(videoUrl);
      if (audioUrl.startsWith('ypstream://')) unregisterStream(audioUrl);
      const videoSessionId = await LocalMediaProxy.createSingleUrlSession(video.url, video);
      if (!videoSessionId) {
        Logger.error(TAG, 'buildDualEdlUrl: video session unavailable');
        return '';
      }
      candidate.sessionId = videoSessionId;
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
      videoUrl = LocalMediaProxy.getPlaybackUrl(videoSessionId);
      audioUrl = LocalMediaProxy.getPlaybackUrl(audioSessionId);
      if (!videoUrl.startsWith('http://127.0.0.1:') || !audioUrl.startsWith('http://127.0.0.1:')) {
        Logger.error(TAG, `buildDualEdlUrl: invalid track urls video=${videoSessionId} audio=${audioSessionId}`);
        LocalMediaProxy.destroySession(videoSessionId);
        LocalMediaProxy.destroySession(audioSessionId);
        return '';
      }
      candidate.sessionId = videoSessionId;
      candidate.audioSessionId = audioSessionId;
    }

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
    if (this.pendingDestroyStreamUrls.length > 0) {
      for (let i = 0; i < this.pendingDestroyStreamUrls.length; i++) {
        unregisterStream(this.pendingDestroyStreamUrls[i]);
      }
      this.pendingDestroyStreamUrls = [];
    }
    if (this.currentStreamUrls.length > 0) {
      this.pendingDestroyStreamUrls = this.currentStreamUrls;
      this.currentStreamUrls = [];
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
    generation: number = this.mediaSessionGeneration, candidate?: PreparedPlaybackSource): boolean {
    if (!this.isMediaSessionCurrent(generation)) return false;
    if (candidate && !this.isPreparedSourceCurrent(candidate)) return false;
    const sessionId = candidate ? candidate.sessionId : this.currentLocalMediaSessionId;
    const expectedStartMs = Math.max(0, Math.round(startPosSec * 1000));
    this.localTimelineAwaitingReady = sessionId.length > 0;
    this.localTimelineExpectedStartMs = expectedStartMs;
    this.localTimelineMismatchLogged = false;
    if (sessionId) {
      LocalMediaProxy.updatePlaybackPosition(sessionId, expectedStartMs);
      Logger.info(TAG, `local timeline armed session=${sessionId} ` +
        `startMs=${expectedStartMs}`);
    }
    const videoBitrate: number = (candidate && candidate.videoBitrate > 0)
      ? candidate.videoBitrate
      : (this.vm.playerModel.getCurrentStreams().video?.bitrate ?? 0);
    this.playbackEngine.setTargetVideoBitrate(videoBitrate);
    const loaded = this.playbackEngine.load(playbackUrl, startPosSec,
      candidate ? candidate.hlsAudioUrl : this.currentHlsAudioUrl);
    if (loaded) {
      this.playbackLoadSeq++;
    }
    if (loaded && candidate) {
      this.commitPreparedSource(candidate);
      this.syncCurrentStreamMeta();
      this.localTimelineAwaitingReady = sessionId.length > 0;
      this.localTimelineExpectedStartMs = expectedStartMs;
    }
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
    for (let i = 0; i < this.currentStreamUrls.length; i++) {
      unregisterStream(this.currentStreamUrls[i]);
    }
    this.currentStreamUrls = [];
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
    for (let i = 0; i < this.pendingDestroyStreamUrls.length; i++) {
      unregisterStream(this.pendingDestroyStreamUrls[i]);
    }
    this.pendingDestroyStreamUrls = [];
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
    this.avSessionManager.onAudioFocusHint = undefined;
    this.avSessionManager.onOutputDeviceDisconnected = undefined;
  }

  private isRemoteManifestUrl(url: string): boolean {
    return /\.mpd($|[?#])/i.test(url) || /\.m3u8($|[?#])/i.test(url);
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
      if (s.isAutoDubbed === true || type === 'DUBBED-AUTO') {
        return false;
      }
      if (type.length > 0) {
        return type === 'ORIGINAL';
      }
      const name = (s.audioTrackName || '').toLowerCase();
      return name.indexOf('original') >= 0
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
      const originalStreams = audioStreams.filter((s: StreamInfo): boolean => {
        const type = (s.audioTrackType || '').toLowerCase();
        if (s.isAutoDubbed === true || type === 'dubbed-auto') {
          return false;
        }
        if (type.length > 0) {
          return type === 'original';
        }
        const name = (s.audioTrackName || '').toLowerCase();
        return name.indexOf('original') >= 0
          || name.indexOf('default') >= 0;
      });
      if (originalStreams.length > 0) {
        return originalStreams;
      }
      const noTrackInfo = audioStreams.filter((s: StreamInfo): boolean =>
        (s.audioTrackId || '') === '' && (s.audioLanguage || '') === ''
        && s.isAutoDubbed !== true
        && (s.audioTrackType || '').toLowerCase() !== 'dubbed-auto');
      return noTrackInfo;
    }
    const matched = audioStreams.filter((s: StreamInfo): boolean => {
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
    // Deprioritize Dynamic Range Control (DRC) renditions so normal audio wins by default.
    if (stream.isDrc === true) score -= 400000;
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

  private isCurrentSourceLocalFile(): boolean {
    const stream = this.vm.playerModel.getCurrentStreams().video ?? this.curSource?.streams?.[0];
    if (!stream) {
      return false;
    }
    const delivery = (stream.deliveryMethod || '').toUpperCase();
    const kind = (stream.kind || '').toLowerCase();
    return delivery === 'LOCAL_FILE'
      || kind === 'local_file'
      || (stream.url || '').startsWith('file://');
  }

  private cloneStateWithError(
    state: PlaybackState,
    category: PlaybackErrorCategory,
    errorMsg: string
  ): PlaybackState {
    return {
      engineState: state.engineState,
      isPlaying: state.isPlaying,
      isReady: state.isReady,
      isBuffered: state.isBuffered,
      isBuffering: state.isBuffering,
      isSeeking: state.isSeeking,
      isEnded: state.isEnded,
      isLive: state.isLive,
      isSeekable: state.isSeekable,
      currentTime: state.currentTime,
      duration: state.duration,
      playbackSpeed: state.playbackSpeed,
      bufferingPercent: state.bufferingPercent,
      seekableRanges: state.seekableRanges,
      uri: state.uri,
      mediaTitle: state.mediaTitle,
      containerFormat: state.containerFormat,
      videoWidth: state.videoWidth,
      videoHeight: state.videoHeight,
      videoStreamCount: state.videoStreamCount,
      audioStreamCount: state.audioStreamCount,
      subtitleStreamCount: state.subtitleStreamCount,
      videoCodec: state.videoCodec,
      videoBitRate: state.videoBitRate,
      frameRate: state.frameRate,
      hwdec: state.hwdec,
      pixelFormat: state.pixelFormat,
      colorSpace: state.colorSpace,
      colorPrimaries: state.colorPrimaries,
      colorGamma: state.colorGamma,
      audioCodec: state.audioCodec,
      audioBitRate: state.audioBitRate,
      audioChannels: state.audioChannels,
      audioSampleRate: state.audioSampleRate,
      audioFormat: state.audioFormat,
      audioChannelLayout: state.audioChannelLayout,
      fileSize: state.fileSize,
      errorMsg: errorMsg,
      errorCategory: category,
      errorCode: state.errorCode
    };
  }

  private onPlaybackStateChange(state: PlaybackState): void {
    if (!this.isActive()) {
      this.stopStallWatchdog();
      return;
    }
    state = normalizePlaybackTimeline(state, this.vm.currentTime, this.vm.durationTime);
    const isLocalFile = this.isCurrentSourceLocalFile();
    const isLiveStream = state.isLive || this.curSource?.isLive === true;
    const eofTolerance = state.duration > 0
      ? Math.min(2, Math.max(0.5, state.duration * 0.05))
      : 0;
    const isPrematureEof = state.isEnded
      && !isLocalFile
      && (isLiveStream
        || (state.duration > 0 && state.currentTime < state.duration - eofTolerance));
    let triggerPrematureEofRecovery = false;
    if (isPrematureEof) {
      // Intercept premature EOF before updating vm.isEnded or relaying COMPLETED
      // to stateMachine / AVSession / endedSubscribers.
      state.isEnded = false;
      if (!this.isRecovering && this.prematureEofHandledSeq !== this.playbackLoadSeq) {
        this.prematureEofHandledSeq = this.playbackLoadSeq;
        this.prematureEofLastPosSec = state.currentTime;
        this.prematureEofStableSinceMs = 0;
        this.errorRetryCount = Math.max(this.errorRetryCount, this.prematureEofCount);
        this.prematureEofCount++;
        state.isBuffering = true;
        triggerPrematureEofRecovery = true;
      } else {
        state.isBuffering = this.vm.userVisibleErrorMsg.length === 0;
      }
    } else if (state.isPlaying && this.prematureEofCount > 0) {
      // Only clear premature EOF counter once playback genuinely advances past
      // the previous EOF position (or sustains live playback for 5s).
      if (!isLiveStream && state.currentTime >= this.prematureEofLastPosSec + 2) {
        this.prematureEofCount = 0;
        this.prematureEofLastPosSec = -1;
        this.prematureEofStableSinceMs = 0;
      } else if (isLiveStream) {
        if (this.prematureEofStableSinceMs === 0) {
          this.prematureEofStableSinceMs = Date.now();
        } else if (Date.now() - this.prematureEofStableSinceMs >= 5000) {
          this.prematureEofCount = 0;
          this.prematureEofStableSinceMs = 0;
        }
      }
    }
    this.latestPlaybackState = state;
    // Watchdog lifecycle follows the media window: armed from the first engine
    // state of an active session, stopped when the session goes away.
    this.ensureStallWatchdog();
    if (state.errorMsg) {
      // An in-flight recovery/retry resets the baseline so the watchdog does
      // not fire on top of an already-handled failure.
      this.resetStallBaseline();
    }

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
    const prevReady = this.vm.isReady;
    this.vm.isReady = state.isReady;
    this.vm.isSeeking = state.isSeeking;
    this.vm.isEnded = state.isEnded;
    // 同会话重载（SABR 重试 / 质量切换）在 !isReady 阶段会把位置与时长清零，直接
    // 透传会让进度条/时间文案在恢复瞬间跳变。保留已知的正值直到新文件上报；
    // 真正的新源走 resetPlaybackState() → vm.reset() 清零。
    const keepLastTimeline = !state.isReady && this.vm.durationTime > 0;
    this.vm.currentTime = keepLastTimeline && state.currentTime <= 0
      ? this.vm.currentTime : state.currentTime;
    this.updateSubtitleOverlayText(this.vm.currentTime);
    this.vm.durationTime = keepLastTimeline && state.duration <= 0
      ? this.vm.durationTime : state.duration;
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
    this.vm.hwdec = state.hwdec;
    this.vm.pixelFormat = state.pixelFormat;
    this.vm.colorSpace = state.colorSpace;
    this.vm.colorPrimaries = state.colorPrimaries;
    this.vm.colorGamma = state.colorGamma;
    this.vm.audioCodec = state.audioCodec;
    this.vm.audioBitRate = state.audioBitRate;
    this.vm.audioChannels = state.audioChannels;
    this.vm.audioSampleRate = state.audioSampleRate;
    this.vm.audioFormat = state.audioFormat;
    this.vm.audioChannelLayout = state.audioChannelLayout;
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
    if (state.isReady && this.pendingDestroyStreamUrls.length > 0) {
      for (let i = 0; i < this.pendingDestroyStreamUrls.length; i++) {
        unregisterStream(this.pendingDestroyStreamUrls[i]);
      }
      this.pendingDestroyStreamUrls = [];
    }

    // 仅音频等：load 后引擎可能回到默认 vid=auto，仅在刚进入就绪态时重放一次期望值
    // （避免每 100ms 进度回调重复向 MPV 下发 vid=auto 刷屏）。
    if (state.isReady) {
      if (!prevReady) {
        this.applyVideoOutputPreference();
      }
      if (!this.avSessionArtworkPublished) {
        this.avSessionArtworkPublished = true;
        this.updateAvSessionMetadata(true);
      }
    }

    // 错误监听（手动，需要特殊处理）
    const errorChanged = prevErrorMsg !== state.errorMsg;
    if (triggerPrematureEofRecovery) {
      Logger.warn(TAG, `premature EOF intercepted: pos=${state.currentTime.toFixed(2)}s `
        + `dur=${state.duration.toFixed(2)}s live=${isLiveStream} `
        + `retryCount=${this.errorRetryCount}/${this.MAX_ERROR_RETRIES} `
        + `loadSeq=${this.playbackLoadSeq} — routing to error recovery`);
      this.resetStallBaseline();
      const synthetic = this.cloneStateWithError(state, 'network', '[PLAYER] PREMATURE_EOF');
      void this.handlePlaybackError(synthetic);
    } else if (errorChanged && state.errorMsg && !this.isRecovering) {
      // MPV/FFmpeg may emit several Invalid states while probing or while an
      // automatic retry is in progress. Do not turn those diagnostics into UI.
      this.handlePlaybackError(state);
    }
    if (!state.errorMsg && !isPrematureEof && (state.isReady || state.isPlaying)) {
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
    this.subtitleCues = [];
    this.subtitleLoadSeq++;
    this.secondarySubtitleCues = [];
    this.secondarySubtitleIndex = -1;
    this.secondarySubtitleLoadSeq++;
    this.vm.reset();
    this.seekableRangesListeners.forEach(listener => listener());
    // Keep videoOutputEnabled: session audio-only must survive source switch.
    this.lastKnownGoodPosition = 0;
    this.prematureEofHandledSeq = -1;
    this.prematureEofCount = 0;
    this.prematureEofLastPosSec = -1;
    this.prematureEofStableSinceMs = 0;
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

  /**
   * Playback stall watchdog. MPV/FFmpeg can silently stop making progress
   * (SABR pump parked, dead upstream fetch, hung demuxer) without ever
   * emitting an error — until now those freezes had no recovery at all. When
   * an active, non-seek, non-paused playback window stops advancing the
   * position for STALL_DETECT_MS, a synthetic network-class error is injected
   * into the standard handlePlaybackError ladder (same-URL retries, then the
   * entry-side fresh-stream re-extraction with resume).
   */
  private ensureStallWatchdog(): void {
    if (this.stallWatchdogTimer >= 0) {
      return;
    }
    this.stallBaselinePosSec = this.lastKnownGoodPosition;
    this.stallBaselineAtMs = Date.now();
    this.stallWatchdogTimer = setInterval(() => this.stallWatchdogTick(), AvPlayerController.STALL_TICK_MS);
  }

  private stopStallWatchdog(): void {
    if (this.stallWatchdogTimer >= 0) {
      clearInterval(this.stallWatchdogTimer);
      this.stallWatchdogTimer = -1;
    }
    this.stallBaselinePosSec = -1;
    this.stallBaselineAtMs = 0;
    this.startupStallSinceMs = 0;
  }

  private resetStallBaseline(): void {
    this.stallBaselinePosSec = this.lastKnownGoodPosition;
    this.stallBaselineAtMs = Date.now();
    this.startupStallSinceMs = 0;
  }

  /**
   * 用户 seek 后把停滞窗口的基线钉在目标位置：跳转后位置应从目标处继续前进，
   * 而不是从 seek 之前的旧位置算位移（否则回退 seek 会被读成负位移，20s 后误报冻结）。
   */
  private resetStallBaselineTo(posSec: number): void {
    this.stallBaselinePosSec = posSec > 0 ? posSec : this.lastKnownGoodPosition;
    this.stallBaselineAtMs = Date.now();
  }

  private stallWatchdogTick(): void {
    if (!this.isActive() || this.isRecovering) {
      this.resetStallBaseline();
      return;
    }
    // Only watch windows that should be delivering media: READY/PLAYING/BUFFERING
    // and not user-paused (PAUSED state), user-seeking, or mid quality switch.
    const watching = this.stateMachine.isOneOf(PlayerState.READY, PlayerState.PLAYING,
      PlayerState.BUFFERING)
      && !this.vm.isSeeking && !this.vm.isSourceSwitching;
    if (!watching) {
      this.resetStallBaseline();
      return;
    }
    const pos = this.lastKnownGoodPosition;
    if (pos <= 0) {
      // Catch startup/buffering deadlocks stuck at 0s beyond STARTUP_STALL_DETECT_MS.
      if (this.startupStallSinceMs <= 0) {
        this.startupStallSinceMs = Date.now();
        return;
      }
      const startupElapsedMs = Date.now() - this.startupStallSinceMs;
      if (startupElapsedMs < AvPlayerController.STARTUP_STALL_DETECT_MS) {
        return;
      }
      Logger.warn(TAG, `stall watchdog: startup frozen at 0s for `
        + `${Math.round(startupElapsedMs / 1000)}s videoId=${this.curSource?.videoId || 'unknown'} `
        + `state=${this.stateMachine.currentState} — injecting recovery`);
      this.startupStallSinceMs = 0;
      const synthetic: PlaybackState = this.getPlaybackState();
      synthetic.errorCategory = 'network';
      synthetic.errorMsg = '[WATCHDOG] startup stalled';
      this.handlePlaybackError(synthetic);
      return;
    }
    this.startupStallSinceMs = 0;
    if (this.stallBaselinePosSec < 0) {
      this.resetStallBaseline();
      return;
    }
    const elapsedMs = Date.now() - this.stallBaselineAtMs;
    if (elapsedMs < AvPlayerController.STALL_DETECT_MS) {
      return;
    }
    const progressed = pos - this.stallBaselinePosSec;
    // 位移在两个方向上都算"没有卡住"：回退 seek 后位置会低于基线（基线停在 seek
    // 之前的位置），旧的单向判定把这种负位移读成"零进展"，会在 seek 后 ~20s 误
    // 触发一次整源 reload（日志表现为 load + end-file、进度短暂跳变后回原位）。
    // 任一方向超过阈值都重开窗口；只有位移 ≈ 0 才是真卡住。
    if (progressed >= AvPlayerController.STALL_MIN_PROGRESS_SEC
      || progressed <= -AvPlayerController.STALL_MIN_PROGRESS_SEC) {
      this.resetStallBaseline();
      return;
    }
    Logger.warn(TAG, `stall watchdog: pos frozen at ${pos.toFixed(2)}s for `
      + `${Math.round(elapsedMs / 1000)}s videoId=${this.curSource?.videoId || 'unknown'} `
      + `state=${this.stateMachine.currentState} — injecting recovery`);
    this.resetStallBaseline();
    // Synthetic network-class error feeds the standard retry ladder; the error
    // state itself stays invisible to the user unless every recovery fails.
    const synthetic: PlaybackState = this.getPlaybackState();
    synthetic.errorCategory = 'network';
    synthetic.errorMsg = '[WATCHDOG] playback stalled';
    this.handlePlaybackError(synthetic);
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
        await this.retryPlayback(resumePos);
      } finally {
        this.isRecovering = false;
      }
      return;
    }

    // 同 URL 快速重试已耗尽:升级给 entry 做"重新提取新鲜流 URL + 原地重载"
    // (PipePipe reloadPlayQueueManager 语义),而不是直接报错/放弃。
    if (this.onRetryWithFreshStreams) {
      const freshResumePos = this.curSource?.isLive ? 0 : resumePos;
      Logger.info(TAG, `handlePlaybackError: escalate to fresh-stream retry resumePos=${freshResumePos.toFixed(2)}s`);
      this.errorRetryCount = 0;
      this.onRetryWithFreshStreams(freshResumePos);
      return;
    }

    this.errorRetryCount = 0;
    const errText = state.errorMsg || this.vm.errorMsg || '[PLAYER] PLAYBACK_FAILED';
    this.vm.isBuffering = false;
    this.vm.errorMsg = errText;
    this.publishUserVisibleError(errText);
    this.onErrorNeedsUserAction?.(errText);
  }

  private async retryPlayback(resumePos: number): Promise<void> {
    if (this.qualitySwitchPending && !this.qualitySwitchLoadStarted) return;
    const isLive = this.curSource?.isLive === true;
    const effectiveResumePos = isLive ? 0 : resumePos;
    Logger.debug(TAG, `retryPlayback at ${effectiveResumePos.toFixed(2)}s live=${isLive}`);
    const generation = this.mediaSessionGeneration;

    // Live HLS retry: re-resolve fresh variant & audio rendition from master and wrap
    // in native HlsLiveStream at live edge (startPos=0). Never attach stale DASH audio.
    if (isLive && this.curSource?.hlsUrl) {
      const candidate = new PreparedPlaybackSource();
      candidate.mediaGeneration = generation;
      candidate.switchGeneration = ++this.sourceSwitchGeneration;
      try {
        const maxHeight = this.resolveMaxHeight(PlaybackPreferences.snapshot().defaultQuality || 'best');
        const current = this.vm.playerModel.getCurrentStreams();
        let picked: StreamInfo | undefined = current.video;
        if (this.livePlayingVariantItag !== undefined && (!picked || picked.itag !== this.livePlayingVariantItag)) {
          const streams = this.curSource.streams || [];
          const matched = streams.find((s) => s.itag === this.livePlayingVariantItag);
          if (matched) picked = matched;
        }
        let hls: HlsTrackPair | null = null;
        try {
          hls = await this.resolveLiveHlsStreams(maxHeight, picked);
        } catch (e) {
          Logger.warn(TAG, `retryPlayback: resolveLiveHlsStreams failed: ${(e as Error).message}`);
        }
        if (!this.isPreparedSourceCurrent(candidate)) return;
        this.applyLiveHlsCandidate(hls, this.curSource.hlsUrl, this.livePlayingVariantItag, picked?.bitrate ?? 0, candidate);
        if (!candidate.url) {
          this.setError('[PLAYER] RETRY_FAILED');
          return;
        }
        Logger.info(TAG, `retryPlayback live: proto=${candidate.url.startsWith('ypstream://') ? 'ypstream-hls' : 'ffmpeg-hls'} `
          + `itag=${candidate.liveItag ?? '-'} extAudio=${candidate.hlsAudioUrl.length > 0}`);
        this.loadPlaybackSource(candidate.url, 0, generation, candidate);
        if (this.vm.isPlaying || this.transportIntentPlaying) {
          this.playbackEngine.play();
        }
      } finally {
        this.destroyPreparedSource(candidate);
      }
      return;
    }

    const current = this.vm.playerModel.getCurrentStreams();
    const sourceGeneration = this.sourceSwitchGeneration + 1;
    const playbackUrl = await this.createPlaybackUrl(current.video, current.audio, generation);
    if (sourceGeneration !== this.sourceSwitchGeneration) return;
    if (!this.isMediaSessionCurrent(generation)) return;
    if (!playbackUrl) {
      this.setError('[PLAYER] RETRY_FAILED');
      return;
    }
    this.loadPlaybackSource(playbackUrl, effectiveResumePos, generation);
    if (this.vm.isPlaying || this.transportIntentPlaying) {
      this.playbackEngine.play();
    }
  }

  private async switchToProgressiveFallback(resumePos: number): Promise<void> {
    if (this.qualitySwitchPending && !this.qualitySwitchLoadStarted) return;
    const generation = this.mediaSessionGeneration;
    const categories = this.vm.playerModel.categorizedStreams;
    if (categories.progressive.length > 0) {
      const progressive = this.selectBestProgressive(categories.progressive);
      Logger.info(TAG, `Switched to progressive fallback: ${progressive.quality} [${progressive.itag}]`);
      const sourceGeneration = this.sourceSwitchGeneration + 1;
      const playbackUrl = await this.createPlaybackUrl(progressive, undefined, generation);
      if (sourceGeneration !== this.sourceSwitchGeneration) return;
      if (!this.isMediaSessionCurrent(generation)) return;
      if (playbackUrl) {
        this.vm.playerModel.updateVideoStream(progressive);
        this.vm.playerModel.updateAudioStream(undefined);
        this.syncCurrentStreamMeta();
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

  /** Sync active stream itags and extractor endpoint onto PlayerUiViewModel for Stats UI. */
  private syncCurrentStreamMeta(): void {
    const cur: CurrentStreams = this.vm.playerModel.getCurrentStreams();
    const videoItag: number = cur.video?.itag ?? this.livePlayingVariantItag ?? 0;
    const audioItag: number = cur.audio?.itag ?? 0;
    const endpoint: string = cur.video?.sourceClient
      || cur.audio?.sourceClient
      || this.curSource?.streams?.[0]?.sourceClient
      || '';
    if (this.vm.currentVideoItag !== videoItag) {
      this.vm.currentVideoItag = videoItag;
    }
    if (this.vm.currentAudioItag !== audioItag) {
      this.vm.currentAudioItag = audioItag;
    }
    if (this.vm.currentStreamEndpoint !== endpoint) {
      this.vm.currentStreamEndpoint = endpoint;
    }
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
    BackgroundTaskManager.registerCancelListener((reason: number) => {
      this.clearBackgroundTaskStopTimer();
      if (this.backgroundTaskActive) {
        this.backgroundTaskActive = false;
        Logger.warn(TAG, `[StateTrace] [BgTask] canceled by system reason=${reason}, flag reset`);
      }
    });
  }

  private detachBackgroundTaskListener(): void {
    this.clearBackgroundTaskStopTimer();
    BackgroundTaskManager.unregisterCancelListener();
    if (this.backgroundTaskListener) {
      this.stateMachine.removeListener(this.backgroundTaskListener);
      this.backgroundTaskListener = null;
    }
    if (this.backgroundTaskActive) {
      const ctx = ContextProvider.get();
      this.backgroundTaskActive = false;
      if (ctx) BackgroundTaskManager.stopContinuousTask(ctx);
    }
  }

  private clearBackgroundTaskStopTimer(): void {
    if (this.backgroundTaskStopTimer >= 0) {
      clearTimeout(this.backgroundTaskStopTimer);
      this.backgroundTaskStopTimer = -1;
    }
  }

  // 由 BackgroundTaskStateListener 调用，集中管理后台任务的开关。
  // 遵循鸿蒙规范：仅在活跃播放/起播缓冲期持有 AUDIO_PLAYBACK；暂停/完播后经短宽限期主动释放，
  // 避免后台无音频输出时长期占着长时任务触发系统一致性校验惩罚。
  public _bgTaskOnStateChange(to: PlayerState): void {
    const ctx = ContextProvider.get();
    if (!ctx) return;
    const isPlayingOrLoading = to === PlayerState.PLAYING || to === PlayerState.BUFFERING
      || to === PlayerState.READY || to === PlayerState.LOADING;
    const isPausedOrDone = to === PlayerState.PAUSED || to === PlayerState.COMPLETED;
    const isTerminal = to === PlayerState.IDLE || to === PlayerState.RELEASED || to === PlayerState.ERROR;

    if (isPlayingOrLoading) {
      this.clearBackgroundTaskStopTimer();
      if (!this.backgroundTaskActive) {
        this.backgroundTaskActive = true;
        Logger.info(TAG, `[StateTrace] [BgTask] startContinuousTask state=${to}`);
        BackgroundTaskManager.startContinuousTask(ctx);
      }
    } else if (isPausedOrDone) {
      if (this.backgroundTaskActive && this.backgroundTaskStopTimer < 0) {
        Logger.info(TAG, `[StateTrace] [BgTask] arm delayed stop (${AvPlayerController.BG_TASK_PAUSE_GRACE_MS}ms) state=${to}`);
        this.backgroundTaskStopTimer = setTimeout(() => {
          this.backgroundTaskStopTimer = -1;
          const cur: PlayerState = this.stateMachine.currentState;
          const stillIdleAudio = cur === PlayerState.PAUSED || cur === PlayerState.COMPLETED
            || cur === PlayerState.IDLE || cur === PlayerState.RELEASED || cur === PlayerState.ERROR;
          if (stillIdleAudio && this.backgroundTaskActive) {
            const latestCtx = ContextProvider.get();
            this.backgroundTaskActive = false;
            Logger.info(TAG, `[StateTrace] [BgTask] delayed stopContinuousTask state=${cur}`);
            if (latestCtx) {
              BackgroundTaskManager.stopContinuousTask(latestCtx);
            }
          }
        }, AvPlayerController.BG_TASK_PAUSE_GRACE_MS);
      }
    } else if (isTerminal) {
      this.clearBackgroundTaskStopTimer();
      if (this.backgroundTaskActive) {
        this.backgroundTaskActive = false;
        Logger.info(TAG, `[StateTrace] [BgTask] stopContinuousTask state=${to}`);
        BackgroundTaskManager.stopContinuousTask(ctx);
      }
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
