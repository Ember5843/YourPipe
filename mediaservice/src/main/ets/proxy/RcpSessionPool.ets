import { rcp } from '@kit.RemoteCommunicationKit';
import Logger from '../utils/Logger';

const TAG = '[LocalProxy][RcpSessionPool]';
/**
 * Pool cap — far below the system-wide 1024-session limit. Overflow evicts
 * (and closes) the least-recently-used entry so even a session-id leak can
 * never exhaust the process budget.
 */
const POOL_CAP = 32;

export interface RcpSessionEntry {
  session: rcp.Session;
  /** Hosts already warmed by a connectOnly pre-connect on this session. */
  warmedHosts: Set<string>;
}

/**
 * Long-lived RCP sessions for the local proxy's YouTube media fetches.
 * RCP keeps a per-session connection pool: a connectOnly pre-connect only
 * pays off when the later range fetches run on the SAME session, so
 * RangeProxy acquires sessions here instead of creating/closing one per
 * range fetch. Keys are `${proxySessionId}|${proxy fingerprint}` — a changed
 * app-proxy config simply lands on a fresh entry.
 * Teardown: LocalProxyServer.wireSessionCancel → closeForSession(sessionId).
 */
class RcpSessionPool {
  private entries: Map<string, RcpSessionEntry> = new Map();

  acquire(key: string, factory: () => rcp.Session): RcpSessionEntry {
    const existing = this.entries.get(key);
    if (existing) {
      // 删后重插刷新插入序，让淘汰近似 LRU
      this.entries.delete(key);
      this.entries.set(key, existing);
      return existing;
    }
    const entry: RcpSessionEntry = { session: factory(), warmedHosts: new Set<string>() };
    this.entries.set(key, entry);
    while (this.entries.size > POOL_CAP) {
      const oldest = this.entries.keys().next();
      if (oldest.done) {
        break;
      }
      const evicted = this.entries.get(oldest.value);
      this.entries.delete(oldest.value);
      if (evicted) {
        try {
          evicted.session.close();
        } catch (_e) {
        }
      }
      Logger.debug(TAG, `evict+close key=${oldest.value} cap=${POOL_CAP}`);
    }
    return entry;
  }

  /** Close + drop every entry owned by a proxy session (`${sessionId}|…` keys). */
  closeForSession(sessionId: string): void {
    if (!sessionId) {
      return;
    }
    const prefix = `${sessionId}|`;
    const keys: string[] = [];
    for (const key of this.entries.keys()) {
      if (key.startsWith(prefix)) {
        keys.push(key);
      }
    }
    for (const key of keys) {
      const entry = this.entries.get(key);
      this.entries.delete(key);
      if (entry) {
        try {
          entry.session.close();
        } catch (_e) {
        }
      }
    }
    if (keys.length > 0) {
      Logger.debug(TAG, `closeForSession: id=${sessionId} closed=${keys.length}`);
    }
  }
}

export const rcpSessionPool = new RcpSessionPool();
