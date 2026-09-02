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

// Mirrors the PCM chunk object produced by the audio tap bridge in
// player_napi.cpp (mpv asrtap filter: 16kHz mono float32, ~200ms batches).
// ptsMs is the media-timeline pts of the first sample. Control markers
// (DISCONTINUITY=1: seek/reset, drop partial data; EOF=2: end of stream)
// arrive with an empty samples array and the flag set.
export interface AudioTapChunk {
  ptsMs: number;
  samples: Float32Array;
  flags: number;
}
