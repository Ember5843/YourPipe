import cipher from 'libyourpipe_cipher.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { PipePipeApiDecoder, PlayerMetadata, SolveResult } from './PipePipeApiDecoder';

const logger = YTCoreLogger.getInstance('YoutubeJavaScriptPlayerManager');

interface EjsResponseEntry {
  type: string;
  data: Record<string, string>;
}

interface EjsResult {
  type: string;
  error?: string;
  responses: EjsResponseEntry[];
  preprocessed_player?: string;
}

interface NativePrepareResult {
  prepared: boolean;
  hasN: boolean;
  hasSig: boolean;
}

interface CipherDiskCache {
  version: number;
  playerId: string;
  playerJsUrl: string;
  preprocessedPlayer: string;
  validatedAt: number;
}

export enum LocalCipherState {
  IDLE = 'IDLE',
  PREPARING = 'PREPARING',
  READY = 'READY',
  COOLDOWN = 'COOLDOWN',
  DISABLED = 'DISABLED'
}

export class YoutubeJavaScriptPlayerManager {
  private static readonly MAX_PLAYER_JS_BYTES: number = 8 * 1024 * 1024;
  private static readonly MAX_LOCAL_FAILURES: number = 3;
  private static readonly RETRY_DELAYS_MS: number[] = [5000, 30000];
  private static readonly PREWARM_VIDEO_ID: string = 'jNQXAC9IVRw';
  private static readonly CACHE_VERSION: number = 1;
  private static prepared: Set<string> = new Set();
  private static preparing: Map<string, Promise<boolean>> = new Map();
  private static failedUntil: Map<string, number> = new Map();
  private static states: Map<string, LocalCipherState> = new Map();
  private static failureCounts: Map<string, number> = new Map();
  private static cachePath: string = '';
  private static prewarmPromise: Promise<boolean> | undefined = undefined;

  /**
   * Query system Secure Shield (坚盾守护) via Device Security Kit.
   * When on, JIT is disabled globally and local JSVM cipher is slow/unavailable.
   */
  static isSecureShieldMode(): boolean {
    try {
      return cipher.isSecureShieldMode() === true;
    } catch (e) {
      logger.warn(`[CipherRoute] isSecureShieldMode failed: ${String(e)}`);
      return false;
    }
  }

  static async startAppPrewarm(context: common.UIAbilityContext): Promise<boolean> {
    const client = new YouTubeHttpClient(context);
    await client.initialize();
    return YoutubeJavaScriptPlayerManager.startPrewarm(client, context.cacheDir);
  }

  static startPrewarm(client: YouTubeHttpClient, cacheDir: string): Promise<boolean> {
    if (YoutubeJavaScriptPlayerManager.prewarmPromise) {
      return YoutubeJavaScriptPlayerManager.prewarmPromise;
    }
    YoutubeJavaScriptPlayerManager.cachePath = `${cacheDir}/yourpipe_cipher_player.json`;
    const task = YoutubeJavaScriptPlayerManager.prewarm(client);
    YoutubeJavaScriptPlayerManager.prewarmPromise = task;
    return task;
  }

  private static async prewarm(client: YouTubeHttpClient): Promise<boolean> {
    const startedAt = Date.now();
    try {
      const url = `https://www.youtube.com/watch?v=${YoutubeJavaScriptPlayerManager.PREWARM_VIDEO_ID}`
        + '&bpctr=9999999999&has_verified=1&hl=en';
      const response = await client.get(url, undefined, false);
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        throw new Error(`prewarm watch HTTP ${response.responseCode}`);
      }
      const html = response.result as string;
      const urlMatch = /"PLAYER_JS_URL":"([^"]+)"/.exec(html);
      if (!urlMatch?.[1]) throw new Error('prewarm watch missing PLAYER_JS_URL');
      let playerJsUrl = urlMatch[1].replace(/\\\//g, '/');
      if (playerJsUrl.startsWith('/')) playerJsUrl = 'https://www.youtube.com' + playerJsUrl;
      const idMatch = /\/s\/player\/([^/]+)\//.exec(playerJsUrl);
      if (!idMatch?.[1]) throw new Error('prewarm watch has invalid Player JS URL');
      const playerId = idMatch[1];
      const stsMatch = /"STS"\s*:\s*(\d+)/.exec(html);
      const signatureTimestamp = stsMatch?.[1] ? parseInt(stsMatch[1], 10) : 0;
      if (signatureTimestamp > 0) {
        PipePipeApiDecoder.setLocalMetadata({
          playerId: playerId,
          signatureTimestamp: signatureTimestamp
        });
        logger.info(`[CipherWarmup] stage=metadata player=${playerId} sts=${signatureTimestamp}`);
      }

      const cached = YoutubeJavaScriptPlayerManager.readDiskCache();
      if (cached && cached.playerId === playerId && cached.playerJsUrl === playerJsUrl) {
        const prepared = await cipher.preparePlayer(playerId, cached.preprocessedPlayer) as NativePrepareResult;
        if (!prepared.prepared) throw new Error('native runtime rejected cached Player');
        YoutubeJavaScriptPlayerManager.prepared.add(playerId);
        YoutubeJavaScriptPlayerManager.setReady(playerId, 'disk');
        logger.info(`[CipherWarmup] stage=ready source=DISK player=${playerId} elapsed=${Date.now() - startedAt}ms`);
        return true;
      }
      const result = await YoutubeJavaScriptPlayerManager.prepareLocalPlayer(playerId, playerJsUrl, client);
      logger.info(`[CipherWarmup] stage=ready source=NETWORK player=${playerId} success=${result} elapsed=${Date.now() - startedAt}ms`);
      return result;
    } catch (e) {
      logger.warn(`[CipherWarmup] stage=failed elapsed=${Date.now() - startedAt}ms`, e);
      return false;
    }
  }

  private static readDiskCache(): CipherDiskCache | undefined {
    if (!YoutubeJavaScriptPlayerManager.cachePath) return undefined;
    try {
      const raw = fs.readTextSync(YoutubeJavaScriptPlayerManager.cachePath);
      const cache = JSON.parse(raw) as CipherDiskCache;
      if (cache.version !== YoutubeJavaScriptPlayerManager.CACHE_VERSION
        || !cache.playerId || !cache.preprocessedPlayer) return undefined;
      return cache;
    } catch (_) {
      return undefined;
    }
  }

  private static writeDiskCache(playerId: string, playerJsUrl: string,
    preprocessedPlayer: string): void {
    if (!YoutubeJavaScriptPlayerManager.cachePath) return;
    try {
      const cache: CipherDiskCache = {
        version: YoutubeJavaScriptPlayerManager.CACHE_VERSION,
        playerId: playerId,
        playerJsUrl: playerJsUrl,
        preprocessedPlayer: preprocessedPlayer,
        validatedAt: Date.now()
      };
      const file = fs.openSync(YoutubeJavaScriptPlayerManager.cachePath,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(cache));
      fs.closeSync(file);
    } catch (e) {
      logger.warn(`[CipherWarmup] stage=cache_write_failed player=${playerId}`, e);
    }
  }

  static async clearPersistentCache(): Promise<void> {
    const path = YoutubeJavaScriptPlayerManager.cachePath;
    YoutubeJavaScriptPlayerManager.prepared.clear();
    YoutubeJavaScriptPlayerManager.preparing.clear();
    YoutubeJavaScriptPlayerManager.failedUntil.clear();
    YoutubeJavaScriptPlayerManager.states.clear();
    YoutubeJavaScriptPlayerManager.failureCounts.clear();
    YoutubeJavaScriptPlayerManager.prewarmPromise = undefined;
    try {
      if (path && fs.accessSync(path)) fs.unlinkSync(path);
    } catch (e) {
      logger.warn('[CipherWarmup] stage=cache_clear_failed', e);
    }
    try {
      await cipher.shutdown();
      logger.info('[CipherWarmup] stage=cache_cleared');
    } catch (e) {
      logger.warn('[CipherWarmup] stage=runtime_shutdown_failed', e);
    }
  }

  static async ensurePlayer(html: string, _client: YouTubeHttpClient): Promise<PlayerMetadata> {
    // Local HTML extraction is the fast path; remote PipePipe is fallback.
    const match = /"STS"\s*:\s*(\d+)/.exec(html);
    if (match?.[1]) {
      const sts = parseInt(match[1], 10);
      if (sts > 0) {
        const urlMatch = /"PLAYER_JS_URL"\s*:\s*"([^"]+)"/.exec(html);
        const playerId = urlMatch?.[1]
          ? /\/s\/player\/([^/]+)\//.exec(urlMatch[1].replace(/\\\//g, '/'))?.[1]
          : undefined;
        const meta: PlayerMetadata = {
          playerId: playerId || '',
          signatureTimestamp: sts,
        };
        if (playerId) PipePipeApiDecoder.setLocalMetadata(meta);
        return meta;
      }
    }
    return PipePipeApiDecoder.getLatestPlayer();
  }

  static getLocalState(playerId: string): LocalCipherState {
    return YoutubeJavaScriptPlayerManager.states.get(playerId) ?? LocalCipherState.IDLE;
  }

  private static setReady(playerId: string, source: string): void {
    YoutubeJavaScriptPlayerManager.states.set(playerId, LocalCipherState.READY);
    YoutubeJavaScriptPlayerManager.failedUntil.delete(playerId);
    logger.info(`[CipherState] player=${playerId} state=READY source=${source}`);
  }

  private static markFailure(playerId: string, stage: string): void {
    const failures = (YoutubeJavaScriptPlayerManager.failureCounts.get(playerId) ?? 0) + 1;
    YoutubeJavaScriptPlayerManager.failureCounts.set(playerId, failures);
    YoutubeJavaScriptPlayerManager.prepared.delete(playerId);
    if (failures >= YoutubeJavaScriptPlayerManager.MAX_LOCAL_FAILURES) {
      YoutubeJavaScriptPlayerManager.states.set(playerId, LocalCipherState.DISABLED);
      YoutubeJavaScriptPlayerManager.failedUntil.delete(playerId);
      logger.warn(`[CipherState] player=${playerId} state=DISABLED failures=${failures} stage=${stage} route=REMOTE`);
      return;
    }
    const delay = YoutubeJavaScriptPlayerManager.RETRY_DELAYS_MS[failures - 1];
    YoutubeJavaScriptPlayerManager.states.set(playerId, LocalCipherState.COOLDOWN);
    YoutubeJavaScriptPlayerManager.failedUntil.set(playerId, Date.now() + delay);
    logger.warn(`[CipherState] player=${playerId} state=COOLDOWN failures=${failures} retryInMs=${delay} stage=${stage} route=REMOTE`);
  }

  static async prepareLocalPlayer(playerId: string, playerJsUrl: string,
    client: YouTubeHttpClient): Promise<boolean> {
    const state = YoutubeJavaScriptPlayerManager.getLocalState(playerId);
    if (state === LocalCipherState.READY && YoutubeJavaScriptPlayerManager.prepared.has(playerId)) return true;
    if (state === LocalCipherState.DISABLED) return false;
    if (state === LocalCipherState.COOLDOWN
      && (YoutubeJavaScriptPlayerManager.failedUntil.get(playerId) || 0) > Date.now()) return false;
    const existing = YoutubeJavaScriptPlayerManager.preparing.get(playerId);
    if (existing) return existing;
    YoutubeJavaScriptPlayerManager.states.set(playerId, LocalCipherState.PREPARING);
    logger.info(`[CipherState] player=${playerId} state=PREPARING attempt=${(YoutubeJavaScriptPlayerManager.failureCounts.get(playerId) ?? 0) + 1}`);
    const task = YoutubeJavaScriptPlayerManager.prepareLocalPlayerInner(playerId, playerJsUrl, client);
    YoutubeJavaScriptPlayerManager.preparing.set(playerId, task);
    try { return await task; }
    finally { YoutubeJavaScriptPlayerManager.preparing.delete(playerId); }
  }

  private static async prepareLocalPlayerInner(playerId: string, playerJsUrl: string,
    client: YouTubeHttpClient): Promise<boolean> {
    const startedAt = Date.now();
    try {
      const expected = new RegExp('^https://(?:www\\.)?youtube\\.com/s/player/' + playerId
        + '/[^?#]+/base\\.js$');
      if (!expected.test(playerJsUrl)) throw new Error('Rejected untrusted Player JS URL');
      const response = await client.get(playerJsUrl, {
        'Accept': 'text/javascript,application/javascript;q=0.9,*/*;q=0.1',
        'Referer': 'https://www.youtube.com/'
      });
      if (response.responseCode !== 200 || typeof response.result !== 'string') {
        throw new Error(`Player JS HTTP ${response.responseCode}`);
      }
      const playerJs = response.result as string;
      if (playerJs.length < 1000 || playerJs.length > YoutubeJavaScriptPlayerManager.MAX_PLAYER_JS_BYTES) {
        throw new Error(`Invalid Player JS size=${playerJs.length}`);
      }
      const preprocessRaw: string = await cipher.preprocessPlayer(playerJs);
      const preprocessResult = JSON.parse(preprocessRaw) as EjsResult;
      if (preprocessResult.type !== 'result' || !preprocessResult.preprocessed_player) {
        throw new Error(`EJS preprocessing failed: ${preprocessResult.error || preprocessResult.type}`);
      }
      const prepared: NativePrepareResult = await cipher.preparePlayer(
        playerId, preprocessResult.preprocessed_player);
      if (!prepared.prepared) throw new Error('Native JSVM rejected Player scripts');
      YoutubeJavaScriptPlayerManager.prepared.add(playerId);
      YoutubeJavaScriptPlayerManager.setReady(playerId, 'network');
      YoutubeJavaScriptPlayerManager.writeDiskCache(
        playerId, playerJsUrl, preprocessResult.preprocessed_player);
      logger.info(`[CipherRoute] route=LOCAL_JSVM stage=prepare player=${playerId} hasN=${prepared.hasN} hasSig=${prepared.hasSig} elapsed=${Date.now() - startedAt}ms`);
      return true;
    } catch (e) {
      YoutubeJavaScriptPlayerManager.markFailure(playerId, 'prepare');
      logger.warn(`[CipherRoute] route=LOCAL_JSVM stage=prepare_failed player=${playerId} elapsed=${Date.now() - startedAt}ms`, e);
      return false;
    }
  }

  static async deobfuscateBatch(sigs: string[], nParams: string[], playerId?: string): Promise<SolveResult> {
    const resolvedPlayerId = playerId
      || (PipePipeApiDecoder.peekCachedMetadata()?.playerId)
      || (await PipePipeApiDecoder.getLatestPlayer()).playerId;
    const localState = YoutubeJavaScriptPlayerManager.getLocalState(resolvedPlayerId);
    if (localState === LocalCipherState.READY
      && YoutubeJavaScriptPlayerManager.prepared.has(resolvedPlayerId)) {
      const startedAt = Date.now();
      try {
        const raw: string = await cipher.decodeBatch(resolvedPlayerId, sigs, nParams);
        const parsed = JSON.parse(raw) as EjsResult;
        if (parsed.type !== 'result' || !Array.isArray(parsed.responses)) {
          throw new Error(`EJS decode failed: ${parsed.error || parsed.type}`);
        }
        const result: SolveResult = { sig: {}, n: {} };
        let responseIndex = 0;
        const nResponse = nParams.length > 0 ? parsed.responses[responseIndex++] : undefined;
        const sigResponse = sigs.length > 0 ? parsed.responses[responseIndex] : undefined;
        const expectedResponses = (nParams.length > 0 ? 1 : 0) + (sigs.length > 0 ? 1 : 0);
        if (parsed.responses.length !== expectedResponses
          || (nResponse && nResponse.type !== 'result')
          || (sigResponse && sigResponse.type !== 'result')) {
          throw new Error('Local cipher response type/order mismatch');
        }
        for (const n of nParams) {
          const decoded = nResponse?.data[n];
          if (!decoded || decoded === n) throw new Error('Invalid local n result');
          result.n[n] = decoded;
        }
        for (const sig of sigs) {
          const decoded = sigResponse?.data[sig];
          if (!decoded) throw new Error('Invalid local sig result');
          result.sig[sig] = decoded;
        }
        YoutubeJavaScriptPlayerManager.failureCounts.delete(resolvedPlayerId);
        logger.info(`[CipherRoute] route=LOCAL_JSVM stage=decode player=${resolvedPlayerId} sig=${sigs.length} n=${nParams.length} elapsed=${Date.now() - startedAt}ms`);
        return result;
      } catch (e) {
        YoutubeJavaScriptPlayerManager.markFailure(resolvedPlayerId, 'decode');
        cipher.evictPlayer(resolvedPlayerId).catch(() => {});
        logger.warn(`[CipherRoute] route=LOCAL_JSVM stage=decode_failed player=${resolvedPlayerId} fallback=REMOTE`, e);
      }
    } else {
      logger.info(`[CipherRoute] route=REMOTE reason=local_not_ready player=${resolvedPlayerId} state=${localState}`);
    }
    return PipePipeApiDecoder.decodeBatch(resolvedPlayerId, sigs, nParams);
  }

  static async getLatestPlayer(): Promise<PlayerMetadata> {
    const cached = PipePipeApiDecoder.peekCachedMetadata();
    if (cached) return cached;
    return PipePipeApiDecoder.getLatestPlayer();
  }
}
