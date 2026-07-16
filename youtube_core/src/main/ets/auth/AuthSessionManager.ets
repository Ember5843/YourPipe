import { preferences } from '@kit.ArkData';
import { YTCoreLogger } from '../common/YTCoreLogger';
import { AuthAccountStatus, AuthStage, AuthTokenResponse } from './AuthModels';
import { SmartTubeAuthProbe } from './SmartTubeAuthProbe';
import { CookieAuthCredential } from './CookieAuthCredential';
import { SapisidHashUtil } from './SapisidHashUtil';

const logger = YTCoreLogger.getInstance('AuthSessionManager');

export interface AuthBackupState {
  refreshToken: string;
  accessToken: string;
  accessTokenExpiresAt: number;
  cookieCredentialJson: string;
}

export class AuthSessionManager {
  private static instance: AuthSessionManager | null = null;
  private static readonly STORAGE_NAME: string = 'yourpipe_auth_poc';
  private static readonly REFRESH_TOKEN_KEY: string = 'refresh_token';
  private static readonly COOKIE_CREDENTIAL_KEY: string = 'cookie_auth_credential';
  private static readonly AUTH_ENABLED_KEY: string = 'auth_enabled';
  private static readonly USE_AUTH_FOR_USER_DATA_KEY: string = 'use_auth_for_user_data';
  private static readonly USE_AUTH_FOR_PLAYBACK_KEY: string = 'use_auth_for_playback';
  private static readonly REFRESH_MARGIN_MS: number = 60000;

  private context: Context;
  private probe: SmartTubeAuthProbe = new SmartTubeAuthProbe();
  private refreshToken: string = '';
  private accessToken: string = '';
  private accessTokenExpiresAt: number = 0;
  private cookieCredential: CookieAuthCredential | null = null;
  /** Master switch. When false, keep credentials but do not attach auth to any request. */
  private authEnabled: boolean = true;
  /** Fine-grained: attach auth to user-data requests (feed / subscriptions / history / search). */
  private useAuthForUserData: boolean = true;
  /** Fine-grained: attach auth to playback extraction (player API + stream URL cookies). */
  private useAuthForPlayback: boolean = true;

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
    status.authEnabled = this.authEnabled;
    status.useAuthForUserData = this.useAuthForUserData;
    status.useAuthForPlayback = this.useAuthForPlayback;
    status.hasCredential = this.hasCredential();
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

  hasCredential(): boolean {
    if (this.cookieCredential && this.cookieCredential.cookies.length > 0) {
      return true;
    }
    return this.refreshToken.length > 0;
  }

  isAuthEnabled(): boolean {
    return this.authEnabled;
  }

  setAuthEnabled(enabled: boolean): AuthAccountStatus {
    this.authEnabled = enabled;
    this.persistAuthEnabled();
    logger.info(`Auth enabled set to ${enabled}`);
    return this.getStatus();
  }

  isUseAuthForUserData(): boolean {
    return this.useAuthForUserData;
  }

  setUseAuthForUserData(enabled: boolean): AuthAccountStatus {
    this.useAuthForUserData = enabled;
    this.persistUseAuthForUserData();
    logger.info(`Use auth for user data set to ${enabled}`);
    return this.getStatus();
  }

  isUseAuthForPlayback(): boolean {
    return this.useAuthForPlayback;
  }

  setUseAuthForPlayback(enabled: boolean): AuthAccountStatus {
    this.useAuthForPlayback = enabled;
    this.persistUseAuthForPlayback();
    logger.info(`Use auth for playback set to ${enabled}`);
    return this.getStatus();
  }

  /** Effective: user-data requests should attach auth. */
  isAuthEnabledForUserData(): boolean {
    return this.authEnabled && this.useAuthForUserData && this.hasCredential();
  }

  /** Effective: playback extraction should attach auth. */
  isAuthEnabledForPlayback(): boolean {
    return this.authEnabled && this.useAuthForPlayback && this.hasCredential();
  }

  /**
   * Whether requests should attach login credentials (legacy coarse signal).
   * False when private browsing is on, even if a credential is stored.
   * Prefer isAuthEnabledForUserData / isAuthEnabledForPlayback at call sites.
   */
  isSignedIn(): boolean {
    if (!this.authEnabled) {
      return false;
    }
    return this.hasCredential();
  }

  async getAuthorizationHeader(): Promise<string | undefined> {
    if (!this.authEnabled) {
      return undefined;
    }
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
    this.authEnabled = true;
    this.useAuthForUserData = true;
    this.useAuthForPlayback = true;
    this.persistRefreshToken();
    this.persistCookieCredential();
    this.persistAuthEnabled();
    this.persistUseAuthForUserData();
    this.persistUseAuthForPlayback();
    logger.info('Signed out');
    return this.getStatus();
  }

  getCookieString(): string | undefined {
    if (!this.authEnabled) {
      return undefined;
    }
    if (this.cookieCredential && this.cookieCredential.cookies.length > 0) {
      return this.cookieCredential.cookies;
    }
    return undefined;
  }

  /** Cookie string for user-data requests; respects fine-grained toggle. */
  getCookieStringForUserData(): string | undefined {
    if (!this.isAuthEnabledForUserData()) {
      return undefined;
    }
    if (this.cookieCredential && this.cookieCredential.cookies.length > 0) {
      return this.cookieCredential.cookies;
    }
    return undefined;
  }

  /** Cookie string for playback extraction; respects fine-grained toggle. */
  getCookieStringForPlayback(): string | undefined {
    if (!this.isAuthEnabledForPlayback()) {
      return undefined;
    }
    if (this.cookieCredential && this.cookieCredential.cookies.length > 0) {
      return this.cookieCredential.cookies;
    }
    return undefined;
  }

  getPotToken(): string | undefined {
    if (!this.authEnabled) {
      return undefined;
    }
    if (this.cookieCredential && this.cookieCredential.potToken.length > 0) {
      return this.cookieCredential.potToken;
    }
    return undefined;
  }

  /** PoToken for playback extraction; respects fine-grained toggle. */
  getPotTokenForPlayback(): string | undefined {
    if (!this.isAuthEnabledForPlayback()) {
      return undefined;
    }
    if (this.cookieCredential && this.cookieCredential.potToken.length > 0) {
      return this.cookieCredential.potToken;
    }
    return undefined;
  }

  saveCookieCredential(credential: CookieAuthCredential): AuthAccountStatus {
    this.cookieCredential = credential;
    this.authEnabled = true;
    this.persistCookieCredential();
    this.persistAuthEnabled();
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
      const enabledRaw = storage.getSync(AuthSessionManager.AUTH_ENABLED_KEY, 'true') as string;
      this.authEnabled = enabledRaw !== 'false';
      const userDataRaw = storage.getSync(AuthSessionManager.USE_AUTH_FOR_USER_DATA_KEY, 'true') as string;
      this.useAuthForUserData = userDataRaw !== 'false';
      const playbackRaw = storage.getSync(AuthSessionManager.USE_AUTH_FOR_PLAYBACK_KEY, 'true') as string;
      this.useAuthForPlayback = playbackRaw !== 'false';
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

  private persistAuthEnabled(): void {
    try {
      const storage = preferences.getPreferencesSync(this.context, { name: AuthSessionManager.STORAGE_NAME });
      storage.putSync(AuthSessionManager.AUTH_ENABLED_KEY, this.authEnabled ? 'true' : 'false');
      storage.flush();
    } catch (e) {
      logger.error('Failed to persist auth enabled');
    }
  }

  private persistUseAuthForUserData(): void {
    try {
      const storage = preferences.getPreferencesSync(this.context, { name: AuthSessionManager.STORAGE_NAME });
      storage.putSync(AuthSessionManager.USE_AUTH_FOR_USER_DATA_KEY, this.useAuthForUserData ? 'true' : 'false');
      storage.flush();
    } catch (e) {
      logger.error('Failed to persist useAuthForUserData');
    }
  }

  private persistUseAuthForPlayback(): void {
    try {
      const storage = preferences.getPreferencesSync(this.context, { name: AuthSessionManager.STORAGE_NAME });
      storage.putSync(AuthSessionManager.USE_AUTH_FOR_PLAYBACK_KEY, this.useAuthForPlayback ? 'true' : 'false');
      storage.flush();
    } catch (e) {
      logger.error('Failed to persist useAuthForPlayback');
    }
  }

  exportAuthState(): AuthBackupState {
    return {
      refreshToken: this.refreshToken,
      accessToken: this.accessToken,
      accessTokenExpiresAt: this.accessTokenExpiresAt,
      cookieCredentialJson: this.cookieCredential ? this.cookieCredential.toJson() : ''
    };
  }

  importAuthState(state: AuthBackupState): void {
    this.refreshToken = state.refreshToken;
    this.accessToken = state.accessToken;
    this.accessTokenExpiresAt = state.accessTokenExpiresAt;
    this.cookieCredential = state.cookieCredentialJson.length > 0
      ? CookieAuthCredential.fromJson(state.cookieCredentialJson)
      : null;
    this.persistRefreshToken();
    this.persistCookieCredential();
    logger.info('Auth state imported');
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
