import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { CipherSolverApiDecoder, PlayerMetadata, SolveResult } from './CipherSolverApiDecoder';

const logger = YTCoreLogger.getInstance('YoutubeJavaScriptPlayerManager');

/**
 * Manager for YouTube player signature/throttling deobfuscation.
 * Backed by the AGC cloud function `cipher-solver` (trigger `test1`).
 *
 * 调用顺序约束:必须先在 fetchWatchPage 之后调用 ensurePlayer(html, client),
 * 才能调用 getLatestPlayer / deobfuscateBatch。
 */
export class YoutubeJavaScriptPlayerManager {
  static async ensurePlayer(html: string, client: YouTubeHttpClient): Promise<PlayerMetadata> {
    return CipherSolverApiDecoder.ensurePlayer(html, client);
  }

  static async deobfuscateBatch(sigs: string[], nParams: string[]): Promise<SolveResult> {
    const meta = await CipherSolverApiDecoder.getLatestPlayer();
    return CipherSolverApiDecoder.decodeBatch(meta.playerId, sigs, nParams);
  }

  static async getLatestPlayer(): Promise<PlayerMetadata> {
    return CipherSolverApiDecoder.getLatestPlayer();
  }

  static clearCaches(): void {
    CipherSolverApiDecoder.clearCaches();
  }
}
