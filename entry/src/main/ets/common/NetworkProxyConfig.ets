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
/**
 * 代理连接状态（设置页常驻显示）。用 @Observed 挂在 AppStorage 上，
 * 桥接熔断 / 换端口 / apply 结果都能实时反映到 UI。
 */
@Observed
export class NetworkProxyStatus {
  /** 配置是否启用。 */
  enabled: boolean = false;
  /** 走本地桥接时的端口（0 = 未走桥接，或桥接没起来）。 */
  bridgePort: number = 0;
  /** 桥接是否在监听。 */
  bridgeRunning: boolean = false;
  /** 桥接熔断：自愈失败，必须重新应用配置才能恢复。 */
  bridgeFuseBlown: boolean = false;
  /** 最近一次 apply 的结果。 */
  lastApplyOk: boolean = true;
  lastApplyError: string = '';
  lastApplyAtMs: number = 0;
  /** 最近一次连接测试的结果（时间戳 0 = 没测过）。 */
  lastTestOk: boolean = false;
  lastTestAtMs: number = 0;
  lastTestMessage: string = '';
}

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

  /** AppStorage 上的状态镜像（单例，设置页 @StorageLink 订阅）。 */
  private static readonly statusInstance: NetworkProxyStatus = new NetworkProxyStatus();
  static readonly STATUS_KEY: string = 'networkProxyStatus';

  /** 当前代理状态快照（不改动 UI 镜像）。 */
  static getStatus(): NetworkProxyStatus {
    const cfg = NetworkProxyConfig.lastAppliedCfg;
    const status = NetworkProxyConfig.statusInstance;
    status.enabled = cfg ? cfg.enabled : false;
    status.bridgePort = socks5Bridge.getPort();
    status.bridgeRunning = socks5Bridge.isRunning();
    status.bridgeFuseBlown = socks5Bridge.isFuseBlown();
    return status;
  }

  /** 把状态镜像挂到 AppStorage（首次调用时创建，之后原地更新）。 */
  static ensureStatusMirror(): NetworkProxyStatus {
    const existing = AppStorage.get<NetworkProxyStatus>(NetworkProxyConfig.STATUS_KEY);
    if (existing) {
      return existing;
    }
    AppStorage.setOrCreate(NetworkProxyConfig.STATUS_KEY, NetworkProxyConfig.statusInstance);
    return NetworkProxyConfig.statusInstance;
  }

  /** 刷新状态镜像（apply 结束 / 桥接事件 / 测试结束后调用）。 */
  static publishStatus(): NetworkProxyStatus {
    const status = NetworkProxyConfig.ensureStatusMirror();
    NetworkProxyConfig.getStatus();
    return status;
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
   * 代理落地后的 MPV env 刷新钩子（单槽）。PlayerSession 注册它来重刷 MPV 的
   * http_proxy 进程 env——env 只在 load() 时写入，不随 provider 快照惰性更新。
   * 两个触发点：桥自愈换端口（onBridgePortChanged，仅 socks5——http+认证的
   * MPV env 内嵌真实上游，与桥端口无关），以及每次 applyInternal 完成
   * （fireRepointListener），覆盖播放中改 host/认证/类型/关闭代理的场景。
   */
  private static bridgeRepointListener?: () => void;

  static setBridgeRepointListener(listener?: () => void): void {
    NetworkProxyConfig.bridgeRepointListener = listener;
  }

  private static fireRepointListener(): void {
    const repointListener = NetworkProxyConfig.bridgeRepointListener;
    if (repointListener) {
      try {
        repointListener();
      } catch (e) {
        logger.warn(`bridge repoint listener failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
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
   * directly for unauthenticated kind==='http'. HTTP with credentials starts
   * the same bridge in HTTP-upstream mode and points BOTH the WebView override
   * and the app-level proxy at 127.0.0.1:{bridgePort} (insertProxyRule does
   * not accept userinfo, and the ArkUI Image fetcher does not answer proxy 407
   * challenges — the bridge's loopback side is auth-free, so thumbnails work);
   * only the netstack request snapshot (HttpProxyOptions) keeps the native
   * credentialed fields. A bridge start failure removes the WebView override
   * and clears the app proxy — fail visible, never silent direct.
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
   * Register the single-slot socks5Bridge listeners exactly once (the bridge
   * serves both socks5 and credentialed-http configs). Port change:
   * a self-heal re-listen lands on a NEW ephemeral port, so the ArkWeb override
   * and the app-level proxy (both pointed at the old port by applyInternal)
   * must be re-pointed. Never a full re-apply (that would
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

  /** 当前配置是否经 loopback 桥 egress（socks5，或带用户名认证的 http）。 */
  private static cfgUsesBridge(cfg: NetworkProxyConfig): boolean {
    return cfg.kind === 'socks5' || (cfg.kind === 'http' && (cfg.username || '').length > 0);
  }

  private static onBridgePortChanged(port: number): void {
    const cfg = NetworkProxyConfig.lastAppliedCfg;
    if (!cfg || !cfg.isReady() || !NetworkProxyConfig.cfgUsesBridge(cfg) || !socks5Bridge.isRunning()) {
      logger.warn(`bridge port change to ${port} ignored (bridge no longer the active config)`);
      return;
    }
    logger.info(`bridge re-listened on new port=${port}, re-pointing webview/app proxy`);
    // HttpProxyOptions needs no update: the installed provider reads
    // socks5Bridge.getPort() lazily per snapshot, so downloaders/RangeProxy
    // follow the new port on their own.
    NetworkProxyConfig.applyWebViewProxy(`http://127.0.0.1:${port}`);
    // Both bridge-backed modes point the app-level proxy at the bridge, so it
    // must follow the new port. (For credentialed http this is what lets ArkUI
    // Image thumbnails work — the Image fetcher does not answer proxy 407
    // challenges, while the loopback side of the bridge is auth-free.)
    NetworkProxyConfig.setAppProxy({
      host: '127.0.0.1',
      port: port,
      exclusionList: HttpProxyOptions.defaultExclusions()
    } as connection.HttpProxy, `app http proxy re-applied on bridge port=${port}`);
    if (cfg.kind === 'socks5') {
      // MPV's process env was written at load() pointing at the bridge and must
      // be re-applied explicitly. Credentialed-http MPV env embeds the real
      // upstream with userinfo instead, so it does not depend on the port.
      NetworkProxyConfig.fireRepointListener();
    }
  }

  private static onBridgeFuseBlown(reason: string): void {
    logger.error(`socks5 bridge fuse blown, proxy unavailable until settings are re-applied: ${reason}`);
    const status = NetworkProxyConfig.publishStatus();
    status.lastApplyOk = false;
    status.lastApplyError = reason;
    status.lastApplyAtMs = Date.now();
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
      if (cfg.username && cfg.username.length > 0) {
        // ArkWeb insertProxyRule 只支持 [scheme://]host[:port]，不接受 userinfo；
        // ArkUI Image 的 fetcher 同样不会应答代理 407 质询。带认证时 WebView
        // override 和 app 级代理都指向 loopback 桥（桥向上游注入 Basic 认证，
        // 127.0.0.1 侧免认证），netstack 请求快照（HttpProxyOptions）保持原生
        // 带凭据字段，不随桥走。
        NetworkProxyConfig.removeWebViewProxy();
        const ok: boolean = await socks5Bridge.start(cfg.host.trim(), cfg.port, cfg.username, cfg.password || '', 'http')
          .catch((e: Error) => {
            logger.warn(`http proxy bridge start failed: ${e.message}`);
            return false;
          });
        const bridgePort = socks5Bridge.getPort();
        logger.info(`http proxy bridge start ok=${ok} localPort=${bridgePort}`);
        if (ok && bridgePort > 0) {
          NetworkProxyConfig.applyWebViewProxy(`http://127.0.0.1:${bridgePort}`);
          NetworkProxyConfig.setAppProxy({
            host: '127.0.0.1',
            port: bridgePort,
            exclusionList: HttpProxyOptions.defaultExclusions()
          } as connection.HttpProxy, `app http proxy on http-auth bridge port=${bridgePort}`);
        } else {
          // 桥不可用时不留指向死端口的 override，也不装 direct 规则——WebView
          // 明确失败，绝不静默直连。app 级代理同样清掉（与 socks5 失败路径一致）。
          NetworkProxyConfig.removeWebViewProxy();
          NetworkProxyConfig.clearAppProxy();
          logger.error('http proxy bridge unavailable; WebView override and app proxy removed (no silent direct fallback)');
        }
      } else {
        socks5Bridge.stop();
        NetworkProxyConfig.applyWebViewProxy(`http://${cfg.host.trim()}:${cfg.port}`);
        const proxy: connection.HttpProxy = {
          host: cfg.host.trim(),
          port: cfg.port,
          exclusionList: HttpProxyOptions.defaultExclusions()
        };
        NetworkProxyConfig.setAppProxy(proxy, `app http proxy on host=${cfg.host.trim()} port=${cfg.port}`);
      }
    } else {
      socks5Bridge.stop();
      NetworkProxyConfig.removeWebViewProxy();
      NetworkProxyConfig.clearAppProxy();
    }

    HttpProxyOptions.setProvider((): AppHttpProxySnapshot => cfg.toSnapshot());
    NetworkProxyConfig.lastAppliedCfg = cfg;
    // MPV 的 http_proxy 进程 env 只在 load() 写入：配置落地后立刻为当前源重刷，
    // 否则播放中的直连抓取（直播 HLS）会继续用旧代理直到下一次 load。
    // 无加载源时 refreshNetworkProxy 自身 no-op。
    NetworkProxyConfig.fireRepointListener();
    const status = NetworkProxyConfig.publishStatus();
    status.lastApplyOk = true;
    status.lastApplyError = '';
    status.lastApplyAtMs = Date.now();
  }

  /**
   * 记录一次连接测试结果（设置页「测试连接」按钮调用）。
   * 只更新状态镜像，不改代理配置。
   */
  static recordTestResult(ok: boolean): void {
    const status = NetworkProxyConfig.publishStatus();
    status.lastTestOk = ok;
    status.lastTestAtMs = Date.now();
  }
}
