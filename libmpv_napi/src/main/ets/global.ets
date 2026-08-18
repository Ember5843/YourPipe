import nativeModule from 'libmpv_napi.so';

/**
 * Mux one video file + one audio file into a single output file (remux, no
 * re-encode). Output container is inferred from outPath's extension (.mp4/.mkv).
 * Paths must be real filesystem paths, not file:// URIs.
 *
 * Runs synchronously and may take a while for large files — call it inside an
 * ArkTS TaskPool task to keep it off the UI thread. Throws on failure.
 */
export function muxAudioVideo(videoPath: string, audioPath: string, outPath: string): void {
  nativeModule.muxAudioVideo(videoPath, audioPath, outPath);
}

export interface VideoHwDecoderCaps {
  probed: boolean;
  avc: boolean;
  hevc: boolean;
  vp9: boolean;
  av1: boolean;
  vp8: boolean;
}

/** Cached OHOS hardware video decoder capability probe. */
export function probeVideoHwDecoders(): VideoHwDecoderCaps {
  return nativeModule.probeVideoHwDecoders() as VideoHwDecoderCaps;
}
