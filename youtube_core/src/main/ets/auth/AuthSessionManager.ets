import { preferences } from '@kit.ArkData';
import { YTCoreLogger } from '../common/YTCoreLogger';
import { AuthAccountStatus, AuthStage, AuthTokenResponse } from './AuthModels';
import { SmartTubeAuthProbe } from './SmartTubeAuthProbe';
import { CookieAuthCredential } from './CookieAuthCredential';
import { SapisidHashUtil } from './SapisidHashUtil';
import { HttpDownloader } from '../network/HttpDownloader';

const logger = YTCoreLogger.getInstance('AuthSessionManager');

export interface AuthBackupState {
  refreshToken: string;
  accessToken: string;
  accessTokenExpiresAt: number;
  cookieCredentialJson: string;
}

/** 鉴权持久化 preferences 存储名（"清除所有数据"需要按此名擦除，entry 侧经 Index 导出引用）。 */
export const AUTH_STORAGE_NAME = 'yourpipe_auth_poc';

/** 登录态/凭据变更监听（单槽；entry 在 init 后接线到 AuthStateHelper.refresh）。 */
export type AuthStateChangeListener = () => void;

export class AuthSessionManager {
  private static instance: AuthSessionManager | null = null;
  private static readonly STORAGE_NAME: string = AUTH_STORAGE_NAME;
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

  /** In-flight TV access-token refresh; concurrent callers share one refresh
   * so refresh-token rotation cannot invalidate a later concurrent request. */
  private refreshPromise: Promise<AuthAccountStatus> | undefined = undefined;

  /** Device / QR OAuth (SmartTube-style) in-flight state. */
  private deviceFlowActive: boolean = false;
  private deviceCode: string = '';
  private deviceUserCode: string = '';
  private deviceVerificationUrl: string = 'https://yt.be/activate';
  private deviceExpiresAt: number = 0;
  private devicePollIntervalMs: number = 5000;
  private devicePollGeneration: number = 0;
  private deviceLastError: string = '';
  private deviceLastErrorCode: string = '';
  private deviceStage: AuthStage = AuthStage.SIGNED_OUT;

  /** 账号 cookie 白名单：仅这些 Set-Cookie 会合并进 cookieCredential。 */
  private static readonly ACCOUNT_COOKIE_NAMES: string[] = [
    'SID', 'HSID', 'SSID', 'APISID', 'SAPISID',
    '__Secure-1PAPISID', '__Secure-3PAPISID',
    '__Secure-1PSID', '__Secure-3PSID',
    'LOGIN_INFO',
    'SIDCC', '__Secure-1PSIDCC', '__Secure-3PSIDCC'
  ];
  /** 服务端清除这些 cookie 视为登录态失效。 */
  private static readonly AUTH_CLEAR_COOKIE_NAMES: string[] = [
    'SID', 'SAPISID', '__Secure-1PAPISID', '__Secure-3PAPISID', 'LOGIN_INFO'
  ];

  /** 登录态被拒的一次性提示标记（由 entry 首页消费并清除）。 */
  private authRejectionNoticePending: boolean = false;

  private constructor(context: Context) {
    this.context = context;
  }

  static init(context: Context): AuthSessionManager {
    if (!AuthSessionManager.instance) {
      AuthSessionManager.instance = new AuthSessionManager(context);
    }
    AuthSessionManager.instance.context = context;
    AuthSessionManager.instance.load();
    HttpDownloader.setSetCookieObserver((sc: string | string[], url: string) => {
      const mgr = AuthSessionManager.instance;
      if (!mgr) {
        return;
      }
      try {
        mgr.mergeAccountSetCookies(sc, url);
      } catch (e) {
        logger.error('Set-Cookie merge failed');
      }
    });
    return AuthSessionManager.instance;
  }

  static getInstance(): AuthSessionManager | null {
    return AuthSessionManager.instance;
  }

  private static authStateChangeListener?: AuthStateChangeListener;

  /** 注册/清除登录态变更监听（单槽，后注册覆盖先注册；同 HttpDownloader.setSetCookieObserver 风格）。 */
  static setAuthStateChangeListener(listener?: AuthStateChangeListener): void {
    AuthSessionManager.authStateChangeListener = listener;
  }

  /** 凭据状态变更 + 持久化完成后通知监听者；监听器异常不外抛。 */
  private static emitAuthStateChange(): void {
    const listener = AuthSessionManager.authStateChangeListener;
    if (!listener) {
      return;
    }
    try {
      listener();
    } catch (e) {
      logger.error('AuthStateChangeListener threw');
    }
  }

  /** 记录一次登录态被拒（不携带任何凭据值），供 UI 层提示重新登录。 */
  noteAuthRejection(rail: string, reason: string): void {
    logger.warn(`Auth rejection noticed rail=${rail} reason=${reason}`);
    this.authRejectionNoticePending = true;
  }

  /** 读取并清除登录态被拒提示标记。 */
  consumeAuthRejectionNotice(): boolean {
    const pending = this.authRejectionNoticePending;
    this.authRejectionNoticePending = false;
    return pending;
  }

  /**
   * 合并 youtube.com 响应里的账号 Set-Cookie：
   * 白名单内的正常设置 → 替换/追加进 credential.cookies 并重算 sapiSid；
   * 关键 cookie 被服务端删除（空值 / Max-Age=0 / Expires 过去时间）→ 移除并标记登录态失效。
   * 日志只记录 cookie 名称，绝不记录值。
   */
  mergeAccountSetCookies(setCookie: string | string[], requestUrl: string): void {
    if (!this.authEnabled || !this.cookieCredential) {
      return;
    }
    if (!AuthSessionManager.isYoutubeHost(requestUrl)) {
      return;
    }
    const lines: string[] = Array.isArray(setCookie) ? setCookie : [setCookie];
    const appliedNames: string[] = [];
    let touched = false;
    let cleared = false;
    for (const line of lines) {
      const semi = line.indexOf(';');
      const pair = semi >= 0 ? line.substring(0, semi) : line;
      const attrs = semi >= 0 ? line.substring(semi + 1) : '';
      const eq = pair.indexOf('=');
      if (eq < 0) {
        continue;
      }
      const name = pair.substring(0, eq).trim();
      const value = pair.substring(eq + 1).trim();
      const isDelete = value.length === 0
        || attrs.indexOf('Max-Age=0') >= 0
        || AuthSessionManager.hasPastExpiresAttr(attrs);
      if (isDelete) {
        if (AuthSessionManager.AUTH_CLEAR_COOKIE_NAMES.indexOf(name) >= 0) {
          this.cookieCredential.cookies =
            AuthSessionManager.removeCookiePair(this.cookieCredential.cookies, name);
          cleared = true;
          appliedNames.push(name);
        }
        continue;
      }
      if (AuthSessionManager.ACCOUNT_COOKIE_NAMES.indexOf(name) < 0) {
        continue;
      }
      this.cookieCredential.cookies =
        AuthSessionManager.upsertCookiePair(this.cookieCredential.cookies, name, value);
      touched = true;
      appliedNames.push(name);
    }
    if (!touched && !cleared) {
      return;
    }
    this.cookieCredential.sapiSid = CookieAuthCredential.parseSapiSid(this.cookieCredential.cookies);
    this.persistCookieCredential();
    if (cleared) {
      logger.warn(`Account cookies cleared by server names=[${appliedNames.join(',')}]`);
      this.noteAuthRejection('web', 'server-cleared');
      AuthSessionManager.emitAuthStateChange();
    } else {
      logger.info(`Account cookies updated names=[${appliedNames.join(',')}]`);
    }
  }

  /** requestUrl 的 host 必须是 youtube.com 或其子域（小写比较）。 */
  private static isYoutubeHost(requestUrl: string): boolean {
    if (!requestUrl) {
      return false;
    }
    let rest = requestUrl.toLowerCase();
    const schemeIdx = rest.indexOf('://');
    if (schemeIdx >= 0) {
      rest = rest.substring(schemeIdx + 3);
    }
    let end = rest.length;
    const slashIdx = rest.indexOf('/');
    if (slashIdx >= 0 && slashIdx < end) {
      end = slashIdx;
    }
    const portIdx = rest.indexOf(':');
    if (portIdx >= 0 && portIdx < end) {
      end = portIdx;
    }
    const host = rest.substring(0, end);
    return host === 'youtube.com' || host.endsWith('.youtube.com');
  }

  private static hasPastExpiresAttr(attrs: string): boolean {
    const lower = attrs.toLowerCase();
    const idx = lower.indexOf('expires=');
    if (idx < 0) {
      return false;
    }
    const valueStart = idx + 'expires='.length;
    const semiIdx = attrs.indexOf(';', valueStart);
    const dateStr = attrs.substring(valueStart, semiIdx >= 0 ? semiIdx : attrs.length).trim();
    const time = Date.parse(dateStr);
    return !isNaN(time) && time <= Date.now();
  }

  private static removeCookiePair(cookies: string, name: string): string {
    const parts = cookies.split(';');
    const out: string[] = [];
    for (const raw of parts) {
      const p = raw.trim();
      if (p.length === 0) {
        continue;
      }
      const eq = p.indexOf('=');
      const n = eq >= 0 ? p.substring(0, eq).trim() : p;
      if (n !== name) {
        out.push(p);
      }
    }
    return out.join('; ');
  }

  private static upsertCookiePair(cookies: string, name: string, value: string): string {
    const pair = `${name}=${value}`;
    const parts = cookies.split(';');
    const out: string[] = [];
    let replaced = false;
    for (const raw of parts) {
      const p = raw.trim();
      if (p.length === 0) {
        continue;
      }
      const eq = p.indexOf('=');
      const n = eq >= 0 ? p.substring(0, eq).trim() : p;
      if (n === name) {
        if (!replaced) {
          out.push(pair);
          replaced = true;
        }
        continue;
      }
      out.push(p);
    }
    if (!replaced) {
      out.push(pair);
    }
    return out.join('; ');
  }

  getStatus(): AuthAccountStatus {
    const status = new AuthAccountStatus();
    status.authEnabled = this.authEnabled;
    status.useAuthForUserData = this.useAuthForUserData;
    status.useAuthForPlayback = this.useAuthForPlayback;
    status.hasCredential = this.hasCredential();
    status.userCode = this.deviceUserCode;
    status.verificationUrl = this.deviceVerificationUrl;
    status.expiresAt = this.deviceExpiresAt;
    status.pollIntervalMs = this.devicePollIntervalMs;
    status.lastError = this.deviceLastError;
    status.lastErrorCode = this.deviceLastErrorCode;

    const hasCookie = this.hasWebCredentialStored();
    const hasOauth = this.hasOauthCredentialStored();
    status.hasCookieCredential = hasCookie;
    status.hasRefreshToken = hasOauth;
    status.accessTokenExpiresAt = hasOauth ? this.accessTokenExpiresAt : 0;

    if (hasCookie && hasOauth) {
      status.stage = AuthStage.SIGNED_IN;
      status.authMode = 'both';
    } else if (hasCookie) {
      status.stage = AuthStage.SIGNED_IN;
      status.authMode = 'cookie';
    } else if (hasOauth) {
      status.stage = AuthStage.SIGNED_IN;
      status.authMode = 'oauth';
    } else if (this.deviceFlowActive) {
      status.stage = this.deviceStage;
      status.authMode = 'oauth';
    } else {
      status.authMode = 'none';
      status.stage = AuthStage.SIGNED_OUT;
    }

    status.canWebUserData = this.hasCookieAuthForUserData();
    status.canTvUserData = this.hasTvAuthForUserData();
    status.canPersonalizedHome = status.canWebUserData || status.canTvUserData;
    status.canWebPlayback = this.hasWebAuthForPlayback();
    status.canTvPlayback = this.hasTvAuthForPlayback();
    return status;
  }

  /**
   * SmartTube-style device OAuth: request user_code, then poll until authorized.
   * UI shows QR(verificationUrl + user_code) and the human-readable code.
   */
  async startDeviceLogin(): Promise<AuthAccountStatus> {
    this.cancelDeviceLoginInternal(false);
    this.deviceFlowActive = true;
    this.deviceStage = AuthStage.REQUESTING_CODE;
    this.deviceLastError = '';
    this.deviceLastErrorCode = '';
    this.deviceUserCode = '';
    this.deviceCode = '';
    logger.info('Device login: requesting code');
    try {
      const code = await this.probe.requestDeviceCode();
      if (!code.deviceCode || !code.userCode) {
        this.deviceStage = AuthStage.FAILED;
        this.deviceLastErrorCode = 'empty_device_code';
        this.deviceLastError = '无法获取设备码，请稍后重试';
        this.deviceFlowActive = false;
        return this.getStatus();
      }
      this.deviceCode = code.deviceCode;
      this.deviceUserCode = code.userCode;
      this.deviceVerificationUrl = code.verificationUrl || 'https://yt.be/activate';
      this.deviceExpiresAt = Date.now() + Math.max(code.expiresIn, 60) * 1000;
      this.devicePollIntervalMs = Math.max(3, code.interval || 5) * 1000;
      this.deviceStage = AuthStage.WAITING_FOR_USER;
      const gen = ++this.devicePollGeneration;
      this.scheduleDevicePoll(gen);
      logger.info(`Device login: waiting user_code=${code.userCode} intervalMs=${this.devicePollIntervalMs}`);
      return this.getStatus();
    } catch (e) {
      this.deviceStage = AuthStage.FAILED;
      this.deviceFlowActive = false;
      this.deviceLastErrorCode = 'network_error';
      this.deviceLastError = e instanceof Error ? e.message : '网络错误';
      logger.error(`Device login request failed: ${this.deviceLastError}`);
      return this.getStatus();
    }
  }

  cancelDeviceLogin(): AuthAccountStatus {
    this.cancelDeviceLoginInternal(true);
    return this.getStatus();
  }

  private cancelDeviceLoginInternal(log: boolean): void {
    this.devicePollGeneration++;
    this.deviceFlowActive = false;
    this.deviceCode = '';
    this.deviceUserCode = '';
    this.deviceExpiresAt = 0;
    this.deviceStage = AuthStage.SIGNED_OUT;
    this.deviceLastError = '';
    this.deviceLastErrorCode = '';
    if (log) {
      logger.info('Device login cancelled');
    }
  }

  private scheduleDevicePoll(generation: number): void {
    const delay = this.devicePollIntervalMs > 0 ? this.devicePollIntervalMs : 5000;
    setTimeout(() => {
      this.pollDeviceOnce(generation).catch((e: Error) => {
        logger.warn(`Device poll exception: ${e.message || e}`);
      });
    }, delay);
  }

  private async pollDeviceOnce(generation: number): Promise<void> {
    if (generation !== this.devicePollGeneration || !this.deviceFlowActive) {
      return;
    }
    if (Date.now() >= this.deviceExpiresAt) {
      this.deviceStage = AuthStage.FAILED;
      this.deviceFlowActive = false;
      this.deviceLastErrorCode = 'expired_token';
      this.deviceLastError = this.toUserMessage('expired_token');
      logger.warn('Device login expired');
      return;
    }
    this.deviceStage = AuthStage.POLLING_TOKEN;
    try {
      const token = await this.probe.pollToken(this.deviceCode);
      if (generation !== this.devicePollGeneration || !this.deviceFlowActive) {
        return;
      }
      if (token.accessToken.length > 0 || token.refreshToken.length > 0) {
        // Dual-rail: keep Cookie if present; OAuth coexists (web + tv rails).
        this.authEnabled = true;
        this.persistAuthEnabled();
        this.saveToken(token);
        this.deviceFlowActive = false;
        this.deviceStage = AuthStage.SIGNED_IN;
        this.deviceCode = '';
        this.deviceUserCode = '';
        this.deviceLastError = '';
        this.deviceLastErrorCode = '';
        logger.info(`Device login succeeded authMode=${this.getStatus().authMode}`);
        return;
      }
      const err = token.error || '';
      if (err === 'authorization_pending' || err === 'slow_down') {
        if (err === 'slow_down') {
          this.devicePollIntervalMs = Math.min(this.devicePollIntervalMs + 2000, 15000);
        }
        this.deviceStage = AuthStage.WAITING_FOR_USER;
        this.scheduleDevicePoll(generation);
        return;
      }
      if (err === 'expired_token' || err === 'access_denied') {
        this.deviceStage = AuthStage.FAILED;
        this.deviceFlowActive = false;
        this.deviceLastErrorCode = err;
        this.deviceLastError = this.toUserMessage(err);
        logger.warn(`Device login terminal: ${err}`);
        return;
      }
      if (err.length > 0) {
        this.deviceStage = AuthStage.FAILED;
        this.deviceFlowActive = false;
        this.deviceLastErrorCode = err;
        this.deviceLastError = this.toUserMessage(err);
        return;
      }
      this.deviceStage = AuthStage.WAITING_FOR_USER;
      this.scheduleDevicePoll(generation);
    } catch (e) {
      if (generation !== this.devicePollGeneration || !this.deviceFlowActive) {
        return;
      }
      // Transient network: keep polling until expiry.
      logger.warn(`Device poll network error, retrying: ${e instanceof Error ? e.message : String(e)}`);
      this.deviceStage = AuthStage.WAITING_FOR_USER;
      this.scheduleDevicePoll(generation);
    }
  }

  hasCredential(): boolean {
    return this.hasWebCredentialStored() || this.hasOauthCredentialStored();
  }

  /** Stored WEB cookie string present (ignores toggles). */
  hasWebCredentialStored(): boolean {
    return !!(this.cookieCredential && this.cookieCredential.cookies.length > 0);
  }

  /** Stored OAuth refresh token present (ignores toggles). */
  hasOauthCredentialStored(): boolean {
    return this.refreshToken.length > 0;
  }

  /** Cookie has SAPISID needed for SAPISIDHASH (ignores toggles). */
  hasWebSapisidStored(): boolean {
    return !!(this.cookieCredential
      && this.cookieCredential.cookies.length > 0
      && this.cookieCredential.sapiSid.length > 0);
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

  /**
   * WEB rail: personalized home / library via Cookie + SAPISIDHASH (FEwhat_to_watch etc.).
   */
  hasCookieAuthForUserData(): boolean {
    if (!this.authEnabled || !this.useAuthForUserData) {
      return false;
    }
    return this.hasWebSapisidStored();
  }

  /** Alias for WEB user-data capability. */
  hasWebAuthForUserData(): boolean {
    return this.hasCookieAuthForUserData();
  }

  /**
   * TV rail: personalized browse/player via OAuth Bearer (SmartTube-style).
   * Does not imply WEB FEwhat_to_watch works.
   */
  hasTvAuthForUserData(): boolean {
    if (!this.authEnabled || !this.useAuthForUserData) {
      return false;
    }
    return this.hasOauthCredentialStored();
  }

  /** Either rail can attach auth for user-data surfaces. */
  hasAuthForUserData(): boolean {
    return this.hasCookieAuthForUserData() || this.hasTvAuthForUserData();
  }

  /** Effective: playback extraction should attach auth (any rail). */
  isAuthEnabledForPlayback(): boolean {
    return this.authEnabled && this.useAuthForPlayback && this.hasCredential();
  }

  hasWebAuthForPlayback(): boolean {
    if (!this.authEnabled || !this.useAuthForPlayback) {
      return false;
    }
    return this.hasWebCredentialStored();
  }

  hasTvAuthForPlayback(): boolean {
    if (!this.authEnabled || !this.useAuthForPlayback) {
      return false;
    }
    return this.hasOauthCredentialStored();
  }

  hasAuthForPlayback(): boolean {
    return this.hasWebAuthForPlayback() || this.hasTvAuthForPlayback();
  }

  /**
   * Preferred rail for user-data: WEB first, else TV, else none.
   */
  preferredUserDataRail(): 'none' | 'web' | 'tv' {
    if (this.hasCookieAuthForUserData()) {
      return 'web';
    }
    if (this.hasTvAuthForUserData()) {
      return 'tv';
    }
    return 'none';
  }

  /**
   * Preferred rail for playback: Cookie/WEB first, else OAuth/TV, else none.
   */
  preferredPlaybackRail(): 'none' | 'web' | 'tv' {
    if (this.hasWebAuthForPlayback()) {
      return 'web';
    }
    if (this.hasTvAuthForPlayback()) {
      return 'tv';
    }
    return 'none';
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

  /** Cookie rail only: SAPISIDHASH … */
  async getWebAuthorizationHeader(): Promise<string | undefined> {
    if (!this.authEnabled) {
      return undefined;
    }
    if (this.cookieCredential && this.cookieCredential.sapiSid.length > 0) {
      return await SapisidHashUtil.generate(this.cookieCredential.sapiSid);
    }
    return undefined;
  }

  /** TV/OAuth rail only: Bearer … (refreshes access token as needed). */
  async getTvAuthorizationHeader(): Promise<string | undefined> {
    if (!this.authEnabled) {
      return undefined;
    }
    if (!this.refreshToken) {
      return undefined;
    }
    if (!this.accessToken || Date.now() + AuthSessionManager.REFRESH_MARGIN_MS >= this.accessTokenExpiresAt) {
      await this.refreshAccessTokenShared();
    }
    return this.accessToken ? `Bearer ${this.accessToken}` : undefined;
  }

  /** Merge concurrent refreshes into one in-flight call (WebClientVersionResolver pattern). */
  private async refreshAccessTokenShared(): Promise<AuthAccountStatus> {
    if (this.refreshPromise) {
      return this.refreshPromise;
    }
    this.refreshPromise = this.refreshAccessToken();
    try {
      return await this.refreshPromise;
    } finally {
      this.refreshPromise = undefined;
    }
  }

  async refreshAccessToken(): Promise<AuthAccountStatus> {
    if (!this.refreshToken) {
      return this.getStatus();
    }

    try {
      const token = await this.probe.refreshAccessToken(this.refreshToken);
      if (token.error.length > 0) {
        logger.warn(`Refresh failed with code: ${token.error}`);
        if (token.error === 'invalid_grant') {
          // 服务端判定 refresh token 失效：清空 OAuth 凭据并标记登录态失效。
          logger.warn('Refresh token rejected (invalid_grant) — clearing OAuth credential');
          this.refreshToken = '';
          this.accessToken = '';
          this.accessTokenExpiresAt = 0;
          this.persistRefreshToken();
          this.noteAuthRejection('tv', 'invalid_grant');
          AuthSessionManager.emitAuthStateChange();
        }
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
    AuthSessionManager.emitAuthStateChange();
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
    AuthSessionManager.emitAuthStateChange();
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

  saveCookieCredential(credential: CookieAuthCredential): AuthAccountStatus {
    this.cookieCredential = credential;
    this.authEnabled = true;
    this.persistCookieCredential();
    this.persistAuthEnabled();
    logger.info('Cookie credential saved');
    AuthSessionManager.emitAuthStateChange();
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
      case 'access_denied':
        return '授权被拒绝';
      case 'authorization_pending':
        return '等待授权中';
      case 'slow_down':
        return '请稍后再试';
      default:
        return code.length > 0 ? `登录失败：${code}` : '登录失败';
    }
  }
}
