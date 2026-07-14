import { YTCoreLogger } from '../common/YTCoreLogger';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Localization } from '../model/Localization';

const logger = YTCoreLogger.getInstance('HttpDownloader');

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

    // 3xx - 重定向
    if (responseCode >= 300 && responseCode < 400) {
      const result: ErrorAnalysisResult = { errorType: HttpErrorType.REDIRECT, isRecoverable: true };
      return result;
    }

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
      [HttpErrorType.REDIRECT]: 'Request was redirected',
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

// HTTP 错误类型枚举
export enum HttpErrorType {
  // 网络层错误
  NETWORK_ERROR = 'NETWORK_ERROR',
  
  // 1xx - 信息性响应
  INFORMATIONAL = 'INFORMATIONAL',
  
  // 3xx - 重定向
  REDIRECT = 'REDIRECT',
  
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

  /**
   * 核心请求方法，处理所有 HTTP 请求（带错误分析和重试）
   * @param method 请求方法（GET/POST/HEAD 等）
   * @param url 请求 URL
   * @param headers 请求头
   * @param data 请求体（POST 时使用）
   * @param localization 本地化信息（用于 Accept-Language 头）
   * @param enableRetry 是否启用自动重试（默认 true）
   */
  async request(
    method: string,
    url: string,
    headers?: Record<string, string[] | string>,
    data?: string,
    localization?: Localization,
    enableRetry: boolean = true
  ): Promise<http.HttpResponse> {
    let lastError: HttpError | null = null;
    let attempt = 0;

    while (attempt < (enableRetry ? HttpDownloader.MAX_RETRIES : 1)) {
      attempt++;
      try {
        logger.debug(`${method} ${url} (attempt ${attempt}/${HttpDownloader.MAX_RETRIES})`);

        // 1. 处理请求头（合并默认头和传入头，添加本地化相关头）
        const requestHeaders = this.processHeaders(headers, localization)

        // 禁用压缩，避免收到 gzip 内容
        requestHeaders['Accept-Encoding'] = 'identity'

        // 2. 创建 HTTP 请求
        const httpRequest = http.createHttp()

        // 3. 转换请求参数为 HTTP 模块所需格式
        const httpOptions: http.HttpRequestOptions = {
          'method': method as http.RequestMethod,
          'header': requestHeaders,
          'extraData': data,
          // 设置超时时间（30 秒）
          'connectTimeout': 30000,
          'readTimeout': 30000,
          'usingCache': false
        }

        // 4. 发送请求并获取响应
        const response = await new Promise<http.HttpResponse>((resolve, reject) => {
          httpRequest.request(
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
          if (httpError.isRecoverable && attempt < HttpDownloader.MAX_RETRIES) {
            logger.debug(`Retrying in ${HttpDownloader.RETRY_DELAY}ms...`);
            await this.sleep(HttpDownloader.RETRY_DELAY * attempt); // 递增延迟
            continue;
          }

          throw httpError;
        }

        // 6. 成功响应
        logger.debug(`Success: ${method} ${url}`);
        httpRequest.destroy();
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
        if (httpError.isRecoverable && attempt < HttpDownloader.MAX_RETRIES) {
          logger.debug(`Retrying network error in ${HttpDownloader.RETRY_DELAY}ms...`);
          await this.sleep(HttpDownloader.RETRY_DELAY * attempt);
          continue;
        }

        // 不再重试，抛出错误
        throw lastError;
      } finally {
        // 清理资源
        try {
          // httpRequest.destroy() 已在成功时调用，这里防止重复
        } catch (e) {
          // 忽略清理错误
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
   * Build Accept-Language without duplicating region when language already has one
   * (e.g. hl=zh-CN + gl=CN must not become zh-CN-CN).
   */
  private buildAcceptLanguage(localization: Localization): string {
    const langCode = (localization.getLanguageCode() || '').trim();
    if (!langCode) {
      return 'en';
    }
    const countryCode = (localization.getCountryCode() || '').trim();
    if (!countryCode) {
      return langCode;
    }
    // Language tag already contains a region/script suffix (zh-CN, en-GB, es-419, sr-Latn).
    if (langCode.indexOf('-') >= 0) {
      const primary = langCode.split('-')[0];
      return `${langCode},${primary};q=0.9`;
    }
    return `${langCode}-${countryCode},${langCode};q=0.9`;
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
      headers['Accept-Language'] = this.buildAcceptLanguage(localization);
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
    contentType?: string
  ): Promise<http.HttpResponse> {
    // 处理 Content-Type
    const postHeaders: Record<string, string[] | string> = headers ? headers : {}
    if (contentType) {
      postHeaders['Content-Type'] = [contentType]
    }
    return this.request('POST', url, postHeaders, data, localization)
  }

  /**
   * Binary POST (SABR protobuf body + UMP response).
   * Uses ARRAY_BUFFER for both request extraData and response result.
   */
  async postBinary(
    url: string,
    data: Uint8Array,
    headers?: Record<string, string[] | string>,
    localization?: Localization,
    enableRetry: boolean = true
  ): Promise<http.HttpResponse> {
    let lastError: HttpError | null = null;
    let attempt = 0;
    // SABR web-like posts must not inject default application/json Content-Type.
    while (attempt < (enableRetry ? HttpDownloader.MAX_RETRIES : 1)) {
      attempt++;
      try {
        logger.debug(`POST-BIN ${url} (attempt ${attempt}/${HttpDownloader.MAX_RETRIES}) bytes=${data.length}`);
        const requestHeaders = this.processBinaryHeaders(headers, localization);
        const httpRequest = http.createHttp();
        // Fresh copy: avoid SharedArrayBuffer / subarray offset issues on OHOS HTTP.
        const bodyCopy = new ArrayBuffer(data.length);
        new Uint8Array(bodyCopy).set(data);
        const httpOptions: http.HttpRequestOptions = {
          'method': http.RequestMethod.POST,
          'header': requestHeaders,
          'extraData': bodyCopy,
          'expectDataType': http.HttpDataType.ARRAY_BUFFER,
          'connectTimeout': 30000,
          'readTimeout': 60000,
          'usingCache': false
        };
        const response = await new Promise<http.HttpResponse>((resolve, reject) => {
          httpRequest.request(url, httpOptions, (err: BusinessError, resp: http.HttpResponse) => {
            if (!err) {
              resolve(resp);
            } else {
              reject(err);
            }
          });
        });
        httpRequest.destroy();
        if (response.responseCode && response.responseCode >= 400) {
          let errBody = '';
          try {
            if (typeof response.result === 'string') {
              errBody = (response.result as string).substring(0, 300);
            } else if (response.result instanceof ArrayBuffer) {
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
          logger.error(`POST-BIN HTTP ${response.responseCode} bodySnippet=${errBody}`);
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
            await this.sleep(HttpDownloader.RETRY_DELAY * attempt);
            continue;
          }
          throw err;
        }
        const businessError = err as BusinessError;
        lastError = new HttpError(businessError.message || 'Network error', url, 'POST');
        if (lastError.isRecoverable && attempt < HttpDownloader.MAX_RETRIES) {
          await this.sleep(HttpDownloader.RETRY_DELAY * attempt);
          continue;
        }
        throw lastError;
      }
    }
    throw lastError || new HttpError('Unknown error', url, 'POST');
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
      headers['Accept-Language'] = this.buildAcceptLanguage(localization);
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
