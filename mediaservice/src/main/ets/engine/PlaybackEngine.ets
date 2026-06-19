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
  // MPV 专用配置
  mpvHwdecEnabled?: boolean;
  mpvCacheSecs?: number;
  mpvDemuxerReadaheadSecs?: number;
  mpvDemuxerMaxBytes?: number;
  mpvGpuApi?: string;
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

  setSubtitle(url: string): void;

  setVideoOutputEnabled(enabled: boolean): void;
  setHwdecMode(mode: string): void;

  getState(): PlaybackState;
  getBandwidthEstimateBps(): number;

  setStateCallback(cb: (state: PlaybackState) => void): void;
  setSubtitleCallback(cb: (text: string, startTime: number, duration: number) => void): void;
  registerLogCallback(cb: (level: string, tag: string, message: string) => void): void;
}
