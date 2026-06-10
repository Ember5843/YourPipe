export type PlaybackEngineState = 'stopped' | 'buffering' | 'paused' | 'playing';

export type PlaybackErrorCategory = 'network' | 'url_expired' | 'format' | 'source' | 'unknown';

export interface PlaybackState {
  engineState: PlaybackEngineState;
  isPlaying: boolean;
  isReady: boolean;
  isBuffering: boolean;
  isSeeking: boolean;
  isEnded: boolean;
  isLive: boolean;
  isSeekable: boolean;
  currentTime: number;
  duration: number;
  playbackSpeed: number;
  bufferingPercent: number;
  uri: string;
  mediaTitle: string;
  containerFormat: string;
  videoWidth: number;
  videoHeight: number;
  videoStreamCount: number;
  audioStreamCount: number;
  subtitleStreamCount: number;
  errorMsg: string;
  errorCategory?: PlaybackErrorCategory;
  errorCode?: number;
}

export interface EngineConfig {
  hwdecMode?: string;
  decoderFallback?: boolean;
  readaheadSecs?: number;
  cachePauseWait?: number;
  maxBackBytesKey?: string;
  streamBufferSizeCap?: number;
  seekKeyframeMode?: boolean;
  msgLevel?: string;
  minBufferMs?: number;
  maxBufferMs?: number;
  bufferForPlaybackMs?: number;
  bufferForPlaybackAfterRebufferMs?: number;
  backBufferDurationMs?: number;
  retainBackBufferFromKeyframe?: boolean;
  livePresentationDelayMs?: number;
  liveDvrWindowSegments?: number;
  liveEdgeThresholdSec?: number;
  subtitlePosition?: string;
  subtitleFontSize?: number;
  subtitleColor?: string;
  subtitleBackgroundAlpha?: number;
  subtitleDelayMs?: number;
  subtitleAutoSync?: boolean;
}

export interface PlaybackEngine {
  initialize(config: EngineConfig): Promise<boolean>;
  destroy(): void;
  isInitialized(): boolean;

  attachSurface(surfaceId: string): void;
  detachSurface(): void;
  resizeSurface(widthPx: number, heightPx: number): void;
  updateVideoRect(x: number, y: number, w: number, h: number): void;

  load(source: string, startPos: number): boolean;
  play(): void;
  pause(): void;
  stop(): void;
  seek(positionSec: number, keyframe: boolean): void;
  setPlaybackSpeed(speed: number): void;

  switchQuality(source: string, resumePos: number): boolean;
  prebufferTargetQuality(videoUrl: string, audioUrl: string): number;
  switchToPrebuffered(videoHandle: number, audioHandle: number, resumePos: number): boolean;

  preloadSubtitleTracks(urls: string[]): void;
  selectSubtitleTrack(index: number): void;
  setSubtitleVisible(visible: boolean): void;
  setSubtitleDelay(delayMs: number): void;
  getSubtitleDelay(): number;
  setSubtitleStyle(position: string, fontSize: number, color: string, bgAlpha: number): void;
  setSubtitleAutoSync(enabled: boolean): void;

  setVideoOutputEnabled(enabled: boolean): void;
  setHwdecMode(mode: string): void;

  getState(): PlaybackState;
  getBandwidthEstimateBps(): number;

  setStateCallback(cb: (state: PlaybackState) => void): void;
  setSubtitleCallback(cb: (text: string, startTime: number, duration: number) => void): void;
  registerLogCallback(cb: (level: string, tag: string, message: string) => void): void;
}
