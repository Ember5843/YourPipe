/**
 * POC only / do not ship.
 *
 * These values mirror SmartTube's public debug OAuth client for local device-flow
 * validation. Replace this file with YourPipe-owned OAuth credentials before any
 * release build, or remove the POC entirely.
 */
export class DebugAuthConstants {
  static readonly CLIENT_ID: string = '861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com';
  static readonly CLIENT_SECRET: string = 'SboVhoG9s0rNafixCSGGKXAT';
  static readonly DEVICE_CODE_URL: string = 'https://www.youtube.com/o/oauth2/device/code';
  static readonly TOKEN_URL: string = 'https://www.youtube.com/o/oauth2/token';
  /** Human-typed activate page (SmartTube SIGN_IN_URL). */
  static readonly VERIFICATION_URL: string = 'https://yt.be/activate';
  /**
   * QR deep-link prefix (SmartTube QR_SIGN_IN_URL).
   * Full QR payload = QR_ACTIVATE_PREFIX + user_code with spaces → '-'.
   * Do NOT append ?user_code= to verification_url from the API — phone scanners
   * hit google.com/device?user_code=... which often shows Bad Request.
   */
  static readonly QR_ACTIVATE_PREFIX: string = 'https://youtube.com/qr/activate/';
  static readonly GRANT_TYPE_DEVICE_CODE: string = 'http://oauth.net/grant_type/device/1.0';
  static readonly GRANT_TYPE_REFRESH: string = 'refresh_token';
  static readonly MODEL_NAME: string = 'ytlr::';
  static readonly SCOPE: string = 'http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content';
  /** TV-ish UA; device/code is more reliable with a real browser/TV agent. */
  static readonly USER_AGENT: string =
    'Mozilla/5.0 (Linux; Android 10; SMART TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
}
