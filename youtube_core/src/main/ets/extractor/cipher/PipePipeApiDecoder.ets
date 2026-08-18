import { http } from '@kit.NetworkKit';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { arrayBufferToString } from '../../common/YoutubeParsingHelper';
import { ApiConfig } from './ApiConfig';
import { HttpDownloader } from '../../network/HttpDownloader';

const logger = YTCoreLogger.getInstance('PipePipeApiDecoder');

export interface PlayerMetadata {
  playerId: string;
  signatureTimestamp: number;
}

export interface SolveResult {
  sig: Record<string, string | null>;
  n: Record<string, string | null>;
}

interface DecodeResponseEntry {
  type: string;
  data: Record<string, string>;
}

interface DecodeResponse {
  type: string;
  responses: DecodeResponseEntry[];
}

interface HttpHeaders {
  'User-Agent': string;
}

export class PipePipeApiDecoder {
  private static readonly TTL_MS = 24 * 60 * 60 * 1000;

  private static readonly REQUEST_HEADERS: HttpHeaders = {
    'User-Agent': 'PipePipe/4.9.0',
  };

  private static cachedMetadata: PlayerMetadata | null = null;
  private static cacheExpiry: number = 0;

  private static sigCache: Map<string, string> = new Map();
  private static nCache: Map<string, string> = new Map();

  /**
   * 是否正在使用本地解密服务
   */
  static isUsingLocalApi(): boolean {
    return ApiConfig.isUsingLocalApi();
  }

  /**
   * Inject locally-extracted player metadata into the cache.
   * Called from YouTubeExtractor after parsing ytcfg from HTML.
   * Subsequent getLatestPlayer() calls will hit this cache instead of the API.
   */
  static setLocalMetadata(meta: PlayerMetadata): void {
    if (!meta.playerId || meta.signatureTimestamp <= 0) {
      logger.warn(`Ignoring incomplete local player metadata: id=${meta.playerId || '(missing)'} sts=${meta.signatureTimestamp || '(missing)'}`);
      return;
    }
    PipePipeApiDecoder.cachedMetadata = meta;
    PipePipeApiDecoder.cacheExpiry = Date.now() + PipePipeApiDecoder.TTL_MS;
    logger.info(`Player metadata set from local extraction: id=${meta.playerId} sts=${meta.signatureTimestamp}`);
  }

  /** Sync read of process cache — no network. */
  static peekCachedMetadata(): PlayerMetadata | null {
    if (PipePipeApiDecoder.cachedMetadata && Date.now() < PipePipeApiDecoder.cacheExpiry) {
      return PipePipeApiDecoder.cachedMetadata;
    }
    return null;
  }

  /** Drop only player metadata so a failed/stale extraction can force refresh once. */
  static invalidatePlayerMetadata(): void {
    PipePipeApiDecoder.cachedMetadata = null;
    PipePipeApiDecoder.cacheExpiry = 0;
    logger.info('Player metadata cache invalidated');
  }

  static async getLatestPlayer(): Promise<PlayerMetadata> {
    const now = Date.now();
    if (PipePipeApiDecoder.cachedMetadata && now < PipePipeApiDecoder.cacheExpiry) {
      logger.debug('Using cached player metadata (local)');
      return PipePipeApiDecoder.cachedMetadata;
    }

    // PipePipe remote fallback when watch-page STS is unavailable.
    const latestUrl = ApiConfig.getLatestPlayerUrl();
    try {
      // Remote is fallback only; keep a tight budget so the happy path
      // (watch HTML STS) is not blocked when the API is slow/unreachable.
      const httpRequest = http.createHttp();
      const latestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: PipePipeApiDecoder.REQUEST_HEADERS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 4000,
        readTimeout: 4000
      };
      HttpDownloader.applyProxyToOptions(latestOptions, latestUrl);
      const response = await httpRequest.request(latestUrl, latestOptions);
      httpRequest.destroy();
      if (response.responseCode !== 200 || !response.result) {
        throw new Error(`latest-player HTTP ${response.responseCode}`);
      }
      const body = arrayBufferToString(response.result as ArrayBuffer);
      const parsed = JSON.parse(body) as Record<string, Object>;
      const playerId = String(parsed['player'] ?? parsed['playerId'] ?? '');
      const signatureTimestamp = Number(parsed['signatureTimestamp'] ?? 0);
      if (!playerId || !signatureTimestamp) {
        throw new Error('latest-player response missing player/signatureTimestamp');
      }
      const meta: PlayerMetadata = {
        playerId: playerId,
        signatureTimestamp: signatureTimestamp
      };
      PipePipeApiDecoder.cachedMetadata = meta;
      PipePipeApiDecoder.cacheExpiry = Date.now() + PipePipeApiDecoder.TTL_MS;
      logger.info(`Player metadata from remote latest-player: id=${meta.playerId} sts=${meta.signatureTimestamp}`);
      return meta;
    } catch (e) {
      logger.warn('getLatestPlayer remote failed:', e);
      throw new Error('Player metadata not available — setLocalMetadata() or latest-player failed');
    }
  }

  static async decodeBatch(
    playerId: string,
    sigs: string[],
    nParams: string[]
  ): Promise<SolveResult> {
    const result: SolveResult = { sig: {}, n: {} };

    if (!playerId.trim()) {
      throw new Error('Cannot decode without a valid playerId');
    }

    if (sigs.length === 0 && nParams.length === 0) {
      return result;
    }

    const uncachedSigs: string[] = [];
    for (const s of sigs) {
      const cached = PipePipeApiDecoder.sigCache.get(`${playerId}:sig:${s}`);
      if (cached !== undefined) {
        result.sig[s] = cached;
      } else {
        uncachedSigs.push(s);
      }
    }
    const uncachedNs: string[] = [];
    for (const n of nParams) {
      const cached = PipePipeApiDecoder.nCache.get(`${playerId}:n:${n}`);
      if (cached !== undefined) {
        result.n[n] = cached;
      } else {
        uncachedNs.push(n);
      }
    }

    if (uncachedSigs.length === 0 && uncachedNs.length === 0) {
      logger.debug('decodeBatch: all results from cache');
      return result;
    }

    const decodeUrl: string = ApiConfig.getDecodeUrl();
    let url: string = decodeUrl + '?player=' + encodeURIComponent(playerId);
    if (uncachedNs.length > 0) {
      url += '&n=' + uncachedNs.map(encodeURIComponent).join(',');
    }
    if (uncachedSigs.length > 0) {
      url += '&sig=' + uncachedSigs.map(encodeURIComponent).join(',');
    }

    const apiMode: string = ApiConfig.isUsingLocalApi() ? 'LOCAL' : 'REMOTE';
    logger.info(`[CipherRoute] route=HTTP mode=${apiMode} endpoint=${decodeUrl} player=${playerId} sig=${uncachedSigs.length} n=${uncachedNs.length}`);

    const httpRequest = http.createHttp();
    try {
      // 本地 API 超时更短，远程 API 保持原值
      const timeout = ApiConfig.isUsingLocalApi() ? 30000 : 15000;
      const decodeOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: PipePipeApiDecoder.REQUEST_HEADERS,
        connectTimeout: timeout,
        readTimeout: timeout,
      };
      HttpDownloader.applyProxyToOptions(decodeOptions, url);
      const response = await httpRequest.request(url, decodeOptions);

      if (response.responseCode !== 200) {
        throw new Error(`decode HTTP ${response.responseCode}`);
      }

      const body = typeof response.result === 'string'
        ? response.result
        : arrayBufferToString(response.result as ArrayBuffer);
      const parsed = JSON.parse(body) as DecodeResponse;

      if (parsed.type !== 'result' || !Array.isArray(parsed.responses)) {
        throw new Error(`Unexpected decode response: ${parsed.type}`);
      }

      let nResponse: DecodeResponseEntry | undefined;
      let sigResponse: DecodeResponseEntry | undefined;

      if (uncachedNs.length > 0 && uncachedSigs.length > 0) {
        nResponse = parsed.responses[0];
        sigResponse = parsed.responses[1];
      } else if (uncachedNs.length > 0) {
        nResponse = parsed.responses[0];
      } else {
        sigResponse = parsed.responses[0];
      }

      if (uncachedNs.length > 0 && (nResponse?.type !== 'result' || !nResponse.data)) {
        throw new Error('Decode response is missing the n result');
      }
      if (nResponse?.data) {
        for (const orig of uncachedNs) {
          const decoded = nResponse.data[orig];
          if (!decoded || decoded === orig) {
            throw new Error(`Decode response returned an invalid n result for ${orig}`);
          }
          PipePipeApiDecoder.nCache.set(`${playerId}:n:${orig}`, decoded);
          result.n[orig] = decoded;
        }
      }

      if (uncachedSigs.length > 0 && (sigResponse?.type !== 'result' || !sigResponse.data)) {
        throw new Error('Decode response is missing the signature result');
      }
      if (sigResponse?.data) {
        for (const orig of uncachedSigs) {
          const decoded = sigResponse.data[orig];
          if (!decoded) {
            throw new Error('Decode response returned an empty signature result');
          }
          PipePipeApiDecoder.sigCache.set(`${playerId}:sig:${orig}`, decoded);
          result.sig[orig] = decoded;
        }
      }

      logger.info(`decodeBatch OK: sig=${Object.keys(result.sig).length} n=${Object.keys(result.n).length}`);
      return result;
    } finally {
      httpRequest.destroy();
    }
  }
}
