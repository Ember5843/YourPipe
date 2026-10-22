import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HttpDownloader } from 'youtube_core';
import { getAppVersion } from '../AppVersion';
import { NetworkProxyConfig } from '../NetworkProxyConfig';
import { AppLog } from '../AppLog';

const logger = AppLog.getInstance('CommunityHttp');

export interface CommunityHttpResult {
  status: number;
  body: string;
}

/**
 * 第三方社区服务（SponsorBlock / DeArrow / AiSList）的 HTTP 收口。
 * 与 UpdateChecker 一样走 HttpDownloader.applyProxyToOptions，保证应用代理生效；
 * 非 2xx 不抛异常（404/204 是这些接口的正常语义），网络层错误才抛。
 */
export class CommunityHttp {
  private static userAgent(): string {
    try {
      return `YourPipe/${getAppVersion().versionName} (HarmonyOS; experimental)`;
    } catch (_e) {
      return 'YourPipe (HarmonyOS; experimental)';
    }
  }

  static async getText(url: string, timeoutMs: number = 8000): Promise<CommunityHttpResult> {
    await NetworkProxyConfig.awaitReady();
    const request = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': CommunityHttp.userAgent(),
        'Accept': 'application/json, text/plain, */*'
      },
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      usingCache: false
    };
    HttpDownloader.applyProxyToOptions(options, url);
    const startedAt = Date.now();
    try {
      const response = await request.request(url, options);
      const body = CommunityHttp.toText(response.result);
      logger.debug(`GET host=${CommunityHttp.hostOf(url)} status=${response.responseCode} `
        + `bytes=${body.length} elapsed=${Date.now() - startedAt}ms`);
      return { status: response.responseCode, body };
    } catch (e) {
      logger.warn(`GET host=${CommunityHttp.hostOf(url)} failed elapsed=${Date.now() - startedAt}ms `
        + `error=${(e as Error).message || String(e)}`);
      throw e as Error;
    } finally {
      try {
        request.destroy();
      } catch (_e) {
        // ignore destroy races
      }
    }
  }

  private static toText(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      return result;
    }
    if (result instanceof ArrayBuffer) {
      return new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(result));
    }
    try {
      return JSON.stringify(result);
    } catch (_e) {
      return '';
    }
  }

  /** 日志里只保留 host，避免把完整查询串（可达数百字符）写进日志。 */
  private static hostOf(url: string): string {
    const schemeEnd = url.indexOf('://');
    if (schemeEnd < 0) {
      return 'invalid';
    }
    const rest = url.substring(schemeEnd + 3);
    const slash = rest.indexOf('/');
    return slash >= 0 ? rest.substring(0, slash) : rest;
  }
}
