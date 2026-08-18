import { AuthSessionManager, AuthAccountStatus, YoutubeJavaScriptPlayerManager, YoutubePlayerClientConfig } from 'youtube_core';
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
   * client 选择（PipePipe reconcileYoutubePlayerClient：登录 → tv_downgraded，
   * 游客 → visionos；清除手动 pin）。启动、登录、登出、鉴权开关都必须走这里，
   * 不要在调用点散落 resetToAuthDefault 及其参数推导。
   */
  static reconcilePlaybackClient(): void {
    const usePlaybackAuth = AuthSessionManager.getInstance()?.isAuthEnabledForPlayback() === true;
    YoutubePlayerClientConfig.resetToAuthDefault(usePlaybackAuth);
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
