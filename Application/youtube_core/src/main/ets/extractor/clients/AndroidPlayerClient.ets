import { ClientFetchContext, ClientFetchResult } from './ClientTypes';
import { PlayerResponse } from '../PlayerResponseTypes';
import { ClientsConstants } from '../../model/ClientsConstants';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';

const logger = YTCoreLogger.getInstance('AndroidPlayerClient');

interface AndroidClientInfo {
  clientName: string;
  clientVersion: string;
  clientScreen: string;
  androidSdkVersion: number;
  osName: string;
  osVersion: string;
  hl: string;
  gl: string;
  platform: string;
  visitorData: string | undefined;
  utcOffsetMinutes: number;
}

interface AndroidRequestInfo {
  internalExperimentFlags: string[];
  useSsl: boolean;
}

interface AndroidUserInfo {
  lockedSafetyMode: boolean;
}

interface AndroidClientContext {
  client: AndroidClientInfo;
  request: AndroidRequestInfo;
  user: AndroidUserInfo;
}

interface AndroidPlayerRequest {
  videoId: string;
  cpn: string;
  contentCheckOk: boolean;
  racyCheckOk: boolean;
}

interface AndroidPayload {
  context: AndroidClientContext;
  playerRequest: AndroidPlayerRequest;
  disablePlayerResponse: boolean;
}

interface AndroidReelResponse {
  playerResponse?: PlayerResponse;
}

export class AndroidPlayerClient {
  static async fetch(ctx: ClientFetchContext, httpClient: YouTubeHttpClient): Promise<ClientFetchResult | undefined> {
    const cpn = randomCpn();
    const clientInfo: AndroidClientInfo = {
      clientName: ClientsConstants.ANDROID_CLIENT_NAME,
      clientVersion: ClientsConstants.ANDROID_CLIENT_VERSION,
      clientScreen: 'WATCH',
      androidSdkVersion: parseInt(ClientsConstants.ANDROID_SDK_VERSION),
      osName: 'Android',
      osVersion: ClientsConstants.ANDROID_OS_VERSION,
      hl: ctx.hl,
      gl: ctx.gl,
      platform: 'MOBILE',
      visitorData: ctx.visitorData,
      utcOffsetMinutes: 0
    };
    const reqInfo: AndroidRequestInfo = { internalExperimentFlags: [], useSsl: true };
    const userInfo: AndroidUserInfo = { lockedSafetyMode: false };
    const context: AndroidClientContext = { client: clientInfo, request: reqInfo, user: userInfo };
    const playerReq: AndroidPlayerRequest = { videoId: ctx.videoId, cpn: cpn, contentCheckOk: true, racyCheckOk: true };
    const payload: AndroidPayload = { context: context, playerRequest: playerReq, disablePlayerResponse: false };

    const headers: Record<string, string> = {
      'User-Agent': ClientsConstants.ANDROID_USER_AGENT,
      'Content-Type': 'application/json',
      'X-Goog-Api-Format-Version': '2'
    };
    const t = randomTParameter();
    const url = `https://youtubei.googleapis.com/youtubei/v1/reel/reel_item_watch?prettyPrint=false&t=${t}&id=${ctx.videoId}&$fields=playerResponse`;

    try {
      const response = await httpClient.postJson(url, payload, headers);
      if (response && response.responseCode === 200) {
        const parsed = JSON.parse(response.result as string) as AndroidReelResponse;
        const pr = parsed.playerResponse;
        if (pr?.streamingData) {
          const result: ClientFetchResult = { streamingData: pr.streamingData, cpn: cpn, sourceClient: 'android', playerResponse: pr };
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

function randomTParameter(): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let result = '';
  for (let i = 0; i < 12; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}
