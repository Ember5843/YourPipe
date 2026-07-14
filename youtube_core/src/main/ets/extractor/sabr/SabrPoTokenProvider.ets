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
}
