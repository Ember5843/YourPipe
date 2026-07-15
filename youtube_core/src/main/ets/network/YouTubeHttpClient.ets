import { YTCoreLogger } from '../common/YTCoreLogger';
import { http } from '@kit.NetworkKit';
import { HttpDownloader } from './HttpDownloader';
import { CookieJar, Cookie } from './CookieJar';
import { Localization } from '../model/Localization';
import { ContentCountry } from '../model/ContentCountry';
import { ClientsConstants } from '../model/ClientsConstants';
import { AuthSessionManager } from '../auth/AuthSessionManager';

const logger = YTCoreLogger.getInstance('YouTubeHttpClient');

/**
 * YouTube HTTP 客户端
 * 封装 HttpDownloader 和 CookieJar，提供自动 Cookie 管理和 YouTube 专用请求头
 */
export class YouTubeHttpClient {
  private static requestSequence: number = 0;
  private downloader: HttpDownloader = new HttpDownloader();
  private cookieJar: CookieJar;
  private localization: Localization;
  private contentCountry: ContentCountry;
  private context: Context;
  private authSession?: AuthSessionManager;

  private static safeRequestTarget(url: string): string {
    const match = /^(https?:\/\/[^/?#]+)([^?#]*)/.exec(url);
    return match ? `${match[1]}${match[2] || '/'}` : '(invalid-url)';
  }

  private static nextRequestId(): number {
    YouTubeHttpClient.requestSequence++;
    return YouTubeHttpClient.requestSequence;
  }

  // 默认 YouTube 请求头
  private static readonly DEFAULT_USER_AGENT: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  private static readonly DEFAULT_HEADERS: Record<string, string> = {
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept-Encoding': 'gzip, deflate, br',
    'DNT': '1',
    'Connection': 'keep-alive',
    'Upgrade-Insecure-Requests': '1',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'none',
    'Sec-Fetch-User': '?1',
    'Cache-Control': 'max-age=0'
  };

  constructor(context: Context, localization?: Localization, contentCountry?: ContentCountry) {
    this.context = context;
    this.cookieJar = new CookieJar(context);
    this.localization = localization || Localization.DEFAULT;
    this.contentCountry = contentCountry || ContentCountry.DEFAULT;
    this.authSession = AuthSessionManager.getInstance() || undefined;
    logger.info('Context initialized');
  }

  setAuthSession(authSession?: AuthSessionManager): void {
    this.authSession = authSession;
  }

  /**
   * 初始化：从持久化存储加载 Cookie
   */
  async initialize(): Promise<void> {
    await this.cookieJar.load();
    logger.info('Initialized');
  }

  /**
   * 发送 GET 请求
   * 默认匿名（对齐 PipePipe）。仅在 stream 提取链上把 withAuth 设为 true 才注入登录头。
   */
  async get(
    url: string,
    customHeaders?: Record<string, string | string[]>,
    withAuth: boolean = false
  ): Promise<http.HttpResponse> {
    const requestId = YouTubeHttpClient.nextRequestId();
    const target = YouTubeHttpClient.safeRequestTarget(url);
    const startedAt = Date.now();
    logger.info(`[NET] id=${requestId} phase=start method=GET target=${target} auth=${withAuth}`);
    const headers = await this.prepareHeaders(customHeaders, url, withAuth);
    try {
      const response: http.HttpResponse = await this.downloader.request('GET', url, headers, undefined, this.localization);
      this.saveCookiesFromResponse(response, url);
      logger.info(`[NET] id=${requestId} phase=complete method=GET target=${target} status=${response.responseCode} elapsed=${Date.now() - startedAt}ms`);
      return response;
    } catch (e) {
      logger.error(`[NET] id=${requestId} phase=failed method=GET target=${target} elapsed=${Date.now() - startedAt}ms error=${String(e)}`);
      throw new Error(String(e));
    }
  }

  /**
   * 发送 POST 请求
   * 默认匿名（对齐 PipePipe）。仅在 stream 提取链上把 withAuth 设为 true 才注入登录头。
   */
  async post(
    url: string,
    data?: string,
    customHeaders?: Record<string, string | string[]>,
    contentType?: string,
    withAuth: boolean = false
  ): Promise<http.HttpResponse> {
    const requestId = YouTubeHttpClient.nextRequestId();
    const target = YouTubeHttpClient.safeRequestTarget(url);
    const startedAt = Date.now();
    logger.info(`[NET] id=${requestId} phase=start method=POST target=${target} auth=${withAuth} bytes=${data?.length ?? 0}`);
    const headers = await this.prepareHeaders(customHeaders, url, withAuth);

    const postHeaders: Record<string, string[]> = {};
    const headerKeys = Object.keys(headers);
    for (let i = 0; i < headerKeys.length; i++) {
      const key = headerKeys[i];
      const value = headers[key];
      if (Array.isArray(value)) {
        postHeaders[key] = value;
      } else {
        postHeaders[key] = [value];
      }
    }

    try {
      const response: http.HttpResponse = await this.downloader.post(url, data, postHeaders, this.localization, contentType);
      this.saveCookiesFromResponse(response, url);
      logger.info(`[NET] id=${requestId} phase=complete method=POST target=${target} status=${response.responseCode} elapsed=${Date.now() - startedAt}ms`);
      return response;
    } catch (e) {
      logger.error(`[NET] id=${requestId} phase=failed method=POST target=${target} elapsed=${Date.now() - startedAt}ms error=${String(e)}`);
      throw new Error(String(e));
    }
  }

  /**
   * 发送 POST JSON 请求
   * 默认匿名。stream 提取链显式传 withAuth=true。
   */
  async postJson(
    url: string,
    data?: object,
    customHeaders?: Record<string, string | string[]>,
    withAuth: boolean = false
  ): Promise<http.HttpResponse> {
    const jsonData = data ? JSON.stringify(data) : undefined;
    return this.post(url, jsonData, customHeaders, 'application/json', withAuth);
  }

  /**
   * Binary POST for SABR (protobuf body, UMP ARRAY_BUFFER response).
   * Does not inject browser page defaults or application/json — caller owns headers.
   */
  async postBinary(
    url: string,
    data: Uint8Array,
    customHeaders?: Record<string, string | string[]>,
    withAuth: boolean = false
  ): Promise<http.HttpResponse> {
    const requestId = YouTubeHttpClient.nextRequestId();
    const target = YouTubeHttpClient.safeRequestTarget(url);
    const startedAt = Date.now();
    logger.info(`[NET] id=${requestId} phase=start method=POST_BINARY target=${target} auth=${withAuth} bytes=${data.length}`);
    // Minimal cookie/auth only — SABR googlevideo rejects wrong browser/API defaults.
    const headers: Record<string, string | string[]> = {};
    if (customHeaders) {
      const keys = Object.keys(customHeaders);
      for (let i = 0; i < keys.length; i++) {
        headers[keys[i]] = customHeaders[keys[i]];
      }
    }
    if (withAuth) {
      const activeAuthSession = this.authSession || AuthSessionManager.getInstance() || undefined;
      if (activeAuthSession && activeAuthSession.isSignedIn()) {
        const cookieStr = activeAuthSession.getCookieString();
        if (cookieStr) {
          headers['Cookie'] = cookieStr;
        }
        const authorization = await activeAuthSession.getAuthorizationHeader();
        if (authorization && authorization.length > 0) {
          headers['Authorization'] = authorization;
        }
      }
    }
    try {
      const response = await this.downloader.postBinary(url, data, headers, this.localization);
      this.saveCookiesFromResponse(response, url);
      logger.info(`[NET] id=${requestId} phase=complete method=POST_BINARY target=${target} status=${response.responseCode} elapsed=${Date.now() - startedAt}ms`);
      return response;
    } catch (e) {
      logger.error(`[NET] id=${requestId} phase=failed method=POST_BINARY target=${target} elapsed=${Date.now() - startedAt}ms error=${String(e)}`);
      throw new Error(String(e));
    }
  }

  /**
   * 准备请求头（合并默认头、Cookie、自定义头）
   *
   * 对齐 PipePipe DownloaderImpl + addLoggedInHeaders 行为：
   *   - 默认匿名：仅 SOCS（同意）+ 受限模式 cookie + cookieJar 已有的非鉴权 cookie
   *   - withAuth=true 时才注入 SAPISIDHASH Authorization + 完整 Cookie + X-Origin + DNT
   *   - 调用方显式 opt-in：stream Safari、WEB metadata /player、WEB /next 等
   */
  private async prepareHeaders(
    customHeaders?: Record<string, string | string[]>,
    targetUrl?: string,
    withAuth: boolean = false
  ): Promise<Record<string, string | string[]>> {
    const headers: Record<string, string | string[]> = {};

    // 判断是否为 API 请求（InnerTube POST）— 不应注入浏览器页面头
    const isApiRequest = customHeaders !== undefined &&
      Object.keys(customHeaders).some(k => k.toLowerCase() === 'content-type');

    if (!isApiRequest) {
      // 页面请求：注入完整浏览器头
      const defaultHeaderKeys = Object.keys(YouTubeHttpClient.DEFAULT_HEADERS);
      for (let i = 0; i < defaultHeaderKeys.length; i++) {
        const key = defaultHeaderKeys[i];
        headers[key] = YouTubeHttpClient.DEFAULT_HEADERS[key];
      }
      headers['User-Agent'] = YouTubeHttpClient.DEFAULT_USER_AGENT;
    }

    // Cookie：cookieJar 中累积的非鉴权 cookie（SOCS、CONSENT、受限模式 cookie 等）
    if (targetUrl) {
      const cookieHeader = this.cookieJar.getCookieHeader(targetUrl);
      if (cookieHeader) {
        headers['Cookie'] = cookieHeader;
      }
    }

    // YouTube 特定处理
    if (targetUrl && targetUrl.includes('youtube.com')) {
      // SOCS Cookie（隐私同意）— 仅页面请求需要
      if (!isApiRequest) {
        if (!headers['Cookie'] || !(headers['Cookie'] as string).includes('SOCS=')) {
          const existingCookie = headers['Cookie'] ? headers['Cookie'] + '; ' : '';
          headers['Cookie'] = existingCookie + 'SOCS=CAISAiAD';
        }
      }

      // InnerTube 默认客户端头 — 仅当自定义头未提供时
      if (!isApiRequest && targetUrl.includes('/youtubei/v1/')) {
        headers['X-YouTube-Client-Name'] = ClientsConstants.WEB_CLIENT_ID;
        headers['X-YouTube-Client-Version'] = ClientsConstants.WEB_HARDCODED_CLIENT_VERSION;
        headers['Origin'] = 'https://www.youtube.com';
        headers['Referer'] = 'https://www.youtube.com/';
      }

      // 登录头：显式 withAuth 时注入（对齐 PipePipe addLoggedInHeaders）
      if (withAuth) {
        const activeAuthSession = this.authSession || AuthSessionManager.getInstance() || undefined;
        if (activeAuthSession && activeAuthSession.isSignedIn()) {
          const cookieStr = activeAuthSession.getCookieString();
          if (cookieStr) {
            headers['Cookie'] = cookieStr;
            headers['X-Origin'] = 'https://www.youtube.com';
            headers['DNT'] = '1';
          }
          const authorization = await activeAuthSession.getAuthorizationHeader();
          if (authorization && authorization.length > 0) {
            headers['Authorization'] = authorization;
          }
        }
      }
    }

    // 合并自定义头（最高优先级，覆盖所有默认值）
    if (customHeaders) {
      const customHeaderKeys = Object.keys(customHeaders);
      for (let i = 0; i < customHeaderKeys.length; i++) {
        const key = customHeaderKeys[i];
        const value = customHeaders[key];
        if (Array.isArray(value)) {
          headers[key] = value.join(', ');
        } else {
          headers[key] = value;
        }
      }
    }

    return headers;
  }

  /**
   * 从响应中保存 Cookie
   */
  private saveCookiesFromResponse(response: http.HttpResponse, requestUrl: string): void {
    // 从响应头中提取 Set-Cookie
    const header = response.header as Record<string, string | string[]>;
    const setCookieHeader = header?.['Set-Cookie'];
    if (setCookieHeader) {
      this.cookieJar.parseSetCookie(setCookieHeader, requestUrl);
      // 异步保存到持久化存储
      this.cookieJar.save().catch((err: Error) => {
        logger.error('Failed to save cookies:', err);
      });
    }
  }

  /**
   * 手动设置 Cookie
   */
  setCookie(name: string, value: string, domain?: string, path?: string): void {
    const cookie = new Cookie(
      name,
      value,
      domain || '.youtube.com',
      path || '/'
    );
    this.cookieJar.setCookie(cookie);
  }

  /**
   * 获取特定名称的 Cookie
   */
  getCookie(name: string): Cookie | undefined {
    return this.cookieJar.getCookie(name);
  }

  /**
   * 删除 Cookie
   */
  deleteCookie(name: string, domain?: string, path?: string): void {
    this.cookieJar.deleteCookie(name, domain, path);
  }

  /**
   * 清空所有 Cookie
   */
  clearCookies(): void {
    this.cookieJar.clearAll();
  }

  /**
   * 获取 Cookie 数量
   */
  getCookieCount(): number {
    return this.cookieJar.getCookieCount();
  }

  /**
   * 保存 Cookie 到持久化存储
   */
  async saveCookies(): Promise<void> {
    await this.cookieJar.save();
  }

  /**
   * 从持久化存储加载 Cookie
   */
  async loadCookies(): Promise<void> {
    await this.cookieJar.load();
  }

  /**
   * 获取当前本地化设置
   */
  getLocalization(): Localization {
    return this.localization;
  }

  /**
   * 设置本地化
   */
  setLocalization(localization: Localization): void {
    this.localization = localization;
  }

  /**
   * 获取当前内容国家
   */
  getContentCountry(): ContentCountry {
    return this.contentCountry;
  }

  /**
   * 设置内容国家
   */
  setContentCountry(contentCountry: ContentCountry): void {
    this.contentCountry = contentCountry;
  }
}
