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
  hwdec: string;
  pixelFormat: string;
  colorSpace: string;
  colorPrimaries: string;
  colorGamma: string;
  audioCodec: string;
  audioBitRate: number;
  audioChannels: number;
  audioSampleRate: number;
  audioFormat: string;
  audioChannelLayout: string;
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
  /** Estimated total video frame number from MPV (`estimated-frame-number`). */
  totalFrames: number;
  /** Last A/V sync delta in milliseconds (`avsync` * 1000), or undefined when unavailable. */
  avSyncMs: number | undefined;
  /** Measured video filter output FPS (`estimated-vf-fps`). */
  measuredFps: number;
  /** Forward buffered bytes in MPV demuxer cache (`demuxer-cache-state/fw-bytes`). */
  bufferedBytes: number;
  /** Active MPV audio filter chain (`af`). */
  activeAudioFilters: string;
  /** Inferred transport protocol (`sabr` | `ypstream` | `hls` | `local` | `http` | ``). */
  transportKind: string;
}

export interface EngineConfig {
  // MPV 专用配置
  mpvHwdecEnabled?: boolean;
  mpvCacheSecs?: number;
  mpvDemuxerReadaheadSecs?: number;
  mpvDemuxerMaxBytes?: number;
  mpvGpuApi?: string;
  /** Writable sandbox directory for persistent Vulkan/libplacebo SPIR-V shader cache. */
  mpvShaderCacheDir?: string;
}

export interface PlaybackEngine {
  initialize(config: EngineConfig): Promise<boolean>;
  destroy(): void;
  isInitialized(): boolean;

  attachSurface(surfaceId: string): void;
  detachSurface(): void;
  resizeSurface(widthPx: number, heightPx: number): void;

  /**
   * Load a source. audioUrl (optional) is an external audio track for split
   * HLS live/post-live playback (audio rendition playlist), mapped to mpv
   * audio-files; empty/omitted clears any previous external audio.
   */
  load(source: string, startPos: number, audioUrl?: string): boolean;
  play(): void;
  pause(): void;
  stop(): void;
  seek(positionSec: number, keyframe: boolean): void;
  setPlaybackSpeed(speed: number): void;
  /** 单文件循环（Shorts 单条循环）：loop-file=inf/no，跨 load 保持。 */
  setFileLoop(enabled: boolean): void;
  /** 设置 MPV 原生音频滤镜链（响度均衡）。 */
  setAudioFilters(normalize: boolean): void;
  /** 设置 MPV 原生音画延迟（毫秒，自动钳制到 -1000..1000）。 */
  setAudioDelayMs(delayMs: number): void;
  setVolume(volume: number): void;
  getVolume(): number;

  setSubtitle(url: string): void;

  setVideoOutputEnabled(enabled: boolean): void;
  /** Hint target video bitrate (bps) so the engine scales demuxer forward/back buffer caps. */
  setTargetVideoBitrate(bitrateBps: number): void;

  getState(): PlaybackState;
  getPlaybackStats(): PlaybackStats;
  /** Toggle on-demand observation of high-frequency stats properties (frame count, avsync, fps, cache-speed). */
  setStatsObservationEnabled(enabled: boolean): void;
  /**
   * True when the loaded source is fetched directly from the network by the
   * engine (e.g. live HLS) instead of through the loopback proxy. Stats
   * consumers use this to pick the meaningful speed source: mpv `cache-speed`
   * for direct sources, the proxy traffic meter for proxy-fed ones.
   */
  isDirectNetworkSource(): boolean;

  setStateCallback(cb: (state: PlaybackState) => void): void;
  setSubtitleCallback(cb: (text: string, startTime: number, duration: number) => void): void;
}
