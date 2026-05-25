import { ClientFetchContext, ClientFetchResult } from './ClientTypes';
import { PlayerResponse } from '../PlayerResponseTypes';
import { ClientsConstants } from '../../model/ClientsConstants';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';

const logger = YTCoreLogger.getInstance('IosPlayerClient');

interface IosClientInfo {
  clientName: string;
  clientVersion: string;
  clientScreen: string;
  deviceMake: string;
  deviceModel: string;
  osName: string;
  osVersion: string;
  hl: string;
  gl: string;
  platform: string;
  visitorData: string | undefined;
  utcOffsetMinutes: number;
}

interface IosRequestInfo {
  internalExperimentFlags: string[];
  useSsl: boolean;
}

interface IosUserInfo {
  lockedSafetyMode: boolean;
}

interface IosContext {
  client: IosClientInfo;
  request: IosRequestInfo;
  user: IosUserInfo;
}

interface IosPayload {
  context: IosContext;
  videoId: string;
  cpn: string;
  contentCheckOk: boolean;
  racyCheckOk: boolean;
}

export class IosPlayerClient {
  static async fetch(ctx: ClientFetchContext, httpClient: YouTubeHttpClient): Promise<ClientFetchResult | undefined> {
    const cpn = randomCpn();
    const clientInfo: IosClientInfo = {
      clientName: ClientsConstants.IOS_CLIENT_NAME,
      clientVersion: ClientsConstants.IOS_CLIENT_VERSION,
      clientScreen: 'WATCH',
      deviceMake: 'Apple',
      deviceModel: ClientsConstants.IOS_DEVICE_MODEL,
      osName: 'iOS',
      osVersion: ClientsConstants.IOS_OS_VERSION,
      hl: ctx.hl,
      gl: ctx.gl,
      platform: 'MOBILE',
      visitorData: ctx.visitorData,
      utcOffsetMinutes: 0
    };
    const reqInfo: IosRequestInfo = { internalExperimentFlags: [], useSsl: true };
    const userInfo: IosUserInfo = { lockedSafetyMode: false };
    const context: IosContext = { client: clientInfo, request: reqInfo, user: userInfo };
    const payload: IosPayload = { context: context, videoId: ctx.videoId, cpn: cpn, contentCheckOk: true, racyCheckOk: true };

    const headers: Record<string, string> = {
      'User-Agent': ClientsConstants.IOS_USER_AGENT,
      'Content-Type': 'application/json',
      'X-Goog-Api-Format-Version': '2'
    };
    const t = randomTParameter();
    const url = `https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false&t=${t}&id=${ctx.videoId}`;

    try {
      const response = await httpClient.postJson(url, payload, headers);
      if (response && response.responseCode === 200) {
        const pr = JSON.parse(response.result as string) as PlayerResponse;
        if (pr?.streamingData) {
          const result: ClientFetchResult = { streamingData: pr.streamingData, cpn: cpn, sourceClient: 'ios', playerResponse: pr };
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
