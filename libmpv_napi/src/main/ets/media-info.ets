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
  // Extra live fields read from mpv (best-effort; may be empty/0 when unknown).
  title?: string;
  fileSize?: string;
  frameRate?: number;
}
