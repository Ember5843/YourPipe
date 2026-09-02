import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { YTCoreLogger } from '../common/YTCoreLogger';

const logger = YTCoreLogger.getInstance('Socks5Bridge');
const TAG = '[Socks5Bridge]';

interface Socks5Target {
  host: string;
  port: number;
  isDomain: boolean;
}

interface Socks5Config {
  host: string;
  port: number;
  username: string;
  password: string;
}

const CRLF: string = '\r\n';
/** Idle cap per accepted connection: a client that never completes an HTTP
 *  request head must not hold the connection (and its fd) forever. */
const IDLE_HEAD_TIMEOUT_MS: number = 30000;

function encodeText(s: string): ArrayBuffer {
  return new util.TextEncoder().encode(s).buffer as ArrayBuffer;
}

/** Best-effort structured error description (netstack throws BusinessError objects). */
function describeErr(e: Object): string {
  const rec = e as Record<string, Object>;
  if (rec && typeof rec === 'object') {
    const code = rec['code'];
    const message = rec['message'];
    if (code !== undefined) {
      return `code=${String(code)} msg=${String(message)}`;
    }
  }
  return String(e);
}

/** Numeric BusinessError code, or 0 when the error carries none. */
function errorCodeOf(e: Object): number {
  const rec = e as Record<string, Object>;
  if (rec && typeof rec === 'object') {
    const code = rec['code'];
    if (typeof code === 'number') {
      return code;
    }
  }
  return 0;
}

/**
 * SOCKS5 authentication errors (2301207 invalid username/password,
 * 2301209 negotiated auth failure): retrying is pointless — the credentials
 * will fail again.
 */
function isSocks5AuthError(e: Object): boolean {
  const code = errorCodeOf(e);
  return code === 2301207 || code === 2301209;
}

/** NetAddress.family: 1=IPv4, 2=IPv6, 3=Domain (API 18+). */
function familyForHost(host: string): number {
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) {
    return 1;
  }
  if (host.indexOf(':') >= 0) {
    return 2;
  }
  return 3;
}

/** Parse `host:port` / `[v6]:port` CONNECT authority. */
function parseAuthority(authority: string): Socks5Target | undefined {
  const s = (authority || '').trim();
  if (!s) {
    return undefined;
  }
  let host = '';
  let portText = '';
  if (s.startsWith('[')) {
    const close = s.indexOf(']');
    if (close < 0) {
      return undefined;
    }
    host = s.substring(1, close);
    portText = s.substring(close + 1);
  } else {
    const colon = s.lastIndexOf(':');
    if (colon < 0) {
      return undefined;
    }
    host = s.substring(0, colon);
    portText = s.substring(colon + 1);
  }
  if (portText.startsWith(':')) {
    portText = portText.substring(1);
  }
  const port = parseInt(portText, 10);
  if (!Number.isFinite(port) || port <= 0 || port > 65535 || !host) {
    return undefined;
  }
  const isDomain = host.indexOf(':') < 0 && !/^\d{1,3}(\.\d{1,3}){3}$/.test(host);
  return { host, port, isDomain };
}

/** Open a native SOCKS5 tunnel to the target through the configured server (single attempt). */
function openSocksTunnelOnce(cfg: Socks5Config, target: Socks5Target): Promise<socket.TCPSocket> {
  return new Promise<socket.TCPSocket>((resolve, reject) => {
    const tcp = socket.constructTCPSocketInstance();
    let settled = false;
    const fail = (e: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        tcp.off('error');
        tcp.close();
      } catch (_e) {
      }
      reject(e);
    };

    tcp.on('error', (e: Error) => {
      fail(e);
    });

    const proxyOptions: socket.ProxyOptions = {
      type: socket.ProxyTypes.SOCKS5,
      address: { address: cfg.host, port: cfg.port, family: familyForHost(cfg.host) }
    };
    if (cfg.username && cfg.username.length > 0) {
      proxyOptions.username = cfg.username;
      proxyOptions.password = cfg.password || '';
    }
    const connectOptions: socket.TCPConnectOptions = {
      address: {
        address: target.host,
        port: target.port,
        family: target.isDomain ? 3 : familyForHost(target.host)
      },
      timeout: 15000,
      proxy: proxyOptions
    };
    tcp.connect(connectOptions).then(() => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        tcp.off('error');
      } catch (_e) {
      }
      resolve(tcp);
    }).catch((e: Error) => {
      // Reject with the original object: netstack failures arrive as
      // BusinessError-shaped objects (code/message); wrapping them in
      // Error(String(e)) would destroy the code (logs show "[object Object]").
      fail(e);
    });
  });
}

/**
 * Open a native SOCKS5 tunnel, retrying once after 300ms on transient failure
 * (the upstream proxy or the network can flap briefly). Authentication errors
 * (isSocks5AuthError) are rejected immediately — a retry would fail again.
 */
async function openSocksTunnel(cfg: Socks5Config, target: Socks5Target): Promise<socket.TCPSocket> {
  try {
    return await openSocksTunnelOnce(cfg, target);
  } catch (e) {
    if (isSocks5AuthError(e)) {
      // Re-throw the original object (cast for arkts-limited-throw): wrapping it
      // in a new Error would destroy the netstack BusinessError code.
      throw e as Error;
    }
    logger.warn(TAG, `tunnel to ${target.host}:${target.port} failed, retry once in 300ms: ${describeErr(e)}`);
    await new Promise<void>((r) => setTimeout(r, 300));
    return openSocksTunnelOnce(cfg, target);
  }
}

/** Bidirectional byte pipe between the proxy client and the SOCKS tunnel. */
function pipeConnections(client: socket.TCPSocketConnection, tunnel: socket.TCPSocket): void {
  let closed = false;
  const closeAll = (): void => {
    if (closed) {
      return;
    }
    closed = true;
    try {
      client.off('message');
      client.off('close');
      client.off('error');
    } catch (_e) {
    }
    try {
      tunnel.off('message');
      tunnel.off('close');
      tunnel.off('error');
    } catch (_e) {
    }
    try {
      client.close();
    } catch (_e) {
    }
    try {
      tunnel.close();
    } catch (_e) {
    }
  };

  tunnel.on('message', (value: socket.SocketMessageInfo) => {
    if (closed) {
      return;
    }
    client.send({ data: value.message }).catch(() => {
      closeAll();
    });
  });
  client.on('message', (value: socket.SocketMessageInfo) => {
    if (closed) {
      return;
    }
    tunnel.send({ data: value.message }).catch(() => {
      closeAll();
    });
  });
  tunnel.on('close', () => closeAll());
  tunnel.on('error', (e: Error) => {
    logger.warn(TAG, `tunnel error: ${describeErr(e)}`);
    closeAll();
  });
  client.on('close', () => closeAll());
  client.on('error', (e: Error) => {
    logger.warn(TAG, `client error: ${describeErr(e)}`);
    closeAll();
  });
}

async function sendRaw(conn: socket.TCPSocketConnection, data: ArrayBuffer): Promise<void> {
  await conn.send({ data });
}

/** Rewrite the request line to origin-form, strip proxy-only headers. */
function buildForwardHead(requestLine: string, headerLines: string[], pathAndQuery: string): string {
  const line = requestLine.split(' ');
  const method = line[0] || 'GET';
  const httpVersion = line[2] || 'HTTP/1.1';
  const out: string[] = [`${method} ${pathAndQuery} ${httpVersion}`];
  for (let i = 0; i < headerLines.length; i++) {
    const h = headerLines[i];
    if (!h) {
      continue;
    }
    if (/^proxy-connection:/i.test(h)) {
      continue;
    }
    out.push(h);
  }
  return out.join(CRLF) + CRLF + CRLF;
}

function handleConnection(conn: socket.TCPSocketConnection, cfg: Socks5Config): Promise<void> {
  return new Promise<void>((resolve) => {
    let raw = new Uint8Array(0);
    let settled = false;
    let idleTimerId: number = -1;

    const findHeaderEnd = (buf: Uint8Array): number => {
      for (let i = 0; i + 3 < buf.length; i++) {
        if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) {
          return i;
        }
      }
      return -1;
    };

    const clearIdleTimer = (): void => {
      if (idleTimerId >= 0) {
        clearTimeout(idleTimerId);
        idleTimerId = -1;
      }
    };

    const done = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearIdleTimer();
      // Deliberately do NOT off('message') here: some OHOS socket versions clear
      // all listeners of a type even when a specific callback is passed, which
      // would strip pipeConnections' forwarding handler and kill the data path.
      // The `settled` guard makes requestHandler a no-op for any later messages;
      // pipeConnections' own handlers take over forwarding.
      resolve();
    };

    // Idle timeout: armed on accept, cleared once the request head is fully
    // parsed (tunnel establishment and the pipe phase have their own bounds —
    // openSocksTunnel's connect timeout, and an established CONNECT tunnel is
    // long-lived by design). On expiry, close quietly.
    idleTimerId = setTimeout(() => {
      idleTimerId = -1;
      logger.debug(TAG, `connection idle ${IDLE_HEAD_TIMEOUT_MS}ms without complete request head, closing`);
      try {
        conn.close();
      } catch (_e) {
      }
      done();
    }, IDLE_HEAD_TIMEOUT_MS);

    const requestHandler = async (value: socket.SocketMessageInfo): Promise<void> => {
      if (settled) {
        return;
      }
      try {
        const chunk = new Uint8Array(value.message);
        const merged = new Uint8Array(raw.length + chunk.length);
        merged.set(raw, 0);
        merged.set(chunk, raw.length);
        raw = merged;
        const headerEnd = findHeaderEnd(raw);
        if (headerEnd < 0) {
          if (raw.length > 65536) {
            await sendRaw(conn, encodeText('HTTP/1.1 431 Request Header Fields Too Large' + CRLF + 'Connection: close' + CRLF + CRLF));
            conn.close();
            done();
          }
          return;
        }
        // Request head complete: the idle guard has done its job.
        clearIdleTimer();
        const headText = new util.TextDecoder().decode(raw.subarray(0, headerEnd).slice());
        const headLines = headText.split(CRLF);
        const requestLine = headLines[0] || '';
        const parts = requestLine.split(' ');
        const method = parts[0] || '';
        const target = parts[1] || '';

        if (method === 'CONNECT') {
          const addr = parseAuthority(target);
          if (!addr) {
            await sendRaw(conn, encodeText('HTTP/1.1 400 Bad Request' + CRLF + 'Connection: close' + CRLF + CRLF));
            conn.close();
            done();
            return;
          }
          // Capture before any await: if the client coalesced early data (e.g. an
          // optimistic TLS ClientHello) with the CONNECT header, those bytes sit
          // in `raw` after the header and must reach the tunnel or the TLS
          // handshake stalls until timeout.
          const early = raw.subarray(headerEnd + 4).slice();
          try {
            const tunnel = await openSocksTunnel(cfg, addr);
            await sendRaw(conn, encodeText('HTTP/1.1 200 Connection Established' + CRLF + CRLF));
            if (early.length > 0) {
              await tunnel.send({ data: early.buffer });
            }
            pipeConnections(conn, tunnel);
          } catch (e) {
            logger.warn(TAG, `CONNECT ${target} failed: ${describeErr(e)}`);
            await sendRaw(conn, encodeText('HTTP/1.1 502 Bad Gateway' + CRLF + 'Connection: close' + CRLF + CRLF));
            conn.close();
          }
          done();
          return;
        }

        // Plain HTTP (absolute-URI) forwarding — covers http:// targets that the
        // http stack sends to a proxy in absolute form.
        const urlMatch = /^https?:\/\/([^/:?#]+)(?::(\d+))?([^?#]*)(\?[^#]*)?$/i.exec(target);
        if (!urlMatch) {
          await sendRaw(conn, encodeText('HTTP/1.1 400 Bad Request' + CRLF + 'Connection: close' + CRLF + CRLF));
          conn.close();
          done();
          return;
        }
        const host = urlMatch[1];
        const isHttps = target.toLowerCase().startsWith('https:');
        const port = urlMatch[2] ? parseInt(urlMatch[2], 10) : (isHttps ? 443 : 80);
        const pathAndQuery = (urlMatch[3] || '/') + (urlMatch[4] || '');
        const addr: Socks5Target = parseAuthority(`${host}:${port}`) ?? { host, port, isDomain: true };
        const body = raw.subarray(headerEnd + 4).slice().buffer;
        try {
          const tunnel = await openSocksTunnel(cfg, addr);
          const head = buildForwardHead(requestLine, headLines.slice(1), pathAndQuery);
          await tunnel.send({ data: encodeText(head) });
          if (body.byteLength > 0) {
            await tunnel.send({ data: body });
          }
          pipeConnections(conn, tunnel);
        } catch (e) {
          logger.warn(TAG, `forward ${target} failed: ${describeErr(e)}`);
          await sendRaw(conn, encodeText('HTTP/1.1 502 Bad Gateway' + CRLF + 'Connection: close' + CRLF + CRLF));
          conn.close();
        }
        done();
      } catch (e) {
        logger.error(TAG, `handleConnection error: ${e}`);
        try {
          conn.close();
        } catch (_e) {
        }
        done();
      }
    };

    conn.on('message', requestHandler);
    conn.on('close', done);
    conn.on('error', (e: Error) => {
      logger.warn(TAG, `connection error: ${describeErr(e)}`);
      done();
    });
  });
}

/**
 * Loopback HTTP CONNECT bridge → native SOCKS5.
 *
 * The http / rcp stacks only speak HTTP proxies, so when the user selects
 * SOCKS5 we expose a tiny HTTP proxy on 127.0.0.1 that opens the real tunnel
 * through socket.ProxyTypes.SOCKS5 (API 18+). HttpDownloader / RangeProxy point
 * their per-request proxy at 127.0.0.1:{port}; credentials stay on the bridge.
 *
 * Self-heal: a listening server that reports an 'error' event is torn down and
 * re-listened with the same config, up to MAX_SELF_HEAL_RESTARTS times with a
 * 1s/2s/4s backoff. `stop()` (and any new `start()`) bumps `generation`, so a
 * restart scheduled by a superseded generation is a no-op.
 * (TCPSocketServer has no 'close' event in the current SDK — 'error' is the
 * only async failure signal, so self-heal hooks it.)
 *
 * Outward port snapshot: `getPort()` reports `lastKnownGoodPort`, which is set
 * on every successful listen and is NOT cleared when the server errors into the
 * self-heal window — consumers keep routing at the (temporarily dead) loopback
 * port so their connects fail fast instead of silently going direct, per the
 * "a failing proxy must fail" rule. When self-heal ultimately fails the bridge
 * blows its fuse (`blowFuse`): the port is STILL kept (fail-fast at the dead
 * port) and the failure listener fires so entry can surface "proxy unavailable".
 * Only a real stop (`stop()` — user disabled the proxy, config changed, or the
 * initial listen failed) clears the port back to 0 and resets the fuse.
 */

/** 熔断通知（单槽；entry 注册后可在代理彻底不可用时提示/触发重新应用）。 */
export type Socks5BridgeFailureListener = (reason: string) => void;

/**
 * 端口变化通知（单槽）。自愈重监听使用 port:0（每次新临时端口），成功后新端口
 * 与旧端口不同时触发，entry 据此把 app 级代理 / ArkWeb override 重指到新端口。
 */
export type Socks5BridgePortChangeListener = (port: number) => void;

export class Socks5Bridge {
  private server: socket.TCPSocketServer | null = null;
  private config: Socks5Config | null = null;
  private localPort: number = 0;
  private lastKnownGoodPort: number = 0;
  private running: boolean = false;
  private generation: number = 0;
  private selfHealAttempts: number = 0;
  private healTimerId: number = -1;
  private fuseBlown: boolean = false;
  private failureListener?: Socks5BridgeFailureListener;
  private portChangeListener?: Socks5BridgePortChangeListener;
  private static readonly MAX_SELF_HEAL_RESTARTS: number = 3;

  async start(host: string, port: number, username: string, password: string): Promise<boolean> {
    const h = (host || '').trim();
    const p = Number(port);
    if (!h || !(Number.isFinite(p) && p > 0 && p <= 65535)) {
      this.stop();
      return false;
    }
    if (this.running && this.config
      && this.config.host === h
      && this.config.port === p
      && this.config.username === (username || '')
      && this.config.password === (password || '')) {
      return true;
    }
    this.stop();
    const cfg: Socks5Config = { host: h, port: p, username: username || '', password: password || '' };
    this.selfHealAttempts = 0;
    const gen = this.generation;
    return this.listenOnce(cfg, gen);
  }

  /**
   * Listen on a fresh TCPSocketServer and wire handlers. On failure closes the
   * half-open server. An initial-listen failure stops the bridge (clearing the
   * port); a self-heal re-listen failure blows the fuse instead — the port is
   * kept so consumers keep failing fast at the dead loopback port.
   */
  private async listenOnce(cfg: Socks5Config, gen: number, isSelfHeal: boolean = false): Promise<boolean> {
    const server = socket.constructTCPSocketServerInstance();
    const prevPort = this.lastKnownGoodPort;
    try {
      await server.listen({ address: '127.0.0.1', port: 0, family: 1 });
      if (gen !== this.generation) {
        try {
          server.close();
        } catch (_e) {
        }
        return false;
      }
      const addr = await server.getLocalAddress();
      if (gen !== this.generation) {
        try {
          server.close();
        } catch (_e) {
        }
        return false;
      }
      this.server = server;
      this.config = cfg;
      this.localPort = addr.port ?? 0;
      if (this.localPort > 0) {
        this.lastKnownGoodPort = this.localPort;
      }
      this.running = true;
      logger.info(TAG + ` started localPort=${this.localPort} socks5=${cfg.host}:${cfg.port} auth=${cfg.username.length > 0}`);
      server.on('connect', (conn: socket.TCPSocketConnection) => {
        handleConnection(conn, cfg).catch((e: Error) => logger.warn(TAG + ` conn error: ${describeErr(e)}`));
      });
      server.on('error', (e: Error) => {
        this.handleServerError(server, cfg, gen, e);
      });
      if (isSelfHeal && this.localPort > 0 && this.localPort !== prevPort) {
        // 自愈重监听落在新的临时端口：通知 entry 把 app 级代理 / WebView
        // override 从死掉的旧端口重指到新端口（HttpDownloader / RangeProxy 走
        // 惰性 provider 快照，自行跟随 getPort()，无需通知）。
        logger.info(TAG + ` self-heal re-listen moved port ${prevPort} -> ${this.localPort}`);
        const listener = this.portChangeListener;
        if (listener) {
          try {
            listener(this.localPort);
          } catch (_e) {
            logger.error(TAG + ' port change listener threw');
          }
        }
      }
      return true;
    } catch (e) {
      logger.error(TAG + ` listen failed: ${describeErr(e)}`);
      try {
        server.close();
      } catch (_e) {
      }
      if (isSelfHeal) {
        this.blowFuse(`self-heal re-listen failed: ${describeErr(e)}`);
      } else {
        this.stop();
      }
      return false;
    }
  }

  /**
   * A listening server errored (e.g. netstack killed the fd): tear it down and
   * schedule a bounded self-heal re-listen. Stale servers (superseded by
   * stop()/start()) are ignored via the generation guard.
   * `lastKnownGoodPort` is intentionally kept: while the bridge re-listens,
   * `getPort()` still reports the old (now dead) port so proxy consumers fail
   * fast on connect-refused instead of falling back to a silent direct route.
   */
  private handleServerError(server: socket.TCPSocketServer, cfg: Socks5Config, gen: number, e: Error): void {
    if (gen !== this.generation || this.server !== server) {
      return;
    }
    logger.error(TAG + ` server error, resetting: ${describeErr(e)}`);
    try {
      server.off('connect');
      server.off('error');
      server.close();
    } catch (_e) {
    }
    this.server = null;
    this.localPort = 0;
    this.running = false;
    if (this.selfHealAttempts >= Socks5Bridge.MAX_SELF_HEAL_RESTARTS) {
      this.blowFuse('self-heal restart budget exhausted');
      return;
    }
    this.selfHealAttempts++;
    const delayMs = 1000 * (1 << (this.selfHealAttempts - 1)); // 1s, 2s, 4s
    logger.warn(TAG + ` scheduling self-heal restart attempt=${this.selfHealAttempts} delay=${delayMs}ms`);
    this.healTimerId = setTimeout(() => {
      this.healTimerId = -1;
      if (gen !== this.generation) {
        return; // stop() or a newer start() superseded this restart.
      }
      this.listenOnce(cfg, gen, true).then((ok: boolean) => {
        if (ok) {
          this.selfHealAttempts = 0;
          this.fuseBlown = false;
          logger.info(TAG + ' self-heal restart succeeded');
        } else {
          logger.error(TAG + ' self-heal restart failed to listen');
        }
      }).catch((err: Error) => {
        logger.error(TAG + ` self-heal restart error: ${describeErr(err)}`);
      });
    }, delayMs);
  }

  /**
   * 熔断：自愈彻底失败后的终态。保留 lastKnownGoodPort（消费者继续在死端口上
   * fail-fast，绝不静默直连），关闭 server、取消未决自愈定时器、ERROR 日志并
   * 触发失败监听。之后的 start()（新配置）或 stop()（用户关闭代理）清除熔断。
   */
  private blowFuse(reason: string): void {
    this.generation++; // 使未决的自愈回调/陈旧 server 失效
    if (this.healTimerId >= 0) {
      clearTimeout(this.healTimerId);
      this.healTimerId = -1;
    }
    if (this.server) {
      try {
        this.server.close();
      } catch (_e) {
      }
      this.server = null;
    }
    this.config = null;
    this.localPort = 0;
    this.running = false;
    this.fuseBlown = true;
    // lastKnownGoodPort 故意保留 —— 见 getPort() 的 fail-fast 语义。
    logger.error(TAG + ` fuse blown, bridge stays down at dead port=${this.lastKnownGoodPort}: ${reason}`);
    const listener = this.failureListener;
    if (listener) {
      try {
        listener(reason);
      } catch (_e) {
        logger.error(TAG + ' failure listener threw');
      }
    }
  }

  stop(): void {
    this.generation++;
    if (this.healTimerId >= 0) {
      clearTimeout(this.healTimerId);
      this.healTimerId = -1;
    }
    if (this.server) {
      try {
        this.server.close();
      } catch (_e) {
      }
      this.server = null;
    }
    this.config = null;
    this.localPort = 0;
    this.lastKnownGoodPort = 0;
    this.running = false;
    this.fuseBlown = false;
  }

  isRunning(): boolean {
    return this.running;
  }

  /** 熔断状态：自愈彻底失败后为 true，直到显式 start()/stop()。 */
  isFuseBlown(): boolean {
    return this.fuseBlown;
  }

  /** 注册/清除熔断通知（单槽，后注册覆盖先注册；同 HttpDownloader.setSetCookieObserver 风格）。 */
  setFailureListener(listener?: Socks5BridgeFailureListener): void {
    this.failureListener = listener;
  }

  /** 注册/清除端口变化通知（单槽；自愈重监听到新端口时触发）。 */
  setPortChangeListener(listener?: Socks5BridgePortChangeListener): void {
    this.portChangeListener = listener;
  }

  /**
   * Outward port snapshot for proxy consumers. Reports the last successfully
   * listened port; during the self-heal re-listen window this is the stale
   * (dead) port on purpose — connects fail fast rather than leaking direct.
   * 0 only when the bridge was never started or was explicitly stopped.
   */
  getPort(): number {
    return this.lastKnownGoodPort;
  }
}

export const socks5Bridge = new Socks5Bridge();
