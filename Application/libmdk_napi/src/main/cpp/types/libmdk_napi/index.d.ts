export const enum ColorSpace {
  Unknown = 0,
  BT709 = 1,
  BT2100_PQ = 2,
  SCRGB = 3,
  ExtendedLinearDisplayP3 = 4,
  ExtendedSRGB = 5,
  ExtendedLinearSRGB = 6,
  BT2100_HLG = 7,
}

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

export const enum SeekFlag {
  From0 = 1,
  FromStart = 1 << 1,
  FromNow = 1 << 2,
  Frame = 1 << 6,
  KeyFrame = 1 << 8,
  Fast = KeyFrame,
  AnyFrame = 1 << 9,
  InCache = 1 << 10,
  Backward = 1 << 16,
  Default = KeyFrame | FromStart | InCache,
}

export const enum LogLevel {
  Off = 0,
  Error = 1,
  Warning = 2,
  Info = 3,
  Debug = 4,
  All = 5,
}

export const enum VideoEffect {
  Brightness = 0,
  Contrast = 1,
  Hue = 2,
  Saturation = 3,
  ScaleChannels = 4,
  ShiftChannels = 5,
}

// Note: these enums are defined as ArkTS enums in the HAR package.
// Import enums from ETS files when writing app code.
export interface AudioCodecParameters {
  codec: string;
  codecTag: number;
  extraDataSize: number;
  bitRate: number;
  profile: number;
  level: number;
  frameRate: number;
  isFloat: boolean;
  isUnsigned: boolean;
  isPlanar: boolean;
  rawSampleSize: number;
  channels: number;
  sampleRate: number;
  blockAlign: number;
  frameSize: number;
}

export interface VideoCodecParameters {
  codec: string;
  codecTag: number;
  extraDataSize: number;
  bitRate: number;
  profile: number;
  level: number;
  frameRate: number;
  format: number;
  formatName: string;
  width: number;
  height: number;
  bFrames: number;
  par: number;
  colorSpace: number;
  doviProfile: number;
}

export interface SubtitleCodecParameters {
  codec: string;
  codecTag: number;
  extraDataSize: number;
  width: number;
  height: number;
}

export interface MediaStreamInfo {
  index: number;
  startTime: number;
  duration: number;
  metadata: Record<string, string>;
}

export interface AudioStreamInfo extends MediaStreamInfo {
  frames: number;
  codec: AudioCodecParameters;
}

export interface VideoStreamInfo extends MediaStreamInfo {
  frames: number;
  rotation: number;
  width: number;
  height: number;
  codec: VideoCodecParameters;
}

export interface SubtitleStreamInfo extends MediaStreamInfo {
  codec: SubtitleCodecParameters;
}

export interface MediaInfo {
  startTime: number;
  duration: number;
  bitRate: number;
  format: string;
  streams: number;
  metadata: Record<string, string>;
  audio: AudioStreamInfo[];
  video: VideoStreamInfo[];
  subtitle: SubtitleStreamInfo[];
}

// Note: ColorSpace, MediaType, PlaybackState are defined as ArkTS enums in enums.ets
// and should be imported from the HAR package, not from this native module.

export interface NativeMdkPlayerModule {
  ensurePlayer: (playerId: string) => void;
  releasePlayer: (playerId: string) => void;
  setMedia: (playerId: string, url: string) => void;
  setMediaSource: (playerId: string, url: string, mediaType: number) => void;
  play: (playerId: string) => void;
  pause: (playerId: string) => void;
  stop: (playerId: string) => void;
  prepare: (playerId: string, startPosition?: number) => void;
  seek: (playerId: string, positionMs: number) => void;
  seekWithFlags: (playerId: string, positionMs: number, flags: number) => void;
  setPlaybackRate: (playerId: string, rate: number) => void;
  setVolume: (playerId: string, volume: number) => void;
  setLoop: (playerId: string, count: number) => void;
  setProperty: (playerId: string, key: string, value: string) => void;
  getProperty: (playerId: string, key: string) => string;
  setColorSpace: (playerId: string, colorSpace: number) => void;
  setVideoEffect: (playerId: string, effect: number, value: number) => void;
  setDecoders: (playerId: string, mediaType: number, names: string[]) => void;
  setActiveTracks: (playerId: string, mediaType: number, tracks: number[]) => void;
  setAudioBackends: (playerId: string, names: string[]) => void;
  getPosition: (playerId: string) => number;
  buffered: (playerId: string) => number;
  getState: (playerId: string) => number;
  getMediaStatus: (playerId: string) => number;
  getMediaInfo: (playerId: string) => MediaInfo;
  getDuration: (playerId: string) => number;
  setEventCallback: (playerId: string, callback: (type: number, value: number) => void) => void;
  isPlaying: (playerId: string) => boolean;
  setVideoSurfaceSize: (playerId: string, width: number, height: number) => void;
  setVideoSurfaceId: (playerId: string, surfaceId: string) => void;
  version: () => number;
  ffmpegVersion: () => string;
  /**
   * Mux one video file + one audio file into a single output file (remux, no
   * re-encode). Output container is inferred from outPath's extension.
   * Runs synchronously — call it inside an ArkTS TaskPool task to run in the
   * background. Throws an Error (with a descriptive message) on failure.
   */
  muxAudioVideo: (videoPath: string, audioPath: string, outPath: string) => void;
  setGlobalOptionString: (key: string, value: string) => void;
  getGlobalOptionString: (key: string) => string | null;
  setGlobalOptionInt: (key: string, value: number) => void;
  getGlobalOptionInt: (key: string) => number | null;
  setGlobalOptionFloat: (key: string, value: number) => void;
  command: (playerId: string, args: string[]) => void;
  setResourceManager: (manager: object) => void;
}

declare const nativeModule: NativeMdkPlayerModule;

export default nativeModule;
