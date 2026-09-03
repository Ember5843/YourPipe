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
    NetworkProxyConfig.applySystemAndProviders(cfg)
      .catch((e: Error) => logger.warn(`resetToDefault apply proxy failed: ${e.message}`));
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
   * used the proxy — inconsistent egress IP. No direct fallback rules are
   * installed for HTTP/HTTPS: insertDirectRule(MATCH_HTTP/HTTPS) would make
   * Chromium silently fall back to a direct connection whenever the proxy is
   * unavailable, which is exactly the leak a proxy user wants to avoid. The
   * implicit rules stay — localhost / local-IP hosts remain direct, so the
   * PoToken local DOM is unaffected.
   */
  private static applyWebViewProxy(proxyUrl: string): void {
    try {
      const config = new webview.ProxyConfig();
      config.insertProxyRule(proxyUrl, webview.ProxySchemeFilter.MATCH_ALL_SCHEMES);
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

  private static setAppProxy(proxy: connection.HttpProxy, logMessage: string): void {
    try {
      connection.setAppHttpProxy(proxy);
      logger.info(logMessage);
    } catch (e) {
      logger.warn(`setAppHttpProxy failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private static clearAppProxy(): void {
    NetworkProxyConfig.setAppProxy({
      host: '',
      port: 0,
      exclusionList: HttpProxyOptions.defaultExclusions()
    } as connection.HttpProxy, 'app http proxy cleared');
  }

  /** Promise of the latest applySystemAndProviders run (never rejects). */
  private static applyPromise: Promise<void> = Promise.resolve();

  /** Latest config that finished applyInternal — used by the bridge port-change listener. */
  private static lastAppliedCfg?: NetworkProxyConfig;

  /** Guard against double registration of the single-slot bridge listeners. */
  private static bridgeListenersRegistered: boolean = false;

  /**
   * 桥自愈换端口后的额外动作（单槽）。PlayerSession 注册它来刷新 MPV 的
   * http_proxy 进程 env——env 只在 load() 时写入，不随 provider 快照惰性更新，
   * 不刷新会让进行中的直播直连抓取继续打死掉的旧端口。
   */
  private static bridgeRepointListener?: () => void;

  static setBridgeRepointListener(listener?: () => void): void {
    NetworkProxyConfig.bridgeRepointListener = listener;
  }

  /**
   * Resolves when the latest applySystemAndProviders has fully settled —
   * for socks5 that includes the loopback bridge listen. Startup network work
   * (home feed, proxy test) should await this so it never runs in the bridge's
   * async startup window (which would go direct).
   */
  static awaitReady(): Promise<void> {
    return NetworkProxyConfig.applyPromise;
  }

  /**
   * Wire HttpProxyOptions provider + app-level HTTP proxy + WebView proxy
   * override. Call after load and after every settings change. The returned
   * promise never rejects; it settles once the configuration is fully applied
   * (for socks5: after the bridge started or failed).
   *
   * SOCKS5 starts a loopback HTTP CONNECT bridge (youtube_core Socks5Bridge);
   * only after the bridge is listening do we point the WebView override and the
   * app-level proxy at 127.0.0.1:{bridgePort} — the app-level proxy lets paths
   * that share the netstack default (notably ArkUI Image thumbnails) ride the
   * bridge too. Official docs do not state explicitly that Image honors the
   * app proxy; the setting is applied best-effort. On bridge failure/stop the
   * app proxy is cleared (no silent direct half-configured state).
   * The app-level system proxy stays HTTP-only and carries the user proxy
   * directly for kind==='http'.
   */
  static applySystemAndProviders(cfg: NetworkProxyConfig): Promise<void> {
    NetworkProxyConfig.ensureBridgeListeners();
    // Serialize applies (promise-chain mutex): each new apply chains onto the
    // previous tail, so two applies can never interleave (e.g. a socks5 apply
    // awaiting bridge start racing a user switch to http). The last requested
    // config always lands last. awaitReady() returns the tail as of call time,
    // so waiters resolve once the latest requested apply settles — they are not
    // stuck behind applies requested after their awaitReady() call.
    const tail: Promise<void> = NetworkProxyConfig.applyPromise;
    const p: Promise<void> = tail
      .catch((e: Error) => logger.warn(`previous proxy apply failed: ${e.message}`))
      .then(() => NetworkProxyConfig.applyInternal(cfg));
    NetworkProxyConfig.applyPromise = p;
    return p;
  }

  /**
   * Register the single-slot socks5Bridge listeners exactly once. Port change:
   * a self-heal re-listen lands on a NEW ephemeral port, so the app-level proxy
   * and the ArkWeb override (pointed at the old port by applyInternal) must be
   * re-pointed — only those two pieces, never a full re-apply (that would
   * restart the bridge). Fuse blown: log an ERROR and surface a toast; no
   * auto-restart — a user re-save re-applies the config and resets the fuse.
   */
  private static ensureBridgeListeners(): void {
    if (NetworkProxyConfig.bridgeListenersRegistered) {
      return;
    }
    NetworkProxyConfig.bridgeListenersRegistered = true;
    socks5Bridge.setPortChangeListener((port: number) => NetworkProxyConfig.onBridgePortChanged(port));
    socks5Bridge.setFailureListener((reason: string) => NetworkProxyConfig.onBridgeFuseBlown(reason));
  }

  private static onBridgePortChanged(port: number): void {
    const cfg = NetworkProxyConfig.lastAppliedCfg;
    if (!cfg || !cfg.isReady() || cfg.kind !== 'socks5' || !socks5Bridge.isRunning()) {
      logger.warn(`socks5 bridge port change to ${port} ignored (socks5 no longer the active config)`);
      return;
    }
    logger.info(`socks5 bridge re-listened on new port=${port}, re-pointing app/webview proxy`);
    // HttpProxyOptions needs no update: the installed provider reads
    // socks5Bridge.getPort() lazily per snapshot, so downloaders/RangeProxy
    // follow the new port on their own. MPV's process env was written at
    // load() and must be re-applied explicitly via the repoint listener.
    NetworkProxyConfig.applyWebViewProxy(`http://127.0.0.1:${port}`);
    NetworkProxyConfig.setAppProxy({
      host: '127.0.0.1',
      port: port,
      exclusionList: HttpProxyOptions.defaultExclusions()
    } as connection.HttpProxy, `app http proxy re-applied on socks5 bridge port=${port}`);
    const repointListener = NetworkProxyConfig.bridgeRepointListener;
    if (repointListener) {
      try {
        repointListener();
      } catch (e) {
        logger.warn(`bridge repoint listener failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
  }

  private static onBridgeFuseBlown(reason: string): void {
    logger.error(`socks5 bridge fuse blown, proxy unavailable until settings are re-applied: ${reason}`);
    NetworkProxyConfig.showToast($r('app.string.yt_proxy_bridge_unavailable'));
  }

  private static showToast(message: ResourceStr): void {
    try {
      const uiContext = AppStorage.get<UIContext>('uiContext');
      if (!uiContext) {
        logger.warn('proxy notice toast skipped, missing uiContext');
        return;
      }
      uiContext.getPromptAction().showToast({ message, duration: 3000 });
    } catch (e) {
      logger.warn(`proxy notice toast failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private static async applyInternal(cfg: NetworkProxyConfig): Promise<void> {
    if (cfg.isReady() && cfg.kind === 'socks5') {
      NetworkProxyConfig.removeWebViewProxy();
      const ok: boolean = await socks5Bridge.start(cfg.host.trim(), cfg.port, cfg.username || '', cfg.password || '')
        .catch((e: Error) => {
          logger.warn(`socks5 bridge start failed: ${e.message}`);
          return false;
        });
      const port = socks5Bridge.getPort();
      logger.info(`socks5 bridge start ok=${ok} localPort=${port}`);
      if (ok && port > 0) {
        NetworkProxyConfig.applyWebViewProxy(`http://127.0.0.1:${port}`);
        NetworkProxyConfig.setAppProxy({
          host: '127.0.0.1',
          port: port,
          exclusionList: HttpProxyOptions.defaultExclusions()
        } as connection.HttpProxy, `app http proxy on socks5 bridge port=${port}`);
      } else {
        NetworkProxyConfig.clearAppProxy();
      }
    } else if (cfg.isReady() && cfg.kind === 'http') {
      socks5Bridge.stop();
      const auth = cfg.username && cfg.username.length > 0
        ? `${encodeURIComponent(cfg.username)}:${encodeURIComponent(cfg.password || '')}@`
        : '';
      NetworkProxyConfig.applyWebViewProxy(`http://${auth}${cfg.host.trim()}:${cfg.port}`);
      const proxy: connection.HttpProxy = {
        host: cfg.host.trim(),
        port: cfg.port,
        exclusionList: HttpProxyOptions.defaultExclusions()
      };
      if (cfg.username && cfg.username.length > 0) {
        proxy.username = cfg.username;
        proxy.password = cfg.password || '';
      }
      NetworkProxyConfig.setAppProxy(proxy, `app http proxy on host=${cfg.host.trim()} port=${cfg.port}`);
    } else {
      socks5Bridge.stop();
      NetworkProxyConfig.removeWebViewProxy();
      NetworkProxyConfig.clearAppProxy();
    }

    HttpProxyOptions.setProvider((): AppHttpProxySnapshot => cfg.toSnapshot());
    NetworkProxyConfig.lastAppliedCfg = cfg;
  }
}
