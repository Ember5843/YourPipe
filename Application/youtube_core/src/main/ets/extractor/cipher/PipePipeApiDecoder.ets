import { http } from '@kit.NetworkKit';
import { YTCoreLogger } from '../../common/YTCoreLogger';

const logger = YTCoreLogger.getInstance('PipePipeApiDecoder');

function arrayBufferToString(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let result = '';
  for (let i = 0; i < bytes.length; i++) {
    result += String.fromCharCode(bytes[i]);
  }
  return result;
}

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
  private static readonly DECODE_URL = 'https://api.pipepipe.dev/decoder/decode';
  private static readonly TTL_MS = 24 * 60 * 60 * 1000;

  private static readonly REQUEST_HEADERS: HttpHeaders = {
    'User-Agent': 'PipePipe/4.9.0',
  };

  private static cachedMetadata: PlayerMetadata | null = null;
  private static cacheExpiry: number = 0;

  private static sigCache: Map<string, string> = new Map();
  private static nCache: Map<string, string> = new Map();

  /**
   * Inject locally-extracted player metadata into the cache.
   * Called from YouTubeExtractor after parsing ytcfg from HTML.
   * Subsequent getLatestPlayer() calls will hit this cache instead of the API.
   */
  static setLocalMetadata(meta: PlayerMetadata): void {
    PipePipeApiDecoder.cachedMetadata = meta;
    PipePipeApiDecoder.cacheExpiry = Date.now() + PipePipeApiDecoder.TTL_MS;
    logger.info(`Player metadata set from local extraction: id=${meta.playerId} sts=${meta.signatureTimestamp}`);
  }

  static async getLatestPlayer(): Promise<PlayerMetadata> {
    const now = Date.now();
    if (PipePipeApiDecoder.cachedMetadata && now < PipePipeApiDecoder.cacheExpiry) {
      logger.debug('Using cached player metadata (local)');
      return PipePipeApiDecoder.cachedMetadata;
    }
    throw new Error('Player metadata not available — setLocalMetadata() must be called first');
  }

  static async decodeBatch(
    playerId: string,
    sigs: string[],
    nParams: string[]
  ): Promise<SolveResult> {
    const result: SolveResult = { sig: {}, n: {} };

    if (sigs.length === 0 && nParams.length === 0) {
      return result;
    }

    const uncachedSigs: string[] = [];
    for (const s of sigs) {
      const cached = PipePipeApiDecoder.sigCache.get(s);
      if (cached !== undefined) {
        result.sig[s] = cached;
      } else {
        uncachedSigs.push(s);
      }
    }
    const uncachedNs: string[] = [];
    for (const n of nParams) {
      const cached = PipePipeApiDecoder.nCache.get(n);
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

    let url = `${PipePipeApiDecoder.DECODE_URL}?player=${encodeURIComponent(playerId)}`;
    if (uncachedNs.length > 0) {
      url += `&n=${uncachedNs.map(encodeURIComponent).join(',')}`;
    }
    if (uncachedSigs.length > 0) {
      url += `&sig=${uncachedSigs.map(encodeURIComponent).join(',')}`;
    }

    logger.info(`decodeBatch: sigs=${uncachedSigs.length}/${sigs.length} n=${uncachedNs.length}/${nParams.length}`);

    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: PipePipeApiDecoder.REQUEST_HEADERS,
        connectTimeout: 15000,
        readTimeout: 15000,
      });

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

      if (nResponse?.type === 'result' && nResponse.data) {
        for (const orig of uncachedNs) {
          const decoded = nResponse.data[orig];
          if (decoded !== undefined) {
            PipePipeApiDecoder.nCache.set(orig, decoded);
            result.n[orig] = decoded;
          } else {
            result.n[orig] = null;
          }
        }
      }

      if (sigResponse?.type === 'result' && sigResponse.data) {
        for (const orig of uncachedSigs) {
          const decoded = sigResponse.data[orig];
          if (decoded !== undefined) {
            PipePipeApiDecoder.sigCache.set(orig, decoded);
            result.sig[orig] = decoded;
          } else {
            result.sig[orig] = null;
          }
        }
      }

      logger.info(`decodeBatch OK: sig=${Object.keys(result.sig).length} n=${Object.keys(result.n).length}`);
      return result;
    } finally {
      httpRequest.destroy();
    }
  }
}
