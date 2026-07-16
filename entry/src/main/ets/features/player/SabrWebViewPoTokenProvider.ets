import type { SabrPoTokenProvider, YoutubeSabrInfo, YoutubeSabrStreamState } from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { poTokenBytesToString } from './SabrLocalDomPoTokenGenerator';

const logger = AppLog.getInstance('SabrLocalDomProvider');

interface CachedPoToken {
  token: Uint8Array;
  mintedAtMs: number;
}

interface CachedDashPoToken {
  /** base64url-encoded string for pot= URL param */
  tokenStr: string;
  mintedAtMs: number;
}

export type LocalDomMintFn = (
  visitorData: string,
  videoId: string,
  forceRefresh: boolean
) => Promise<Uint8Array | undefined>;

export class SabrWebViewPoTokenProvider implements SabrPoTokenProvider {
  private static instance: SabrWebViewPoTokenProvider = new SabrWebViewPoTokenProvider();
  private cache: Map<string, CachedPoToken> = new Map();
  private dashCache: Map<string, CachedDashPoToken> = new Map();
  private mint?: LocalDomMintFn;
  private mintPromise?: Promise<Uint8Array | undefined>;

  static getInstance(): SabrWebViewPoTokenProvider {
    return SabrWebViewPoTokenProvider.instance;
  }

  setMinter(mint?: LocalDomMintFn): void {
    this.mint = mint;
  }

  async getPoToken(
    info: YoutubeSabrInfo,
    _streamState: YoutubeSabrStreamState,
    forceRefresh: boolean
  ): Promise<Uint8Array | undefined> {
    if (!info.visitorData) {
      logger.warn(`missing visitorData video=${info.videoId}`);
      return undefined;
    }
    if (forceRefresh) {
      this.cache.delete(info.videoId);
    }
    const cached = this.cache.get(info.videoId);
    if (cached && Date.now() - cached.mintedAtMs < 6 * 60 * 60 * 1000) {
      return cached.token;
    }
    if (!this.mint) {
      logger.warn('Local DOM ArkWeb is not attached');
      return undefined;
    }
    if (this.mintPromise) {
      return await this.mintPromise;
    }
    logger.info(`mint start video=${info.videoId} force=${forceRefresh}`);
    this.mintPromise = this.mint(info.visitorData, info.videoId, forceRefresh);
    try {
      const token = await this.mintPromise;
      if (token && token.length > 0) {
        this.cache.set(info.videoId, { token: token, mintedAtMs: Date.now() });
        logger.info(`mint success video=${info.videoId} bytes=${token.length}`);
      }
      return token;
    } catch (e) {
      logger.error(`mint failed video=${info.videoId}: ${String(e)}`);
      return undefined;
    } finally {
      this.mintPromise = undefined;
    }
  }

  /**
   * Get a base64url-encoded PoToken for DASH segment URL injection (pot=).
   * DASH URLs are short-lived so keep TTL at 5 min.
   */
  async getDashPoToken(visitorData: string, videoId: string): Promise<string | undefined> {
    if (!visitorData) {
      logger.warn(`getDashPoToken: missing visitorData video=${videoId}`);
      return undefined;
    }
    const cached = this.dashCache.get(videoId);
    if (cached && Date.now() - cached.mintedAtMs < 5 * 60 * 1000) {
      return cached.tokenStr;
    }
    if (!this.mint) {
      logger.warn('getDashPoToken: Local DOM ArkWeb is not attached');
      return undefined;
    }
    logger.info(`getDashPoToken: mint start video=${videoId}`);
    const raw = await this.mint(visitorData, videoId, false);
    if (!raw || raw.length === 0) {
      logger.warn(`getDashPoToken: mint returned empty video=${videoId}`);
      return undefined;
    }
    const tokenStr = poTokenBytesToString(raw);
    this.dashCache.set(videoId, { tokenStr, mintedAtMs: Date.now() });
    logger.info(`getDashPoToken: success video=${videoId} len=${tokenStr.length}`);
    return tokenStr;
  }
}
