import { YoutubeSabrInfo } from './YoutubeSabrInfo';
import { YoutubeSabrStreamState } from './YoutubeSabrStreamState';

/**
 * Optional PO token source for protected SABR responses.
 * Provider may return null; session continues without hard-fail until protection boundary.
 */
export interface SabrPoTokenProvider {
  getPoToken(
    info: YoutubeSabrInfo,
    streamState: YoutubeSabrStreamState,
    forceRefresh: boolean
  ): Promise<Uint8Array | undefined>;

  /**
   * ROTATE_IDENTITY: drop every token minted against the current session
   * identity (and the identity pin itself) so the next mint runs on the
   * re-probed visitorData. Returns true when the invalidation took effect.
   */
  invalidatePoTokenIdentity?(info: YoutubeSabrInfo): Promise<boolean>;
}
