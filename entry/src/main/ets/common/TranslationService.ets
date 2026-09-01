import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HttpDownloader } from 'youtube_core';
import { AppLog } from './AppLog';
import { UIConfig } from './AppState';
import { LanguageManager } from './LanguageManager';

const logger = AppLog.getInstance('TranslationService');

const GTEX_URL = 'https://translate.googleapis.com/translate_a/single';

/**
 * Google Translate (free gtx endpoint) backed comment translation.
 * In-memory cache only — nothing persists, so no "clear app data" wiring.
 */
export class TranslationService {
  private static cache: Map<string, string> = new Map();
  private static readonly MAX_CACHE_ENTRIES: number = 500;

  /** Google language code for the app's current display language. */
  static targetLanguage(): string {
    const uiConfig: UIConfig = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
    const manual = uiConfig.translationLanguage;
    const applied = (manual && manual !== 'default')
      ? manual
      : LanguageManager.resolveAppliedLanguage(uiConfig);
    return TranslationService.toGoogleCode(applied);
  }

  /**
   * tlang 自动翻译字幕的目标语言：字幕专用设置优先，'default' 时跟随
   * 评论翻译语言（targetLanguage）。
   */
  static subtitleTargetLanguage(): string {
    const uiConfig: UIConfig = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
    const manual = uiConfig.subtitleTranslateLanguage;
    if (manual && manual !== 'default') {
      return TranslationService.toGoogleCode(manual);
    }
    return TranslationService.targetLanguage();
  }

  private static toGoogleCode(applied: string): string {
    if (applied.startsWith('zh-Hans')) {
      return 'zh-CN';
    }
    if (applied.startsWith('zh-HK')) {
      return 'zh-HK';
    }
    if (applied.startsWith('zh-TW')) {
      return 'zh-TW';
    }
    if (applied.startsWith('en')) {
      return 'en';
    }
    // ar / de / es / fr / ru etc. pass through (Google accepts ISO 639-1).
    const dash = applied.indexOf('-');
    return dash > 0 ? applied.substring(0, dash) : applied;
  }

  /**
   * Translation is offered for every non-empty comment. Local language
   * heuristics proved unreliable (Japanese kanji, mixed scripts), and a
   * same-language gtx request harmlessly echoes the original text.
   */
  static shouldOfferTranslation(text: string): boolean {
    return !!text && text.trim().length > 0;
  }

  static getCached(text: string): string | undefined {
    return TranslationService.cache.get(TranslationService.keyOf(text));
  }

  static async translate(text: string): Promise<string> {
    const key = TranslationService.keyOf(text);
    const hit = TranslationService.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const target = TranslationService.targetLanguage();
    const url = GTEX_URL
      + '?client=gtx&sl=auto&dt=t&tl=' + encodeURIComponent(target)
      + '&q=' + encodeURIComponent(text);
    const startedAt = Date.now();
    logger.info(`translate start tl=${target} len=${text.length}`);
    const request = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': 'YourPipe-Translation' },
      connectTimeout: 10000,
      readTimeout: 15000
    };
    HttpDownloader.applyProxyToOptions(options, url);
    try {
      const response = await request.request(url, options);
      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      const translated = TranslationService.parseGtxResponse(response.result);
      if (!translated) {
        throw new Error('empty translation result');
      }
      TranslationService.putCache(key, translated);
      logger.info(`translate done tl=${target} len=${text.length} elapsed=${Date.now() - startedAt}ms`);
      return translated;
    } catch (e) {
      const err = e as Error;
      logger.warn(`translate failed tl=${target} len=${text.length}: ${err.message || String(e)}`);
      throw new Error(err.message || 'translate failed');
    } finally {
      request.destroy();
    }
  }

  private static keyOf(text: string): string {
    return TranslationService.targetLanguage() + ':' + text;
  }

  private static putCache(key: string, value: string): void {
    if (TranslationService.cache.size >= TranslationService.MAX_CACHE_ENTRIES) {
      // Drop the oldest entries (Map iterates in insertion order).
      const drop = TranslationService.MAX_CACHE_ENTRIES / 2;
      let i = 0;
      for (const k of TranslationService.cache.keys()) {
        TranslationService.cache.delete(k);
        if (++i >= drop) {
          break;
        }
      }
    }
    TranslationService.cache.set(key, value);
  }

  /**
   * 批量翻译（AI 字幕 P2 用）：把多行文本以 "<编号>\t<文本>" 行块形式
   * 装进单个 gtx 请求（该端点对重复 q 参数只处理第一个，行块是可行的
   * 批量方式）。返回与输入等长、按编号对齐的数组；解析不齐时按段顺序
   * 兜底对齐，仍缺失的位置回填原文，绝不抛半截结果。
   */
  static async translateBatch(texts: string[], target: string): Promise<string[]> {
    if (texts.length === 0) {
      return [];
    }
    const block = texts.map((t: string, i: number) => `${i + 1}\t${t.replace(/\r?\n/g, ' ')}`).join('\n');
    const url = GTEX_URL
      + '?client=gtx&sl=auto&dt=t&tl=' + encodeURIComponent(target)
      + '&q=' + encodeURIComponent(block);
    const startedAt = Date.now();
    logger.info(`translateBatch start tl=${target} lines=${texts.length} len=${block.length}`);
    const request = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': 'YourPipe-Translation' },
      connectTimeout: 10000,
      readTimeout: 20000
    };
    HttpDownloader.applyProxyToOptions(options, url);
    try {
      const response = await request.request(url, options);
      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode}`);
      }
      const segments = TranslationService.parseGtxSegments(response.result);
      const out = TranslationService.alignBatchSegments(segments, texts);
      logger.info(`translateBatch done tl=${target} lines=${texts.length} elapsed=${Date.now() - startedAt}ms`);
      return out;
    } catch (e) {
      const err = e as Error;
      logger.warn(`translateBatch failed tl=${target} lines=${texts.length}: ${err.message || String(e)}`);
      throw new Error(err.message || 'translateBatch failed');
    } finally {
      request.destroy();
    }
  }

  /** gtx 返回 [[[译文,原文,...], 每源行一段], null, "srcLang", ...]，取所有段的首元素。 */
  private static parseGtxSegments(body: string | Object | ArrayBuffer): string[] {
    let parsed: Object;
    if (typeof body === 'string') {
      parsed = JSON.parse(body) as Object;
    } else if (body instanceof ArrayBuffer) {
      const text = new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(body));
      parsed = JSON.parse(text) as Object;
    } else {
      parsed = body;
    }
    const segments = (parsed as Array<Object>)[0] as Array<Array<string>>;
    if (!segments || !Array.isArray(segments)) {
      return [];
    }
    const out: string[] = [];
    for (const seg of segments) {
      if (seg && typeof seg[0] === 'string') {
        out.push(seg[0]);
      }
    }
    return out;
  }

  /**
   * 段 → 输入行对齐：优先解析行首编号（gtx 会把 "\t" 译成空格，兼容两种
   * 分隔）；编号缺失过多时退化为顺序对齐；未覆盖的行回填原文。
   */
  private static alignBatchSegments(segments: string[], texts: string[]): string[] {
    const byId: Map<number, string> = new Map();
    const lineRe = /^(\d+)[\t ]+([\s\S]*)$/;
    for (const seg of segments) {
      const m = lineRe.exec(seg.trim());
      if (m) {
        const id = parseInt(m[1], 10);
        if (id >= 1 && id <= texts.length && !byId.has(id)) {
          byId.set(id, m[2].trim());
        }
      }
    }
    if (byId.size >= Math.ceil(texts.length * 0.6)) {
      return texts.map((t: string, i: number) => byId.get(i + 1) || t);
    }
    // 顺序兜底：剥掉行首编号后按顺序对齐
    const stripped = segments.map((s: string) => s.replace(/^(\d+)[\t ]+/, '').trim());
    return texts.map((t: string, i: number) => (i < stripped.length && stripped[i].length > 0) ? stripped[i] : t);
  }

  /** gtx returns nested arrays: [[["译文","原文",...],...],...,"srcLang"]. */
  private static parseGtxResponse(body: string | Object | ArrayBuffer): string {
    let parsed: Object;
    if (typeof body === 'string') {
      parsed = JSON.parse(body) as Object;
    } else if (body instanceof ArrayBuffer) {
      const text = new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(body));
      parsed = JSON.parse(text) as Object;
    } else {
      parsed = body;
    }
    const segments = (parsed as Array<Object>)[0] as Array<Array<string>>;
    if (!segments || !Array.isArray(segments)) {
      return '';
    }
    let out = '';
    for (const seg of segments) {
      if (seg && typeof seg[0] === 'string') {
        out += seg[0];
      }
    }
    return out;
  }
}
