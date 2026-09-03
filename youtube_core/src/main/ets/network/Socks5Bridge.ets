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

// ── Hand-rolled SOCKS5 client (RFC 1928 / RFC 1929) ────────────────────────
// The upstream leg used to delegate the SOCKS5 handshake to netstack's
// socket-level client (socket.ProxyTypes.SOCKS5). On some builds (observed on
// HarmonyOS 7.0.0.105) that layer establishes the tunnel but corrupts/resets
// the byte stream: TLS through the tunnel dies with fatal-alert / CONN_RESET
// while netstack logs "remove socks5 udp header failed". The bridge now runs
// the handshake itself on a plain TCPSocket (CONNECT, ATYP=domain for
// proxy-side DNS, optional username/password auth), so tunnel behavior no
// longer depends on the netstack SOCKS5 implementation.

const SOCKS_VER: number = 0x05;
const SOCKS_CMD_CONNECT: number = 0x01;
const SOCKS_AUTH_NONE: number = 0x00;
const SOCKS_AUTH_USERPASS: number = 0x02;
const SOCKS_NO_ACCEPTABLE_METHOD: number = 0xff;
/** Budget for the whole handshake after TCP connect (greeting + auth + CONNECT reply). */
const SOCKS_HANDSHAKE_TIMEOUT_MS: number = 15000;

/** SOCKS5 握手/CONNECT 失败。authFailed=true 表示认证类失败——同样凭据重试无意义。 */
export class SocksHandshakeError extends Error {
  readonly authFailed: boolean;

  constructor(message: string, authFailed: boolean = false) {
    super(message);
    this.name = 'SocksHandshakeError';
    this.authFailed = authFailed;
  }
}

/** SOCKS5 CONNECT 应答 rep 码 → 可读描述。 */
function socksRepText(rep: number): string {
  switch (rep) {
    case 0x01: return 'general failure';
    case 0x02: return 'not allowed by ruleset';
    case 0x03: return 'network unreachable';
    case 0x04: return 'host unreachable';
    case 0x05: return 'connection refused';
    case 0x06: return 'TTL expired';
    case 0x07: return 'command not supported';
    case 0x08: return 'address type not supported';
    default: return `unknown rep=${rep}`;
  }
}

function socksHandshakeTimeoutError(): SocksHandshakeError {
  return new SocksHandshakeError('SOCKS5 handshake timeout');
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

function encodeTextBytes(s: string): Uint8Array {
  return new util.TextEncoder().encode(s);
}

/** 把字节数组打成一帧待发送的 ArrayBuffer。 */
function frameOf(bytes: number[]): ArrayBuffer {
  return new Uint8Array(bytes).buffer as ArrayBuffer;
}

/** Parse an IPv6 literal into 16 bytes (supports '::' compression and an embedded IPv4 tail). */
function parseIpv6(host: string): Uint8Array | undefined {
  let h = host.trim();
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  let v4: number[] | null = null;
  if (h.indexOf('.') >= 0) {
    const idx = h.lastIndexOf(':');
    if (idx < 0) {
      return undefined;
    }
    const tail = h.substring(idx + 1);
    if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(tail)) {
      return undefined;
    }
    v4 = [];
    const tailParts = tail.split('.');
    for (let i = 0; i < tailParts.length; i++) {
      v4.push(parseInt(tailParts[i], 10) & 0xff);
    }
    h = h.substring(0, idx + 1);
    if (h.endsWith(':') && !h.endsWith('::')) {
      h = h.substring(0, h.length - 1);
    }
  }
  const parseGroups = (s: string): number[] | undefined => {
    const out: number[] = [];
    if (s.length === 0) {
      return out;
    }
    const parts = s.split(':');
    for (let i = 0; i < parts.length; i++) {
      if (!/^[0-9a-fA-F]{1,4}$/.test(parts[i])) {
        return undefined;
      }
      out.push(parseInt(parts[i], 16));
    }
    return out;
  };
  const v4Groups = v4 ? 2 : 0;
  let groups: number[];
  const dc = h.indexOf('::');
  if (dc >= 0) {
    const headGroups = parseGroups(h.substring(0, dc));
    const tailGroups = parseGroups(h.substring(dc + 2));
    if (!headGroups || !tailGroups || headGroups.length + tailGroups.length + v4Groups > 7) {
      return undefined;
    }
    groups = headGroups;
    const zeros = 8 - headGroups.length - tailGroups.length - v4Groups;
    for (let i = 0; i < zeros; i++) {
      groups.push(0);
    }
    for (let i = 0; i < tailGroups.length; i++) {
      groups.push(tailGroups[i]);
    }
  } else {
    const all = parseGroups(h);
    if (!all || all.length + v4Groups !== 8) {
      return undefined;
    }
    groups = all;
  }
  const bytes = new Uint8Array(16);
  for (let i = 0; i < 8; i++) {
    const g = i < groups.length ? groups[i] : 0;
    bytes[i * 2] = (g >> 8) & 0xff;
    bytes[i * 2 + 1] = g & 0xff;
  }
  if (v4) {
    bytes[12] = v4[0];
    bytes[13] = v4[1];
    bytes[14] = v4[2];
    bytes[15] = v4[3];
  }
  return bytes;
}

/** CONNECT 目标编为 ATYP+ADDR+PORT 字节；域名走 ATYP=03（代理解析 DNS，不本地泄漏）。 */
function socksTargetBytes(target: Socks5Target): number[] {
  const out: number[] = [];
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(target.host)) {
    out.push(0x01);
    const parts = target.host.split('.');
    for (let i = 0; i < 4; i++) {
      out.push(parseInt(parts[i], 10) & 0xff);
    }
  } else if (target.host.indexOf(':') >= 0) {
    const v6 = parseIpv6(target.host);
    if (!v6) {
      throw new SocksHandshakeError(`malformed IPv6 target ${target.host}`);
    }
    out.push(0x04);
    for (let i = 0; i < 16; i++) {
      out.push(v6[i]);
    }
  } else {
    const name = encodeTextBytes(target.host);
    if (name.length === 0 || name.length > 255) {
      throw new SocksHandshakeError(`bad target host length=${name.length}`);
    }
    out.push(0x03);
    out.push(name.length);
    for (let i = 0; i < name.length; i++) {
      out.push(name[i]);
    }
  }
  out.push((target.port >> 8) & 0xff);
  out.push(target.port & 0xff);
  return out;
}

/**
 * Handshake-phase byte pump over a TCPSocket: accumulates 'message' chunks and
 * fulfills strictly-sequential exact-length reads (at most one outstanding).
 * fail() rejects the pending read and every later one. After the handshake the
 * caller detaches it via off('message'/'close'/'error') BEFORE pipeConnections
 * attaches its own handlers — on some OHOS versions off(type) clears ALL
 * listeners of that type, so the detach must happen before the pipe wires up.
 */
class HandshakeReader {
  private pending: number[] = [];
  private waiter: HandshakeWaiter | null = null;
  private failure: Object | null = null;
  /** 非 null 即转发模式：之后每个 message 直接进 sink，不再走握手缓冲。 */
  private pipeSink: ((bytes: Uint8Array) => void) | null = null;

  readonly onMessage = (value: socket.SocketMessageInfo): void => {
    const chunk = new Uint8Array(value.message);
    if (this.pipeSink) {
      this.pipeSink(chunk);
      return;
    }
    for (let i = 0; i < chunk.length; i++) {
      this.pending.push(chunk[i]);
    }
    const w = this.waiter;
    if (w && this.pending.length >= w.needed) {
      const out = new Uint8Array(this.pending.splice(0, w.needed));
      this.waiter = null;
      w.resolve(out);
    }
  };

  readonly onClose = (): void => {
    // 转发模式下 close/error 由 pipeConnections 自己的处理器负责 teardown。
    if (this.pipeSink) {
      return;
    }
    this.fail(new Error('connection closed during SOCKS5 handshake'));
  };

  readonly onError = (e: Error): void => {
    if (this.pipeSink) {
      return;
    }
    this.fail(new Error(`socket error during SOCKS5 handshake: ${describeErr(e)}`));
  };

  fail(e: Object): void {
    if (!this.failure) {
      this.failure = e;
    }
    const w = this.waiter;
    this.waiter = null;
    if (w) {
      w.reject(this.failure);
    }
  }

  readExactly(n: number): Promise<Uint8Array> {
    if (this.failure) {
      return Promise.reject(this.failure);
    }
    if (this.pending.length >= n) {
      return Promise.resolve(new Uint8Array(this.pending.splice(0, n)));
    }
    if (this.waiter) {
      return Promise.reject(new Error('concurrent handshake read not supported'));
    }
    return new Promise<Uint8Array>((resolve, reject) => {
      this.waiter = { needed: n, resolve, reject };
    });
  }

  /**
   * 切到转发模式：先把握手阶段缓冲的剩余字节按序冲刷给 sink，之后每个
   * message 直接转发。握手完成后保持挂接不 off——部分 OHOS 版本 off(type)
   * 会误清该类型全部监听器；而且"摘 reader→pipe 重挂"窗口内到达的上游字节
   * 无人接收会丢字节（TLS 流直接损坏）。
   */
  switchToPipe(sink: (bytes: Uint8Array) => void): void {
    this.pipeSink = sink;
    if (this.pending.length > 0) {
      const out = new Uint8Array(this.pending.splice(0, this.pending.length));
      this.pipeSink(out);
    }
  }
}

interface HandshakeWaiter {
  needed: number;
  resolve: (v: Uint8Array) => void;
  reject: (e: Object) => void;
}

/** 已打通的隧道：socket + 仍挂在 socket 上的握手读取器（pipe 时切转发模式）。 */
interface OpenedTunnel {
  sock: socket.TCPSocket;
  reader: HandshakeReader;
}

/** greeting + 可选用户名/密码认证 + CONNECT + 应答校验。 */
async function doSocks5Handshake(tcp: socket.TCPSocket, reader: HandshakeReader,
  cfg: Socks5Config, target: Socks5Target): Promise<void> {
  const greeting: number[] = [SOCKS_VER, 0, SOCKS_AUTH_NONE];
  if (cfg.username.length > 0) {
    greeting.push(SOCKS_AUTH_USERPASS);
  }
  greeting[1] = greeting.length - 2;
  await tcp.send({ data: frameOf(greeting) });
  const sel = await reader.readExactly(2);
  if (sel[0] !== SOCKS_VER) {
    throw new SocksHandshakeError(`bad greeting reply version=${sel[0]}`);
  }
  if (sel[1] === SOCKS_NO_ACCEPTABLE_METHOD) {
    throw new SocksHandshakeError('server accepted no offered auth method', true);
  }
  if (sel[1] === SOCKS_AUTH_USERPASS) {
    const u = encodeTextBytes(cfg.username);
    const p = encodeTextBytes(cfg.password);
    if (u.length > 255 || p.length > 255) {
      throw new SocksHandshakeError('credentials exceed 255 bytes', true);
    }
    const authReq: number[] = [0x01, u.length];
    for (let i = 0; i < u.length; i++) {
      authReq.push(u[i]);
    }
    authReq.push(p.length);
    for (let i = 0; i < p.length; i++) {
      authReq.push(p[i]);
    }
    await tcp.send({ data: frameOf(authReq) });
    const authReply = await reader.readExactly(2);
    if (authReply[1] !== 0x00) {
      throw new SocksHandshakeError('username/password rejected by server', true);
    }
  } else if (sel[1] !== SOCKS_AUTH_NONE) {
    throw new SocksHandshakeError(`server selected unsupported auth method=${sel[1]}`);
  }

  const connectReq: number[] = [SOCKS_VER, SOCKS_CMD_CONNECT, 0x00];
  const targetBytes = socksTargetBytes(target);
  for (let i = 0; i < targetBytes.length; i++) {
    connectReq.push(targetBytes[i]);
  }
  await tcp.send({ data: frameOf(connectReq) });

  const head = await reader.readExactly(4);
  if (head[0] !== SOCKS_VER) {
    throw new SocksHandshakeError(`bad CONNECT reply version=${head[0]}`);
  }
  const atyp = head[3];
  if (atyp === 0x01) {
    await reader.readExactly(4);
  } else if (atyp === 0x03) {
    const len = await reader.readExactly(1);
    await reader.readExactly(len[0]);
  } else if (atyp === 0x04) {
    await reader.readExactly(16);
  } else {
    throw new SocksHandshakeError(`bad CONNECT reply atyp=${atyp}`);
  }
  await reader.readExactly(2); // BND.PORT
  if (head[1] !== 0x00) {
    throw new SocksHandshakeError(`CONNECT rejected: ${socksRepText(head[1])}`);
  }
}

/** Single attempt: direct TCP to the SOCKS5 server + hand-rolled handshake. */
async function openSocksTunnelOnce(cfg: Socks5Config, target: Socks5Target): Promise<OpenedTunnel> {
  const tcp = socket.constructTCPSocketInstance();
  const reader = new HandshakeReader();
  tcp.on('message', reader.onMessage);
  tcp.on('close', reader.onClose);
  tcp.on('error', reader.onError);
  let timeoutId: number = -1;
  try {
    await tcp.connect({
      address: { address: cfg.host, port: cfg.port, family: familyForHost(cfg.host) },
      timeout: SOCKS_HANDSHAKE_TIMEOUT_MS
    });
    const timeoutPromise = new Promise<never>((_resolve, reject) => {
      timeoutId = setTimeout(() => {
        reader.fail(socksHandshakeTimeoutError());
        reject(socksHandshakeTimeoutError());
      }, SOCKS_HANDSHAKE_TIMEOUT_MS);
    });
    // race 对两个分支都挂了 rejection 处理器，超时后 handshake 的迟到 reject 不会
    // 变成 unhandled rejection。
    await Promise.race([doSocks5Handshake(tcp, reader, cfg, target), timeoutPromise]);
    clearTimeout(timeoutId);
    timeoutId = -1;
    // 不摘 reader、不清监听器：pipeConnections 会把它切到转发模式（见
    // switchToPipe 注释），保持挂接同时消除"重挂窗口丢上游字节"的竞态。
    return { sock: tcp, reader };
  } catch (e) {
    if (timeoutId >= 0) {
      clearTimeout(timeoutId);
    }
    try {
      tcp.off('message');
      tcp.off('close');
      tcp.off('error');
      tcp.close();
    } catch (_e) {
    }
    // 原样抛出，不包装：netstack 失败是 BusinessError 形状的对象，包装成
    // Error(String(e)) 会丢掉 code（日志变 "[object Object]"）。
    throw e as Error;
  }
}

/**
 * Open a SOCKS5 tunnel, retrying once after 300ms on transient failure (the
 * upstream proxy or the network can flap briefly). Authentication failures
 * (SocksHandshakeError.authFailed) are rejected immediately — the same
 * credentials would fail again.
 */
async function openSocksTunnel(cfg: Socks5Config, target: Socks5Target): Promise<OpenedTunnel> {
  try {
    return await openSocksTunnelOnce(cfg, target);
  } catch (e) {
    if (e instanceof SocksHandshakeError && e.authFailed) {
      throw e;
    }
    logger.warn(TAG, `tunnel to ${target.host}:${target.port} failed, retry once in 300ms: ${describeErr(e)}`);
    await new Promise<void>((r) => setTimeout(r, 300));
    return openSocksTunnelOnce(cfg, target);
  }
}

/**
 * 单方向串行写队列。分片入队前先复制（netstack 的 message ArrayBuffer 在回调
 * 返回后可能被复用，异步 send 若仍引用原 buffer 会发出脏数据），send 串行
 * await 保序——并发 send 不承诺落线顺序，TLS 流里字节乱序/丢字即致命。
 * 任一 send 失败即通过 closeFn 关闭双方向。
 */
class SendQueue {
  private tail: Promise<void> = Promise.resolve();
  private closed: boolean = false;
  private readonly sendFn: (data: ArrayBuffer) => Promise<void>;
  private readonly closeFn: () => void;

  constructor(sendFn: (data: ArrayBuffer) => Promise<void>, closeFn: () => void) {
    this.sendFn = sendFn;
    this.closeFn = closeFn;
  }

  close(): void {
    this.closed = true;
  }

  enqueue(bytes: Uint8Array): void {
    if (this.closed) {
      return;
    }
    const copy = bytes.slice();
    this.tail = this.tail.then(async () => {
      if (this.closed) {
        return;
      }
      await this.sendFn(copy.buffer as ArrayBuffer);
    }).catch(() => {
      this.closeFn();
    });
  }
}

/** Bidirectional byte pipe between the proxy client and the SOCKS tunnel. */
function pipeConnections(client: socket.TCPSocketConnection, tunnel: socket.TCPSocket,
  reader: HandshakeReader): void {
  let closed = false;
  const toClient = new SendQueue((data: ArrayBuffer) => client.send({ data: data }), (): void => closeAll());
  const toTunnel = new SendQueue((data: ArrayBuffer) => tunnel.send({ data: data }), (): void => closeAll());
  const closeAll = (): void => {
    if (closed) {
      return;
    }
    closed = true;
    toClient.close();
    toTunnel.close();
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

  // 上行（tunnel→client）：复用握手阶段就挂在 tunnel 上的 reader，切到转发
  // 模式；缓冲里可能已有上游在挂接窗口内送达的字节，由 switchToPipe 先冲刷。
  reader.switchToPipe((bytes: Uint8Array) => toClient.enqueue(bytes));
  client.on('message', (value: socket.SocketMessageInfo) => {
    toTunnel.enqueue(new Uint8Array(value.message));
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
              await tunnel.sock.send({ data: early.buffer });
            }
            // 隧道侧缓冲的剩余字节由 switchToPipe 按序冲刷，无需单独处理。
            pipeConnections(conn, tunnel.sock, tunnel.reader);
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
          await tunnel.sock.send({ data: encodeText(head) });
          if (body.byteLength > 0) {
            await tunnel.sock.send({ data: body });
          }
          pipeConnections(conn, tunnel.sock, tunnel.reader);
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
 * Loopback HTTP CONNECT bridge → SOCKS5.
 *
 * ArkWeb ProxyController / RCP / MPV(FFmpeg http_proxy env) / app 级代理的
 * 消费方都只能说 HTTP 代理，所以用户选 SOCKS5 时本桥在 127.0.0.1 暴露一个
 * 微型 HTTP 代理，把每条 CONNECT 翻译成到目标的真实 SOCKS5 隧道。上游握手
 * 由桥内手写（RFC 1928 CONNECT + 可选 RFC 1929 认证，见 openSocksTunnelOnce），
 * 不再使用 netstack 的 socket.ProxyTypes.SOCKS5——该实现在部分系统版本上
 * （如 7.0.0.105）能建通隧道但会损毁/重置字节流。认证信息只留在桥上，
 * 127.0.0.1 侧永远无认证。
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
