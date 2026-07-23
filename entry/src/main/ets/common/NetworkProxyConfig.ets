import { connection } from '@kit.NetworkKit';
import {
  AppHttpProxySnapshot,
  AppProxyKind,
  HttpProxyOptions
} from 'youtube_core';
import { PreferencesStore } from './PreferencesStore';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('NetworkProxyConfig');

const KEY_ENABLED = 'cfg_proxy_enabled';
const KEY_KIND = 'cfg_proxy_kind';
const KEY_HOST = 'cfg_proxy_host';
const KEY_PORT = 'cfg_proxy_port';
const KEY_USER = 'cfg_proxy_username';
const KEY_PASS = 'cfg_proxy_password';

@Observed
export class NetworkProxyConfig {
  enabled: boolean = false;
  /** Product: only http is active; socks5 is UI placeholder. */
  kind: AppProxyKind = 'http';
  host: string = '';
  port: number = 7890;
  username: string = '';
  password: string = '';

  static load(): NetworkProxyConfig {
    const cfg = new NetworkProxyConfig();
    cfg.enabled = PreferencesStore.getString(KEY_ENABLED, 'false') === 'true';
    const kindRaw = PreferencesStore.getString(KEY_KIND, 'http');
    cfg.kind = kindRaw === 'socks5' ? 'socks5' : (kindRaw === 'none' ? 'http' : 'http');
    cfg.host = PreferencesStore.getString(KEY_HOST, '');
    const portRaw = parseInt(PreferencesStore.getString(KEY_PORT, '7890'), 10);
    cfg.port = Number.isFinite(portRaw) && portRaw > 0 && portRaw <= 65535 ? portRaw : 7890;
    cfg.username = PreferencesStore.getString(KEY_USER, '');
    cfg.password = PreferencesStore.getString(KEY_PASS, '');
    return cfg;
  }

  static save(cfg: NetworkProxyConfig): void {
    PreferencesStore.setString(KEY_ENABLED, cfg.enabled ? 'true' : 'false');
    PreferencesStore.setString(KEY_KIND, cfg.kind === 'socks5' ? 'socks5' : 'http');
    PreferencesStore.setString(KEY_HOST, cfg.host || '');
    PreferencesStore.setString(KEY_PORT, `${Math.max(1, Math.min(65535, Math.round(cfg.port || 7890)))}`);
    PreferencesStore.setString(KEY_USER, cfg.username || '');
    PreferencesStore.setString(KEY_PASS, cfg.password || '');
  }

  static resetToDefault(): NetworkProxyConfig {
    const cfg = new NetworkProxyConfig();
    NetworkProxyConfig.save(cfg);
    NetworkProxyConfig.applySystemAndProviders(cfg);
    return cfg;
  }

  toSnapshot(): AppHttpProxySnapshot {
    const exclusions = HttpProxyOptions.defaultExclusions();
    if (!this.enabled || this.kind === 'socks5') {
      // socks5 UI-only for now — treat as none for request injection
      return {
        kind: 'none',
        host: '',
        port: 0,
        username: '',
        password: '',
        exclusionList: exclusions
      };
    }
    return {
      kind: 'http',
      host: (this.host || '').trim(),
      port: this.port,
      username: this.username || '',
      password: this.password || '',
      exclusionList: exclusions
    };
  }

  subtitle(): ResourceStr {
    if (!this.enabled) {
      return $r('app.string.yt_proxy_off');
    }
    if (this.kind === 'socks5') {
      return $r('app.string.yt_proxy_socks5_soon');
    }
    const host = (this.host || '').trim();
    if (!host || this.port <= 0) {
      return $r('app.string.yt_proxy_incomplete');
    }
    return `${host}:${this.port}`;
  }

  isReady(): boolean {
    return this.enabled
      && this.kind === 'http'
      && (this.host || '').trim().length > 0
      && this.port > 0
      && this.port <= 65535;
  }

  /**
   * Wire HttpProxyOptions provider + optional app-level HTTP proxy.
   * Call after load and after every settings change.
   */
  static applySystemAndProviders(cfg: NetworkProxyConfig): void {
    HttpProxyOptions.setProvider((): AppHttpProxySnapshot => cfg.toSnapshot());

    try {
      if (cfg.isReady()) {
        const proxy: connection.HttpProxy = {
          host: cfg.host.trim(),
          port: cfg.port,
          exclusionList: HttpProxyOptions.defaultExclusions()
        };
        if (cfg.username && cfg.username.length > 0) {
          proxy.username = cfg.username;
          proxy.password = cfg.password || '';
        }
        connection.setAppHttpProxy(proxy);
        logger.info(`app http proxy on host=${cfg.host.trim()} port=${cfg.port}`);
      } else {
        connection.setAppHttpProxy({
          host: '',
          port: 0,
          exclusionList: HttpProxyOptions.defaultExclusions()
        } as connection.HttpProxy);
        logger.info('app http proxy cleared');
      }
    } catch (e) {
      logger.warn(`setAppHttpProxy failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
}
