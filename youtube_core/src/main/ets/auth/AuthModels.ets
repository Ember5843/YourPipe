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
  verificationUrl: string = 'https://youtube.com/activate';
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

export class AuthAccountStatus {
  stage: AuthStage = AuthStage.SIGNED_OUT;
  authMode: string = 'none';
  userCode: string = '';
  verificationUrl: string = 'https://youtube.com/activate';
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
  lastError: string = '';
  lastErrorCode: string = '';
  pollIntervalMs: number = 3000;
}
