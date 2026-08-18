export type PlaybackEngineState = 'stopped' | 'buffering' | 'paused' | 'playing';

export type PlaybackErrorCategory = 'network' | 'url_expired' | 'format' | 'source' | 'unknown';

export interface PlaybackState {
  engineState: PlaybackEngineState;
  isPlaying: boolean;
  isReady: boolean;
  /** True for the native MPV buffered/playback-restart status event. */
  isBuffered: boolean;
  isBuffering: boolean;
  isSeeking: boolean;
  isEnded: boolean;
  isLive: boolean;
  isSeekable: boolean;
  currentTime: number;
  duration: number;
  playbackSpeed: number;
  bufferingPercent: number;
  /** MPV demuxer cache ranges in media seconds; ranges may be sparse after seeking. */
  seekableRanges: number[][];
  uri: string;
  mediaTitle: string;
  containerFormat: string;
  videoWidth: number;
  videoHeight: number;
  videoStreamCount: number;
  audioStreamCount: number;
  subtitleStreamCount: number;
  videoCodec: string;
  videoBitRate: number;
  frameRate: number;
  audioCodec: string;
  audioBitRate: number;
  audioChannels: number;
  audioSampleRate: number;
  fileSize: number;
  errorMsg: string;
  errorCategory?: PlaybackErrorCategory;
  errorCode?: number;
}

export interface EngineConfig {
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
  setVolume(volume: number): void;
  getVolume(): number;

  switchQuality(source: string, resumePos: number): boolean;

  setSubtitle(url: string): void;

  setVideoOutputEnabled(enabled: boolean): void;
  setHwdecMode(mode: string): void;

  getState(): PlaybackState;
  getBandwidthEstimateBps(): number;

  setStateCallback(cb: (state: PlaybackState) => void): void;
  setSubtitleCallback(cb: (text: string, startTime: number, duration: number) => void): void;
  registerLogCallback(cb: (level: string, tag: string, message: string) => void): void;
}
