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
   * @param useWebAuth Cookie+SAPISIDHASH — attaches to ANY client when a cookie
   *   credential exists, including tv_downgraded (PipePipe addLoggedInHeaders:
   *   TVHTML5 /player is authed via Cookie+SAPISIDHASH, not OAuth).
   * @param useTvAuth  Bearer for tv_downgraded only (SmartTube OAuth-only fallback).
   */
  static async fetch(
    key: YoutubePlayerClientKey,
    ctx: ClientFetchContext,
    httpClient: YouTubeHttpClient,
    useWebAuth: boolean = false,
    useTvAuth: boolean = false
  ): Promise<ClientFetchResult | undefined> {
    if (key === 'visionos') {
      return ConfiguredPlayerClient.fetchVisionOs(ctx, httpClient, useWebAuth);
    }
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

    // Stage 2 identity pass: non-TV clients carry the pinned session
    // visitorData and, when the injected hook can mint one fast enough, a
    // visitor-bound player PoToken (PipePipe prepareSessionPoTokenPlayerRequest
    // skips only TVHTML5). tv_downgraded stays token-free (PipePipe 7673caed).
    // A missing/slow/failed hook never blocks extraction.
    if (key !== 'tv_downgraded') {
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

    // PipePipe addLoggedInHeaders: Cookie+SAPISIDHASH attaches to any client
    // (TVHTML5 included) when a cookie credential exists. OAuth Bearer stays a
    // TV-only fallback for OAuth-only (cookie-less) sessions; Cookie wins when
    // both rails somehow apply.
    const webAuth = useWebAuth;
    const tvAuth = key === 'tv_downgraded' && !useWebAuth ? useTvAuth : false;

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
   * PipePipe fetchVisionOsJsonPlayer: token-free guest client.
   * POST youtubei.googleapis.com (GAPIS) — body has NO playbackContext /
   * signatureTimestamp and NO serviceIntegrityDimensions; pot is never minted
   * for this client. visitorData is the pinned session value when available
   * (PipePipe fetches one from innertube when absent; we skip that extra RTT
   * and omit the field instead).
   */
  static async fetchVisionOs(
    ctx: ClientFetchContext,
    httpClient: YouTubeHttpClient,
    useWebAuth: boolean = false
  ): Promise<ClientFetchResult | undefined> {
    const cpn = randomCpn();
    const client: Record<string, Object> = {
      'clientName': ClientsConstants.VISIONOS_CLIENT_NAME,
      'clientVersion': ClientsConstants.VISIONOS_CLIENT_VERSION,
      'clientScreen': ClientsConstants.WATCH_CLIENT_SCREEN,
      'platform': ClientsConstants.MOBILE_CLIENT_PLATFORM,
      'deviceMake': ClientsConstants.VISIONOS_DEVICE_MAKE,
      'deviceModel': ClientsConstants.VISIONOS_DEVICE_MODEL,
      'osName': ClientsConstants.VISIONOS_OS_NAME,
      'osVersion': ClientsConstants.VISIONOS_OS_VERSION,
      'hl': ctx.hl,
      'gl': ctx.gl,
      'utcOffsetMinutes': 0
    };
    const visitorData = SessionIdentityManager.current()?.visitorData
      || ctx.visitorData || '';
    if (visitorData.length > 0) {
      client['visitorData'] = visitorData;
    }

    const payload: Record<string, Object> = {
      'context': {
        'client': client,
        'request': {
          'internalExperimentFlags': [] as Object[],
          'useSsl': true
        } as Record<string, Object>,
        'user': {
          'lockedSafetyMode': false
        } as Record<string, Object>
      } as Record<string, Object>,
      'videoId': ctx.videoId,
      'cpn': cpn,
      'contentCheckOk': true,
      'racyCheckOk': true
    };

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'User-Agent': ClientsConstants.visionOsUserAgent(ctx.gl),
      'X-Goog-Api-Format-Version': '2'
    };

    const url = `${ClientsConstants.YOUTUBEI_V1_GAPIS_URL}player?prettyPrint=false`
      + `&t=${randomCpn().substring(0, 12)}&id=${ctx.videoId}`;
    try {
      const response = await httpClient.postJson(url, payload, headers, useWebAuth, false);
      if (!response || response.responseCode !== 200 || !response.result) {
        logger.warn(`[visionos] stream player HTTP ${response?.responseCode} webAuth=${useWebAuth}`);
        return undefined;
      }
      const pr = JSON.parse(response.result as string) as PlayerResponse;
      if (!pr) {
        return undefined;
      }
      const result: ClientFetchResult = {
        streamingData: pr.streamingData,
        cpn: cpn,
        sourceClient: 'visionos',
        playerResponse: pr
      };
      const sd = pr.streamingData;
      logger.info(`[visionos] status=${pr.playabilityStatus?.status || '(none)'} `
        + `adaptive=${sd?.adaptiveFormats?.length ?? 0} formats=${sd?.formats?.length ?? 0} `
        + `hasServerAbr=${!!sd?.serverAbrStreamingUrl} hasHls=${!!sd?.hlsManifestUrl}`);
      return result;
    } catch (e) {
      logger.warn('[visionos] fetch failed:', e);
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
