import { YoutubeSabrInfo } from './YoutubeSabrInfo';

/**
 * Re-probes the SABR bootstrap for a video mid-playback (RELOAD_PLAYER /
 * ROTATE_IDENTITY actions). Injected from entry through SabrSessionStore so
 * the re-probe is serialized against normal playback extraction (the
 * extractor is a stateful singleton). Returns undefined when the re-probe
 * failed; the session then falls through to the next policy action.
 *
 * `reloadToken` is the token carried by a RELOAD_PLAYER_RESPONSE part
 * (`playbackContext.reloadPlaybackContext.reloadPlaybackParams.token`); the
 * re-probe player request must echo it so YouTube hands out a fresh streaming
 * URL / ustreamer config for the same session (PipePipe
 * `fetchSabrInfoForReload`). Empty/undefined for a ROTATE_IDENTITY re-probe.
 */
export interface SabrInfoReloader {
  reloadSabrInfo(info: YoutubeSabrInfo, reason: string, reloadToken?: string): Promise<YoutubeSabrInfo | undefined>;
}
