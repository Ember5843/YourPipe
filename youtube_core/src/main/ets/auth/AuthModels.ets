export enum AuthStage {
  SIGNED_OUT = 'SIGNED_OUT',
  REQUESTING_CODE = 'REQUESTING_CODE',
  WAITING_FOR_USER = 'WAITING_FOR_USER',
  POLLING_TOKEN = 'POLLING_TOKEN',
  EXTRACTING_COOKIES = 'EXTRACTING_COOKIES',
  SIGNED_IN = 'SIGNED_IN',
  FAILED = 'FAILED'
}

export class DeviceCodeResponse {
  deviceCode: string = '';
  userCode: string = '';
  verificationUrl: string = 'https://yt.be/activate';
  expiresIn: number = 0;
  interval: number = 5;
}

export class AuthTokenResponse {
  accessToken: string = '';
  refreshToken: string = '';
  expiresIn: number = 0;
  tokenType: string = 'Bearer';
  error: string = '';
  errorDescription: string = '';
}

/**
 * Auth transport rail for request injection.
 * web = Cookie + SAPISIDHASH (PipePipe-style WEB).
 * tv  = Bearer access token (SmartTube-style TV Innertube).
 */
export type AuthRail = 'none' | 'web' | 'tv';

export class AuthAccountStatus {
  stage: AuthStage = AuthStage.SIGNED_OUT;
  /** none | cookie | oauth | both */
  authMode: string = 'none';
  userCode: string = '';
  verificationUrl: string = 'https://yt.be/activate';
  expiresAt: number = 0;
  accessTokenExpiresAt: number = 0;
  hasRefreshToken: boolean = false;
  hasCookieCredential: boolean = false;
  /** Credential exists (cookie or refresh token), regardless of private mode. */
  hasCredential: boolean = false;
  /** When false, requests stay anonymous (private browsing) while credentials are kept. */
  authEnabled: boolean = true;
  /** Fine-grained: attach auth to user-data requests (feed / subscriptions / history / search). */
  useAuthForUserData: boolean = true;
  /** Fine-grained: attach auth to playback extraction (player API + stream URL cookies). */
  useAuthForPlayback: boolean = true;
  /** WEB rail ready (Cookie + SAPISID) for personalized browse when toggles allow. */
  canWebUserData: boolean = false;
  /** TV rail ready (OAuth) for personalized browse when toggles allow. */
  canTvUserData: boolean = false;
  /** Either rail can personalize home / library. */
  canPersonalizedHome: boolean = false;
  /** WEB rail ready for playback auth. */
  canWebPlayback: boolean = false;
  /** TV rail ready for playback auth. */
  canTvPlayback: boolean = false;
  lastError: string = '';
  lastErrorCode: string = '';
  pollIntervalMs: number = 3000;
}
