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

/** Live playback statistics snapshot (Stats-for-Nerds style); MPV fields + proxy-metered network speed. */
export interface PlaybackStats {
  /** Demuxer cache fill speed in bytes/sec; collapses to 0 once the loopback-fed cache is full. */
  cacheSpeedBps: number;
  /**
   * Real network throughput in bytes/sec. For proxy-fed sources it is metered
   * at the local proxy's inbound side (`proxyTrafficMeter`); for direct network
   * sources (live HLS handed straight to MPV) it mirrors mpv's `cache-speed`.
   * Optional because engine-level snapshots don't know proxy traffic;
   * `AvPlayerController.getPlaybackStats()` always fills it.
   */
  networkSpeedBps?: number;
  /** Buffered media duration ahead of the play position, in seconds. */
  demuxerCacheDurationSec: number;
  /** Frames dropped by the video output. */
  droppedFrames: number;
  /** Frames dropped by the decoder. */
  decoderDroppedFrames: number;
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
  getPlaybackStats(): PlaybackStats;
  /**
   * True when the loaded source is fetched directly from the network by the
   * engine (e.g. live HLS) instead of through the loopback proxy. Stats
   * consumers use this to pick the meaningful speed source: mpv `cache-speed`
   * for direct sources, the proxy traffic meter for proxy-fed ones.
   */
  isDirectNetworkSource(): boolean;

  setStateCallback(cb: (state: PlaybackState) => void): void;
  setSubtitleCallback(cb: (text: string, startTime: number, duration: number) => void): void;
  registerLogCallback(cb: (level: string, tag: string, message: string) => void): void;
}
