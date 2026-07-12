import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { sessionStore, DashSession } from './SessionStore';
import { parseInputJson } from './InputParser';
import { serveRange } from './RangeProxy';
import Logger from '../utils/Logger';

const TAG = '[LocalProxy][Server]';

function encodeText(s: string): ArrayBuffer {
  return new util.TextEncoder().encode(s).buffer as ArrayBuffer;
}

interface ParsedRequest {
  method: string;
  path: string;
  rangeHeader: string;
}

function parseHttpRequest(raw: string): ParsedRequest {
  const result: ParsedRequest = { method: 'GET', path: '/', rangeHeader: '' };
  const lines = raw.split('\r\n');
  if (lines.length === 0) return result;
  const parts = lines[0].split(' ');
  result.method = parts[0] ?? 'GET';
  result.path = parts[1] ?? '/';
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    if (!line) break;
    const colon = line.indexOf(':');
    if (colon < 0) continue;
    const key = line.substring(0, colon).trim().toLowerCase();
    const value = line.substring(colon + 1).trim();
    if (key === 'range') result.rangeHeader = value;
  }
  return result;
}

function splitPath(path: string): string[] {
  return path.split('/').filter(p => p.length > 0);
}

async function sendText(conn: socket.TCPSocketConnection, status: number, statusText: string, contentType: string, body: string): Promise<void> {
  const hdr = `HTTP/1.1 ${status} ${statusText}\r\nContent-Type: ${contentType}\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n`;
  await conn.send({ data: encodeText(hdr + body) });
}

async function handleConnection(conn: socket.TCPSocketConnection): Promise<void> {
  return new Promise<void>((resolve) => {
    let rawRequest = '';

    conn.on('message', async (value: socket.SocketMessageInfo) => {
      try {
        const chunk = new util.TextDecoder().decodeWithStream(new Uint8Array(value.message));
        rawRequest += chunk;
        if (!rawRequest.includes('\r\n\r\n')) return;

        const req = parseHttpRequest(rawRequest);
        const pathOnly = req.path.split('?')[0];
        const parts = splitPath(pathOnly);

        Logger.debug(TAG, `route method=${req.method} path=${pathOnly} range=${req.rangeHeader}`);

        if (parts.length < 3 || parts[0] !== 'session') {
          await sendText(conn, 404, 'Not Found', 'text/plain', 'Not Found');
          conn.close();
          resolve();
          return;
        }

        const sessionId = parts[1];
        const session = sessionStore.get(sessionId);
        if (!session) {
          await sendText(conn, 404, 'Not Found', 'text/plain', 'Session not found');
          conn.close();
          resolve();
          return;
        }

        if (session.stale) {
          await sendText(conn, 410, 'Gone', 'text/plain', 'Session stale');
          conn.close();
          resolve();
          return;
        }

        await routeRequest(conn, req.method, parts, req.rangeHeader, session);
      } catch (e) {
        Logger.error(TAG, `handleConnection error: ${e}`);
      } finally {
        conn.close();
        resolve();
      }
    });

    conn.on('close', () => resolve());
    conn.on('error', (e: Error) => {
      Logger.error(TAG, `connection error: ${e.message}`);
      resolve();
    });
  });
}

async function routeRequest(
  conn: socket.TCPSocketConnection,
  method: string,
  parts: string[],
  rangeHeader: string,
  session: DashSession
): Promise<void> {
  const segment = parts[2];

  if (parts.length >= 4) {
    const idx = parseInt(parts[3], 10) || 0;
    if (segment === 'video' && idx < session.videos.length) {
      const resource = session.videos[idx];
      if (resource.isOtf) {
        Logger.warn(TAG, `OTF resource requested through byte-range endpoint: video/${idx}`);
      }
      await serveRange(conn, resource, rangeHeader, method === 'HEAD', session);
      return;
    }
    if (segment === 'audio' && session.hasAudio && idx < session.audios.length) {
      const resource = session.audios[idx];
      if (resource.isOtf) {
        Logger.warn(TAG, `OTF resource requested through byte-range endpoint: audio/${idx}`);
      }
      await serveRange(conn, resource, rangeHeader, method === 'HEAD', session);
      return;
    }
    if (segment === 'resource' && parts[3] === 'main') {
      await serveRange(conn, session.single, rangeHeader, method === 'HEAD', session);
      return;
    }
  }

  await sendText(conn, 404, 'Not Found', 'text/plain', 'Not Found');
}

export class LocalProxyServer {
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private running: boolean = false;

  async start(): Promise<boolean> {
    if (this.running) return true;
    try {
      this.server = socket.constructTCPSocketServerInstance();
      // port 0 = OS assigns a free port
      await this.server.listen({ address: '127.0.0.1', port: 0, family: 1 });
      const addr = await this.server.getLocalAddress();
      this.port = addr.port ?? 35783;
      this.running = true;
      Logger.info(TAG, `LocalProxyServer started on port ${this.port}`);

      this.server.on('connect', (conn: socket.TCPSocketConnection) => {
        handleConnection(conn).catch((e: Error) => Logger.error(TAG, `conn error: ${e.message}`));
      });
      return true;
    } catch (e) {
      Logger.error(TAG, `start failed: ${e}`);
      return false;
    }
  }

  stop(): void {
    if (this.server) {
      try { this.server.close(); } catch (_) {}
      this.server = null;
    }
    this.running = false;
  }

  getPort(): number {
    return this.port;
  }

  isRunning(): boolean {
    return this.running;
  }

  createSession(inputJson: string): string {
    const session = parseInputJson(inputJson);
    const valid = session.type === 'single'
      ? !!session.single.url
      : (session.videos.length > 0 && session.audios.length > 0);
    if (!valid) {
      Logger.warn(TAG, `createSession: invalid input type=${session.type}`);
      return '';
    }
    const id = sessionStore.add(session);
    Logger.info(TAG, `createSession: id=${id} type=${session.type} videos=${session.videos.length} audios=${session.audios.length}`);
    return id;
  }

  refreshSession(sessionId: string, inputJson: string): boolean {
    if (!sessionId) return false;
    const session = parseInputJson(inputJson);
    const valid = session.type === 'single'
      ? !!session.single.url
      : (session.videos.length > 0 && session.audios.length > 0);
    if (!valid) {
      Logger.warn(TAG, `refreshSession: invalid input sessionId=${sessionId}`);
      return false;
    }
    session.id = sessionId;
    // 保留已有的 refreshUrls 回调
    const existing = sessionStore.get(sessionId);
    if (existing?.refreshUrls) {
      session.refreshUrls = existing.refreshUrls;
    }
    sessionStore.add(session);
    Logger.info(TAG, `refreshSession: id=${sessionId} type=${session.type}`);
    return true;
  }

  setSessionRefreshCallback(sessionId: string, callback: () => Promise<boolean>): void {
    const session = sessionStore.get(sessionId);
    if (session) {
      session.refreshUrls = callback;
    }
  }

  destroySession(sessionId: string): void {
    Logger.debug(TAG, `destroySession: id=${sessionId}`);
    const session = sessionStore.get(sessionId);
    if (session) {
      session.cancel?.();
      sessionStore.remove(sessionId);
    }
  }

  markSessionStale(sessionId: string): void {
    if (!sessionId) return;
    const session = sessionStore.get(sessionId);
    if (session) session.stale = true;
  }

  destroyAll(): void {
    sessionStore.clear();
  }

  playbackUrl(sessionId: string): string {
    if (!this.running || !sessionId) return '';
    const session = sessionStore.get(sessionId);
    if (!session) return '';
    const base = `http://127.0.0.1:${this.port}/session/${sessionId}`;
    if (session.type === 'single') return `${base}/resource/main`;
    return base;
  }
}

export const localProxyServer = new LocalProxyServer();
