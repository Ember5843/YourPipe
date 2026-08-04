import { YoutubeSabrInfo } from './YoutubeSabrInfo';

/**
 * Re-probes the SABR bootstrap for a video mid-playback (RELOAD_PLAYER /
 * ROTATE_IDENTITY actions). Injected from entry through SabrSessionStore so
 * the re-probe is serialized against normal playback extraction (the
 * extractor is a stateful singleton). Returns undefined when the re-probe
 * failed; the session then falls through to the next policy action.
 */
export interface SabrInfoReloader {
  reloadSabrInfo(info: YoutubeSabrInfo, reason: string): Promise<YoutubeSabrInfo | undefined>;
}
