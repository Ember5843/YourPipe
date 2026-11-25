/**
 * Outbound proxy for app HTTP. Applied by HttpDownloader / RangeProxy.
 * Loopback must never use proxy (LocalMediaProxy).
 */
import { url } from '@kit.ArkTS';

export type AppProxyKind = 'none' | 'http' | 'socks5';
export type AppProxyState = 'disabled' | 'applying' | 'ready' | 'blocked';

export class ProxyUnavailableError extends Error {
  constructor() {
    super('App proxy is unavailable');
    this.name = 'ProxyUnavailableError';
  }
}

export interface AppHttpProxySnapshot {
  state?: AppProxyState;
  revision?: number;
  kind: AppProxyKind;
  host: string;
  port: number;
  username: string;
  password: string;
  exclusionList: string[];
  /** Required loopback route for SOCKS5 consumers without native SOCKS support. */
  socks5LocalPort?: number;
}

export type AppHttpProxyProvider = () => AppHttpProxySnapshot | undefined;

const DEFAULT_EXCLUSIONS: string[] = [
  'localhost',
  '127.0.0.1',
  '::1',
  '[::1]'
];

export class HttpProxyOptions {
  private static provider?: AppHttpProxyProvider;

  static setProvider(provider?: AppHttpProxyProvider): void {
    HttpProxyOptions.provider = provider;
  }

  static getSnapshot(): AppHttpProxySnapshot {
    const fromProvider = HttpProxyOptions.provider?.();
    if (fromProvider) {
      return fromProvider;
    }
    return {
      kind: 'none',
      host: '',
      port: 0,
      username: '',
      password: '',
      exclusionList: DEFAULT_EXCLUSIONS.slice()
    };
  }

  static defaultExclusions(): string[] {
    return DEFAULT_EXCLUSIONS.slice();
  }

  static assertAvailable(rawUrl: string, snapshot?: AppHttpProxySnapshot, needsBridge: boolean = false): void {
    const s = snapshot ?? HttpProxyOptions.getSnapshot();
    if (s.kind === 'none' || HttpProxyOptions.shouldBypass(rawUrl, s)) return;
    if (!HttpProxyOptions.isActive(s) || s.state === 'applying' || s.state === 'blocked' ||
      (needsBridge && s.kind === 'socks5' && !(s.socks5LocalPort && s.socks5LocalPort > 0))) {
      throw new ProxyUnavailableError();
    }
  }

  /** True when host/port look usable for an enabled proxy. */
  static isActive(snapshot?: AppHttpProxySnapshot): boolean {
    const s = snapshot ?? HttpProxyOptions.getSnapshot();
    if (s.kind === 'none') {
      return false;
    }
    return s.host.trim().length > 0 && s.port > 0 && s.port <= 65535;
  }

  static shouldBypass(url: string, snapshot?: AppHttpProxySnapshot): boolean {
    if (url.startsWith('file://') || url.startsWith('edl://') || url.startsWith('/')) return true;
    const s = snapshot ?? HttpProxyOptions.getSnapshot();
    const host = HttpProxyOptions.extractHost(url).toLowerCase();
    if (!host) return false;
    if (host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]') {
      return true;
    }
    const list = s.exclusionList || [];
    for (let i = 0; i < list.length; i++) {
      const rule = (list[i] || '').trim().toLowerCase();
      if (!rule) {
        continue;
      }
      if (host === rule || host.endsWith('.' + rule)) {
        return true;
      }
    }
    return false;
  }

  private static extractHost(rawUrl: string): string {
    try {
      return url.URL.parseURL(rawUrl).hostname;
    } catch (_e) {
      return '';
    }
  }
}
