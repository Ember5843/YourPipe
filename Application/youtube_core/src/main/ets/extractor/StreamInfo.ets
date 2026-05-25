import { DeliveryMethod } from '../model/DeliveryType';

/**
 * 流信息
 * 对应 Python: StreamInfo dataclass
 */
export interface StreamInfo {
  url: string;
  itag: number | undefined;
  mimeType: string | undefined;
  qualityLabel: string | undefined;
  audioQuality: string | undefined;
  bitrate: number | undefined;
  contentLength: number | undefined;
  hasVideo: boolean;
  hasAudio: boolean;
  deliveryMethod: DeliveryMethod | undefined;
  kind: string | undefined;
  sourceClient: string | undefined;
  container: string | undefined;
  codecs: string | undefined;
  initRange: StreamRange | undefined;
  indexRange: StreamRange | undefined;
  approxDurationMs: number | undefined;
  durationMs: number | undefined;
  isLive: boolean | undefined;
  isOtf: boolean | undefined;
  audioLanguage: string | undefined;
  audioTrackId: string | undefined;
  audioTrackName: string | undefined;
  audioTrackType: string | undefined;
  audioChannels: number | undefined;
  audioSampleRate: number | undefined;
  videoFps: number | undefined;
  codec: string | undefined;
  width: number | undefined;
  height: number | undefined;
}

/**
 * 流范围
 */
export interface StreamRange {
  start: number;
  end: number;
}

/**
 * 流类型枚举
 */
export type StreamKind =
  | 'progressive'
  | 'video_only'
  | 'audio_only'
  | 'manifest_hls'
  | 'manifest_dash';

/**
 * Check if two streams have equal stats (itag, codec, resolution).
 * Ported from org.schabi.newpipe.extractor.stream.Stream.equalStats
 */
export function equalStats(a: StreamInfo, b: StreamInfo): boolean {
  if (a.itag !== b.itag) return false;
  if (a.codec !== b.codec) return false;
  if (a.width !== b.width) return false;
  if (a.height !== b.height) return false;
  return true;
}

/**
 * Check if a list of streams already contains a similar stream.
 * Ported from org.schabi.newpipe.extractor.stream.Stream.containSimilarStream
 */
export function containSimilarStream(stream: StreamInfo, list: StreamInfo[]): boolean {
  return list.some(other => equalStats(stream, other));
}
