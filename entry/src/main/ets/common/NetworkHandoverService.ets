import { connection } from '@kit.NetworkKit';
import { LocalMediaProxy, sabrSessionStore } from 'mediaservice';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('NetworkHandover');

/** Coalesce the burst of events a single network switch produces. */
const DEBOUNCE_MS = 2000;

/**
 * Network-handover adaptation (single subscription site, started by
 * EntryAbility).
 *
 * The SDK 26 kit set has no NetworkBoostKit (`netHandover`), so detection
 * uses `connection` default-network events (GET_NETWORK_INFO, already held):
 * - `netAvailable` with a changed NetHandle id → default network switched
 *   (Wi-Fi ↔ cellular, SIM switch);
 * - `netUnavailable` → connectivity lost; the following `netAvailable` (even
 *   with the same id) counts as lost-and-regained.
 *
 * On a detected switch the playback stack's stale in-flight connections are
 * aborted so they fail fast instead of hanging until their timeouts:
 * - `LocalMediaProxy.abortAllUpstreamFetches` — local-proxy upstream fetches
 *   (direct-link DASH path); quiet teardown, MPV's reconnect re-issues them;
 * - `sabrSessionStore.abortAllInFlightPosts` — SABR UMP sessions' in-flight
 *   POST only; sessions stay open and their own catch/retry/backoff paths
 *   take over (no new SABR policy here).
 *
 * Events within DEBOUNCE_MS of the last invalidation are coalesced. Only
 * event/type names are logged — never network details.
 */
export class NetworkHandoverService {
  private static netConn: connection.NetConnection | undefined = undefined;
  /** Last seen default-network id; -1 = not yet observed (first event only seeds it). */
  private static lastNetId: number = -1;
  /** A netUnavailable fired since the last netAvailable. */
  private static lostPending: boolean = false;
  private static lastInvalidatedAt: number = 0;

  static start(): void {
    if (NetworkHandoverService.netConn) {
      return;
    }
    try {
      const conn = connection.createNetConnection();
      conn.on('netAvailable', (handle: connection.NetHandle) => NetworkHandoverService.onNetAvailable(handle));
      conn.on('netUnavailable', () => NetworkHandoverService.onNetUnavailable());
      conn.register((err) => {
        if (err) {
          logger.error(`net connection register failed: ${err.code} ${err.message}`);
          NetworkHandoverService.netConn = undefined;
          return;
        }
        logger.info('network handover listener registered');
      });
      NetworkHandoverService.netConn = conn;
    } catch (e) {
      logger.error(`start failed: ${JSON.stringify(e)}`);
    }
  }

  static stop(): void {
    const conn = NetworkHandoverService.netConn;
    NetworkHandoverService.netConn = undefined;
    if (!conn) {
      return;
    }
    try {
      conn.unregister(() => {
      });
    } catch (e) {
      logger.warn(`unregister failed: ${JSON.stringify(e)}`);
    }
  }

  private static onNetAvailable(handle: connection.NetHandle): void {
    const switched = NetworkHandoverService.lastNetId >= 0 && handle.netId !== NetworkHandoverService.lastNetId;
    const regained = NetworkHandoverService.lostPending;
    NetworkHandoverService.lostPending = false;
    NetworkHandoverService.lastNetId = handle.netId;
    if (switched) {
      NetworkHandoverService.invalidateStaleConnections('default-network-changed');
    } else if (regained) {
      NetworkHandoverService.invalidateStaleConnections('network-regained');
    }
  }

  private static onNetUnavailable(): void {
    NetworkHandoverService.lostPending = true;
    // In-flight connections are already dead — abort them now (fail fast)
    // instead of waiting out the connect/read timeouts.
    NetworkHandoverService.invalidateStaleConnections('network-unavailable');
  }

  private static invalidateStaleConnections(reason: string): void {
    const now = Date.now();
    if (now - NetworkHandoverService.lastInvalidatedAt < DEBOUNCE_MS) {
      logger.debug(`handover event coalesced: ${reason}`);
      return;
    }
    NetworkHandoverService.lastInvalidatedAt = now;
    try {
      const abortedFetches = LocalMediaProxy.abortAllUpstreamFetches(reason);
      const abortedPosts = sabrSessionStore.abortAllInFlightPosts(reason);
      logger.info(`network handover (${reason}): invalidated upstreamFetches=${abortedFetches} sabrPosts=${abortedPosts}`);
    } catch (e) {
      logger.error(`handover invalidation failed (${reason}): ${JSON.stringify(e)}`);
    }
  }
}
