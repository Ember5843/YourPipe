import { SabrContextUpdate } from './SabrDecodedResponse';

/**
 * Server-owned session state for one SABR epoch (PipePipe serverState subset).
 * Everything here is meaningless after a server-side session reset (reload /
 * identity rotation) and would be cleared together; local playback progress
 * (FormatProgress, segment cache) lives elsewhere and survives an epoch change.
 *
 * Stage 0 note: this is a pure data holder. YoutubeSabrSession owns the
 * request/redirect/backoff/token-refresh counters, YoutubeSabrStreamState
 * delegates cookie/context/token storage here. Read/write timing is unchanged.
 */
export class SabrServerEpoch {
  /** Current POST target; swapped on server redirect. */
  serverAbrStreamingUrl: string;
  requestNumber: number = 0;
  redirectCount: number = 0;
  /** Server-requested cooldown (Date.now() deadline). Honored before every POST. */
  backoffUntilMs: number = 0;
  poTokenRefreshes: number = 0;
  /** RELOAD_PLAYER attempts spent in this session (budget in the policy layer). */
  reloads: number = 0;
  playbackCookie?: Uint8Array;
  poToken?: Uint8Array;
  sabrContexts: Map<number, SabrContextUpdate> = new Map();
  activeSabrContextTypes: Set<number> = new Set();

  constructor(serverAbrStreamingUrl: string) {
    this.serverAbrStreamingUrl = serverAbrStreamingUrl;
  }

  /**
   * Clear server-owned cookie/context/token state (ROTATE_IDENTITY).
   * URL/counters/backoff are reset explicitly by the caller; RELOAD_PLAYER
   * keeps this state and only adjusts its own subset.
   */
  resetServerState(): void {
    this.playbackCookie = undefined;
    this.poToken = undefined;
    this.sabrContexts.clear();
    this.activeSabrContextTypes.clear();
  }
}
