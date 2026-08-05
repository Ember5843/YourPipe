/**
 * Outbound proxy for app HTTP. Applied by HttpDownloader / RangeProxy.
 * Loopback must never use proxy (LocalMediaProxy).
 */
export type AppProxyKind = 'none' | 'http' | 'socks5';

export interface AppHttpProxySnapshot {
  kind: AppProxyKind;
  host: string;
  port: number;
  username: string;
  password: string;
  exclusionList: string[];
  /** Loopback HTTP CONNECT bridge port when kind==='socks5'. Absent/0 = direct. */
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

  /** True when host/port look usable for an enabled proxy. */
  static isActive(snapshot?: AppHttpProxySnapshot): boolean {
    const s = snapshot ?? HttpProxyOptions.getSnapshot();
    if (s.kind === 'none') {
      return false;
    }
    return s.host.trim().length > 0 && s.port > 0 && s.port <= 65535;
  }

  static shouldBypass(url: string, snapshot?: AppHttpProxySnapshot): boolean {
    const s = snapshot ?? HttpProxyOptions.getSnapshot();
    const host = HttpProxyOptions.extractHost(url).toLowerCase();
    if (!host) {
      return true;
    }
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

  private static extractHost(url: string): string {
    try {
      const m = /^https?:\/\/([^/:?#]+)/i.exec(url);
      return m ? m[1] : '';
    } catch (_e) {
      return '';
    }
  }
}
