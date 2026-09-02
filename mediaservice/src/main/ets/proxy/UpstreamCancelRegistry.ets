import Logger from '../utils/Logger';

const TAG = '[LocalProxy][CancelRegistry]';

/**
 * One in-flight upstream operation (RCP request / netstack HttpRequest).
 * abort() must be idempotent and never throw; it only signals the transport
 * (rcp cancel / http destroy) — the fetch itself errors out through its normal
 * catch path, where the aborted flag marks it as quiet teardown.
 */
export interface UpstreamAbortHandle {
  aborted: boolean;
  abort: () => void;
}

/**
 * Registry of in-flight upstream fetches performed by RangeProxy on behalf of
 * a proxy session, keyed by loopback connection (one fetch per connection).
 * - Connection teardown (MPV closed the socket / writer went dead) cancels
 *   just that connection's op — Bug 11.
 * - destroySession cancels every op of every connection on the session —
 *   Bug 10 (wired through DashSession.cancel).
 */
class UpstreamCancelRegistry {
  private connHandles: Map<object, Set<UpstreamAbortHandle>> = new Map();
  private connSession: Map<object, string> = new Map();
  private sessionConns: Map<string, Set<object>> = new Map();

  /**
   * Track a new in-flight op. Returns the handle whose `aborted` flag the
   * fetch path checks to suppress retry/error noise after a cancel.
   */
  register(sessionId: string, conn: object, abortFn: () => void): UpstreamAbortHandle {
    const handle: UpstreamAbortHandle = {
      aborted: false,
      abort: () => {
        if (handle.aborted) {
          return;
        }
        handle.aborted = true;
        try {
          abortFn();
        } catch (_e) {
        }
      }
    };
    let handles = this.connHandles.get(conn);
    if (!handles) {
      handles = new Set();
      this.connHandles.set(conn, handles);
    }
    handles.add(handle);
    if (sessionId) {
      this.connSession.set(conn, sessionId);
      let conns = this.sessionConns.get(sessionId);
      if (!conns) {
        conns = new Set();
        this.sessionConns.set(sessionId, conns);
      }
      conns.add(conn);
    }
    return handle;
  }

  /** Untrack a finished op (success or failure). */
  unregister(conn: object, handle: UpstreamAbortHandle): void {
    const handles = this.connHandles.get(conn);
    if (handles) {
      handles.delete(handle);
      if (handles.size === 0) {
        this.connHandles.delete(conn);
        this.dropConnSessionLink(conn);
      }
    }
  }

  /** Abort all in-flight ops of one loopback connection. Returns abort count. */
  cancelConnection(conn: object): number {
    const handles = this.connHandles.get(conn);
    if (!handles || handles.size === 0) {
      return 0;
    }
    let count = 0;
    for (const handle of handles) {
      if (!handle.aborted) {
        handle.abort();
        count++;
      }
    }
    Logger.debug(TAG, `cancelConnection: aborted=${count}`);
    return count;
  }

  /** Abort every in-flight op registered under a session (destroySession). */
  cancelSession(sessionId: string): number {
    const conns = this.sessionConns.get(sessionId);
    if (!conns || conns.size === 0) {
      return 0;
    }
    let count = 0;
    for (const conn of conns) {
      count += this.cancelConnection(conn);
    }
    Logger.debug(TAG, `cancelSession: id=${sessionId} aborted=${count}`);
    return count;
  }

  /**
   * Abort every in-flight op across all sessions (network handover): the
   * default network switched, so every upstream connection is stale and must
   * fail fast instead of hanging until its timeout. Aborted fetches are quiet
   * teardown — the callers re-issue on the new network.
   */
  cancelAll(): number {
    let count = 0;
    for (const conn of this.connHandles.keys()) {
      count += this.cancelConnection(conn);
    }
    Logger.debug(TAG, `cancelAll: aborted=${count}`);
    return count;
  }

  private dropConnSessionLink(conn: object): void {
    const sessionId = this.connSession.get(conn);
    if (sessionId === undefined) {
      return;
    }
    this.connSession.delete(conn);
    const conns = this.sessionConns.get(sessionId);
    if (conns) {
      conns.delete(conn);
      if (conns.size === 0) {
        this.sessionConns.delete(sessionId);
      }
    }
  }
}

export const upstreamCancelRegistry = new UpstreamCancelRegistry();
