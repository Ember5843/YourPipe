/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0
 */

import { VideoData, StreamInfo, SubtitleTrackInfo } from '../model/VideoData';
import { PlayerModel, StreamCategories, CurrentStreams, VideoEntry } from '../model/PlayerModel';
import { PlaybackEngine, PlaybackState } from '../engine/PlaybackEngine';
import { MpvPlaybackEngine } from '../engine/MpvPlaybackEngine';
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
  private pendingStartFromSec: number = 0;
  /** 上一次 updateVideoSource 处理过的 source 引用，用于幂等去重。 */
  private lastUpdatedSourceRef: VideoData | null = null;

  // Error recovery state
  private errorRetryCount: number = 0;
  private isRecovering: boolean = false;
  private readonly MAX_ERROR_RETRIES = 2;
  private lastKnownGoodPosition: number = 0;
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
      PlayerState.PLAYING, PlayerState.PAUSED, PlayerState.BUFFERING, PlayerState.PIP_ACTIVE)) {
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

    const ok = await this.playbackEngine.initialize({});
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

    // 幂等：PlayerSession 与 AVPlayer.onSourceChange 会先后推同一个 source 引用，
    // 如果 controller 第二次仍跑完整 load 流程会让 MPV 重新建立 timeline / decoder，
    // 直播场景下还会因为 length=0 的 EDL 被 MPV 立刻判 EOF 触发自动 skip。
    if (this.lastUpdatedSourceRef === newSource) {
      Logger.debug(TAG, `updateVideoSource ignored: same source reference videoId=${newSource.videoId || 'N/A'}`);
      return;
    }
    this.lastUpdatedSourceRef = newSource;

    this.resetPlaybackState();
    this.destroyCurrentLocalSession();
    this.curSource = newSource;
    this.curIndex = newSource.index;
    this.vm.subtitleTracks = newSource.subtitleTracks || [];
    // 优先从 newSource 的流信息中恢复 duration，避免后续 resolveDurationMs 取到 0
    if (newSource.streams && newSource.streams.length > 0) {
      const ms = newSource.streams[0].approxDurationMs || 0;
      if (ms > 0) {
        this.vm.durationTime = ms / 1000;
      }
    }

    Logger.info(TAG, `updateVideoSource: videoId=${newSource.videoId || 'N/A'} streams=${newSource.streams?.length || 0} isLive=${newSource.isLive} subtitles=${newSource.subtitleTracks?.length || 0}`);

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

    const autoSubtitle = this.pickSubtitleForLanguage(searchLanguage);
    if (autoSubtitle) {
      this.vm.currentSubtitleUrl = autoSubtitle.url;
      this.vm.subtitleVisible = true;
      this.playbackEngine.preloadSubtitleTracks([autoSubtitle.url]);
    } else {
      this.playbackEngine.preloadSubtitleTracks([]);
    }
    this.playbackEngine.load(playbackUrl, this.pendingStartFromSec);
    this.pendingStartFromSec = 0;
    if (newSource.play || newSource.auto) {
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

    Logger.debug(TAG, `switchQuality: pos=${resumePos.toFixed(2)}s url=${this.describePlaybackUrl(playbackUrl)}`);
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
    if (this.isActive()) this.playbackEngine.resizeSurface(widthPx, heightPx);
  }

  public setSurfaceID(surfaceID: string): void {
    if (!surfaceID || this.surfaceID === surfaceID) return;
    this.surfaceID = surfaceID;
    if (this.isActive()) {
      this.playbackEngine.attachSurface(surfaceID);
    }
  }

  public syncPlay(): void {
    if (!this.isActive()) return;
    if (this.vm.isEnded) {
      this.playbackEngine.seek(0, true);
      this.vm.isEnded = false;
    }
    this.playbackEngine.play();
  }

  public syncPause(): void {
    if (this.isActive()) this.playbackEngine.pause();
  }

  public syncStop(): void {
    if (this.isActive()) this.playbackEngine.stop();
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

  public setVideoOutputEnabled(enabled: boolean): void {
    // 只在 AVPlayer 支持 setMediaMuted 的状态下调用 (prepared/playing/paused/completed)
    if (this.stateMachine.isOneOf(PlayerState.READY, PlayerState.PLAYING, PlayerState.PAUSED,
      PlayerState.BUFFERING, PlayerState.COMPLETED, PlayerState.PIP_ACTIVE)) {
      this.playbackEngine.setVideoOutputEnabled(enabled);
    }
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
    this.errorListeners = [];
    this.waitingForBufferListeners = [];
    this.seekableRangesListeners = [];
    this.vm.playerModel = new PlayerModel();
  }

  public toggleSubtitle(): void {
    this.vm.subtitleVisible = !this.vm.subtitleVisible;
    this.playbackEngine.setSubtitleVisible(this.vm.subtitleVisible);
    if (!this.vm.subtitleVisible) {
      this.vm.subtitleText = '';
    }
  }

  public setSubtitleVisible(visible: boolean): void {
    this.vm.subtitleVisible = visible;
    this.playbackEngine.setSubtitleVisible(visible);
    if (!visible) {
      this.vm.subtitleText = '';
    }
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
    const showHighRes = prefs.showHighResolutions;
    const maxHeight = this.resolveMaxHeight(targetQuality, showHighRes);
    const candidates = streams.filter(s => (s.height || this.heightFromQuality(s.quality)) <= maxHeight);
    const usable = candidates.length > 0 ? candidates : streams;
    return usable.slice().sort((a: StreamInfo, b: StreamInfo): number => {
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
    const prefs = PlaybackPreferences.snapshot();
    const maxHeight = this.resolveMaxHeight(prefs.defaultQuality, prefs.showHighResolutions);
    const candidate = entries.find(e => e.height <= maxHeight);
    return candidate || (entries.length > 0 ? entries[0] : undefined);
  }

  private resolveMaxHeight(targetQuality: string, showHighRes: boolean): number {
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
    return showHighRes ? requested : Math.min(requested, 1080);
  }

  private heightFromQuality(quality?: string): number {
    if (!quality) return 0;
    const match = quality.match(/(\d{3,4})p/);
    return match ? Number(match[1]) : 0;
  }

  private codecPriority(stream: StreamInfo): number {
    const c = (stream.codecs || '').toLowerCase();
    if (c.startsWith('avc1') || c.startsWith('avc3')) return 4;
    if (c.startsWith('hvc1') || c.startsWith('hev1')) return 3;
    if (c.startsWith('vp9') || c.startsWith('vp09')) return 2;
    if (c.startsWith('av01')) return 1;
    return 0;
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

    if (this.isRemoteManifestUrl(video.url)) {
      Logger.debug(TAG, `createPlaybackUrl: using remote manifest directly`);
      this.destroyCurrentLocalSession();
      return video.url;
    }

    switch ((video.deliveryMethod || '').toUpperCase()) {
      case 'HLS':
        this.destroyCurrentLocalSession();
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
    this.destroyCurrentLocalSession();
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
    this.destroyCurrentLocalSession();
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

    const baseUrl = playbackUrl.replace('/manifest.mpd', '');
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

  private pickSubtitleForLanguage(language: string): SubtitleTrackInfo | null {
    if (this.vm.subtitleTracks.length === 0) return null;
    const lang = language.split('-')[0].toLowerCase();
    const exact = this.vm.subtitleTracks.find(t => t.languageCode.toLowerCase() === language.toLowerCase());
    if (exact) return exact;
    const prefix = this.vm.subtitleTracks.find(t => t.languageCode.split('-')[0].toLowerCase() === lang);
    if (prefix) return prefix;
    const manual = this.vm.subtitleTracks.find(t => !t.isAutoGenerated && t.languageCode.split('-')[0].toLowerCase() === lang);
    if (manual) return manual;
    return null;
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
      const maxHeight = this.resolveMaxHeight(prefs.mobileQuality || '480p', prefs.showHighResolutions);
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
      return typeof response.result === 'string' ? response.result : '';
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
    const prevErrorMsg = this.vm.errorMsg;
    this.vm.errorMsg = state.errorMsg;

    if (prevDuration === 0 && this.vm.durationTime > 0) {
      this.updateAvSessionMetadata();
    }

    // 委托给 PlayerStateRelay：状态机 + AVSession + 节流进度
    this.stateRelay.onStateChange(state);

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
      || to === PlayerState.READY || to === PlayerState.LOADING
      || to === PlayerState.PIP_ENTERING || to === PlayerState.PIP_ACTIVE || to === PlayerState.PIP_RESTORING;
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
