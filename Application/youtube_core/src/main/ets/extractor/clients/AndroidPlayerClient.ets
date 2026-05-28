import { ClientFetchContext, ClientFetchResult } from './ClientTypes';
import { PlayerResponse } from '../PlayerResponseTypes';
import { ClientsConstants } from '../../model/ClientsConstants';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';

const logger = YTCoreLogger.getInstance('AndroidPlayerClient');

// ---- Android VR payload types ----

interface AndroidVRClientInfo {
  clientName: string;
  clientVersion: string;
  clientScreen: string;
  deviceMake: string;
  deviceModel: string;
  androidSdkVersion: number;
  osName: string;
  osVersion: string;
  hl: string;
  gl: string;
  platform: string;
  visitorData: string | undefined;
  utcOffsetMinutes: number;
}

interface AndroidVRRequestInfo {
  internalExperimentFlags: string[];
  useSsl: boolean;
}

interface AndroidVRUserInfo {
  lockedSafetyMode: boolean;
}

interface AndroidVRContext {
  client: AndroidVRClientInfo;
  request: AndroidVRRequestInfo;
  user: AndroidVRUserInfo;
}

interface AndroidVRPayload {
  context: AndroidVRContext;
  videoId: string;
  cpn: string;
  contentCheckOk: boolean;
  racyCheckOk: boolean;
}

/**
 * Android VR (Oculus Quest 3) InnerTube client — PipePipe 5.1.1
 *
 * Replaces the old Android Mobile client:
 *   - Endpoint: reel/reel_item_watch → player
 *   - Client: ANDROID (21.03.36) → ANDROID_VR (1.65.10)
 *   - Device: generic Android → Oculus Quest 3
 *   - Response: no longer nested inside playerResponse
 */
export class AndroidPlayerClient {
  static async fetch(ctx: ClientFetchContext, httpClient: YouTubeHttpClient): Promise<ClientFetchResult | undefined> {
    const cpn = randomCpn();

    const clientInfo: AndroidVRClientInfo = {
      clientName: ClientsConstants.ANDROID_VR_CLIENT_NAME,
      clientVersion: ClientsConstants.ANDROID_VR_CLIENT_VERSION,
      clientScreen: 'WATCH',
      deviceMake: ClientsConstants.ANDROID_VR_DEVICE_MAKE,
      deviceModel: ClientsConstants.ANDROID_VR_DEVICE_MODEL,
      androidSdkVersion: parseInt(ClientsConstants.ANDROID_VR_SDK_VERSION),
      osName: 'Android',
      osVersion: ClientsConstants.ANDROID_VR_OS_VERSION,
      hl: ctx.hl,
      gl: ctx.gl,
      platform: 'MOBILE',
      visitorData: ctx.visitorData,
      utcOffsetMinutes: 0
    };

    const reqInfo: AndroidVRRequestInfo = { internalExperimentFlags: [], useSsl: true };
    const userInfo: AndroidVRUserInfo = { lockedSafetyMode: false };
    const context: AndroidVRContext = { client: clientInfo, request: reqInfo, user: userInfo };

    const payload: AndroidVRPayload = {
      context: context,
      videoId: ctx.videoId,
      cpn: cpn,
      contentCheckOk: true,
      racyCheckOk: true
    };

    const headers: Record<string, string> = {
      'User-Agent': ClientsConstants.ANDROID_VR_USER_AGENT,
      'Content-Type': 'application/json',
      'X-Goog-Api-Format-Version': '2'
    };

    const t = randomTParameter();
    const url = `https://youtubei.googleapis.com/youtubei/v1/player`
      + `?key=${ClientsConstants.ANDROID_VR_YOUTUBE_KEY}`
      + `&prettyPrint=false`
      + `&t=${t}`
      + `&id=${ctx.videoId}`;

    try {
      const response = await httpClient.postJson(url, payload, headers);
      if (response && response.responseCode === 200) {
        // Android VR response is directly a PlayerResponse — NOT nested
        const pr = JSON.parse(response.result as string) as PlayerResponse;
        if (pr?.streamingData) {
          const result: ClientFetchResult = {
            streamingData: pr.streamingData,
            cpn: cpn,
            sourceClient: 'android_vr',
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

function randomTParameter(): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let result = '';
  for (let i = 0; i < 12; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}
