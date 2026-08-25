export const enum MediaType {
  Unknown = -1,
  Video = 0,
  Audio = 1,
  Subtitle = 3,
}

export const enum PlaybackState {
  Stopped = 0,
  Running = 1,
  Playing = 1,
  Paused = 2,
}

export const enum MediaStatus {
  NoMedia = 0,
  Unloaded = 1,
  Loading = 1 << 1,
  Loaded = 1 << 2,
  Stalled = 1 << 3,
  Buffering = 1 << 4,
  Buffered = 1 << 5,
  End = 1 << 6,
  Seeking = 1 << 7,
  Prepared = 1 << 8,
  Invalid = 1 << 31,
}

// Note: these enums are defined as ArkTS enums in the HAR package.
// Import enums from ETS files when writing app code.
// Field sets mirror exactly what media_info_napi.cpp produces from live mpv
// properties.
export interface AudioCodecParameters {
  codec: string;
  channels: number;
  sampleRate: number;
  bitRate: number;
  format: string;
  channelLayout: string;
}

export interface VideoCodecParameters {
  codec: string;
  formatName: string;
  width: number;
  height: number;
  frameRate: number;
  bitRate: number;
  pixelFormat: string;
  colorSpace: string;
  primaries: string;
  gamma: string;
  hwdec: string;
}

export interface AudioStreamInfo {
  index: number;
  codec: AudioCodecParameters;
}

export interface VideoStreamInfo {
  index: number;
  rotation: number;
  width: number;
  height: number;
  codec: VideoCodecParameters;
}

export interface MediaInfo {
  startTime: number;
  duration: number;
  bitRate: number;
  format: string;
  streams: number;
  audio: AudioStreamInfo[];
  video: VideoStreamInfo[];
  // Extra live fields read from mpv (best-effort; may be empty/0 when unknown).
  title?: string;
  fileSize?: string;
  frameRate?: number;
}

// Note: MediaType, PlaybackState, MediaStatus are defined as ArkTS enums in
// enums.ets and should be imported from the HAR package, not from this native
// module.

export interface NativeMpvPlayerModule {
  releasePlayer: (playerId: string) => void;
  setMedia: (playerId: string, url: string, startPositionMs?: number) => void;
  play: (playerId: string) => void;
  pause: (playerId: string) => void;
  stop: (playerId: string) => void;
  prepare: (playerId: string, startPosition?: number) => void;
  seekWithFlags: (playerId: string, positionMs: number) => void;
  setPlaybackRate: (playerId: string, rate: number) => void;
  setVolume: (playerId: string, volume: number) => void;
  setProperty: (playerId: string, key: string, value: string) => void;
  getProperty: (playerId: string, key: string) => string;
  getPosition: (playerId: string) => number;
  getSeekableRangesJson: (playerId: string) => string;
  getState: (playerId: string) => number;
  getMediaStatus: (playerId: string) => number;
  getMediaInfo: (playerId: string) => MediaInfo;
  getDuration: (playerId: string) => number;
  setEventCallback: (playerId: string, callback: (type: number, value: number) => void) => void;
  isPlaying: (playerId: string) => boolean;
  setVideoSurfaceSize: (playerId: string, width: number, height: number) => void;
  setVideoSurfaceId: (playerId: string, surfaceId: string) => void;
  /**
   * Set/clear the process-level HTTP proxy env (http_proxy / no_proxy) honored
   * by the vendored FFmpeg for MPV-direct fetches (HLS masters/segments,
   * sub-add subtitles). A non-empty URL may embed user:pass; an empty string
   * clears both variables. no_proxy pins 127.0.0.1,localhost so loopback
   * endpoints (LocalMediaProxy, SOCKS5 bridge) always stay direct.
   */
  setHttpProxyEnv: (url: string) => void;
  /**
   * Mux one video file + one audio file into a single output file (remux, no
   * re-encode). Output container is inferred from outPath's extension.
   * Runs synchronously — call it inside an ArkTS TaskPool task to run in the
   * background. Throws an Error (with a descriptive message) on failure.
   */
  muxAudioVideo: (videoPath: string, audioPath: string, outPath: string) => void;
  /**
   * Probe OHOS hardware video decoder capability (cached after first call).
   * category HARDWARE for video/avc, hevc, vp9, av01, vp8.
   */
  probeVideoHwDecoders: () => {
    probed: boolean;
    avc: boolean;
    hevc: boolean;
    vp9: boolean;
    av1: boolean;
    vp8: boolean;
  };
  /**
   * hwdec-codecs whitelist derived from the probed caps (single source of
   * truth; EnsureMpv applies the same value natively). Probe failure keeps the
   * legacy full list rather than disabling hwdec.
   */
  getHwdecCodecsWhitelist: () => string;
  command: (playerId: string, args: string[]) => void;
}

declare const nativeModule: NativeMpvPlayerModule;

export default nativeModule;
