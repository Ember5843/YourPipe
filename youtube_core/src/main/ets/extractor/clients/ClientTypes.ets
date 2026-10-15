import { PlayerResponse, StreamingData } from '../PlayerResponseTypes';

export interface ClientFetchResult {
  streamingData: StreamingData | undefined;
  cpn: string;
  sourceClient: string;
  playerResponse: PlayerResponse | undefined;
}

export interface ClientFetchContext {
  videoId: string;
  hl: string;
  gl: string;
  visitorData: string | undefined;
  signatureTimestamp: number | undefined;
  /**
   * RELOAD_PLAYER echo: token from the SABR reload part, sent back in
   * `playbackContext.reloadPlaybackContext.reloadPlaybackParams.token`.
   * Only set by the mid-playback re-probe (`reprobeSabrInfo`).
   */
  reloadPlaybackToken?: string;
}
