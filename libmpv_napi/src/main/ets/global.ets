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

/**
 * Set the process-level HTTP proxy env (http_proxy / no_proxy) for MPV-direct
 * fetches (HLS master/segment playlists, sub-add subtitle downloads) via the
 * vendored FFmpeg. Non-empty url may embed user:pass for an authenticated
 * upstream proxy; empty string clears both variables (direct). Loopback
 * (127.0.0.1 / localhost — LocalMediaProxy, SOCKS5 bridge) is pinned to
 * no_proxy and always stays direct.
 */
export function setHttpProxyEnv(url: string): void {
  nativeModule.setHttpProxyEnv(url);
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

/**
 * hwdec-codecs whitelist derived from the probed hardware decoder caps
 * (native is the single source of truth; EnsureMpv applies the same value).
 * Probe failure keeps the legacy full list rather than disabling hwdec.
 */
export function getHwdecCodecsWhitelist(): string {
  return nativeModule.getHwdecCodecsWhitelist();
}
