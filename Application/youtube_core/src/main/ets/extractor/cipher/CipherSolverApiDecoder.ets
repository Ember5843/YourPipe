import { cloudFunction } from '@kit.CloudFoundationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { PlayerJsExtractor } from './PlayerJsExtractor';

const logger = YTCoreLogger.getInstance('CipherSolverApiDecoder');

export interface PlayerMetadata {
  playerId: string;
  signatureTimestamp: number;
}

export interface SolveResult {
  sig: Record<string, string | null>;
  n: Record<string, string | null>;
}

class CachedPlayer {
  jsUrl: string = '';
  playerId: string = '';
  playerHash: string = '';
  signatureTimestamp: number = 0;
  playerJs: string = '';
  expiresAt: number = 0;
}

class ChallengeMap {
  sig?: string[];
  n?: string[];
}

class CloudSolveRequest {
  playerHash: string = '';
  playerJs?: string;
  challenges: ChallengeMap = new ChallengeMap();
}

class CloudSolveResponse {
  status: string = 'error';
  sig?: Record<string, string | null>;
  n?: Record<string, string | null>;
  playerHash?: string;
  error?: string;
}

const FN_NAME = 'test1';
const FN_VERSION = '$latest';
const FN_TIMEOUT_MS = 30 * 1000;
const PLAYER_TTL_MS = 24 * 60 * 60 * 1000;

// 本地调试用,生产部署后改为 undefined 走线上
const LOCAL_URL: string | undefined = 'http://localhost:18090';

export class CipherSolverApiDecoder {
  private static cachedPlayer: CachedPlayer | null = null;
  private static sigCache: Map<string, string> = new Map<string, string>();
  private static nCache: Map<string, string> = new Map<string, string>();

  /**
   * 在 fetchWatchPage 之后调用一次,准备 player.js 与 signatureTimestamp。
   * 后续 getLatestPlayer / decodeBatch 都依赖这里写入的 cachedPlayer。
   */
  static async ensurePlayer(html: string, client: YouTubeHttpClient): Promise<PlayerMetadata> {
    let jsUrl: string | null = PlayerJsExtractor.extractPlayerJsUrl(html);
    if (!jsUrl) {
      logger.warn('player.js URL not found in watch page, falling back to iframe_api');
      jsUrl = await PlayerJsExtractor.fetchPlayerJsUrlFromIframeApi(client);
    }
    if (!jsUrl) {
      throw new Error('Cannot resolve player.js URL');
    }

    const now = Date.now();
    const cached = CipherSolverApiDecoder.cachedPlayer;
    if (cached && cached.jsUrl === jsUrl && now < cached.expiresAt) {
      logger.debug(`Using cached player ${cached.playerId}`);
      const meta: PlayerMetadata = { playerId: cached.playerId, signatureTimestamp: cached.signatureTimestamp };
      return meta;
    }

    const playerId = PlayerJsExtractor.extractPlayerId(jsUrl) ?? '';
    const playerJs = await PlayerJsExtractor.fetchPlayerJs(jsUrl, client);
    const playerHash = await PlayerJsExtractor.computePlayerHash(playerJs);
    const sts = PlayerJsExtractor.extractSignatureTimestamp(playerJs);
    if (sts === null) {
      throw new Error('signatureTimestamp not found in player.js');
    }

    const next = new CachedPlayer();
    next.jsUrl = jsUrl;
    next.playerId = playerId;
    next.playerHash = playerHash;
    next.signatureTimestamp = sts;
    next.playerJs = playerJs;
    next.expiresAt = now + PLAYER_TTL_MS;
    CipherSolverApiDecoder.cachedPlayer = next;
    // playerId 变化时清空 sig/n 缓存,避免错配
    CipherSolverApiDecoder.sigCache.clear();
    CipherSolverApiDecoder.nCache.clear();

    logger.info(`Player ready: id=${playerId} hash=${playerHash.substring(0, 8)} sts=${sts}`);
    const meta: PlayerMetadata = { playerId, signatureTimestamp: sts };
    return meta;
  }

  static async getLatestPlayer(): Promise<PlayerMetadata> {
    const cached = CipherSolverApiDecoder.cachedPlayer;
    if (!cached) {
      throw new Error('Player not initialized; call ensurePlayer(html) first');
    }
    const meta: PlayerMetadata = { playerId: cached.playerId, signatureTimestamp: cached.signatureTimestamp };
    return meta;
  }

  static async decodeBatch(
    _playerId: string,
    sigs: string[],
    nParams: string[]
  ): Promise<SolveResult> {
    const result: SolveResult = { sig: {}, n: {} };
    if (sigs.length === 0 && nParams.length === 0) {
      return result;
    }

    const cached = CipherSolverApiDecoder.cachedPlayer;
    if (!cached) {
      throw new Error('Player not initialized; call ensurePlayer(html) first');
    }

    const uncachedSigs: string[] = [];
    for (const s of sigs) {
      const hit = CipherSolverApiDecoder.sigCache.get(s);
      if (hit !== undefined) {
        result.sig[s] = hit;
      } else {
        uncachedSigs.push(s);
      }
    }
    const uncachedNs: string[] = [];
    for (const n of nParams) {
      const hit = CipherSolverApiDecoder.nCache.get(n);
      if (hit !== undefined) {
        result.n[n] = hit;
      } else {
        uncachedNs.push(n);
      }
    }
    if (uncachedSigs.length === 0 && uncachedNs.length === 0) {
      logger.debug('decodeBatch: all results from local cache');
      return result;
    }

    logger.info(`decodeBatch: sigs=${uncachedSigs.length}/${sigs.length} n=${uncachedNs.length}/${nParams.length}`);

    const challenges = new ChallengeMap();
    if (uncachedSigs.length > 0) challenges.sig = uncachedSigs;
    if (uncachedNs.length > 0) challenges.n = uncachedNs;

    const baseRequest = new CloudSolveRequest();
    baseRequest.playerHash = cached.playerHash;
    baseRequest.challenges = challenges;

    let response = await CipherSolverApiDecoder.callSolver(baseRequest);
    if (response.status === 'need_player') {
      logger.info('Cloud cache miss, sending player.js');
      const withJs = new CloudSolveRequest();
      withJs.playerHash = cached.playerHash;
      withJs.playerJs = cached.playerJs;
      withJs.challenges = challenges;
      response = await CipherSolverApiDecoder.callSolver(withJs);
    }

    if (response.status === 'error') {
      throw new Error(`cipher-solver: ${response.error ?? 'unknown error'}`);
    }
    if (response.status !== 'ok') {
      throw new Error(`cipher-solver: unexpected status ${response.status}`);
    }

    if (response.sig) {
      for (const s of uncachedSigs) {
        const decoded = response.sig[s] ?? null;
        if (decoded !== null) {
          CipherSolverApiDecoder.sigCache.set(s, decoded);
        }
        result.sig[s] = decoded;
      }
    } else {
      for (const s of uncachedSigs) result.sig[s] = null;
    }
    if (response.n) {
      for (const n of uncachedNs) {
        const decoded = response.n[n] ?? null;
        if (decoded !== null) {
          CipherSolverApiDecoder.nCache.set(n, decoded);
        }
        result.n[n] = decoded;
      }
    } else {
      for (const n of uncachedNs) result.n[n] = null;
    }

    logger.info(`decodeBatch OK: sig=${Object.keys(result.sig).length} n=${Object.keys(result.n).length}`);
    return result;
  }

  private static async callSolver(req: CloudSolveRequest): Promise<CloudSolveResponse> {
    const params: cloudFunction.FunctionParams = {
      name: FN_NAME,
      version: FN_VERSION,
      timeout: FN_TIMEOUT_MS,
      data: req as Object,
    };
    if (LOCAL_URL) {
      params.localUrl = LOCAL_URL;
    }
    try {
      const value: cloudFunction.FunctionResult = await cloudFunction.call(params);
      return CipherSolverApiDecoder.parseResult(value.result);
    } catch (err) {
      const e = err as BusinessError;
      throw new Error(`cipher-solver call failed (code=${e.code}): ${e.message}`);
    }
  }

  private static parseResult(raw: string | Object): CloudSolveResponse {
    let obj: Object;
    if (typeof raw === 'string') {
      try {
        obj = JSON.parse(raw) as Object;
      } catch (e) {
        throw new Error(`cipher-solver: invalid JSON response: ${(e as Error).message}`);
      }
    } else if (raw) {
      obj = raw;
    } else {
      throw new Error('cipher-solver: empty response');
    }
    return obj as CloudSolveResponse;
  }

  static clearCaches(): void {
    CipherSolverApiDecoder.cachedPlayer = null;
    CipherSolverApiDecoder.sigCache.clear();
    CipherSolverApiDecoder.nCache.clear();
  }
}
