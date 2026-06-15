export enum ColorSpace {
  Unknown = 0,
  BT709 = 1,
  BT2100_PQ = 2,
  SCRGB = 3,
  ExtendedLinearDisplayP3 = 4,
  ExtendedSRGB = 5,
  ExtendedLinearSRGB = 6,
  BT2100_HLG = 7,
}

export enum MediaType {
  Unknown = -1,
  Video = 0,
  Audio = 1,
  Subtitle = 3,
}

export enum PlaybackState {
  Stopped = 0,
  Running = 1,
  Playing = 1,
  Paused = 2,
}

export enum MediaStatus {
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

export enum SeekFlag {
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

export enum LogLevel {
  Off = 0,
  Error = 1,
  Warning = 2,
  Info = 3,
  Debug = 4,
  All = 5,
}

export enum VideoEffect {
  Brightness = 0,
  Contrast = 1,
  Hue = 2,
  Saturation = 3,
  ScaleChannels = 4,
  ShiftChannels = 5,
}

