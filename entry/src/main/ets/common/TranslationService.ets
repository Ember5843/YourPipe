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
