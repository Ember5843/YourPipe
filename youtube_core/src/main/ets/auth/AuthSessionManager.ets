import { preferences } from '@kit.ArkData';
import { YTCoreLogger } from '../common/YTCoreLogger';
import { AuthAccountStatus, AuthStage, AuthTokenResponse } from './AuthModels';
import { SmartTubeAuthProbe } from './SmartTubeAuthProbe';
import { CookieAuthCredential } from './CookieAuthCredential';
import { SapisidHashUtil } from './SapisidHashUtil';

const logger = YTCoreLogger.getInstance('AuthSessionManager');

export class AuthSessionManager {
  private static instance: AuthSessionManager | null = null;
  private static readonly STORAGE_NAME: string = 'yourpipe_auth_poc';
  private static readonly REFRESH_TOKEN_KEY: string = 'refresh_token';
  private static readonly COOKIE_CREDENTIAL_KEY: string = 'cookie_auth_credential';
  private static readonly REFRESH_MARGIN_MS: number = 60000;

  private context: Context;
  private probe: SmartTubeAuthProbe = new SmartTubeAuthProbe();
  private refreshToken: string = '';
  private accessToken: string = '';
  private accessTokenExpiresAt: number = 0;
  private cookieCredential: CookieAuthCredential | null = null;

  private constructor(context: Context) {
    this.context = context;
  }

  static init(context: Context): AuthSessionManager {
    if (!AuthSessionManager.instance) {
      AuthSessionManager.instance = new AuthSessionManager(context);
    }
    AuthSessionManager.instance.context = context;
    AuthSessionManager.instance.load();
    return AuthSessionManager.instance;
  }

  static getInstance(): AuthSessionManager | null {
    return AuthSessionManager.instance;
  }

  getStatus(): AuthAccountStatus {
    const status = new AuthAccountStatus();
    if (this.cookieCredential && this.cookieCredential.cookies.length > 0) {
      status.stage = AuthStage.SIGNED_IN;
      status.authMode = 'cookie';
      status.hasCookieCredential = true;
    } else if (this.refreshToken.length > 0) {
      status.stage = AuthStage.SIGNED_IN;
      status.authMode = 'oauth';
      status.hasRefreshToken = true;
      status.accessTokenExpiresAt = this.accessTokenExpiresAt;
    } else {
      status.authMode = 'none';
    }
    return status;
  }

  isSignedIn(): boolean {
    if (this.cookieCredential && this.cookieCredential.cookies.length > 0) {
      return true;
    }
    return this.refreshToken.length > 0;
  }

  async getAuthorizationHeader(): Promise<string | undefined> {
    if (this.cookieCredential && this.cookieCredential.sapiSid.length > 0) {
      return await SapisidHashUtil.generate(this.cookieCredential.sapiSid);
    }
    if (!this.refreshToken) {
      return undefined;
    }
    if (!this.accessToken || Date.now() + AuthSessionManager.REFRESH_MARGIN_MS >= this.accessTokenExpiresAt) {
      await this.refreshAccessToken();
    }
    return this.accessToken ? `Bearer ${this.accessToken}` : undefined;
  }

  async refreshAccessToken(): Promise<AuthAccountStatus> {
    if (!this.refreshToken) {
      return this.getStatus();
    }

    try {
      const token = await this.probe.refreshAccessToken(this.refreshToken);
      if (token.error.length > 0) {
        logger.warn(`Refresh failed with code: ${token.error}`);
        const status = this.getStatus();
        status.stage = AuthStage.FAILED;
        status.lastErrorCode = token.error;
        status.lastError = this.toUserMessage(token.error);
        return status;
      }
      this.applyToken(token);
      logger.info('Access token refreshed');
      return this.getStatus();
    } catch (e) {
      logger.error('Refresh failed');
      const status = this.getStatus();
      status.stage = AuthStage.FAILED;
      status.lastError = '网络错误，无法刷新 token';
      return status;
    }
  }

  saveToken(token: AuthTokenResponse): AuthAccountStatus {
    this.applyToken(token);
    this.persistRefreshToken();
    logger.info('POC token saved');
    return this.getStatus();
  }

  signOut(): AuthAccountStatus {
    this.refreshToken = '';
    this.accessToken = '';
    this.accessTokenExpiresAt = 0;
    this.cookieCredential = null;
    this.persistRefreshToken();
    this.persistCookieCredential();
    logger.info('Signed out');
    return this.getStatus();
  }

  getCookieString(): string | undefined {
    if (this.cookieCredential && this.cookieCredential.cookies.length > 0) {
      return this.cookieCredential.cookies;
    }
    return undefined;
  }

  getPotToken(): string | undefined {
    if (this.cookieCredential && this.cookieCredential.potToken.length > 0) {
      return this.cookieCredential.potToken;
    }
    return undefined;
  }

  saveCookieCredential(credential: CookieAuthCredential): AuthAccountStatus {
    this.cookieCredential = credential;
    this.persistCookieCredential();
    logger.info('Cookie credential saved');
    return this.getStatus();
  }

  private applyToken(token: AuthTokenResponse): void {
    if (token.refreshToken.length > 0) {
      this.refreshToken = token.refreshToken;
    }
    if (token.accessToken.length > 0) {
      this.accessToken = token.accessToken;
      const expiresInMs = Math.max(token.expiresIn, 0) * 1000;
      this.accessTokenExpiresAt = Date.now() + expiresInMs;
    }
  }

  private load(): void {
    try {
      const storage = preferences.getPreferencesSync(this.context, { name: AuthSessionManager.STORAGE_NAME });
      this.refreshToken = storage.getSync(AuthSessionManager.REFRESH_TOKEN_KEY, '') as string;
      if (this.refreshToken.length > 0) {
        logger.info('POC refresh token loaded');
      }
      const credentialJson = storage.getSync(AuthSessionManager.COOKIE_CREDENTIAL_KEY, '') as string;
      if (credentialJson.length > 0) {
        this.cookieCredential = CookieAuthCredential.fromJson(credentialJson);
        if (this.cookieCredential) {
          logger.info('Cookie credential loaded');
        }
      }
    } catch (e) {
      logger.error('Failed to load auth state');
    }
  }

  private persistRefreshToken(): void {
    try {
      const storage = preferences.getPreferencesSync(this.context, { name: AuthSessionManager.STORAGE_NAME });
      storage.putSync(AuthSessionManager.REFRESH_TOKEN_KEY, this.refreshToken);
      storage.flush();
    } catch (e) {
      logger.error('Failed to persist auth state');
    }
  }

  private persistCookieCredential(): void {
    try {
      const storage = preferences.getPreferencesSync(this.context, { name: AuthSessionManager.STORAGE_NAME });
      const json = this.cookieCredential ? this.cookieCredential.toJson() : '';
      storage.putSync(AuthSessionManager.COOKIE_CREDENTIAL_KEY, json);
      storage.flush();
    } catch (e) {
      logger.error('Failed to persist cookie credential');
    }
  }

  private toUserMessage(code: string): string {
    switch (code) {
      case 'invalid_grant':
        return '登录状态已失效，请重新登录';
      case 'expired_token':
        return '设备码已过期，请重新开始登录';
      default:
        return `登录失败：${code}`;
    }
  }
}
