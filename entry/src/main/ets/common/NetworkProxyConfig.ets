import { connection } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import {
  AppHttpProxySnapshot,
  AppProxyKind,
  HttpProxyOptions,
  socks5Bridge
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
    if (!this.enabled) {
      return {
        kind: 'none',
        host: '',
        port: 0,
        username: '',
        password: '',
        exclusionList: exclusions
      };
    }
    if (this.kind === 'socks5') {
      const bridgePort = socks5Bridge.getPort();
      return {
        kind: 'socks5',
        host: (this.host || '').trim(),
        port: this.port,
        username: this.username || '',
        password: this.password || '',
        exclusionList: exclusions,
        socks5LocalPort: bridgePort > 0 ? bridgePort : undefined
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
    const host = (this.host || '').trim();
    if (!host || this.port <= 0) {
      return $r('app.string.yt_proxy_incomplete');
    }
    return `${host}:${this.port}`;
  }

  isReady(): boolean {
    return this.enabled
      && (this.kind === 'http' || this.kind === 'socks5')
      && (this.host || '').trim().length > 0
      && this.port > 0
      && this.port <= 65535;
  }

  /**
   * Route all WebView traffic through the app proxy (ProxyController, API 15+).
   * Chromium honors neither setAppHttpProxy nor the http module's usingProxy, so
   * the login page / PoToken runtime were going direct while app HTTP requests
   * used the proxy — inconsistent egress IP. Default implicit rules keep
   * localhost / local-IP hosts direct, so the PoToken local DOM is unaffected.
   */
  private static applyWebViewProxy(proxyUrl: string): void {
    try {
      const config = new webview.ProxyConfig();
      config.insertProxyRule(proxyUrl, webview.ProxySchemeFilter.MATCH_ALL_SCHEMES);
      config.insertDirectRule(webview.ProxySchemeFilter.MATCH_HTTP);
      config.insertDirectRule(webview.ProxySchemeFilter.MATCH_HTTPS);
      webview.ProxyController.applyProxyOverride(config, () => {
        logger.info('webview proxy override applied');
      });
    } catch (e) {
      logger.warn(`applyProxyOverride failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private static removeWebViewProxy(): void {
    try {
      webview.ProxyController.removeProxyOverride(() => {
        logger.info('webview proxy override removed');
      });
    } catch (e) {
      logger.warn(`removeProxyOverride failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  /**
   * Wire HttpProxyOptions provider + optional app-level HTTP proxy + WebView
   * proxy override. Call after load and after every settings change.
   * SOCKS5 starts a loopback HTTP CONNECT bridge (youtube_core Socks5Bridge);
   * the app-level system proxy stays HTTP-only and is used for kind==='http'.
   */
  static applySystemAndProviders(cfg: NetworkProxyConfig): void {
    if (cfg.isReady() && cfg.kind === 'socks5') {
      NetworkProxyConfig.removeWebViewProxy();
      socks5Bridge.start(cfg.host.trim(), cfg.port, cfg.username || '', cfg.password || '')
        .then((ok: boolean) => {
          const port = socks5Bridge.getPort();
          logger.info(`socks5 bridge start ok=${ok} localPort=${port}`);
          if (ok && port > 0) {
            NetworkProxyConfig.applyWebViewProxy(`http://127.0.0.1:${port}`);
          }
        })
        .catch((e: Error) => {
          logger.warn(`socks5 bridge start failed: ${e.message}`);
        });
    } else if (cfg.isReady() && cfg.kind === 'http') {
      socks5Bridge.stop();
      const auth = cfg.username && cfg.username.length > 0
        ? `${encodeURIComponent(cfg.username)}:${encodeURIComponent(cfg.password || '')}@`
        : '';
      NetworkProxyConfig.applyWebViewProxy(`http://${auth}${cfg.host.trim()}:${cfg.port}`);
    } else {
      socks5Bridge.stop();
      NetworkProxyConfig.removeWebViewProxy();
    }

    HttpProxyOptions.setProvider((): AppHttpProxySnapshot => cfg.toSnapshot());

    try {
      if (cfg.isReady() && cfg.kind === 'http') {
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
