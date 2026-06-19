import { ClientFetchContext, ClientFetchResult } from './ClientTypes';
import { PlayerResponse } from '../PlayerResponseTypes';
import { ClientsConstants } from '../../model/ClientsConstants';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';

const logger = YTCoreLogger.getInstance('SafariPlayerClient');

interface SafariClientInfo {
  clientName: string;
  clientVersion: string;
  userAgent: string;
  timeZone: string;
  utcOffsetMinutes: number;
  hl: string;
  gl: string;
}

interface SafariContext {
  client: SafariClientInfo;
}

interface SafariPlaybackContext {
  html5Preference: string;
  signatureTimestamp: number;
}

interface SafariPlaybackWrapper {
  contentPlaybackContext: SafariPlaybackContext;
}

interface SafariPayload {
  context: SafariContext;
  playbackContext: SafariPlaybackWrapper;
  cpn: string;
  videoId: string;
  contentCheckOk: boolean;
  racyCheckOk: boolean;
}

export class SafariPlayerClient {
  static async fetch(ctx: ClientFetchContext, httpClient: YouTubeHttpClient): Promise<ClientFetchResult | undefined> {
    if (!ctx.signatureTimestamp) {
      logger.warn('No signatureTimestamp, skipping Safari client');
      return undefined;
    }
    const cpn = randomCpn();
    const clientInfo: SafariClientInfo = {
      clientName: ClientsConstants.SAFARI_CLIENT_NAME,
      clientVersion: ClientsConstants.SAFARI_CLIENT_VERSION,
      userAgent: ClientsConstants.SAFARI_USER_AGENT,
      timeZone: 'UTC',
      utcOffsetMinutes: 0,
      hl: ctx.hl,
      gl: ctx.gl
    };
    const safariCtx: SafariContext = { client: clientInfo };
    const pbCtx: SafariPlaybackContext = { html5Preference: 'HTML5_PREF_WANTS', signatureTimestamp: ctx.signatureTimestamp };
    const pbWrapper: SafariPlaybackWrapper = { contentPlaybackContext: pbCtx };
    const payload: SafariPayload = { context: safariCtx, playbackContext: pbWrapper, cpn: cpn, videoId: ctx.videoId, contentCheckOk: true, racyCheckOk: true };

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'User-Agent': ClientsConstants.SAFARI_USER_AGENT,
      'X-YouTube-Client-Name': ClientsConstants.SAFARI_CLIENT_ID,
      'X-YouTube-Client-Version': ClientsConstants.SAFARI_CLIENT_VERSION
    };
    const url = 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';

    try {
      // SafariPlayerClient 是登录态下的主流提取客户端，显式 opt-in 注入登录头
      // （对齐 PipePipe getSafariPostResponseAsync → addLoggedInHeaders）
      const response = await httpClient.postJson(url, payload, headers, true);
      if (response && response.responseCode === 200) {
        const pr = JSON.parse(response.result as string) as PlayerResponse;
        if (pr?.streamingData) {
          const result: ClientFetchResult = { streamingData: pr.streamingData, cpn: cpn, sourceClient: 'safari', playerResponse: pr };
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
