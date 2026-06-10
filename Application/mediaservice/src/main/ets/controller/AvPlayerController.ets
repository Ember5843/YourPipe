/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0
 */

import { VideoData, StreamInfo, SubtitleTrackInfo } from '../model/VideoData';
import { PlayerModel, StreamCategories, CurrentStreams } from '../model/PlayerModel';
import { PlaybackEngine, PlaybackState } from '../engine/PlaybackEngine';
import { MpvPlaybackEngine } from '../engine/MpvPlaybackEngine';
import { LocalMediaProxy } from './LocalMediaProxy';
import { AvSessionManager } from '../common/AvSessionManager';
import { PlayerStateRelay, ProgressSubscriber } from '../state/PlayerStateRelay';
import { PlayerStateMachine, StateChangeListener } from '../state/PlayerStateMachine';
import { PlayerState } from '../state/PlayerState';
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
  @Track surfaceID: string = '';
  @Track isPlaying: boolean = false;
  @Track isReady: boolean = false;
  @Track isBuffering: boolean = false;
  @Track isSeeking: boolean = false;
  @Track isEnded: boolean = false;
  @Track currentTime: number = 0;
  @Track duration: number = 0;
  @Track durationTime: number = 0;
  @Track errorMsg: string = '';
  @Track cachedPercent: number = 0;
  @Track seekableRanges: number[][] = [];
  @Track playbackSpeed: number = 1.0;
  @Track public playerModel: PlayerModel = new PlayerModel();
  @Track subtitleTracks: SubtitleTrackInfo[] = [];
  @Track currentSubtitleUrl: string = '';
  @Track subtitleVisible: boolean = false;
  @Track subtitleText: string = '';
  @Track isCasting: boolean = false;
  @Track castDeviceName: string = '';
  public onCastStateChange: ((isCasting: boolean, deviceName: string) => void) | undefined = undefined;
  public onNextCommand: (() => void) | undefined = undefined;
  public onPreviousCommand: (() => void) | undefined = undefined;

  private curIndex: number = 0;
  private curSource: VideoData;
  private playbackEngine: PlaybackEngine = new MpvPlaybackEngine();
  private avSessionManager: AvSessionManager = AvSessionManager.getInstance();
  private stateMachine: PlayerStateMachine = new PlayerStateMachine();
  private stateRelay: PlayerStateRelay = new PlayerStateRelay();

  private errorListeners: ((errorMsg: string) => void)[] = [];
  private waitingForBufferListeners: ((isWaiting: boolean) => void)[] = [];
  private seekableRangesListeners: (() => void)[] = [];

  private currentLocalMediaSessionId: string = '';
  private pendingStartFromSec: number = 0;
  private lastUpdateTimestamp: number = 0;
  private lastUpdateVideoId: string = '';

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
      this.playerModel.classifyStreams(curSource.streams);
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

  public getStreamCategories(): StreamCategories { return this.playerModel.getStreamCategories(); }
  public getCurrentStreams(): CurrentStreams { return this.playerModel.getCurrentStreams(); }
  public updateVideoStream(stream: StreamInfo): void { this.playerModel.updateVideoStream(stream); }
  public updateAudioStream(stream: StreamInfo | undefined): void { this.playerModel.updateAudioStream(stream); }
  public setCurIndex(curIndex: number): void { this.curIndex = curIndex; }
  public setIsPlaying(isPlaying: boolean): void { this.isPlaying = isPlaying; }

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
      const newTime = Math.min(this.durationTime || Infinity, this.currentTime + skip);
      this.playbackEngine.seek(newTime, false);
      if (!this.isPlaying) {
        this.playbackEngine.play();
      }
    };
    this.avSessionManager.onRewindCommand = (skipIntervalSec?: number) => {
      const skip = skipIntervalSec ?? 15;
      const newTime = Math.max(0, this.currentTime - skip);
      this.playbackEngine.seek(newTime, false);
      if (!this.isPlaying) {
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
      this.isCasting = isCasting;
      this.castDeviceName = deviceName;
      this.onCastStateChange?.(isCasting, deviceName);
    };

    const ok = await this.playbackEngine.initialize({});
    if (ok) {
      this.stateMachine.forceTransition(PlayerState.INITIALIZING);
      this.playbackEngine.setStateCallback((state: PlaybackState) => this.onPlaybackStateChange(state));
      this.playbackEngine.setSubtitleCallback((text: string, _startTime: number, _duration: number) => {
        this.subtitleText = text;
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

    const now = Date.now();
    const newVideoId = newSource.videoId || '';
    if (newVideoId && newVideoId === this.lastUpdateVideoId && now - this.lastUpdateTimestamp < 500) {
      Logger.warn(TAG, `updateVideoSource ignored duplicate call videoId=${newVideoId}`);
      return;
    }
    this.lastUpdateTimestamp = now;
    this.lastUpdateVideoId = newVideoId;

    this.resetPlaybackState();
    this.destroyCurrentLocalSession();
    this.curSource = newSource;
    this.curIndex = newSource.index;
    this.subtitleTracks = newSource.subtitleTracks || [];
    // 优先从 newSource 的流信息中恢复 duration，避免后续 resolveDurationMs 取到 0
    if (newSource.streams && newSource.streams.length > 0) {
      const ms = newSource.streams[0].approxDurationMs || 0;
      if (ms > 0) {
        this.durationTime = ms / 1000;
      }
    }

    Logger.info(TAG, `updateVideoSource: videoId=${newSource.videoId || 'N/A'} streams=${newSource.streams?.length || 0} isLive=${newSource.isLive} subtitles=${newSource.subtitleTracks?.length || 0}`);

    const uiConfig = AppStorage.get('uiConfig') as Record<string, string> | undefined;
    const searchLanguage = uiConfig?.searchLanguage || 'en-GB';
    this.playerModel.classifyStreams(newSource.streams, searchLanguage);

    if (!this.selectInitialStreams(newSource.isLive === true)) {
      Logger.warn(TAG, `selectInitialStreams failed: no supported stream found`);
      this.setError('[API] NO_SUPPORTED_STREAM');
      return;
    }

    await this.initPlaybackEngine();
    if (this.stateMachine.isOneOf(PlayerState.RELEASED, PlayerState.IDLE)) return;

    this.stateMachine.forceTransition(PlayerState.LOADING);

    // Live streams: use HLS manifest URL directly, skip local proxy
    if (newSource.isLive && newSource.hlsUrl) {
      Logger.info(TAG, `Live stream detected, using HLS manifest directly: ${this.describePlaybackUrl(newSource.hlsUrl)}`);
      const playbackUrl = await this.resolveManifestPlaybackUrl(newSource.hlsUrl, true);
      if (!playbackUrl) {
        this.setError('[PLAYER] LOCAL_PROXY_FAILED');
        return;
      }
      this.updateAvSessionMetadata();
      this.isBuffering = true;
      this.playbackEngine.load(playbackUrl, 0);
      if (newSource.play || newSource.auto) {
        this.playbackEngine.play();
      }
      return;
    }

    const current = this.playerModel.getCurrentStreams();
    const playbackUrl = await this.resolveManifestPlaybackUrl(
      await this.createPlaybackUrl(current.video, current.audio),
      newSource.isLive === true
    );
    if (!playbackUrl) {
      this.setError('[PLAYER] LOCAL_PROXY_FAILED');
      return;
    }

    this.updateAvSessionMetadata();
    this.isBuffering = true;

    const autoSubtitle = this.pickSubtitleForLanguage(searchLanguage);
    if (autoSubtitle) {
      this.currentSubtitleUrl = autoSubtitle.url;
      this.subtitleVisible = true;
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
    const wasPlaying = this.isPlaying;
    const resumePos = this.currentTime;
    const effectiveAudio = this.isSeparatedDash(videoStream, audioStream) ? this.ensureCompatibleAudio(videoStream, audioStream) : undefined;

    this.playerModel.updateVideoStream(videoStream);
    this.playerModel.updateAudioStream(effectiveAudio);

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
    this.playbackSpeed = speed;
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
    if (this.isEnded) {
      this.playbackEngine.seek(0, true);
      this.isEnded = false;
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
    this.stateMachine.forceTransition(PlayerState.RELEASED);
    Logger.debug(TAG, 'releaseVideo: destroy playback engine and LocalMediaProxy session');
    this.playbackEngine.destroy();
    this.destroyCurrentLocalSession();
    this.avSessionManager.destroy();
    this.resetPlaybackState();
    this.errorListeners = [];
    this.waitingForBufferListeners = [];
    this.seekableRangesListeners = [];
    this.playerModel = new PlayerModel();
  }

  public toggleSubtitle(): void {
    this.subtitleVisible = !this.subtitleVisible;
    this.playbackEngine.setSubtitleVisible(this.subtitleVisible);
    if (!this.subtitleVisible) {
      this.subtitleText = '';
    }
  }

  public setSubtitleVisible(visible: boolean): void {
    this.subtitleVisible = visible;
    this.playbackEngine.setSubtitleVisible(visible);
    if (!visible) {
      this.subtitleText = '';
    }
  }

  public getNativeLogBridgeFns(_onLog: (level: string, tag: string, message: string) => void): NativeLogBridgeFns {
    return { start: () => {}, stop: () => {} };
  }

  private selectInitialStreams(isLive: boolean): boolean {
    const categories = this.playerModel.categorizedStreams;
    if (isLive) {
      const manifest = this.selectManifestByCap(categories.hlsManifest.length > 0 ? categories.hlsManifest : categories.dashManifest, true);
      if (manifest) {
        this.playerModel.updateVideoStream(manifest);
        this.playerModel.updateAudioStream(undefined);
        Logger.info(TAG, `Selected live manifest: ${this.describePlaybackUrl(manifest.url)}`);
        return true;
      }
    }

    if (categories.video.length > 0 && categories.audio.length > 0) {
      const video = this.selectBestVideo(categories.video, false);
      const audio = video ? this.selectBestCompatibleAudio(video, categories.audio) : undefined;
      if (video && audio) {
        this.playerModel.updateVideoStream(video);
        this.playerModel.updateAudioStream(audio);
        Logger.info(TAG, `Selected DASH separated: video=${video.quality} [${video.itag}], audio=${audio.quality} [${audio.itag}]`);
        return true;
      }
    }

    if (categories.progressive.length > 0) {
      const progressive = this.selectBestProgressive(categories.progressive);
      this.playerModel.updateVideoStream(progressive);
      this.playerModel.updateAudioStream(undefined);
      Logger.info(TAG, `Selected progressive: ${progressive.quality} [${progressive.itag}]`);
      return true;
    }

    const manifest = this.selectManifestByCap(categories.hlsManifest.length > 0 ? categories.hlsManifest : categories.dashManifest, false);
    if (manifest) {
      this.playerModel.updateVideoStream(manifest);
      this.playerModel.updateAudioStream(undefined);
      Logger.info(TAG, `Selected fallback manifest: ${this.describePlaybackUrl(manifest.url)}`);
      return true;
    }

    return false;
  }

  private selectBestVideo(streams: StreamInfo[], live: boolean): StreamInfo | undefined {
    const pbCfg = AppStorage.get('playbackConfig') as Record<string, Object> | undefined;
    const targetQuality = (live ? pbCfg?.mobileQuality : pbCfg?.defaultQuality) as string || 'best';
    const showHighRes = (pbCfg?.showHighResolutions as boolean) ?? false;
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

  private async createPlaybackUrl(videoStream?: StreamInfo, audioStream?: StreamInfo): Promise<string> {
    if (!videoStream || !videoStream.url) return '';
    if (this.isRemoteManifestUrl(videoStream.url)) {
      Logger.debug(TAG, `createPlaybackUrl: using remote manifest directly`);
      this.destroyCurrentLocalSession();
      return videoStream.url;
    }

    this.destroyCurrentLocalSession();
    const isDual = this.isSeparatedDash(videoStream, audioStream) && !!audioStream;
    const durationMs = isDual ? this.resolveDurationMs(videoStream, audioStream) : 0;
    Logger.info(TAG, `createPlaybackUrl: type=${isDual ? 'dual-dash' : 'single'} video=[itag=${videoStream.itag} ${videoStream.quality} ${videoStream.codecs}]${isDual ? ` audio=[itag=${audioStream!.itag} ${audioStream!.codecs}]` : ''} durationMs=${durationMs}`);

    const sessionId = await (isDual
      ? LocalMediaProxy.createYoutubeDualUrlSession(videoStream, audioStream!, durationMs)
      : LocalMediaProxy.createSingleUrlSession(videoStream.url, videoStream));

    const playbackUrl = LocalMediaProxy.getPlaybackUrl(sessionId);
    if (!playbackUrl.startsWith('http://127.0.0.1:')) {
      Logger.error(TAG, `createPlaybackUrl: invalid playbackUrl="${playbackUrl}" sessionId=${sessionId}`);
      LocalMediaProxy.destroySession(sessionId);
      return '';
    }
    this.currentLocalMediaSessionId = sessionId;
    const cachedUrl = await LocalMediaProxy.proxyUrl(playbackUrl);
    Logger.debug(TAG, `createPlaybackUrl: sessionId=${sessionId} url=${cachedUrl}`);
    return cachedUrl;
  }

  private resolveDurationMs(video: StreamInfo, audio?: StreamInfo): number {
    const fromStream = (video.approxDurationMs && video.approxDurationMs > 0)
      ? video.approxDurationMs
      : (audio?.approxDurationMs && audio.approxDurationMs > 0)
        ? audio.approxDurationMs
        : 0;
    if (fromStream > 0) return fromStream;
    const fromMeta = Math.round((this.durationTime || 0) * 1000);
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
    if (this.subtitleTracks.length === 0) return null;
    const lang = language.split('-')[0].toLowerCase();
    const exact = this.subtitleTracks.find(t => t.languageCode.toLowerCase() === language.toLowerCase());
    if (exact) return exact;
    const prefix = this.subtitleTracks.find(t => t.languageCode.split('-')[0].toLowerCase() === lang);
    if (prefix) return prefix;
    const manual = this.subtitleTracks.find(t => !t.isAutoGenerated && t.languageCode.split('-')[0].toLowerCase() === lang);
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
      const pbCfg = AppStorage.get('playbackConfig') as Record<string, Object> | undefined;
      const maxHeight = this.resolveMaxHeight((pbCfg?.mobileQuality as string) || '480p',
        (pbCfg?.showHighResolutions as boolean) ?? false);
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
    const categories = this.playerModel.categorizedStreams;
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
    return this.selectBestCompatibleAudio(videoStream, this.playerModel.categorizedStreams.audio) || requestedAudio;
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

    if (state.isPlaying && !this.isPlaying) {
      this.errorRetryCount = 0;
    }

    if (state.currentTime > 0) {
      this.lastKnownGoodPosition = state.currentTime;
    } else if (this.currentTime > 0 && state.errorMsg) {
      this.lastKnownGoodPosition = this.currentTime;
    }

    const prevDuration = this.durationTime;

    // 更新 @Track 字段（ArkTS 自动推送到绑定的 UI）
    this.isPlaying = state.isPlaying;
    this.isBuffering = state.isBuffering;
    this.isReady = state.isReady;
    this.isSeeking = state.isSeeking;
    this.isEnded = state.isEnded;
    this.currentTime = state.currentTime;
    this.duration = state.duration;
    this.durationTime = state.duration;
    this.playbackSpeed = state.playbackSpeed;
    this.cachedPercent = state.bufferingPercent;
    this.errorMsg = state.errorMsg;

    if (prevDuration === 0 && this.durationTime > 0) {
      this.updateAvSessionMetadata();
    }

    // 委托给 PlayerStateRelay：状态机 + AVSession + 节流进度
    this.stateRelay.onStateChange(state);

    // 错误监听（手动，需要特殊处理）
    const errorChanged = this.errorMsg !== state.errorMsg;
    if (errorChanged && state.errorMsg) {
      this.errorListeners.forEach(l => l(this.errorMsg));
      if (!this.isRecovering) {
        this.handlePlaybackError(state);
      }
    }
  }

  private resetPlaybackState(): void {
    this.isPlaying = false;
    this.isBuffering = false;
    this.isReady = false;
    this.isSeeking = false;
    this.isEnded = false;
    this.currentTime = 0;
    this.duration = 0;
    this.durationTime = 0;
    this.errorMsg = '';
    this.cachedPercent = 0;
    this.seekableRanges = [];
    this.playbackSpeed = 1.0;
    this.currentSubtitleUrl = '';
    this.subtitleVisible = false;
    this.subtitleText = '';
    this.lastKnownGoodPosition = 0;
    this.waitingForBufferListeners.forEach(l => l(false));
    this.errorListeners.forEach(l => l(''));
  }

  private async handlePlaybackError(state: PlaybackState): Promise<void> {
    if (!this.isActive() || this.isRecovering) return;
    const category = state.errorCategory || 'unknown';
    // 使用 lastKnownGoodPosition 而非 this.currentTime，
    // 因为 error 回调中 player.reset() 会将 currentTime 清零
    const resumePos = this.lastKnownGoodPosition > 0 ? this.lastKnownGoodPosition : this.currentTime;

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
    this.onErrorNeedsUserAction?.(this.errorMsg);
  }

  private async retryPlayback(resumePos: number): Promise<void> {
    Logger.debug(TAG, `retryPlayback at ${resumePos.toFixed(2)}s`);
    const current = this.playerModel.getCurrentStreams();
    const playbackUrl = await this.createPlaybackUrl(current.video, current.audio);
    if (!playbackUrl) {
      this.setError('[PLAYER] RETRY_FAILED');
      return;
    }
    this.playbackEngine.load(playbackUrl, resumePos);
    if (this.isPlaying) {
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
      this.playerModel.classifyStreams(refreshed.streams);
      if (!this.selectInitialStreams(refreshed.isLive === true)) {
        this.setError('[PLAYER] REFRESH_NO_STREAM');
        return;
      }
      const current = this.playerModel.getCurrentStreams();
      const playbackUrl = await this.createPlaybackUrl(current.video, current.audio);
      if (!playbackUrl) {
        this.setError('[PLAYER] REFRESH_PROXY_FAILED');
        return;
      }
      this.playbackEngine.load(playbackUrl, resumePos);
      if (this.isPlaying) {
        this.playbackEngine.play();
      }
    } catch (e) {
      Logger.error(TAG, `refreshAndReplay failed: ${e}`);
      this.retryPlayback(resumePos);
    }
  }

  private async switchToProgressiveFallback(resumePos: number): Promise<void> {
    const categories = this.playerModel.categorizedStreams;
    if (categories.progressive.length > 0) {
      const progressive = this.selectBestProgressive(categories.progressive);
      this.playerModel.updateVideoStream(progressive);
      this.playerModel.updateAudioStream(undefined);
      Logger.info(TAG, `Switched to progressive fallback: ${progressive.quality} [${progressive.itag}]`);
      const playbackUrl = await this.createPlaybackUrl(progressive, undefined);
      if (playbackUrl) {
        this.playbackEngine.load(playbackUrl, resumePos);
        if (this.isPlaying) {
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
    this.errorMsg = error;
    this.errorListeners.forEach(l => l(error));
    Logger.error(TAG, error);
  }

  private updateAvSessionMetadata(): void {
    const title = this.toPlainText(this.curSource.description) || this.toPlainText(this.curSource.name) || 'YourPipe';
    this.avSessionManager.setMetadata(title, this.curSource.author || '', this.durationTime, this.curSource.thumbnailUrl);
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
}
