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
}
