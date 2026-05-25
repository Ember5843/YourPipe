import { ClientFetchContext, ClientFetchResult } from './ClientTypes';
import { PlayerResponse } from '../PlayerResponseTypes';
import { ClientsConstants } from '../../model/ClientsConstants';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';

const logger = YTCoreLogger.getInstance('WebEmbeddedPlayerClient');

interface WebEmbeddedClientInfo {
  clientName: string;
  clientVersion: string;
  clientScreen: string;
  hl: string;
  gl: string;
  platform: string;
  visitorData: string | undefined;
  utcOffsetMinutes: number;
  originalUrl: string;
}

interface WebEmbeddedRequestInfo {
  internalExperimentFlags: string[];
  useSsl: boolean;
}

interface WebEmbeddedUserInfo {
  lockedSafetyMode: boolean;
}

interface WebEmbeddedThirdParty {
  embedUrl: string;
}

interface WebEmbeddedContext {
  client: WebEmbeddedClientInfo;
  request: WebEmbeddedRequestInfo;
  user: WebEmbeddedUserInfo;
}

interface WebEmbeddedPayload {
  context: WebEmbeddedContext;
  videoId: string;
  cpn: string;
  contentCheckOk: boolean;
  racyCheckOk: boolean;
  thirdParty: WebEmbeddedThirdParty;
}

export class WebEmbeddedPlayerClient {
  static async fetch(ctx: ClientFetchContext, httpClient: YouTubeHttpClient): Promise<ClientFetchResult | undefined> {
    const cpn = randomCpn();
    const clientInfo: WebEmbeddedClientInfo = {
      clientName: ClientsConstants.WEB_EMBEDDED_CLIENT_NAME,
      clientVersion: ClientsConstants.WEB_EMBEDDED_CLIENT_VERSION,
      clientScreen: 'EMBED',
      hl: ctx.hl,
      gl: ctx.gl,
      platform: ClientsConstants.DESKTOP_CLIENT_PLATFORM,
      visitorData: ctx.visitorData,
      utcOffsetMinutes: 0,
      originalUrl: 'https://www.youtube.com'
    };
    const reqInfo: WebEmbeddedRequestInfo = { internalExperimentFlags: [], useSsl: true };
    const userInfo: WebEmbeddedUserInfo = { lockedSafetyMode: false };
    const context: WebEmbeddedContext = { client: clientInfo, request: reqInfo, user: userInfo };
    const thirdParty: WebEmbeddedThirdParty = { embedUrl: `https://www.youtube.com/embed/${ctx.videoId}` };
    const payload: WebEmbeddedPayload = {
      context: context,
      videoId: ctx.videoId,
      cpn: cpn,
      contentCheckOk: true,
      racyCheckOk: true,
      thirdParty: thirdParty
    };

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'User-Agent': ClientsConstants.WEB_EMBEDDED_USER_AGENT,
      'X-YouTube-Client-Name': ClientsConstants.WEB_EMBEDDED_CLIENT_ID,
      'X-YouTube-Client-Version': ClientsConstants.WEB_EMBEDDED_CLIENT_VERSION,
      'Origin': 'https://www.youtube.com',
      'Referer': `https://www.youtube.com/embed/${ctx.videoId}`
    };
    const url = 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';

    try {
      const response = await httpClient.postJson(url, payload, headers);
      if (response && response.responseCode === 200) {
        const pr = JSON.parse(response.result as string) as PlayerResponse;
        if (pr?.streamingData) {
          const result: ClientFetchResult = {
            streamingData: pr.streamingData,
            cpn: cpn,
            sourceClient: 'web_embedded',
            playerResponse: pr
          };
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
