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

/** Open a native SOCKS5 tunnel to the target through the configured server. */
function openSocksTunnel(cfg: Socks5Config, target: Socks5Target): Promise<socket.TCPSocket> {
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

    const findHeaderEnd = (buf: Uint8Array): number => {
      for (let i = 0; i + 3 < buf.length; i++) {
        if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) {
          return i;
        }
      }
      return -1;
    };

    const done = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      // Deliberately do NOT off('message') here: some OHOS socket versions clear
      // all listeners of a type even when a specific callback is passed, which
      // would strip pipeConnections' forwarding handler and kill the data path.
      // The `settled` guard makes requestHandler a no-op for any later messages;
      // pipeConnections' own handlers take over forwarding.
      resolve();
    };

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
 */
export class Socks5Bridge {
  private server: socket.TCPSocketServer | null = null;
  private config: Socks5Config | null = null;
  private localPort: number = 0;
  private running: boolean = false;
  private generation: number = 0;

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
    const gen = this.generation;
    const server = socket.constructTCPSocketServerInstance();
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
      this.running = true;
      logger.info(TAG + ` started localPort=${this.localPort} socks5=${h}:${p} auth=${cfg.username.length > 0}`);
      server.on('connect', (conn: socket.TCPSocketConnection) => {
        handleConnection(conn, cfg).catch((e: Error) => logger.warn(TAG + ` conn error: ${describeErr(e)}`));
      });
      return true;
    } catch (e) {
      logger.error(TAG + ` start failed: ${describeErr(e)}`);
      try {
        server.close();
      } catch (_e) {
      }
      this.stop();
      return false;
    }
  }

  stop(): void {
    this.generation++;
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
  }

  isRunning(): boolean {
    return this.running;
  }

  getPort(): number {
    return this.localPort;
  }
}

export const socks5Bridge = new Socks5Bridge();
