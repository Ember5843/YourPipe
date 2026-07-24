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
  /** Consecutive mint timeouts — the wedged ArkWeb-bridge signature. */
  private mintTimeoutStreak: number = 0;
  /** Circuit breaker: while set, getPoToken fails fast instead of re-entering a wedged WebView. */
  private mintBrokenUntilMs: number = 0;
  /** Hard cap for one mint; covers cold BotGuard init (att/get + interpreter + GenerateIT). */
  private static readonly MINT_TIMEOUT_MS: number = 30000;
  private static readonly MINT_BREAKER_MS: number = 30000;
  private static readonly MINT_BREAKER_STREAK: number = 2;

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
    if (Date.now() < this.mintBrokenUntilMs) {
      logger.warn(`mint breaker open video=${info.videoId} remaining=${this.mintBrokenUntilMs - Date.now()}ms`);
      return undefined;
    }
    if (!this.mintPromise) {
      logger.info(`mint start video=${info.videoId} force=${forceRefresh}`);
      this.mintPromise = this.mint(info.visitorData, info.videoId, forceRefresh);
    }
    return await this.awaitMint(this.mintPromise, info.videoId);
  }

  /**
   * Await one mint with a hard cap. A wedged ArkWeb JS bridge must never block
   * SABR playback forever: on timeout the shared mintPromise is discarded so the
   * next caller starts a fresh mint instead of awaiting the poisoned one.
   * Two consecutive timeouts open a short circuit breaker so a dead WebView
   * fails fast (retryable error) instead of re-hanging every pump.
   */
  private async awaitMint(
    promise: Promise<Uint8Array | undefined>,
    videoId: string
  ): Promise<Uint8Array | undefined> {
    let timerId: number = -1;
    try {
      const timeout = new Promise<never>((_resolve, reject) => {
        timerId = setTimeout(() => reject(new Error('mint timeout')),
          SabrWebViewPoTokenProvider.MINT_TIMEOUT_MS);
      });
      const token = await Promise.race([promise, timeout]);
      if (token && token.length > 0) {
        this.cache.set(videoId, { token: token, mintedAtMs: Date.now() });
        this.mintTimeoutStreak = 0;
        this.mintBrokenUntilMs = 0;
        logger.info(`mint success video=${videoId} bytes=${token.length}`);
      }
      return token;
    } catch (e) {
      const isTimeout = (e as Error).message === 'mint timeout';
      if (isTimeout) {
        this.mintTimeoutStreak++;
        if (this.mintTimeoutStreak >= SabrWebViewPoTokenProvider.MINT_BREAKER_STREAK) {
          this.mintBrokenUntilMs = Date.now() + SabrWebViewPoTokenProvider.MINT_BREAKER_MS;
          logger.error(`mint breaker opened streak=${this.mintTimeoutStreak} `
            + `window=${SabrWebViewPoTokenProvider.MINT_BREAKER_MS}ms`);
        }
      }
      logger.error(`mint failed video=${videoId} timeout=${isTimeout} `
        + `streak=${this.mintTimeoutStreak}: ${String(e)}`);
      return undefined;
    } finally {
      clearTimeout(timerId);
      if (this.mintPromise === promise) {
        this.mintPromise = undefined;
      }
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
    let timerId: number = -1;
    let raw: Uint8Array | undefined = undefined;
    try {
      const timeout = new Promise<never>((_resolve, reject) => {
        timerId = setTimeout(() => reject(new Error('mint timeout')),
          SabrWebViewPoTokenProvider.MINT_TIMEOUT_MS);
      });
      raw = await Promise.race([this.mint(visitorData, videoId, false), timeout]);
    } catch (e) {
      logger.warn(`getDashPoToken: mint error video=${videoId}: ${String(e)}`);
      return undefined;
    } finally {
      clearTimeout(timerId);
    }
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
