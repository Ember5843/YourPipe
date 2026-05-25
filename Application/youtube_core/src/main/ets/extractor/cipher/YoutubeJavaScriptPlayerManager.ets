import { YTCoreLogger } from '../../common/YTCoreLogger';
import { PipePipeApiDecoder, PlayerMetadata, SolveResult } from './PipePipeApiDecoder';

const logger = YTCoreLogger.getInstance('YoutubeJavaScriptPlayerManager');

/**
 * Manager for YouTube player signature/throttling deobfuscation.
 * Uses PipePipe remote API only (no JSVM/local fallback).
 * Ported from org.schabi.newpipe.extractor.services.youtube.YoutubeJavaScriptPlayerManager
 */
export class YoutubeJavaScriptPlayerManager {
  /**
   * Batch deobfuscate signatures and throttling parameters via PipePipe API.
   */
  static async deobfuscateBatch(
    sigs: string[],
    nParams: string[]
  ): Promise<SolveResult> {
    const meta = await PipePipeApiDecoder.getLatestPlayer();
    const result = await PipePipeApiDecoder.decodeBatch(meta.playerId, sigs, nParams);
    return result;
  }

  /**
   * Get latest player metadata from PipePipe API.
   */
  static async getLatestPlayer(): Promise<PlayerMetadata> {
    return PipePipeApiDecoder.getLatestPlayer();
  }
}
