import { YTCoreLogger } from '../common/YTCoreLogger';
import { connection, http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Localization } from '../model/Localization';
import { AppHttpProxySnapshot, HttpProxyOptions } from './HttpProxyOptions';

const logger = YTCoreLogger.getInstance('HttpDownloader');

/** 响应 Set-Cookie 观察者（AuthSessionManager 用于跟踪账号 cookie 被服务端清除/轮换）。 */
export type SetCookieObserver = (setCookie: string | string[], url: string) => void;

/** 提取 URL 的 host（小写，去 scheme/端口/路径）；解析失败返回空串。 */
function extractHost(requestUrl: string): string {
  if (!requestUrl) {
    return '';
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
  return rest.substring(0, end);
}

/**
 * host 必须是 youtube.com 或其子域。
 * 复制自 AuthSessionManager.isYoutubeHost：auth 层已依赖本文件（Set-Cookie 观察者注册），
 * 反向 import 会成环，故在 network 内保留一份最小判定。
 */
function isYoutubeHostUrl(requestUrl: string): boolean {
  const host = extractHost(requestUrl);
  return host === 'youtube.com' || host.endsWith('.youtube.com');
}

/** 重定向到非 YouTube 主机时需剥掉的鉴权头（小写比较）。 */
const REDIRECT_STRIP_HEADERS: string[] = ['cookie', 'authorization'];

/**
 * REDIRECTION 拦截器（API 22+）：netstack 自动跟随 3xx 前触发，reqContext 是即将发出的
 * 新请求。若重定向目标不是 YouTube 主机，剥掉 Cookie / Authorization（含 SAPISIDHASH，
 * 走 Authorization 头），防止注入的登录头泄漏到跨域目标。日志只记 host，不记 URL。
 */
class RedirectAuthStripInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.REDIRECTION;

  interceptorHandle(reqContext: http.HttpRequestContext, _rspContext: http.HttpResponse): Promise<http.ChainContinue> {
    const targetUrl = reqContext.url;
    if (isYoutubeHostUrl(targetUrl)) {
      return Promise.resolve(true);
    }
    const header = reqContext.header as Record<string, Object>;
    if (!header) {
      return Promise.resolve(true);
    }
    // ArkTS 不支持 delete：重建一个不含鉴权头的 header 对象再赋回 reqContext。
    const stripped: string[] = [];
    const kept: Record<string, Object> = {};
    Object.keys(header).forEach((key: string) => {
      if (REDIRECT_STRIP_HEADERS.indexOf(key.toLowerCase()) >= 0) {
        stripped.push(key);
      } else {
        kept[key] = header[key];
      }
    });
    if (stripped.length > 0) {
      reqContext.header = kept;
      logger.warn(`Redirect to non-YouTube host=${extractHost(targetUrl) || '(invalid-url)'} stripped=[${stripped.join(',')}]`);
    }
    return Promise.resolve(true);
  }
}

/** FINAL_RESPONSE 拦截器用的响应回调签名。 */
type FinalResponseHook = (response: http.HttpResponse) => void;

/**
 * FINAL_RESPONSE 拦截器（API 22+）：拿到最终响应（任意状态码）后触发，
 * 用于替代 request() 里手动的 Set-Cookie 观察者通知。
 */
class FinalResponseHookInterceptor implements http.HttpInterceptor {
  interceptorType: http.InterceptorType = http.InterceptorType.FINAL_RESPONSE;
  private readonly hook: FinalResponseHook;

  constructor(hook: FinalResponseHook) {
    this.hook = hook;
  }

  interceptorHandle(_reqContext: http.HttpRequestContext, rspContext: http.HttpResponse): Promise<http.ChainContinue> {
    this.hook(rspContext);
    return Promise.resolve(true);
  }
}

// 错误分析结果接口
export interface ErrorAnalysisResult {
  errorType: HttpErrorType;
  isRecoverable: boolean;
}

// 增强的 HTTP 错误类型
export class HttpError extends Error {
  public readonly url: string;
  public readonly method: string;
  public readonly responseCode?: number;
  public readonly httpStatusMessage?: string;
  public readonly errorType: HttpErrorType;
  public readonly isRecoverable: boolean;
  public readonly responseBody?: string;

  constructor(
    message: string,
    url: string,
    method: string,
    responseCode?: number,
    httpStatusMessage?: string,
    responseBody?: string
  ) {
    super(message);
    this.name = 'HttpError';
    this.url = url;
    this.method = method;
    this.responseCode = responseCode;
    this.httpStatusMessage = httpStatusMessage;
    this.responseBody = responseBody;
    
    // 分析错误类型和可恢复性
    const analysis = this.analyzeErrorType(responseCode);
    this.errorType = analysis.errorType;
    this.isRecoverable = analysis.isRecoverable;
  }

  private analyzeErrorType(responseCode?: number): ErrorAnalysisResult {
    if (!responseCode) {
      const result: ErrorAnalysisResult = { errorType: HttpErrorType.NETWORK_ERROR, isRecoverable: true };
      return result;
    }

    // 1xx - 信息性响应
    if (responseCode >= 100 && responseCode < 200) {
      const result: ErrorAnalysisResult = { errorType: HttpErrorType.INFORMATIONAL, isRecoverable: false };
      return result;
    }

    // 3xx 响应不会进入此分析（两处调用点都只在 responseCode >= 400 时构造 HttpError）。

    // 4xx - 客户端错误
    if (responseCode >= 400 && responseCode < 500) {
      switch (responseCode) {
        case 400: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.BAD_REQUEST, isRecoverable: false };
          return result;
        }
        case 401:
        case 403: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.FORBIDDEN, isRecoverable: false };
          return result;
        }
        case 404: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.NOT_FOUND, isRecoverable: false };
          return result;
        }
        case 408: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.TIMEOUT, isRecoverable: true };
          return result;
        }
        case 416: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.RANGE_NOT_SATISFIABLE, isRecoverable: false };
          return result;
        }
        case 429: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.TOO_MANY_REQUESTS, isRecoverable: true };
          return result;
        }
        default: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.CLIENT_ERROR, isRecoverable: false };
          return result;
        }
      }
    }

    // 5xx - 服务器错误
    if (responseCode >= 500 && responseCode < 600) {
      switch (responseCode) {
        case 500: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.SERVER_ERROR, isRecoverable: true };
          return result;
        }
        case 502:
        case 503:
        case 504: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.SERVICE_UNAVAILABLE, isRecoverable: true };
          return result;
        }
        default: {
          const result: ErrorAnalysisResult = { errorType: HttpErrorType.SERVER_ERROR, isRecoverable: true };
          return result;
        }
      }
    }

    const result: ErrorAnalysisResult = { errorType: HttpErrorType.UNKNOWN, isRecoverable: false };
    return result;
  }

  // 获取友好的错误消息
  getFriendlyMessage(): string {
    const messages: Record<HttpErrorType, string> = {
      [HttpErrorType.NETWORK_ERROR]: 'Network connection failed, please check your network settings',
      [HttpErrorType.INFORMATIONAL]: 'Server response abnormal',
      [HttpErrorType.BAD_REQUEST]: 'Bad request format',
      [HttpErrorType.FORBIDDEN]: 'Access denied (403), IP may be blocked or link expired',
      [HttpErrorType.NOT_FOUND]: 'Resource not found (404)',
      [HttpErrorType.TIMEOUT]: 'Request timeout (408)',
      [HttpErrorType.RANGE_NOT_SATISFIABLE]: 'Invalid request range (416)',
      [HttpErrorType.TOO_MANY_REQUESTS]: 'Too many requests, please try again later (429)',
      [HttpErrorType.CLIENT_ERROR]: 'Client error',
      [HttpErrorType.SERVER_ERROR]: 'Server error, please try again later',
      [HttpErrorType.SERVICE_UNAVAILABLE]: 'Service temporarily unavailable, please try again later',
      [HttpErrorType.UNKNOWN]: 'An unknown error occurred'
    };

    const baseMessage = messages[this.errorType] || 'An error occurred';
    return `${baseMessage} [${this.method} ${this.url}] (${this.responseCode})`;
  }
}

/**
 * Cooperative abort handle for a streamed binary POST. The in-flight
 * http.HttpRequest registers itself so the holder can destroy() it mid-flight;
 * the request callbacks then error out through the normal catch paths.
 */
export class HttpAbortToken {
  public aborted: boolean = false;
  public request?: http.HttpRequest;

  abort(): void {
    this.aborted = true;
    try {
      this.request?.destroy();
    } catch (_e) {
    }
  }
}

// HTTP 错误类型枚举
export enum HttpErrorType {
  // 网络层错误
  NETWORK_ERROR = 'NETWORK_ERROR',
  
  // 1xx - 信息性响应
  INFORMATIONAL = 'INFORMATIONAL',

  // 4xx - 客户端错误
  BAD_REQUEST = 'BAD_REQUEST',           // 400
  FORBIDDEN = 'FORBIDDEN',               // 401, 403
  NOT_FOUND = 'NOT_FOUND',               // 404
  TIMEOUT = 'TIMEOUT',                   // 408
  RANGE_NOT_SATISFIABLE = 'RANGE_NOT_SATISFIABLE',  // 416
  TOO_MANY_REQUESTS = 'TOO_MANY_REQUESTS',  // 429
  CLIENT_ERROR = 'CLIENT_ERROR',         // 其他 4xx
  
  // 5xx - 服务器错误
  SERVER_ERROR = 'SERVER_ERROR',         // 500
  SERVICE_UNAVAILABLE = 'SERVICE_UNAVAILABLE',  // 502, 503, 504
  
  // 未知错误
  UNKNOWN = 'UNKNOWN'
}

// 请求参数结构
export class Request {
  method: string
  url: string
  headers?: Map<string, string[]>
  data?: Uint8Array
  localization?: Localization

  constructor(
    method: string,
    url: string,
    headers?: Map<string, string[]>,
    data?: Uint8Array,
    localization?: Localization
  ) {
    this.method = method
    this.url = url
    this.headers = headers
    this.data = data
    this.localization = localization
  }
}

// 增强的下载器实现
export class HttpDownloader {
  // 最大重试次数
  private static readonly MAX_RETRIES = 3;
  // 重试延迟（毫秒）
  private static readonly RETRY_DELAY = 1000;

  private static setCookieObserver: SetCookieObserver | undefined = undefined;

  static setSetCookieObserver(obs?: SetCookieObserver): void {
    HttpDownloader.setCookieObserver = obs;
  }

  /** 拿到响应即通知（不看状态码）；观察者抛错只记日志，不影响请求链路。 */
  private static notifySetCookie(response: http.HttpResponse, url: string): void {
    const obs = HttpDownloader.setCookieObserver;
    if (!obs || !response || !response.header) {
      return;
    }
    const header = response.header as Record<string, Object>;
    let value: Object | undefined = header['Set-Cookie'];
    if (!value) {
      value = header['set-cookie'];
    }
    if (!value) {
      return;
    }
    try {
      if (Array.isArray(value)) {
        obs(value as string[], url);
      } else if (typeof value === 'string') {
        obs(value, url);
      }
    } catch (e) {
      logger.error('Set-Cookie observer threw');
    }
  }

  /** Inject app proxy into request options. Loopback / exclusion always bypass. */
  static applyProxyToOptions(options: http.HttpRequestOptions, url: string): void {
    const snap: AppHttpProxySnapshot = HttpProxyOptions.getSnapshot();
    if (!HttpProxyOptions.isActive(snap) || HttpProxyOptions.shouldBypass(url, snap)) {
      options.usingProxy = false;
      return;
    }
    if (snap.kind === 'http') {
      const proxy: connection.HttpProxy = {
        host: snap.host.trim(),
        port: snap.port,
        exclusionList: snap.exclusionList && snap.exclusionList.length > 0
          ? snap.exclusionList
          : HttpProxyOptions.defaultExclusions()
      };
      if (snap.username && snap.username.length > 0) {
        proxy.username = snap.username;
        proxy.password = snap.password || '';
      }
      options.usingProxy = proxy;
      return;
    }
    // SOCKS5 (API 26): use the netstack-native SOCKS5 client with the real
    // upstream proxy. PROXY_MODE lets the proxy resolve DNS (no local DNS
    // leak); exclusionList mirrors the loopback bypass rules. The loopback
    // HTTP CONNECT bridge (Socks5Bridge) is no longer used by netstack
    // requests — it still serves ArkWeb ProxyController / RCP createTunnel /
    // MPV env, so entry keeps it running independently.
    if (snap.kind === 'socks5') {
      const socks5: connection.Socks5Proxy = {
        host: snap.host.trim(),
        port: snap.port,
        dnsStrategy: connection.Socks5DnsStrategy.PROXY_MODE,
        exclusionList: HttpProxyOptions.defaultExclusions()
      };
      if (snap.username && snap.username.length > 0) {
        socks5.username = snap.username;
        socks5.password = snap.password || '';
      }
      options.usingSocks5Proxy = socks5;
      return;
    }
    options.usingProxy = false;
  }

  /**
   * 核心请求方法，处理所有 HTTP 请求（带错误分析和重试）
   * @param method 请求方法（GET/POST/HEAD 等）
   * @param url 请求 URL
   * @param headers 请求头
   * @param data 请求体（POST 时使用）
   * @param localization 本地化信息（用于 Accept-Language 头）
   * @param enableRetry 是否启用自动重试（默认 true）
   * @param timeoutMs 连接/读取超时（默认 30s；UI 浏览类请求应传 8-10s 避免卡死感）
   */
  async request(
    method: string,
    url: string,
    headers?: Record<string, string[] | string>,
    data?: string,
    localization?: Localization,
    enableRetry: boolean = true,
    timeoutMs: number = 30000
  ): Promise<http.HttpResponse> {
    let lastError: HttpError | null = null;
    let attempt = 0;
    const maxAttempts = enableRetry ? HttpDownloader.MAX_RETRIES : 1;

    while (attempt < maxAttempts) {
      attempt++;
      let httpRequest: http.HttpRequest | null = null;
      try {
        logger.debug(`${method} ${url} (attempt ${attempt}/${maxAttempts})`);

        // 1. 处理请求头（合并默认头和传入头，添加本地化相关头）
        const requestHeaders = this.processHeaders(headers, localization)

        // 禁用压缩，避免收到 gzip 内容
        requestHeaders['Accept-Encoding'] = 'identity'

        // 2. 创建 HTTP 请求
        const request = http.createHttp()
        httpRequest = request

        // 2.1 附加拦截器链（API 22+；链随 HttpRequest 实例走，每次 attempt 新建并重新 apply，
        // apply 必须在 request() 之前）。REDIRECTION 防鉴权头随跨域重定向泄漏；
        // FINAL_RESPONSE 统一触发 Set-Cookie 观察者（覆盖所有状态码）。
        // 挂载失败时降级为手动通知，保证观察者契约不丢。
        let interceptorsApplied = false;
        try {
          const chain = new http.HttpInterceptorChain();
          chain.addChain([
            new RedirectAuthStripInterceptor(),
            new FinalResponseHookInterceptor((resp: http.HttpResponse) => {
              HttpDownloader.notifySetCookie(resp, url);
            })
          ]);
          interceptorsApplied = chain.apply(request);
          if (!interceptorsApplied) {
            logger.error('interceptor chain apply returned false; falling back to manual Set-Cookie notify');
          }
        } catch (e) {
          logger.error('interceptor chain setup failed; falling back to manual Set-Cookie notify');
        }

        // 3. 转换请求参数为 HTTP 模块所需格式
        const httpOptions: http.HttpRequestOptions = {
          'method': method as http.RequestMethod,
          'header': requestHeaders,
          'extraData': data,
          // 超时按调用方分级：播放/提取默认 30s，UI 浏览类传更短
          'connectTimeout': timeoutMs,
          'readTimeout': timeoutMs,
          'usingCache': false,
          // API 26 连接池复用：减少重复请求的 TCP/TLS 握手开销
          'reuseConnections': true,
          'inactivityMs': 30000
        }
        HttpDownloader.applyProxyToOptions(httpOptions, url);

        // 4. 发送请求并获取响应
        const response = await new Promise<http.HttpResponse>((resolve, reject) => {
          request.request(
            url,
            httpOptions,
            (err: BusinessError, data: http.HttpResponse) => {
              if (!err) {
                logger.debug(`Response code: ${data.responseCode}`);
                resolve(data);
              } else {
                logger.error(`Request error: ${JSON.stringify(err)}`);
                reject(err);
              }
            }
          )
        });

        if (!interceptorsApplied) {
          HttpDownloader.notifySetCookie(response, url);
        }

        // 5. 检查响应码
        if (response.responseCode && response.responseCode >= 400) {
          const responseBody = typeof response.result === 'string' 
            ? response.result 
            : JSON.stringify(response.result);
          
          // 根据响应码生成消息
          let statusMessage = 'Error';
          switch (response.responseCode) {
            case 400: statusMessage = 'Bad Request'; break;
            case 401: statusMessage = 'Unauthorized'; break;
            case 403: statusMessage = 'Forbidden'; break;
            case 404: statusMessage = 'Not Found'; break;
            case 408: statusMessage = 'Request Timeout'; break;
            case 416: statusMessage = 'Range Not Satisfiable'; break;
            case 429: statusMessage = 'Too Many Requests'; break;
            case 500: statusMessage = 'Internal Server Error'; break;
            case 502: statusMessage = 'Bad Gateway'; break;
            case 503: statusMessage = 'Service Unavailable'; break;
            case 504: statusMessage = 'Gateway Timeout'; break;
            default: statusMessage = `HTTP ${response.responseCode}`;
          }
          
          const httpError = new HttpError(
            `HTTP ${response.responseCode}: ${statusMessage}`,
            url,
            method,
            response.responseCode,
            statusMessage,
            responseBody
          );

          logger.error(`HTTP error: ${httpError.getFriendlyMessage()}`);

          // 如果是可恢复的错误且还有重试机会，则重试
          if (httpError.isRecoverable && attempt < maxAttempts) {
            logger.debug(`Retrying in ${HttpDownloader.RETRY_DELAY}ms...`);
            await this.sleep(HttpDownloader.RETRY_DELAY * attempt); // 递增延迟
            continue;
          }

          throw httpError;
        }

        // 6. 成功响应
        logger.debug(`Success: ${method} ${url}`);
        return response;

      } catch (err) {
        if (err instanceof HttpError) {
          throw err;
        }

        const businessError = err as BusinessError;
        
        // 网络层错误（连接失败、超时等）
        const httpError = new HttpError(
          businessError.message || 'Network error',
          url,
          method,
          undefined,
          undefined,
          undefined
        );

        lastError = httpError;

        // 如果是可恢复的错误且还有重试机会
        if (httpError.isRecoverable && attempt < maxAttempts) {
          logger.debug(`Retrying network error in ${HttpDownloader.RETRY_DELAY}ms...`);
          await this.sleep(HttpDownloader.RETRY_DELAY * attempt);
          continue;
        }

        // 不再重试，抛出错误
        throw lastError;
      } finally {
        // 统一清理：成功、重试 continue、抛错路径都销毁本次创建的 request
        if (httpRequest) {
          try {
            httpRequest.destroy();
          } catch (e) {
            // 忽略清理错误
          }
        }
      }
    }

    // 所有重试都失败
    throw lastError || new HttpError('Unknown error', url, method);
  }

  /**
   * 延迟函数
   */
  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * 处理请求头（合并默认头、添加 Accept-Language）
   */
  public processHeaders(
    customHeaders?: Record<string, string[] | string>,
    localization?: Localization
  ): Record<string, string[] | string> {
    // 基础默认头
    const headers: Record<string, string | string[]> = { 'Content-Type': 'application/json' };

    // 添加本地化头（Accept-Language）
    if (localization) {
      const langCode = localization.getLanguageCode()
      const countryCode = localization.getCountryCode()
      const acceptLanguage = countryCode
        ? `${langCode}-${countryCode},${langCode};q=0.9`
        : langCode
      headers['Accept-Language'] = acceptLanguage
    }
    // 合并自定义头（覆盖默认头）
    if (customHeaders) {
      Object.keys(customHeaders).forEach((key: string) => {
        const value = customHeaders[key];
        // 检查值的类型并进行相应处理
        if (Array.isArray(value)) {
          // 如果是数组，将其转换为逗号分隔的字符串
          // 过滤掉空字符串，避免不必要的逗号
          const nonEmptyValues = value.filter(item => typeof item === 'string' && item.trim() !== '');
          if (nonEmptyValues.length > 0) {
            headers[key] = nonEmptyValues.join(',');
          }
        } else if (typeof value === 'string') {
          // 如果是字符串且非空，直接赋值
          if (value.trim() !== '') {
            headers[key] = value;
          }
        }
      })
    }

    return headers
  }

  // 便捷方法：POST 请求
  post(
    url: string,
    data?: string,
    headers?: Record<string, string[]>,
    localization?: Localization,
    contentType?: string,
    timeoutMs: number = 30000
  ): Promise<http.HttpResponse> {
    // 处理 Content-Type
    const postHeaders: Record<string, string[] | string> = headers ? headers : {}
    if (contentType) {
      postHeaders['Content-Type'] = [contentType]
    }
    return this.request('POST', url, postHeaders, data, localization, true, timeoutMs)
  }

  /**
   * Binary POST (SABR protobuf body + UMP response).
   * Streamed via requestInStream — OHOS http.request buffers the whole body and rejects
   * ~50MB+ UMP replies with "response data exceeds the maximum limit" / curl 23.
   */
  async postBinary(
    url: string,
    data: Uint8Array,
    headers?: Record<string, string[] | string>,
    localization?: Localization,
    enableRetry: boolean = true,
    onData?: (bytes: number) => void,
    abortToken?: HttpAbortToken
  ): Promise<http.HttpResponse> {
    let lastError: HttpError | null = null;
    let attempt = 0;
    // SABR web-like posts must not inject default application/json Content-Type.
    while (attempt < (enableRetry ? HttpDownloader.MAX_RETRIES : 1)) {
      attempt++;
      if (abortToken?.aborted) {
        throw new HttpError('request aborted', url, 'POST');
      }
      try {
        logger.debug(`POST-BIN-STREAM ${url} (attempt ${attempt}/${HttpDownloader.MAX_RETRIES}) bytes=${data.length}`);
        const response = await this.postBinaryStreamOnce(url, data, headers, localization, onData, abortToken);
        if (response.responseCode && response.responseCode >= 400) {
          let errBody = '';
          try {
            if (response.result instanceof ArrayBuffer) {
              const u8 = new Uint8Array(response.result as ArrayBuffer);
              const n = Math.min(u8.length, 200);
              let s = '';
              for (let i = 0; i < n; i++) {
                s += String.fromCharCode(u8[i]);
              }
              errBody = s;
            }
          } catch (_e) {
            errBody = '';
          }
          logger.error(`POST-BIN-STREAM HTTP ${response.responseCode} bodySnippet=${errBody}`);
          const httpError = new HttpError(
            `HTTP ${response.responseCode}`,
            url,
            'POST',
            response.responseCode,
            `HTTP ${response.responseCode}`,
            errBody
          );
          // 403 on SABR is not recoverable by blind retry (often wrong headers/body).
          if (response.responseCode === 403) {
            throw httpError;
          }
          if (httpError.isRecoverable && attempt < HttpDownloader.MAX_RETRIES) {
            if (abortToken?.aborted) {
              throw new HttpError('request aborted', url, 'POST');
            }
            await this.sleep(HttpDownloader.RETRY_DELAY * attempt);
            continue;
          }
          throw httpError;
        }
        return response;
      } catch (err) {
        if (err instanceof HttpError) {
          lastError = err;
          if (err.responseCode === 403) {
            throw err;
          }
          if (err.isRecoverable && attempt < HttpDownloader.MAX_RETRIES) {
            if (abortToken?.aborted) {
              throw new HttpError('request aborted', url, 'POST');
            }
            await this.sleep(HttpDownloader.RETRY_DELAY * attempt);
            continue;
          }
          throw err;
        }
        const businessError = err as BusinessError;
        lastError = new HttpError(businessError.message || 'Network error', url, 'POST');
        if (lastError.isRecoverable && attempt < HttpDownloader.MAX_RETRIES) {
          if (abortToken?.aborted) {
            throw new HttpError('request aborted', url, 'POST');
          }
          await this.sleep(HttpDownloader.RETRY_DELAY * attempt);
          continue;
        }
        throw lastError;
      }
    }
    throw lastError || new HttpError('Unknown error', url, 'POST');
  }

  /**
   * One streamed binary POST. Accumulates dataReceive chunks into ArrayBuffer result
   * (same shape callers expect from buffered request).
   */
  private postBinaryStreamOnce(
    url: string,
    data: Uint8Array,
    headers?: Record<string, string[] | string>,
    localization?: Localization,
    onData?: (bytes: number) => void,
    abortToken?: HttpAbortToken
  ): Promise<http.HttpResponse> {
    const requestHeaders = this.processBinaryHeaders(headers, localization);
    const httpRequest = http.createHttp();
    const bodyCopy = new ArrayBuffer(data.length);
    new Uint8Array(bodyCopy).set(data);
    const httpOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: requestHeaders,
      extraData: bodyCopy,
      connectTimeout: 30000,
      // Large SABR UMP payloads (init + many media segs) need a long read window.
      readTimeout: 180000,
      usingCache: false,
      // API 26 连接池复用：SABR 反复 POST 同一 UMP 端点，流式结束后连接可入池复用
      reuseConnections: true,
      inactivityMs: 30000
    };
    HttpDownloader.applyProxyToOptions(httpOptions, url);

    return new Promise<http.HttpResponse>((resolve, reject) => {
      const chunks: ArrayBuffer[] = [];
      let totalBytes = 0;
      let responseCode = 0;
      let responseHeader: Object = new Object();
      let requestReturned = false;
      let streamEnded = false;
      let settled = false;
      // Overall watchdog: an empty-body response may never fire dataEnd, which
      // would leave this Promise (and the SABR pump lock) unsettled forever.
      // Budget = readTimeout + 5s grace.
      const watchdogMs = 180000 + 5000;
      let watchdogTimer: number = -1;

      const clearWatchdog = (): void => {
        if (watchdogTimer >= 0) {
          clearTimeout(watchdogTimer);
          watchdogTimer = -1;
        }
      };

      const cleanup = (): void => {
        clearWatchdog();
        if (abortToken && abortToken.request === httpRequest) {
          abortToken.request = undefined;
        }
        try {
          httpRequest.off('headersReceive');
          httpRequest.off('dataReceive');
          httpRequest.off('dataEnd');
        } catch (_e) {
        }
        try {
          httpRequest.destroy();
        } catch (_e) {
        }
      };

      const finishOk = (): void => {
        if (settled || !requestReturned || !streamEnded) {
          return;
        }
        settled = true;
        const result = new ArrayBuffer(totalBytes);
        const out = new Uint8Array(result);
        let offset = 0;
        for (let i = 0; i < chunks.length; i++) {
          const part = new Uint8Array(chunks[i]);
          out.set(part, offset);
          offset += part.length;
        }
        cleanup();
        logger.debug(`POST-BIN-STREAM complete status=${responseCode} bytes=${totalBytes}`);
        const resp: http.HttpResponse = {
          result: result,
          responseCode: responseCode,
          header: responseHeader,
          cookies: '',
          resultType: http.HttpDataType.ARRAY_BUFFER
        } as http.HttpResponse;
        // requestInStream 不支持拦截器链（SDK 明确仅 request() 支持），
        // 这里的 Set-Cookie 观察者通知保持手动触发。
        HttpDownloader.notifySetCookie(resp, url);
        resolve(resp);
      };

      const finishErr = (error: Error | Object): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        reject(error);
      };

      httpRequest.on('headersReceive', (hdrs: Object) => {
        responseHeader = hdrs;
      });

      httpRequest.on('dataReceive', (chunk: ArrayBuffer) => {
        if (settled) {
          return;
        }
        if (chunk && chunk.byteLength > 0) {
          // Copy — framework may reuse the buffer on next callback.
          const copy = new ArrayBuffer(chunk.byteLength);
          new Uint8Array(copy).set(new Uint8Array(chunk));
          chunks.push(copy);
          totalBytes += chunk.byteLength;
          // Arrival-time traffic sample for the connection-speed meter.
          onData?.(chunk.byteLength);
        }
      });

      httpRequest.on('dataEnd', () => {
        streamEnded = true;
        finishOk();
      });

      if (abortToken) {
        abortToken.request = httpRequest;
        if (abortToken.aborted) {
          finishErr(new HttpError('request aborted', url, 'POST'));
          return;
        }
      }

      watchdogTimer = setTimeout(() => {
        watchdogTimer = -1;
        logger.warn(`POST-BIN-STREAM stalled: no dataEnd within ${watchdogMs}ms, aborting request`);
        finishErr(new HttpError('stream stalled: no dataEnd', url, 'POST'));
      }, watchdogMs);

      httpRequest.requestInStream(url, httpOptions).then((code: number) => {
        responseCode = code || 0;
        requestReturned = true;
        finishOk();
      }).catch((error: Error) => {
        finishErr(error);
      });
    });
  }

  /**
   * Headers for binary POST: no default Content-Type: application/json.
   * Only Accept-Language from localization + caller headers.
   */
  private processBinaryHeaders(
    customHeaders?: Record<string, string[] | string>,
    localization?: Localization
  ): Record<string, string | string[]> {
    const headers: Record<string, string | string[]> = {};
    if (localization) {
      const langCode = localization.getLanguageCode();
      const countryCode = localization.getCountryCode();
      headers['Accept-Language'] = countryCode
        ? `${langCode}-${countryCode},${langCode};q=0.9`
        : langCode;
    }
    if (customHeaders) {
      Object.keys(customHeaders).forEach((key: string) => {
        const value = customHeaders[key];
        if (Array.isArray(value)) {
          const nonEmpty = value.filter(item => typeof item === 'string' && item.trim() !== '');
          if (nonEmpty.length > 0) {
            headers[key] = nonEmpty.join(',');
          }
        } else if (typeof value === 'string' && value.trim() !== '') {
          headers[key] = value;
        }
      });
    }
    return headers;
  }

  // 便捷方法：HEAD 请求
  head(
    url: string,
    headers?: Record<string, string[]>
  ): Promise<null | http.HttpResponse> {
    return this.request('HEAD', url, headers)
  }

  // 便捷方法：JSON POST 请求
  postJson(
    url: string,
    data?: string,
    headers?: Record<string, string[]>,
    localization?: Localization
  ): Promise<null | http.HttpResponse> {
    return this.post(url, data, headers, localization, 'application/json')
  }
}
