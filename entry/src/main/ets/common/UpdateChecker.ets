import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HttpDownloader } from 'youtube_core';
import { AppLog } from './AppLog';
import { getAppVersion } from './AppVersion';

const logger = AppLog.getInstance('UpdateChecker');

/**
 * 用 GitHub Releases 的 Atom feed 而不是 REST API：
 * api.github.com 对匿名请求按出口 IP 限流（60 次/小时），触发后固定 403，
 * 而 releases.atom 是普通网页资源，不受这套限流影响。
 */
const RELEASES_ATOM_URL = 'https://github.com/Ember5843/YourPipe/releases.atom';
const LATEST_VERSION_JSON_URL = 'https://github.com/Ember5843/YourPipe/releases/latest/download/version.json';

export const APPGALLERY_TEST_URL = 'https://appgallery.huawei.com/apptest/AOd7gmH8iD5';
export const GITHUB_REPO_URL = 'https://github.com/Ember5843/YourPipe';

export type UpdateCheckStatus = 'upToDate' | 'updateAvailable' | 'failed';

export interface UpdateCheckResult {
  status: UpdateCheckStatus;
  localVersionName: string;
  localVersionCode: number;
  remoteVersionName: string;
  remoteVersionCode: number;
  releaseUrl: string;
  notes: string;
  publishedAt: string;
  /** 本次请求是否命中 GitHub 限流（403）。 */
  rateLimited: boolean;
  /** 检查完成时间（毫秒）。 */
  checkedAt: number;
  error?: string;
}

interface RemoteVersionJson {
  versionName?: string;
  versionCode?: number;
}

interface LocalVersion {
  versionName: string;
  versionCode: number;
}

const MAX_NOTES_CHARS = 400;

export class UpdateChecker {
  private static inFlight: Promise<UpdateCheckResult> | null = null;
  private static lastResult: UpdateCheckResult | null = null;

  /** 最近一次检查结果（供更新设置页展示）。 */
  static getLastResult(): UpdateCheckResult | null {
    return UpdateChecker.lastResult;
  }

  /** 并发去重：启动静默检查与手动检查同时触发时只发一次请求。 */
  static check(): Promise<UpdateCheckResult> {
    if (UpdateChecker.inFlight) {
      return UpdateChecker.inFlight;
    }
    const task = UpdateChecker.runCheck().finally(() => {
      UpdateChecker.inFlight = null;
    });
    UpdateChecker.inFlight = task;
    return task;
  }

  private static async runCheck(): Promise<UpdateCheckResult> {
    const local = UpdateChecker.readLocalVersion();
    const result: UpdateCheckResult = {
      status: 'failed',
      localVersionName: local.versionName,
      localVersionCode: local.versionCode,
      remoteVersionName: '',
      remoteVersionCode: 0,
      releaseUrl: GITHUB_REPO_URL,
      notes: '',
      publishedAt: '',
      rateLimited: false,
      checkedAt: 0
    };
    try {
      logger.info(`check start local=${local.versionName}(${local.versionCode}) source=atom`);
      const xml = await UpdateChecker.requestText(RELEASES_ATOM_URL, 'application/atom+xml');
      const entry = UpdateChecker.firstEntry(xml);
      if (entry.length === 0) {
        throw new Error('release feed has no entry');
      }

      const link = UpdateChecker.xmlValue(entry, 'link', true);
      const tag = UpdateChecker.tagFromLink(link) || UpdateChecker.normalizeVersionName(
        UpdateChecker.decodeEntities(UpdateChecker.xmlValue(entry, 'title', false)));
      const remoteCode = await UpdateChecker.fetchVersionCode();
      result.releaseUrl = link.length > 0 ? link : `${GITHUB_REPO_URL}/releases`;
      result.notes = UpdateChecker.trimNotes(
        UpdateChecker.htmlToText(UpdateChecker.decodeEntities(UpdateChecker.xmlValue(entry, 'content', false))));
      result.publishedAt = UpdateChecker.xmlValue(entry, 'updated', false).substring(0, 10);
      result.remoteVersionName = tag;
      result.remoteVersionCode = remoteCode;

      const hasUpdate = remoteCode > 0
        ? remoteCode > local.versionCode
        : UpdateChecker.compareVersionNames(tag, local.versionName) > 0;
      result.status = hasUpdate ? 'updateAvailable' : 'upToDate';
      logger.info(`check done status=${result.status} remote=${tag}(${remoteCode}) `
        + `via=${remoteCode > 0 ? 'versionCode' : 'versionName'}`);
    } catch (e) {
      result.error = (e as Error).message || String(e);
      result.rateLimited = /HTTP 403|rate.?limit/i.test(result.error);
      logger.error(`check failed: ${result.error} rateLimited=${result.rateLimited}`);
    }
    result.checkedAt = Date.now();
    UpdateChecker.lastResult = result;
    return result;
  }

  private static readLocalVersion(): LocalVersion {
    const version = getAppVersion();
    const local: LocalVersion = { versionName: version.versionName, versionCode: version.versionCode };
    return local;
  }

  /** 可选：拿 release 资产的 version.json 得到 versionCode（失败只降级为版本号比较）。 */
  private static async fetchVersionCode(): Promise<number> {
    try {
      const parsed = await UpdateChecker.requestJson(LATEST_VERSION_JSON_URL) as RemoteVersionJson;
      const code = parsed.versionCode ?? 0;
      if (code > 0) {
        return code;
      }
      logger.warn(`version.json missing versionCode: name=${parsed.versionName || ''}`);
    } catch (e) {
      logger.warn(`version.json unavailable: ${(e as Error).message || String(e)}`);
    }
    return 0;
  }

  static normalizeVersionName(tag: string): string {
    return tag.trim().replace(/^[vV]/, '');
  }

  /** Numeric dotted compare: 0.5.10 > 0.5.6. Returns >0 when a > b. */
  static compareVersionNames(a: string, b: string): number {
    const pa = UpdateChecker.normalizeVersionName(a).split('.');
    const pb = UpdateChecker.normalizeVersionName(b).split('.');
    const len = Math.max(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
      const na = i < pa.length ? (parseInt(pa[i], 10) || 0) : 0;
      const nb = i < pb.length ? (parseInt(pb[i], 10) || 0) : 0;
      if (na !== nb) {
        return na - nb;
      }
    }
    return 0;
  }

  // ── Atom 解析 ──────────────────────────────────────────────────────────────

  private static firstEntry(xml: string): string {
    const start = xml.indexOf('<entry>');
    const end = xml.indexOf('</entry>', start);
    if (start < 0 || end < 0) {
      return '';
    }
    return xml.substring(start, end);
  }

  /**
   * 取 XML 标签内容。link 是自闭合标签（<link href="..."/>），单独处理。
   */
  private static xmlValue(entry: string, tag: string, isLink: boolean): string {
    if (isLink) {
      const re = new RegExp(`<link[^>]*href="([^"]+)"`, 'i');
      const match = re.exec(entry);
      return match ? match[1] : '';
    }
    const re = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, 'i');
    const match = re.exec(entry);
    return match ? match[1] : '';
  }

  private static tagFromLink(link: string): string {
    const index = link.lastIndexOf('/releases/tag/');
    if (index < 0) {
      return '';
    }
    const raw = decodeURIComponent(link.substring(index + '/releases/tag/'.length));
    // 发布 tag 形如 v0.7.0 或 v0.7.0-1000031；只取语义版本用于展示/比较，
    // 精确版本以 version.json 的 versionCode 为准。
    const match = /^[vV]?(\d+(?:\.\d+)*)/.exec(raw);
    return match ? match[1] : UpdateChecker.normalizeVersionName(raw);
  }

  private static decodeEntities(text: string): string {
    return text
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&');
  }

  private static htmlToText(html: string): string {
    return html
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/(p|div|li|h[1-6])>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/[ \t]+/g, ' ')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  private static trimNotes(body: string): string {
    const trimmed = body.trim();
    if (trimmed.length <= MAX_NOTES_CHARS) {
      return trimmed;
    }
    return trimmed.substring(0, MAX_NOTES_CHARS) + '…';
  }

  // ── HTTP ───────────────────────────────────────────────────────────────────

  private static requestText(url: string, accept: string): Promise<string> {
    return UpdateChecker.request(url, accept).then((body: string | Object | ArrayBuffer) => {
      return UpdateChecker.toText(body);
    });
  }

  private static requestJson(url: string): Promise<Object> {
    return UpdateChecker.request(url, 'application/vnd.github+json').then(
      (body: string | Object | ArrayBuffer) => {
        if (typeof body === 'object' && !(body instanceof ArrayBuffer)) {
          return body as Object;
        }
        return JSON.parse(UpdateChecker.toText(body)) as Object;
      });
  }

  private static request(url: string, accept: string): Promise<string | Object | ArrayBuffer> {
    const request = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'YourPipe-UpdateChecker',
        'Accept': accept
      },
      connectTimeout: 10000,
      readTimeout: 15000,
      usingCache: false
    };
    HttpDownloader.applyProxyToOptions(options, url);
    const startedAt = Date.now();
    return request.request(url, options).then((response: http.HttpResponse) => {
      logger.info(`GET ${UpdateChecker.hostOf(url)} status=${response.responseCode} `
        + `elapsed=${Date.now() - startedAt}ms`);
      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode} for ${UpdateChecker.hostOf(url)}`);
      }
      return response.result;
    }).finally(() => {
      request.destroy();
    });
  }

  private static toText(body: string | Object | ArrayBuffer): string {
    if (typeof body === 'string') {
      return body;
    }
    if (body instanceof ArrayBuffer) {
      return new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(body));
    }
    try {
      return JSON.stringify(body);
    } catch (_e) {
      return '';
    }
  }

  /** 日志只保留 host，避免把长链接写进日志。 */
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
