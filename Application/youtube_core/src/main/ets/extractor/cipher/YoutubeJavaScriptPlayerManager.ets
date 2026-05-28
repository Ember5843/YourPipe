import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { PipePipeApiDecoder, PlayerMetadata, SolveResult } from './PipePipeApiDecoder';

const logger = YTCoreLogger.getInstance('YoutubeJavaScriptPlayerManager');

export class YoutubeJavaScriptPlayerManager {
  /**
   * Player metadata is now extracted locally from ytcfg in YouTubeExtractor.
   * This method is kept for backward compatibility but is a no-op.
   * @deprecated Use PipePipeApiDecoder.setLocalMetadata() instead.
   */
  static async ensurePlayer(_html: string, _client: YouTubeHttpClient): Promise<PlayerMetadata> {
    logger.debug('ensurePlayer: metadata now extracted locally from ytcfg');
    // No-op — metadata is injected via PipePipeApiDecoder.setLocalMetadata() in fetchInnertubePlayer
    return PipePipeApiDecoder.getLatestPlayer();
  }

  static async deobfuscateBatch(
    sigs: string[],
    nParams: string[]
  ): Promise<SolveResult> {
    const meta = await PipePipeApiDecoder.getLatestPlayer();
    const result = await PipePipeApiDecoder.decodeBatch(meta.playerId, sigs, nParams);
    return result;
  }

  static async getLatestPlayer(): Promise<PlayerMetadata> {
    return PipePipeApiDecoder.getLatestPlayer();
  }
}
