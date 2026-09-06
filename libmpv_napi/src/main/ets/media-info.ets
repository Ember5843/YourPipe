// Field sets mirror exactly what the native side (media_info_napi.cpp)
// produces from live mpv properties — no legacy libmdk placeholder fields.

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
