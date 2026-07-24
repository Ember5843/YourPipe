import { http } from '@kit.NetworkKit';
import { JSON } from '@kit.ArkTS';
import { YTCoreLogger } from '../common/YTCoreLogger';
import { HttpDownloader, HttpError } from '../network/HttpDownloader';
import { AuthTokenResponse, DeviceCodeResponse } from './AuthModels';
import { DebugAuthConstants } from './DebugAuthConstants';

const logger = YTCoreLogger.getInstance('SmartTubeAuthProbe');

export class AuthProbeError extends Error {
  readonly code: string;

  constructor(code: string, message?: string) {
    super(message || code);
    this.name = 'AuthProbeError';
    this.code = code;
  }
}

export class SmartTubeAuthProbe {
  private downloader: HttpDownloader = new HttpDownloader();
  /** Stable per-process device id (UUID), same idea as SmartTube MediaServiceData.getDeviceId(). */
  private deviceId: string = SmartTubeAuthProbe.newDeviceId();

  async requestDeviceCode(): Promise<DeviceCodeResponse> {
    logger.info(`Requesting device code device_id=${this.deviceId.substring(0, 8)}…`);
    // Match SmartTube AuthApiHelper.getUserCodeQuery JSON body exactly.
    const body = JSON.stringify({
      'client_id': DebugAuthConstants.CLIENT_ID,
      'device_id': this.deviceId,
      'model_name': DebugAuthConstants.MODEL_NAME,
      'scope': DebugAuthConstants.SCOPE
    });

    try {
      const response = await this.postJson(DebugAuthConstants.DEVICE_CODE_URL, body);
      const raw = typeof response.result === 'string'
        ? response.result as string
        : JSON.stringify(response.result);
      const data = JSON.parse(raw) as Record<string, Object>;
      const result = new DeviceCodeResponse();
      result.deviceCode = this.readString(data, 'device_code');
      result.userCode = this.readString(data, 'user_code');
      // Prefer SmartTube human URL for display; API often returns google.com/device.
      result.verificationUrl = DebugAuthConstants.VERIFICATION_URL;
      result.expiresIn = this.readNumber(data, 'expires_in', 0);
      result.interval = this.readNumber(data, 'interval', 5);
      logger.info(`Device code received user_code=${result.userCode} expires=${result.expiresIn}`);
      return result;
    } catch (err) {
      if (err instanceof HttpError) {
        const snippet = (err.responseBody || '').substring(0, 300);
        logger.error(`Device code HTTP ${err.responseCode}: ${snippet || err.message}`);
        throw new AuthProbeError(
          err.responseCode === 400 ? 'bad_request' : 'network_error',
          err.responseCode
            ? `HTTP ${err.responseCode}${snippet ? `: ${snippet}` : ''}`
            : (err.message || 'Device code request failed')
        );
      }
      const msg = err instanceof Error ? err.message : String(err);
      throw new AuthProbeError('network_error', msg || 'Device code request failed');
    }
  }

  async pollToken(deviceCode: string): Promise<AuthTokenResponse> {
    logger.info('Polling device token');
    const body = JSON.stringify({
      'code': deviceCode,
      'client_id': DebugAuthConstants.CLIENT_ID,
      'client_secret': DebugAuthConstants.CLIENT_SECRET,
      'grant_type': DebugAuthConstants.GRANT_TYPE_DEVICE_CODE
    });
    return this.requestToken(body);
  }

  async refreshAccessToken(refreshToken: string): Promise<AuthTokenResponse> {
    logger.info('Refreshing access token');
    const body = JSON.stringify({
      'client_id': DebugAuthConstants.CLIENT_ID,
      'client_secret': DebugAuthConstants.CLIENT_SECRET,
      'refresh_token': refreshToken,
      'grant_type': DebugAuthConstants.GRANT_TYPE_REFRESH
    });
    return this.requestToken(body);
  }

  private async requestToken(body: string): Promise<AuthTokenResponse> {
    try {
      const response = await this.postJson(DebugAuthConstants.TOKEN_URL, body);
      const raw = typeof response.result === 'string'
        ? response.result as string
        : JSON.stringify(response.result);
      return this.parseTokenResponse(raw);
    } catch (err) {
      const httpError = err as HttpError;
      if (httpError && httpError.responseBody) {
        const token = this.parseTokenResponse(httpError.responseBody);
        if (token.error.length > 0) {
          logger.warn(`Token endpoint returned error: ${token.error}`);
          return token;
        }
      }
      logger.error('Token request failed');
      throw new AuthProbeError('network_error', 'Token request failed');
    }
  }

  private parseTokenResponse(body: string): AuthTokenResponse {
    const data = JSON.parse(body) as Record<string, Object>;
    const token = new AuthTokenResponse();
    token.accessToken = this.readString(data, 'access_token');
    token.refreshToken = this.readString(data, 'refresh_token');
    token.expiresIn = this.readNumber(data, 'expires_in', 0);
    token.tokenType = this.readString(data, 'token_type') || 'Bearer';
    token.error = this.readString(data, 'error');
    token.errorDescription = this.readString(data, 'error_description');
    return token;
  }

  private postJson(url: string, body: string): Promise<http.HttpResponse> {
    return this.downloader.request(
      'POST',
      url,
      {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent':
          'Mozilla/5.0 (Linux; Android 10; SMART TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Origin': 'https://www.youtube.com',
        'Referer': 'https://www.youtube.com/tv'
      },
      body,
      undefined,
      false
    );
  }

  private static newDeviceId(): string {
    // UUID v4-ish, unique per process (SmartTube persists; regenerate each cold start is fine).
    const hexChars: string[] = [
      '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'
    ];
    let out = '';
    for (let i = 0; i < 36; i++) {
      if (i === 8 || i === 13 || i === 18 || i === 23) {
        out += '-';
      } else if (i === 14) {
        out += '4';
      } else if (i === 19) {
        const idx = Math.floor(Math.random() * 4) + 8;
        out += hexChars[idx];
      } else {
        out += hexChars[Math.floor(Math.random() * 16)];
      }
    }
    return out;
  }

  private readString(data: Record<string, Object>, key: string): string {
    const value = data[key];
    return typeof value === 'string' ? value : '';
  }

  private readNumber(data: Record<string, Object>, key: string, fallback: number): number {
    const value = data[key];
    return typeof value === 'number' ? value : fallback;
  }
}
