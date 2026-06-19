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

  async requestDeviceCode(): Promise<DeviceCodeResponse> {
    logger.info('Requesting device code');
    const body = JSON.stringify({
      'client_id': DebugAuthConstants.CLIENT_ID,
      'device_id': DebugAuthConstants.DEVICE_ID,
      'model_name': DebugAuthConstants.MODEL_NAME,
      'scope': DebugAuthConstants.SCOPE
    });

    const response = await this.postJson(DebugAuthConstants.DEVICE_CODE_URL, body);
    const data = JSON.parse(response.result as string) as Record<string, Object>;
    const result = new DeviceCodeResponse();
    result.deviceCode = this.readString(data, 'device_code');
    result.userCode = this.readString(data, 'user_code');
    result.verificationUrl = this.readString(data, 'verification_url') ||
      this.readString(data, 'verification_uri') ||
      DebugAuthConstants.VERIFICATION_URL;
    result.expiresIn = this.readNumber(data, 'expires_in', 0);
    result.interval = this.readNumber(data, 'interval', 5);
    logger.info('Device code received');
    return result;
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
      return this.parseTokenResponse(response.result as string);
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
        'Accept': 'application/json'
      },
      body,
      undefined,
      false
    );
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
