import { probeVideoHwDecoders, getHwdecCodecsWhitelist, VideoHwDecoderCaps } from '@yourpipe/libmpv-napi';
import Logger from '../utils/Logger';

const TAG: string = '[PlayerLog][VideoHwCaps]';

/**
 * Process-wide cache of OHOS hardware video decoder capability.
 * Used by stream selection (avoid VP9/AV1 soft-decode heat) and engine routing.
 */
export class VideoHwCaps {
  private static cached: VideoHwDecoderCaps | null = null;
  private static cachedWhitelist: string | null = null;

  static get(): VideoHwDecoderCaps {
    if (VideoHwCaps.cached !== null) {
      return VideoHwCaps.cached;
    }
    try {
      const caps = probeVideoHwDecoders();
      VideoHwCaps.cached = caps;
      Logger.info(TAG,
        `probe: avc=${caps.avc} hevc=${caps.hevc} vp9=${caps.vp9} av1=${caps.av1} vp8=${caps.vp8}`);
      return caps;
    } catch (e) {
      Logger.warn(TAG, `probe failed: ${e}`);
      // Safe defaults: assume classic AVC/HEVC hardware is present; treat VP9/AV1 as soft-only.
      const fallback: VideoHwDecoderCaps = {
        probed: false,
        avc: true,
        hevc: true,
        vp9: false,
        av1: false,
        vp8: false,
      };
      VideoHwCaps.cached = fallback;
      return fallback;
    }
  }

  /**
   * hwdec-codecs whitelist for mpv, passthrough of the native probe-derived
   * value (native is the single source of truth and applies the same string in
   * EnsureMpv). Probe failure keeps the legacy full list rather than disabling
   * hwdec; the same legacy string is the last-ditch guard if the NAPI call
   * itself throws (e.g. stale native library).
   */
  static hwdecCodecsWhitelist(): string {
    if (VideoHwCaps.cachedWhitelist !== null) {
      return VideoHwCaps.cachedWhitelist;
    }
    try {
      const whitelist = getHwdecCodecsWhitelist();
      VideoHwCaps.cachedWhitelist = whitelist;
      Logger.info(TAG, `hwdec-codecs whitelist: ${whitelist}`);
      return whitelist;
    } catch (e) {
      Logger.warn(TAG, `whitelist query failed: ${e}`);
      const legacy = 'h264,hevc,vp8,vp9,av1';
      VideoHwCaps.cachedWhitelist = legacy;
      return legacy;
    }
  }

  /** Whether this codec string is safe for hardware decode on this device. */
  static isCodecHardwareFriendly(codecs?: string): boolean {
    const caps = VideoHwCaps.get();
    const c = (codecs || '').toLowerCase();
    if (c.startsWith('avc1') || c.startsWith('avc3') || c.includes('avc') || c.includes('h264')) {
      return caps.avc;
    }
    if (c.startsWith('hvc1') || c.startsWith('hev1') || c.includes('hevc') || c.includes('h265')) {
      return caps.hevc;
    }
    if (c.startsWith('vp9') || c.startsWith('vp09')) {
      return caps.vp9;
    }
    if (c.startsWith('av01') || c.includes('av1')) {
      return caps.av1;
    }
    if (c.startsWith('vp8')) {
      return caps.vp8;
    }
    return false;
  }

  /** Prefer surface engine only for SDR H.264/HEVC with hardware. */
  static canUseSurfaceEngine(codecs?: string, height?: number): boolean {
    const caps = VideoHwCaps.get();
    const h = height || 0;
    if (h > 1080) {
      return false;
    }
    const c = (codecs || '').toLowerCase();
    if (c.startsWith('avc1') || c.startsWith('avc3')) {
      return caps.avc;
    }
    if (c.startsWith('hvc1') || c.startsWith('hev1')) {
      return caps.hevc;
    }
    return false;
  }
}
