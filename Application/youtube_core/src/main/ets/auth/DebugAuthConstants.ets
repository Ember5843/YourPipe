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
  static readonly VERIFICATION_URL: string = 'https://youtube.com/activate';
  static readonly GRANT_TYPE_DEVICE_CODE: string = 'http://oauth.net/grant_type/device/1.0';
  static readonly GRANT_TYPE_REFRESH: string = 'refresh_token';
  static readonly DEVICE_ID: string = 'yourpipe-poc-device';
  static readonly MODEL_NAME: string = 'ytlr::';
  static readonly SCOPE: string = 'http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content';
}
