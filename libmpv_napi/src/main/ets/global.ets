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
 * Remux video + optional audio + optional subtitle tracks (.srt/.vtt) into a single
 * container (e.g. .mkv) without re-encoding.
 */
export function muxMedia(
  videoPath: string,
  audioPath: string,
  subtitlePaths: string[],
  subtitleLangs: string[],
  subtitleTitles: string[],
  outPath: string
): void {
  nativeModule.muxMedia(videoPath, audioPath, subtitlePaths, subtitleLangs, subtitleTitles, outPath);
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

export interface NativeDirectStreamSpec {
  url: string;
  userAgent?: string;
  contentLength?: number;
  initRangeStart?: number;
  initRangeEnd?: number;
  indexRangeStart?: number;
  indexRangeEnd?: number;
  bitrate?: number;
  itag?: number;
  headers?: Record<string, string>;
}

export interface NativeHlsStreamSpec {
  url: string;
  userAgent?: string;
  bitrate?: number;
  itag?: number;
  isAudio?: boolean;
  headers?: Record<string, string>;
}

export interface NativeStreamProxyConfig {
  kind: string;
  host: string;
  port: number;
  username?: string;
  password?: string;
  bridgePort?: number;
  exclusions?: string[];
  revision?: number;
}

export interface NativeStreamMetrics {
  networkSpeedBps: number;
  totalBytesRead: number;
  retryCount: number;
  lastHttpStatus: number;
}

/** Register a direct HTTP range stream with MPV's native ypstream:// stream_cb bridge. */
export function registerDirectStream(spec: NativeDirectStreamSpec): string {
  return nativeModule.registerDirectStream(JSON.stringify(spec));
}

/** Register a live HLS media playlist stream with MPV's native ypstream:// HlsLiveStream reader. */
export function registerHlsStream(spec: NativeHlsStreamSpec): string {
  return nativeModule.registerHlsStream(JSON.stringify(spec));
}

/** Unregister and cancel any active readers for a ypstream:// stream URL or ID. */
export function unregisterStream(urlOrId: string): void {
  if (!urlOrId) return;
  nativeModule.unregisterStream(urlOrId);
}

/** Update proxy settings used by native ypstream:// librcp_c transfers. */
export function updateStreamProxy(proxy: NativeStreamProxyConfig): void {
  nativeModule.updateStreamProxy(JSON.stringify(proxy));
}

/** Cancel all in-flight ypstream:// HTTP requests on network handover (retries cleanly on new epoch). */
export function abortAllStreams(): void {
  nativeModule.abortAllStreams();
}

/** Aggregate live throughput and retry counters from the native ypstream:// layer. */
export function getStreamMetrics(): NativeStreamMetrics {
  return nativeModule.getStreamMetrics() as NativeStreamMetrics;
}
