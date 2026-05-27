import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';
import { PipePipeApiDecoder, PlayerMetadata, SolveResult } from './PipePipeApiDecoder';

const logger = YTCoreLogger.getInstance('YoutubeJavaScriptPlayerManager');

export class YoutubeJavaScriptPlayerManager {
  /**
   * PipePipe API 无需预处理 player JS，直接拉取远端已缓存的 player 元数据。
   */
  static async ensurePlayer(_html: string, _client: YouTubeHttpClient): Promise<PlayerMetadata> {
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
