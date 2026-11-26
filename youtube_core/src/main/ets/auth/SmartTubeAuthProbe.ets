import { http } from '@kit.NetworkKit';
import { JSON } from '@kit.ArkTS';
import { YTCoreLogger } from '../common/YTCoreLogger';
import { HttpDownloader, HttpError } from '../network/HttpDownloader';
import { ClientsConstants } from '../model/ClientsConstants';
import { AuthTokenResponse, DeviceCodeResponse } from './AuthModels';
import { DebugAuthConstants } from './DebugAuthConstants';

const logger = YTCoreLogger.getInstance('SmartTubeAuthProbe');

export interface TvOAuthClientCredentials {
  clientId: string;
  clientSecret: string;
}

export interface TvAccountFetchResult {
  checked: boolean;
  pageId: string;
  visitorData: string;
}

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
  /** Stable device id persisted by AuthSessionManager (fallback to per-process UUID). */
  private deviceId: string = SmartTubeAuthProbe.newDeviceId();
  private scrapedCreds: TvOAuthClientCredentials | null = null;
  private persistedCreds: TvOAuthClientCredentials | null = null;
  private scrapeInFlight: Promise<TvOAuthClientCredentials> | null = null;
  private cachedTvVisitorData: string = '';

  setDeviceId(deviceId: string): void {
    const trimmed = (deviceId || '').trim();
    if (trimmed.length > 0) {
      this.deviceId = trimmed;
    }
  }

  getDeviceId(): string {
    return this.deviceId;
  }

  setPersistedClientCredentials(clientId: string, clientSecret: string): void {
    const id = (clientId || '').trim();
    const secret = (clientSecret || '').trim();
    if (id.length > 0 && secret.length > 0) {
      this.persistedCreds = { clientId: id, clientSecret: secret };
    } else {
      this.persistedCreds = null;
    }
  }

  getResolvedClientCredentials(): TvOAuthClientCredentials {
    if (this.scrapedCreds) {
      return this.scrapedCreds;
    }
    if (this.persistedCreds) {
      return this.persistedCreds;
    }
    return {
      clientId: DebugAuthConstants.CLIENT_ID,
      clientSecret: DebugAuthConstants.CLIENT_SECRET
    };
  }

  getCachedTvVisitorData(): string {
    return this.cachedTvVisitorData;
  }

  /**
   * Align SmartTube AppServiceCore: GET https://www.youtube.com/tv -> extract base-js +
   * visitorData -> extract first clientId & clientSecret from m=base (or m=main fallback).
   */
  async ensureTvAppClientCredentials(): Promise<TvOAuthClientCredentials> {
    if (this.scrapedCreds) {
      return this.scrapedCreds;
    }
    if (this.scrapeInFlight) {
      return this.scrapeInFlight;
    }
    const task = this.scrapeTvAppClientCredentials().finally(() => {
      if (this.scrapeInFlight === task) {
        this.scrapeInFlight = null;
      }
    });
    this.scrapeInFlight = task;
    return task;
  }

  private async scrapeTvAppClientCredentials(): Promise<TvOAuthClientCredentials> {
    const tvHeaders: Record<string, string> = {
      'User-Agent': ClientsConstants.TVHTML5_FIRE_TV_USER_AGENT,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
      'Referer': 'https://www.youtube.com/tv'
    };
    try {
      const tvResp = await this.downloader.request(
        'GET', 'https://www.youtube.com/tv', tvHeaders, undefined, undefined, false, 10000);
      const html = typeof tvResp.result === 'string' ? tvResp.result as string : '';
      if (tvResp.responseCode === 200 && html.length > 0) {
        const visitorMatch = /"visitorData":"(.*?)"/.exec(html);
        if (visitorMatch && visitorMatch[1]) {
          this.cachedTvVisitorData = visitorMatch[1].replace(/\\u003d/gi, '=');
        }
        const clientUrl = this.extractTvBaseJsUrl(html);
        if (clientUrl.length > 0) {
          const candidates = [clientUrl];
          const legacyUrl = clientUrl
            .replace('/dg=0/', '/exm=base/ed=1/')
            .replace('/m=base', '/m=main');
          if (legacyUrl !== clientUrl) {
            candidates.push(legacyUrl);
          }
          for (let i = 0; i < candidates.length; i++) {
            const creds = await this.fetchClientDataFromScript(candidates[i]);
            if (creds) {
              this.scrapedCreds = creds;
              logger.info(`[TV-OAuth] Scraped live TV clientId=${creds.clientId.substring(0, 14)}... `
                + `hasVisitorData=${this.cachedTvVisitorData.length > 0}`);
              return creds;
            }
          }
        }
      }
    } catch (e) {
      logger.warn(`[TV-OAuth] Live /tv scrape failed, using fallback: ${e instanceof Error ? e.message : String(e)}`);
    }
    return this.getResolvedClientCredentials();
  }

  private extractTvBaseJsUrl(html: string): string {
    const patterns: RegExp[] = [
      /id="base-js"\s+src="(.*?)"/,
      /\.src\s*=\s*'(.*?m=base)'/,
      /\.src\s*=\s*'(.*?)';\s*.\.id\s*=\s*'base-js'/
    ];
    for (let i = 0; i < patterns.length; i++) {
      const match = patterns[i].exec(html);
      if (match && match[1]) {
        return this.normalizeScriptUrl(match[1]);
      }
    }
    return '';
  }

  private normalizeScriptUrl(rawUrl: string): string {
    let url = rawUrl.replace(/\\\//g, '/').replace(/\\u0026/gi, '&').trim();
    if (url.startsWith('//')) {
      return `https:${url}`;
    }
    if (url.startsWith('/')) {
      return `https://www.youtube.com${url}`;
    }
    return url;
  }

  private async fetchClientDataFromScript(scriptUrl: string): Promise<TvOAuthClientCredentials | null> {
    try {
      const resp = await this.downloader.request(
        'GET',
        scriptUrl,
        {
          'User-Agent': ClientsConstants.TVHTML5_FIRE_TV_USER_AGENT,
          'Accept': '*/*',
          'Referer': 'https://www.youtube.com/tv'
        },
        undefined,
        undefined,
        false,
        12000
      );
      const js = typeof resp.result === 'string' ? resp.result as string : '';
      if (resp.responseCode !== 200 || js.length === 0) {
        return null;
      }
      // SmartTube ClientData.java: use FIRST occurrence (Android TV device).
      const idMatch = /clientId:"([-\w]+\.apps\.googleusercontent\.com)",\n?[$\w]+:"\w+"/.exec(js);
      const secretMatch = /clientId:"[-\w]+\.apps\.googleusercontent\.com",\n?[$\w]+:"(\w+)"/.exec(js);
      if (idMatch && idMatch[1] && secretMatch && secretMatch[1]) {
        return {
          clientId: idMatch[1],
          clientSecret: secretMatch[1]
        };
      }
    } catch (e) {
      logger.warn(`[TV-OAuth] Script fetch failed (${scriptUrl.substring(0, 60)}): ${e instanceof Error ? e.message : String(e)}`);
    }
    return null;
  }

  async requestDeviceCode(): Promise<DeviceCodeResponse> {
    logger.info(`Requesting device code device_id=${this.deviceId.substring(0, 8)}…`);
    const creds = await this.ensureTvAppClientCredentials();
    // Match SmartTube AuthApiHelper.getUserCodeQuery JSON body exactly.
    const body = JSON.stringify({
      'client_id': creds.clientId,
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
    const creds = this.getResolvedClientCredentials();
    const body = JSON.stringify({
      'code': deviceCode,
      'client_id': creds.clientId,
      'client_secret': creds.clientSecret,
      'grant_type': DebugAuthConstants.GRANT_TYPE_DEVICE_CODE
    });
    return this.requestToken(body);
  }

  async refreshAccessToken(
    refreshToken: string,
    clientIdOverride?: string,
    clientSecretOverride?: string
  ): Promise<AuthTokenResponse> {
    logger.info('Refreshing access token');
    const fallback = this.getResolvedClientCredentials();
    const clientId = (clientIdOverride || '').trim() || fallback.clientId;
    const clientSecret = (clientSecretOverride || '').trim() || fallback.clientSecret;
    const body = JSON.stringify({
      'client_id': clientId,
      'client_secret': clientSecret,
      'refresh_token': refreshToken,
      'grant_type': DebugAuthConstants.GRANT_TYPE_REFRESH
    });
    return this.requestToken(body);
  }

  /**
   * Align SmartTube AuthService.getAccounts / YouTubeAccountManager:
   * fetch accounts_list under TV Bearer and extract pageIdToken for Brand Accounts
   * ("used along with the access token to support restricted videos").
   */
  async fetchSelectedAccountPageId(accessToken: string, visitorData?: string): Promise<TvAccountFetchResult> {
    const resolvedVisitor = (visitorData || '').trim() || this.cachedTvVisitorData;
    const result: TvAccountFetchResult = {
      checked: false,
      pageId: '',
      visitorData: resolvedVisitor
    };
    if (!accessToken) {
      return result;
    }
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': `Bearer ${accessToken}`,
      'User-Agent': ClientsConstants.TVHTML5_USER_AGENT,
      'X-YouTube-Client-Name': ClientsConstants.TVHTML5_CLIENT_ID,
      'X-YouTube-Client-Version': ClientsConstants.TVHTML5_CLIENT_VERSION,
      'Origin': 'https://www.youtube.com',
      'Referer': 'https://www.youtube.com/tv'
    };
    if (resolvedVisitor.length > 0) {
      headers['X-Goog-Visitor-Id'] = resolvedVisitor;
    }
    const client: Record<string, Object> = {
      'hl': 'en',
      'gl': 'US',
      'clientName': ClientsConstants.TVHTML5_CLIENT_NAME,
      'clientVersion': ClientsConstants.TVHTML5_CLIENT_VERSION,
      'clientScreen': 'WATCH',
      'platform': ClientsConstants.TVHTML5_CLIENT_PLATFORM,
      'userAgent': ClientsConstants.TVHTML5_USER_AGENT,
      'utcOffsetMinutes': 0,
      'tvAppInfo': {
        'appQuality': 'TV_APP_QUALITY_FULL_ANIMATION',
        'zylonLeftNav': true
      } as Record<string, Object>
    };
    if (resolvedVisitor.length > 0) {
      client['visitorData'] = resolvedVisitor;
    }
    const body = JSON.stringify({
      'context': {
        'client': client,
        'request': {
          'internalExperimentFlags': [] as Object[],
          'useSsl': true
        } as Record<string, Object>,
        'user': {
          'enableSafetyMode': false,
          'lockedSafetyMode': false
        } as Record<string, Object>
      } as Record<string, Object>,
      'accountReadMask': {
        'returnOwner': true,
        'returnBrandAccounts': true,
        'returnPersonaAccounts': false
      } as Record<string, Object>
    });
    try {
      const resp = await this.downloader.request(
        'POST',
        'https://www.youtube.com/youtubei/v1/account/accounts_list?prettyPrint=false',
        headers,
        body,
        undefined,
        false,
        10000
      );
      if (resp.responseCode !== 200 || !resp.result) {
        logger.warn(`[TV-OAuth] accounts_list HTTP ${resp.responseCode}`);
        return result;
      }
      result.checked = true;
      const raw = typeof resp.result === 'string' ? resp.result as string : JSON.stringify(resp.result);
      const root = JSON.parse(raw) as Record<string, Object>;
      const respCtx = root['responseContext'] as Record<string, Object> | undefined;
      const respVisitor = respCtx ? respCtx['visitorData'] : undefined;
      if (typeof respVisitor === 'string' && respVisitor.length > 0) {
        result.visitorData = respVisitor;
        this.cachedTvVisitorData = respVisitor;
      }
      const pageId = this.extractPageIdFromAccountsList(root);
      result.pageId = pageId;
      logger.info(`[TV-OAuth] accounts_list ok hasPageId=${pageId.length > 0}`);
      return result;
    } catch (e) {
      logger.warn(`[TV-OAuth] accounts_list failed: ${e instanceof Error ? e.message : String(e)}`);
      return result;
    }
  }

  private extractPageIdFromAccountsList(root: Record<string, Object>): string {
    const contents = root['contents'] as Array<Record<string, Object>> | undefined;
    if (!contents || contents.length === 0) {
      return '';
    }
    const sectionList = contents[0]?.['accountSectionListRenderer'] as Record<string, Object> | undefined;
    const sectionContents = sectionList?.['contents'] as Array<Record<string, Object>> | undefined;
    if (!sectionContents || sectionContents.length === 0) {
      return '';
    }
    const itemSection = sectionContents[0]?.['accountItemSectionRenderer'] as Record<string, Object> | undefined;
    const items = itemSection?.['contents'] as Array<Record<string, Object>> | undefined;
    if (!items || items.length === 0) {
      return '';
    }
    let selectedPageId = '';
    let firstPageId = '';
    for (let i = 0; i < items.length; i++) {
      const accountItem = items[i]?.['accountItem'] as Record<string, Object> | undefined;
      if (!accountItem || accountItem['isDisabled'] === true) {
        continue;
      }
      const pageId = this.extractPageIdFromAccountItem(accountItem);
      if (pageId.length === 0) {
        continue;
      }
      if (firstPageId.length === 0) {
        firstPageId = pageId;
      }
      if (accountItem['isSelected'] === true) {
        selectedPageId = pageId;
        break;
      }
    }
    return selectedPageId.length > 0 ? selectedPageId : firstPageId;
  }

  private extractPageIdFromAccountItem(accountItem: Record<string, Object>): string {
    const endpoint = accountItem['serviceEndpoint'] as Record<string, Object> | undefined;
    const selectIdentity = endpoint?.['selectActiveIdentityEndpoint'] as Record<string, Object> | undefined;
    const tokens = selectIdentity?.['supportedTokens'] as Array<Record<string, Object>> | undefined;
    if (!tokens || tokens.length === 0) {
      return '';
    }
    for (let i = 0; i < tokens.length; i++) {
      const pageIdObj = tokens[i]?.['pageIdToken'] as Record<string, Object> | undefined;
      const pageId = pageIdObj?.['pageId'];
      if (typeof pageId === 'string' && pageId.length > 0) {
        return pageId;
      }
    }
    return '';
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
        'User-Agent': ClientsConstants.TVHTML5_FIRE_TV_USER_AGENT,
        'Origin': 'https://www.youtube.com',
        'Referer': 'https://www.youtube.com/tv'
      },
      body,
      undefined,
      false
    );
  }

  static newDeviceId(): string {
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
