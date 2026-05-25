import { ClientFetchContext, ClientFetchResult } from './ClientTypes';
import { PlayerResponse } from '../PlayerResponseTypes';
import { ClientsConstants } from '../../model/ClientsConstants';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';

const logger = YTCoreLogger.getInstance('TvHtml5PlayerClient');

interface TvClientInfo {
  clientName: string;
  clientVersion: string;
  hl: string;
  gl: string;
  utcOffsetMinutes: number;
}

interface TvContext {
  client: TvClientInfo;
}

interface TvPlaybackContext {
  html5Preference: string;
  signatureTimestamp: number;
}

interface TvPlaybackWrapper {
  contentPlaybackContext: TvPlaybackContext;
}

interface TvPayload {
  context: TvContext;
  playbackContext: TvPlaybackWrapper;
  cpn: string;
  videoId: string;
  contentCheckOk: boolean;
  racyCheckOk: boolean;
}

export class TvHtml5PlayerClient {
  static async fetch(ctx: ClientFetchContext, httpClient: YouTubeHttpClient): Promise<ClientFetchResult | undefined> {
    if (!ctx.signatureTimestamp) {
      logger.warn('No signatureTimestamp, skipping TV client');
      return undefined;
    }
    const cpn = randomCpn();
    const clientInfo: TvClientInfo = {
      clientName: ClientsConstants.TVHTML5_CLIENT_NAME,
      clientVersion: ClientsConstants.TVHTML5_EMBED_CLIENT_VERSION,
      hl: ctx.hl,
      gl: ctx.gl,
      utcOffsetMinutes: 0
    };
    const tvCtx: TvContext = { client: clientInfo };
    const pbCtx: TvPlaybackContext = { html5Preference: 'HTML5_PREF_WANTS', signatureTimestamp: ctx.signatureTimestamp };
    const pbWrapper: TvPlaybackWrapper = { contentPlaybackContext: pbCtx };
    const payload: TvPayload = { context: tvCtx, playbackContext: pbWrapper, cpn: cpn, videoId: ctx.videoId, contentCheckOk: true, racyCheckOk: true };

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'User-Agent': ClientsConstants.TVHTML5_USER_AGENT,
      'X-YouTube-Client-Name': ClientsConstants.TVHTML5_CLIENT_ID,
      'X-YouTube-Client-Version': ClientsConstants.TVHTML5_EMBED_CLIENT_VERSION
    };
    const url = 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';

    try {
      const response = await httpClient.postJson(url, payload, headers);
      if (response && response.responseCode === 200) {
        const pr = JSON.parse(response.result as string) as PlayerResponse;
        if (pr?.streamingData) {
          const result: ClientFetchResult = { streamingData: pr.streamingData, cpn: cpn, sourceClient: 'tv', playerResponse: pr };
          return result;
        }
      }
    } catch (e) {
      logger.warn('fetch failed:', e);
    }
    return undefined;
  }
}

function randomCpn(): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  let result = '';
  for (let i = 0; i < 16; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}
