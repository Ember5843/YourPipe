import { ClientFetchContext, ClientFetchResult } from './ClientTypes';
import { PlayerResponse } from '../PlayerResponseTypes';
import { ClientsConstants } from '../../model/ClientsConstants';
import { YoutubePlayerClientKey } from '../../model/YoutubePlayerClientConfig';
import { WebClientVersionResolver } from '../../common/WebClientVersionResolver';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { SessionIdentityManager } from '../identity/SessionIdentityManager';

const logger = YTCoreLogger.getInstance('ConfiguredPlayerClient');

/** Hard cap for the player PoToken hook — extraction must never wait on BotGuard. */
const PLAYER_PO_TOKEN_TIMEOUT_MS = 5000;

interface PlayerIdentity {
  key: YoutubePlayerClientKey;
  clientName: string;
  clientVersion: string;
  clientId: string;
  userAgent: string;
  needsVrDeviceFields: boolean;
}

/**
 * PipePipe-style single configured stream player.
 * All clients POST www.youtube.com/youtubei/v1/player with signatureTimestamp.
 */
export class ConfiguredPlayerClient {
  static identity(key: YoutubePlayerClientKey): PlayerIdentity {
    switch (key) {
      case 'android_vr':
        return {
          key: key,
          clientName: ClientsConstants.ANDROID_VR_CLIENT_NAME,
          clientVersion: ClientsConstants.ANDROID_VR_CLIENT_VERSION,
          clientId: ClientsConstants.ANDROID_VR_CLIENT_ID,
          userAgent: ClientsConstants.ANDROID_VR_USER_AGENT,
          needsVrDeviceFields: true
        };
      case 'tv_downgraded':
        return {
          key: key,
          clientName: ClientsConstants.TVHTML5_DOWNGRADED_CLIENT_NAME,
          clientVersion: ClientsConstants.TVHTML5_DOWNGRADED_CLIENT_VERSION,
          clientId: ClientsConstants.TVHTML5_DOWNGRADED_CLIENT_ID,
          userAgent: ClientsConstants.TVHTML5_DOWNGRADED_USER_AGENT,
          needsVrDeviceFields: false
        };
      case 'web_safari':
        return {
          key: key,
          clientName: ClientsConstants.SAFARI_CLIENT_NAME,
          clientVersion: ClientsConstants.SAFARI_CLIENT_VERSION,
          clientId: ClientsConstants.SAFARI_CLIENT_ID,
          userAgent: ClientsConstants.SAFARI_USER_AGENT,
          needsVrDeviceFields: false
        };
      case 'mweb':
      default:
        // PipePipe: mweb body/headers use getClientVersion() (WEB version family).
        // Prefer process cache from WebClientVersionResolver (sw.js / results / hardcoded).
        return {
          key: 'mweb',
          clientName: ClientsConstants.MWEB_CLIENT_NAME,
          clientVersion: WebClientVersionResolver.getCachedOrHardcoded(),
          clientId: ClientsConstants.MWEB_CLIENT_ID,
          userAgent: ClientsConstants.MWEB_USER_AGENT,
          needsVrDeviceFields: false
        };
    }
  }

  /**
   * @param useWebAuth Cookie+SAPISIDHASH for mweb/web_safari only
   * @param useTvAuth  Bearer for tv_downgraded only (SmartTube). Never both.
   */
  static async fetch(
    key: YoutubePlayerClientKey,
    ctx: ClientFetchContext,
    httpClient: YouTubeHttpClient,
    useWebAuth: boolean = false,
    useTvAuth: boolean = false
  ): Promise<ClientFetchResult | undefined> {
    if (!ctx.signatureTimestamp || ctx.signatureTimestamp <= 0) {
      logger.warn(`[${key}] No signatureTimestamp, skipping stream player`);
      return undefined;
    }

    const id = ConfiguredPlayerClient.identity(key);
    const cpn = randomCpn();
    const client: Record<string, Object> = {
      'utcOffsetMinutes': 0,
      'timeZone': 'UTC',
      'hl': ctx.hl,
      'gl': ctx.gl,
      'userAgent': id.userAgent,
      'clientName': id.clientName,
      'clientVersion': id.clientVersion
    };
    if (id.needsVrDeviceFields) {
      client['deviceMake'] = ClientsConstants.ANDROID_VR_DEVICE_MAKE;
      client['deviceModel'] = ClientsConstants.ANDROID_VR_DEVICE_MODEL;
      client['androidSdkVersion'] = parseInt(ClientsConstants.ANDROID_VR_SDK_VERSION, 10);
      client['osName'] = 'Android';
      client['osVersion'] = ClientsConstants.ANDROID_VR_OS_VERSION;
    }
    if (ctx.visitorData && ctx.visitorData.length > 0) {
      client['visitorData'] = ctx.visitorData;
    }

    const playbackContext: Record<string, Object> = {
      'contentPlaybackContext': {
        'html5Preference': 'HTML5_PREF_WANTS',
        'signatureTimestamp': ctx.signatureTimestamp
      } as Record<string, Object>
    };

    const payload: Record<string, Object> = {
      'context': { 'client': client } as Record<string, Object>,
      'playbackContext': playbackContext,
      'cpn': cpn,
      'videoId': ctx.videoId,
      'contentCheckOk': true,
      'racyCheckOk': true
    };

    // Stage 2 identity pass: web-like clients carry the pinned session
    // visitorData and, when the injected hook can mint one fast enough, a
    // visitor-bound player PoToken. tv_downgraded stays token-free
    // (PipePipe 7673caed). A missing/slow/failed hook never blocks extraction.
    if (key === 'mweb' || key === 'web_safari') {
      const identityVisitorData = SessionIdentityManager.current()?.visitorData || '';
      if (identityVisitorData) {
        client['visitorData'] = identityVisitorData;
      }
      let playerPoToken: string | undefined = undefined;
      try {
        playerPoToken = await withTimeoutMs(
          SessionIdentityManager.getPlayerPoToken(id.clientName, id.clientVersion, id.userAgent),
          PLAYER_PO_TOKEN_TIMEOUT_MS);
      } catch (e) {
        logger.warn(`[${key}] player PoToken hook failed: ${String(e)}`);
      }
      if (playerPoToken) {
        payload['serviceIntegrityDimensions'] = {
          'poToken': playerPoToken
        } as Record<string, Object>;
        logger.info(`[${key}] player PoToken applied len=${playerPoToken.length} `
          + `hasVisitorData=${identityVisitorData.length > 0}`);
      } else {
        logger.debug(`[${key}] player PoToken unavailable, sending without integrity dimensions`);
      }
    }

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'User-Agent': id.userAgent,
      'X-YouTube-Client-Name': id.clientId,
      'X-YouTube-Client-Version': id.clientVersion
    };
    if (key === 'tv_downgraded') {
      headers['Origin'] = 'https://www.youtube.com';
      headers['Referer'] = 'https://www.youtube.com/tv';
    }

    // Enforce rail: TV client may only take Bearer; mweb/web only Cookie.
    const webAuth = key === 'tv_downgraded' ? false : useWebAuth;
    const tvAuth = key === 'tv_downgraded' ? useTvAuth : false;

    const url = `${ClientsConstants.YOUTUBEI_V1_URL}player?prettyPrint=false`;
    try {
      const response = await httpClient.postJson(url, payload, headers, webAuth, tvAuth);
      if (!response || response.responseCode !== 200 || !response.result) {
        logger.warn(`[${key}] stream player HTTP ${response?.responseCode} webAuth=${webAuth} tvAuth=${tvAuth}`);
        return undefined;
      }
      const pr = JSON.parse(response.result as string) as PlayerResponse;
      if (!pr) {
        return undefined;
      }
      // PipePipe accepts response even when streamingData is empty/SABR-shaped.
      const result: ClientFetchResult = {
        streamingData: pr.streamingData,
        cpn: cpn,
        sourceClient: key,
        playerResponse: pr
      };
      const sd = pr.streamingData;
      logger.info(`[${key}] status=${pr.playabilityStatus?.status || '(none)'} `
        + `adaptive=${sd?.adaptiveFormats?.length ?? 0} formats=${sd?.formats?.length ?? 0} `
        + `hasServerAbr=${!!sd?.serverAbrStreamingUrl} hasHls=${!!sd?.hlsManifestUrl}`);
      return result;
    } catch (e) {
      logger.warn(`[${key}] fetch failed:`, e);
      return undefined;
    }
  }

  /**
   * Extra MWEB player used only to recover hlsManifestUrl for live (PipePipe fetchMwebHlsManifest).
   */
  static async fetchMwebHlsOnly(
    ctx: ClientFetchContext,
    httpClient: YouTubeHttpClient,
    useWebAuth: boolean = false
  ): Promise<string | undefined> {
    // Live HLS helper stays anonymous by default (PipePipe); Cookie only if caller opts in.
    const result = await ConfiguredPlayerClient.fetch('mweb', ctx, httpClient, useWebAuth, false);
    return result?.streamingData?.hlsManifestUrl;
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

/** Rejects with 'player PoToken timeout' after ms so extraction never stalls. */
function withTimeoutMs<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timerId: number = -1;
  const timeout = new Promise<never>((_resolve, reject) => {
    timerId = setTimeout(() => reject(new Error('player PoToken timeout')), ms);
  });
  return Promise.race([promise, timeout]).finally(() => {
    clearTimeout(timerId);
  });
}
