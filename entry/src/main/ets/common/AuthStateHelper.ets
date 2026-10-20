import { AuthSessionManager, AuthAccountStatus, YoutubeJavaScriptPlayerManager, YoutubePlayerClientConfig } from 'youtube_core';
import web_webview from '@ohos.web.webview';
import { SabrWebViewPoTokenProvider } from '../features/player/SabrWebViewPoTokenProvider';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('AuthStateHelper');

export class AuthStateHelper {
  /**
   * Credential-rail fingerprint of the last observed auth state. Only
   * presence-of-credential per rail is tracked — never credential material.
   */
  private static lastCredentialFingerprint: string = '';

  static refresh(): void {
    const session = AuthSessionManager.getInstance() ?? undefined;
    const status = session ? session.getStatus() : new AuthAccountStatus();
    AppStorage.setOrCreate('authStatus', status);
    AuthStateHelper.resetIdentityIfCredentialChanged(session);
  }

  /**
   * 登录态/鉴权开关变化后的统一后置动作：按当前有效播放鉴权重置 stream
   * client 选择（PipePipe reconcileYoutubePlayerClient：登录 → 配置的 auth
   * 端点（默认 mweb SABR），游客 → 配置的 guest 端点（默认 tv_samsung）；
   * 清除手动 pin）。启动、登录、登出、鉴权开关都必须走这里，
   * 不要在调用点散落 resetToAuthDefault 及其参数推导。
   */
  static reconcilePlaybackClient(): void {
    const usePlaybackAuth = AuthSessionManager.getInstance()?.isAuthEnabledForPlayback() === true;
    YoutubePlayerClientConfig.resetToAuthDefault(usePlaybackAuth);
    logger.info(`playback client reconciled state=${usePlaybackAuth ? 'auth' : 'guest'} `
      + `client=${YoutubePlayerClientConfig.getYoutubePlayerClient()}`);
  }

  /**
   * 播放端点设置变更（Options → 播放端点）的统一后置动作：更新 per-state
   * 配置并按当前鉴权态重选端点；身份 pin 与全部 pot 缓存随端点失效（visitor
   * 绑定缓存不跨端点复用）。恢复默认设置也走这里。调用点负责清 prefetch 缓存
   * 与处理进行中的播放。
   */
  static applyPlayerClientConfig(guestClient: string, authClient: string): void {
    YoutubePlayerClientConfig.setConfiguredClients(guestClient, authClient);
    AuthStateHelper.reconcilePlaybackClient();
    YoutubeJavaScriptPlayerManager.resetSessionVisitorData();
    SabrWebViewPoTokenProvider.getInstance().resetForAuthChange();
    // The reset drops the warm flag; re-warm in the background so the next
    // play does not pay the cold BotGuard bootstrap on the /player path.
    SabrWebViewPoTokenProvider.getInstance().warmRuntime();
    logger.info(`player client config applied guest=${guestClient} auth=${authClient} `
      + `active=${YoutubePlayerClientConfig.getYoutubePlayerClient()}`);
  }

  /**
   * PipePipe LocalDomPoTokenProvider credential-bound cache isolation: tokens
   * and the pinned visitor identity belong to the credential state they were
   * minted under. On login/logout/rail change, drop the identity pin and all
   * cached PoTokens so the next extraction re-pins under fresh credentials.
   */
  private static resetIdentityIfCredentialChanged(session?: AuthSessionManager): void {
    const fingerprint = AuthStateHelper.credentialFingerprint(session);
    const previous = AuthStateHelper.lastCredentialFingerprint;
    AuthStateHelper.lastCredentialFingerprint = fingerprint;
    // First observation (app startup): nothing pinned yet in this process.
    if (previous.length === 0 || previous === fingerprint) {
      return;
    }
    logger.info(`auth credential rail changed (${previous} → ${fingerprint}); resetting session identity + pot caches`);
    YoutubeJavaScriptPlayerManager.resetSessionVisitorData();
    SabrWebViewPoTokenProvider.getInstance().resetForAuthChange();
    // Re-warm against the new credential state in the background.
    SabrWebViewPoTokenProvider.getInstance().warmRuntime();
  }

  /**
   * Drop the ArkWeb cookie store. The login page detects an existing session
   * from WebCookieManager; leaving the previous account's cookies behind makes
   * a post-sign-out login silently reuse that account (and re-save it).
   * The PoToken runtime is a loadData page in the same store — it re-bootstraps
   * on the next mint, which is exactly what the caller's warmRuntime does.
   */
  static clearWebViewCookies(reason: string): void {
    try {
      web_webview.WebCookieManager.clearAllCookiesSync();
      web_webview.WebCookieManager.clearSessionCookieSync();
      logger.info(`webview cookies cleared reason=${reason}`);
    } catch (e) {
      logger.warn(`clearWebViewCookies failed reason=${reason}: ${String(e)}`);
    }
  }

  private static credentialFingerprint(session?: AuthSessionManager): string {
    if (!session) {
      return 'none';
    }
    const web = session.hasWebSapisidStored();
    const oauth = session.hasOauthCredentialStored();
    if (web && oauth) {
      return 'both';
    }
    if (web) {
      return 'web';
    }
    if (oauth) {
      return 'oauth';
    }
    return 'none';
  }
}
