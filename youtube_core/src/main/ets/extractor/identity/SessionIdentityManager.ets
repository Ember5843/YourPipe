import { YTCoreLogger } from '../../common/YTCoreLogger';
import { SessionIdentity } from './SessionIdentity';

const logger = YTCoreLogger.getInstance('SessionIdentityManager');

/**
 * Player-request PoToken source (stage 2), injected from entry at startup.
 * The minted token is visitor-bound (a session token), not video-bound, and
 * must be fast: extraction cold start never waits for BotGuard init — an
 * unavailable/slow hook returns undefined and the /player request goes out
 * without serviceIntegrityDimensions.
 */
export interface SessionPoTokenHook {
  getPlayerPoToken(
    clientName: string,
    clientVersion: string,
    userAgent: string,
    visitorData: string
  ): Promise<string | undefined>;
}

/**
 * Process-wide owner of the pinned session identity. Pin once per app
 * session; invalidate() drops it so the next pin starts a fresh epoch.
 * Never log the visitorData value itself.
 */
export class SessionIdentityManager {
  private static identity?: SessionIdentity;
  /** Set by invalidate(). The next pin prefers the fresh player-response value
   *  over the prewarmed one so an identity rotation actually lands on a new
   *  visitorData instead of re-pinning the (stale) prewarmed identity. */
  private static invalidatedSinceLastPin: boolean = false;

  static current(): SessionIdentity | undefined {
    return SessionIdentityManager.identity;
  }

  /** True between invalidate() and the next pin — callers should prefer the
   *  player-response visitorData over the prewarmed value for that pin. */
  static wasInvalidatedSinceLastPin(): boolean {
    return SessionIdentityManager.invalidatedSinceLastPin;
  }

  static pin(visitorData: string): SessionIdentity {
    SessionIdentityManager.invalidatedSinceLastPin = false;
    const existing = SessionIdentityManager.identity;
    if (existing && existing.visitorData === visitorData) {
      return existing;
    }
    const identity: SessionIdentity = {
      visitorData: visitorData,
      clientName: '',
      clientVersion: ''
    };
    SessionIdentityManager.identity = identity;
    return identity;
  }

  static invalidate(): void {
    SessionIdentityManager.invalidatedSinceLastPin = true;
    if (SessionIdentityManager.identity) {
      logger.info('[Identity] invalidate session identity');
      SessionIdentityManager.identity = undefined;
    }
  }

  private static playerPoTokenHook?: SessionPoTokenHook;

  static setPlayerPoTokenHook(hook?: SessionPoTokenHook): void {
    SessionIdentityManager.playerPoTokenHook = hook;
  }

  /**
   * Mint a visitor-bound player PoToken via the injected hook against the
   * currently pinned identity. undefined when no hook/identity is available.
   */
  static async getPlayerPoToken(
    clientName: string,
    clientVersion: string,
    userAgent: string
  ): Promise<string | undefined> {
    const hook = SessionIdentityManager.playerPoTokenHook;
    const identity = SessionIdentityManager.identity;
    if (!hook || !identity || !identity.visitorData) {
      return undefined;
    }
    const token = await hook.getPlayerPoToken(
      clientName, clientVersion, userAgent, identity.visitorData);
    if (token) {
      identity.playerPoToken = token;
    }
    return token;
  }
}
