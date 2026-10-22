import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HttpDownloader } from 'youtube_core';
import { AppLog } from './AppLog';
import { UIConfig } from './AppState';
import { LanguageManager } from './LanguageManager';
import { LlmTranslateConfig } from './LlmTranslateConfig';
import { LlmClient } from './translate/LlmClient';

const logger = AppLog.getInstance('TranslationService');

const GTEX_URL = 'https://translate.googleapis.com/translate_a/single';

interface LibreRequest {
  q: string | string[];
  source: string;
  target: string;
  format: string;
  api_key?: string;
}

interface LibreResponse {
  translatedText?: string | string[];
  error?: string;
}

interface DeepLTranslation {
  text?: string;
}

interface DeepLResponse {
  translations?: DeepLTranslation[];
  message?: string;
}

interface GoogleTranslation {
  translatedText?: string;
}

interface GoogleData {
  translations?: GoogleTranslation[];
}

interface GoogleError {
  message?: string;
}

interface GoogleResponse {
  data?: GoogleData;
  error?: GoogleError;
}

interface GoogleRequest {
  q: string | string[];
  target: string;
  format: string;
}

interface AzureInput {
  Text: string;
}

interface AzureTranslation {
  text?: string;
  to?: string;
}

interface AzureResult {
  translations?: AzureTranslation[];
}

interface MyMemoryData {
  translatedText?: string;
}

interface MyMemoryResponse {
  responseData?: MyMemoryData;
  responseStatus?: number;
  responseDetails?: string;
}

/**
 * 多接口翻译服务（评论 / 简介）。
 *
 * 接口由 LlmTranslateConfig.engine 选择：
 * gtx / Google Cloud / MyMemory / Lingva / LibreTranslate / DeepL / Azure /
 * OpenAI 兼容 LLM / 自定义。
 * 所有请求都走 HttpDownloader 的代理注入；目标语言仍由内容翻译设置决定。
 * 缓存 key 包含接口与端点，切换接口不会误用旧译文。
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
    const dash = applied.indexOf('-');
    return dash > 0 ? applied.substring(0, dash) : applied;
  }

  /** Translation is offered for every non-empty comment. */
  static shouldOfferTranslation(text: string): boolean {
    return !!text && text.trim().length > 0;
  }

  static getCached(text: string): string | undefined {
    return TranslationService.cache.get(TranslationService.keyOf(text));
  }

  static clearCache(): void {
    TranslationService.cache.clear();
  }

  static async translate(text: string): Promise<string> {
    const key = TranslationService.keyOf(text);
    const hit = TranslationService.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const target = TranslationService.targetLanguage();
    const cfg = LlmTranslateConfig.get();
    const startedAt = Date.now();
    logger.info(`translate start engine=${cfg.engine} tl=${target} len=${text.length}`);
    try {
      const translated = await TranslationService.dispatch(text, target, cfg);
      if (!translated || translated.trim().length === 0) {
        throw new Error('empty translation result');
      }
      TranslationService.putCache(key, translated);
      logger.info(`translate done engine=${cfg.engine} tl=${target} len=${text.length} `
        + `elapsed=${Date.now() - startedAt}ms`);
      return translated;
    } catch (e) {
      const err = e as Error;
      logger.warn(`translate failed engine=${cfg.engine} tl=${target} len=${text.length}: `
        + `${err.message || String(e)}`);
      throw new Error(err.message || 'translate failed');
    }
  }

  /**
   * 批量翻译（AI 字幕）：按当前接口选择批量方式；不支持批量的接口逐个请求。
   * 返回与输入等长数组；任何一条失败都会抛错，调用方负责重试/回填。
   */
  static async translateBatch(texts: string[], target: string): Promise<string[]> {
    if (texts.length === 0) {
      return [];
    }
    const cfg = LlmTranslateConfig.get();
    const startedAt = Date.now();
    logger.info(`translateBatch start engine=${cfg.engine} tl=${target} lines=${texts.length}`);
    try {
      let out: string[];
      if (cfg.engine === 'gtx') {
        out = await TranslationService.translateGtxBatch(texts, target);
      } else if (cfg.engine === 'google') {
        out = await TranslationService.translateGoogleBatch(texts, target, cfg);
      } else if (cfg.engine === 'llm') {
        out = await LlmClient.translateBatch(texts, target, cfg);
      } else if (cfg.engine === 'libretranslate') {
        out = await TranslationService.translateLibreBatch(texts, target, cfg);
      } else if (cfg.engine === 'deepl') {
        out = await TranslationService.translateDeepLBatch(texts, target, cfg);
      } else if (cfg.engine === 'azure') {
        out = await TranslationService.translateAzureBatch(texts, target, cfg);
      } else {
        out = [];
        for (let i = 0; i < texts.length; i++) {
          out.push(await TranslationService.dispatch(texts[i], target, cfg));
        }
      }
      logger.info(`translateBatch done engine=${cfg.engine} tl=${target} lines=${texts.length} `
        + `elapsed=${Date.now() - startedAt}ms`);
      return out;
    } catch (e) {
      const err = e as Error;
      logger.warn(`translateBatch failed engine=${cfg.engine} tl=${target} lines=${texts.length}: `
        + `${err.message || String(e)}`);
      throw new Error(err.message || 'translateBatch failed');
    }
  }

  /** 设置页“测试连接”：走一次真实翻译（不读缓存）。 */
  static async testProvider(): Promise<void> {
    const cfg = LlmTranslateConfig.get();
    if (cfg.engine === 'llm' && !cfg.isLlmReady()) {
      throw new Error('llm config incomplete');
    }
    if (cfg.engine === 'custom' && !cfg.isCustomReady()) {
      throw new Error('custom endpoint empty');
    }
    if (cfg.engine === 'deepl' && cfg.apiKey.trim().length === 0) {
      throw new Error('deepl api key empty');
    }
    await TranslationService.dispatch('hello', TranslationService.targetLanguage(), cfg);
  }

  private static async dispatch(text: string, target: string, cfg: LlmTranslateConfig): Promise<string> {
    switch (cfg.engine) {
      case 'google': return TranslationService.translateGoogle(text, target, cfg);
      case 'mymemory': return TranslationService.translateMyMemory(text, target, cfg);
      case 'lingva': return TranslationService.translateLingva(text, target, cfg);
      case 'libretranslate': return TranslationService.translateLibre(text, target, cfg);
      case 'deepl': return TranslationService.translateDeepL(text, target, cfg);
      case 'azure': return TranslationService.translateAzure(text, target, cfg);
      case 'llm': return TranslationService.translateLlm(text, target, cfg);
      case 'custom': return TranslationService.translateCustom(text, target, cfg);
      case 'gtx':
      default: return TranslationService.translateGtx(text, target);
    }
  }

  // ── Google gtx ────────────────────────────────────────────────

  private static async translateGtx(text: string, target: string): Promise<string> {
    const url = GTEX_URL
      + '?client=gtx&sl=auto&dt=t&tl=' + encodeURIComponent(target)
      + '&q=' + encodeURIComponent(text);
    const response = await TranslationService.request(url, http.RequestMethod.GET,
      { 'User-Agent': 'YourPipe-Translation' }, undefined, 15000);
    TranslationService.ensureOk(response, 'gtx');
    const translated = TranslationService.parseGtxResponse(response.result);
    if (!translated) {
      throw new Error('empty gtx translation');
    }
    return translated;
  }

  private static async translateGtxBatch(texts: string[], target: string): Promise<string[]> {
    const block = texts.map((t: string, i: number) => `${i + 1}\t${t.replace(/\r?\n/g, ' ')}`).join('\n');
    const url = GTEX_URL
      + '?client=gtx&sl=auto&dt=t&tl=' + encodeURIComponent(target)
      + '&q=' + encodeURIComponent(block);
    const response = await TranslationService.request(url, http.RequestMethod.GET,
      { 'User-Agent': 'YourPipe-Translation' }, undefined, 20000);
    TranslationService.ensureOk(response, 'gtx');
    const segments = TranslationService.parseGtxSegments(response.result);
    return TranslationService.alignBatchSegments(segments, texts);
  }

  // ── Google Cloud Translation v2（API Key） ───────────────────

  private static async translateGoogle(text: string, target: string, cfg: LlmTranslateConfig): Promise<string> {
    const out = await TranslationService.translateGoogleBatch([text], target, cfg);
    return out[0];
  }

  private static async translateGoogleBatch(
    texts: string[],
    target: string,
    cfg: LlmTranslateConfig
  ): Promise<string[]> {
    const key = cfg.apiKey.trim();
    if (key.length === 0) {
      throw new Error('google cloud api key empty');
    }
    const base = TranslationService.endpointOf(cfg,
      'https://translation.googleapis.com/language/translate/v2');
    const url = `${base}${base.indexOf('?') >= 0 ? '&' : '?'}key=${encodeURIComponent(key)}`;
    const body: GoogleRequest = {
      q: texts.length === 1 ? texts[0] : texts,
      target: TranslationService.toGoogleCode(target),
      format: 'text'
    };
    const response = await TranslationService.request(url, http.RequestMethod.POST,
      { 'Content-Type': 'application/json', 'User-Agent': 'YourPipe-Translation' },
      JSON.stringify(body), 30000);
    TranslationService.ensureOk(response, 'google');
    const json = TranslationService.asJson(response.result) as GoogleResponse;
    if (json.error) {
      throw new Error(json.error.message || 'google translate error');
    }
    const translations = json.data?.translations;
    if (!translations || translations.length !== texts.length) {
      throw new Error('google response mismatch');
    }
    return translations.map((item: GoogleTranslation): string =>
      TranslationService.decodeHtml(item.translatedText || ''));
  }

  // ── MyMemory（免费） ─────────────────────────────────────────

  private static async translateMyMemory(text: string, target: string, cfg: LlmTranslateConfig): Promise<string> {
    // MyMemory 单次请求限制约 500 字节；长简介按空白切块后逐段翻译。
    if (text.length > 450) {
      const chunks = TranslationService.chunkText(text, 450);
      const parts: string[] = [];
      for (let i = 0; i < chunks.length; i++) {
        parts.push(await TranslationService.translateMyMemoryChunk(chunks[i], target, cfg));
      }
      return parts.join(' ').trim();
    }
    return TranslationService.translateMyMemoryChunk(text, target, cfg);
  }

  private static async translateMyMemoryChunk(
    text: string,
    target: string,
    cfg: LlmTranslateConfig
  ): Promise<string> {
    const base = TranslationService.endpointOf(cfg, 'https://api.mymemory.translated.net');
    // MyMemory 不接受 "auto"，但支持 "autodetect"。
    const langPair = `autodetect|${TranslationService.toMyMemoryCode(target)}`;
    const url = `${base}/get?q=${encodeURIComponent(text)}&langpair=${encodeURIComponent(langPair)}`;
    const response = await TranslationService.request(url, http.RequestMethod.GET,
      { 'User-Agent': 'YourPipe-Translation' }, undefined, 20000);
    TranslationService.ensureOk(response, 'mymemory');
    const json = TranslationService.asJson(response.result) as MyMemoryResponse;
    const translated = json.responseData?.translatedText;
    if (!translated || translated.trim().length === 0) {
      throw new Error(json.responseDetails || 'empty mymemory translation');
    }
    return TranslationService.decodeHtml(translated);
  }

  // ── Lingva（Google 代理，免费实例） ─────────────────────────

  private static async translateLingva(text: string, target: string, cfg: LlmTranslateConfig): Promise<string> {
    const base = TranslationService.endpointOf(cfg, 'https://lingva.ml').replace(/\/+$/, '');
    const url = `${base}/api/v1/auto/${encodeURIComponent(TranslationService.toLingvaCode(target))}`
      + `/${encodeURIComponent(text)}`;
    const response = await TranslationService.request(url, http.RequestMethod.GET,
      { 'User-Agent': 'YourPipe-Translation' }, undefined, 20000);
    TranslationService.ensureOk(response, 'lingva');
    const json = TranslationService.asJson(response.result) as Record<string, Object>;
    const translated = json['translation'] as string;
    if (!translated || translated.trim().length === 0) {
      throw new Error('empty lingva translation');
    }
    return translated;
  }

  // ── LibreTranslate ──────────────────────────────────────────

  private static async translateLibre(text: string, target: string, cfg: LlmTranslateConfig): Promise<string> {
    const out = await TranslationService.translateLibreBatch([text], target, cfg);
    return out[0];
  }

  private static async translateLibreBatch(
    texts: string[],
    target: string,
    cfg: LlmTranslateConfig
  ): Promise<string[]> {
    const base = TranslationService.endpointOf(cfg, 'https://libretranslate.com').replace(/\/+$/, '');
    const body: LibreRequest = {
      q: texts.length === 1 ? texts[0] : texts,
      source: 'auto',
      target: TranslationService.toLibreCode(target),
      format: 'text'
    };
    if (cfg.apiKey.trim().length > 0) {
      body.api_key = cfg.apiKey.trim();
    }
    const response = await TranslationService.request(`${base}/translate`, http.RequestMethod.POST,
      { 'Content-Type': 'application/json', 'User-Agent': 'YourPipe-Translation' },
      JSON.stringify(body), 30000);
    TranslationService.ensureOk(response, 'libretranslate');
    const json = TranslationService.asJson(response.result) as LibreResponse;
    if (json.error) {
      throw new Error(json.error);
    }
    const translated = json.translatedText;
    if (typeof translated === 'string') {
      return [translated];
    }
    if (Array.isArray(translated) && translated.length === texts.length) {
      return translated as string[];
    }
    // 部分实例不支持数组：逐个重试。
    const out: string[] = [];
    for (let i = 0; i < texts.length; i++) {
      const single = await TranslationService.translateLibreSingle(texts[i], target, base, cfg);
      out.push(single);
    }
    return out;
  }

  private static async translateLibreSingle(
    text: string,
    target: string,
    base: string,
    cfg: LlmTranslateConfig
  ): Promise<string> {
    const body: LibreRequest = {
      q: text,
      source: 'auto',
      target: TranslationService.toLibreCode(target),
      format: 'text'
    };
    if (cfg.apiKey.trim().length > 0) {
      body.api_key = cfg.apiKey.trim();
    }
    const response = await TranslationService.request(`${base}/translate`, http.RequestMethod.POST,
      { 'Content-Type': 'application/json', 'User-Agent': 'YourPipe-Translation' },
      JSON.stringify(body), 30000);
    TranslationService.ensureOk(response, 'libretranslate');
    const json = TranslationService.asJson(response.result) as LibreResponse;
    if (json.error) {
      throw new Error(json.error);
    }
    const translated = json.translatedText;
    if (typeof translated !== 'string' || translated.trim().length === 0) {
      throw new Error('empty libretranslate translation');
    }
    return translated;
  }

  // ── DeepL ───────────────────────────────────────────────────

  private static async translateDeepL(text: string, target: string, cfg: LlmTranslateConfig): Promise<string> {
    const out = await TranslationService.translateDeepLBatch([text], target, cfg);
    return out[0];
  }

  private static async translateDeepLBatch(
    texts: string[],
    target: string,
    cfg: LlmTranslateConfig
  ): Promise<string[]> {
    const key = cfg.apiKey.trim();
    if (key.length === 0) {
      throw new Error('deepl api key empty');
    }
    const base = TranslationService.endpointOf(cfg, 'https://api-free.deepl.com').replace(/\/+$/, '');
    const url = base.endsWith('/v2/translate') ? base : `${base}/v2/translate`;
    const params: string[] = [
      `target_lang=${encodeURIComponent(TranslationService.toDeepLCode(target))}`
    ];
    texts.forEach((t: string) => {
      params.push(`text=${encodeURIComponent(t)}`);
    });
    const response = await TranslationService.request(url, http.RequestMethod.POST, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Authorization': `DeepL-Auth-Key ${key}`,
      'User-Agent': 'YourPipe-Translation'
    }, params.join('&'), 30000);
    TranslationService.ensureOk(response, 'deepl');
    const json = TranslationService.asJson(response.result) as DeepLResponse;
    const translations = json.translations;
    if (!translations || translations.length !== texts.length) {
      throw new Error(json.message || 'deepl response mismatch');
    }
    return translations.map((item: DeepLTranslation): string => item.text || '');
  }

  // ── Microsoft Translator（Azure） ──────────────────────────

  private static async translateAzure(text: string, target: string, cfg: LlmTranslateConfig): Promise<string> {
    const out = await TranslationService.translateAzureBatch([text], target, cfg);
    return out[0];
  }

  private static async translateAzureBatch(
    texts: string[],
    target: string,
    cfg: LlmTranslateConfig
  ): Promise<string[]> {
    const key = cfg.apiKey.trim();
    if (key.length === 0) {
      throw new Error('azure api key empty');
    }
    const base = TranslationService.endpointOf(cfg,
      'https://api.cognitive.microsofttranslator.com').replace(/\/+$/, '');
    const baseUrl = base.endsWith('/translate') ? base : `${base}/translate`;
    const url = `${baseUrl}${baseUrl.indexOf('?') >= 0 ? '&' : '?'}api-version=3.0&to=`
      + encodeURIComponent(TranslationService.toAzureCode(target));
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Ocp-Apim-Subscription-Key': key,
      'User-Agent': 'YourPipe-Translation'
    };
    if (cfg.region.trim().length > 0) {
      headers['Ocp-Apim-Subscription-Region'] = cfg.region.trim();
    }
    const body: AzureInput[] = texts.map((t: string): AzureInput => {
      return { Text: t } as AzureInput;
    });
    const response = await TranslationService.request(url, http.RequestMethod.POST,
      headers, JSON.stringify(body), 30000);
    TranslationService.ensureOk(response, 'azure');
    const json = TranslationService.asJsonArray(response.result);
    if (json.length !== texts.length) {
      throw new Error('azure response mismatch');
    }
    return json.map((item: Object): string => {
      const result = item as AzureResult;
      const translated = result.translations?.[0]?.text;
      if (!translated) {
        throw new Error('empty azure translation');
      }
      return translated;
    });
  }

  // ── LLM（OpenAI 兼容） ──────────────────────────────────────

  private static async translateLlm(text: string, target: string, cfg: LlmTranslateConfig): Promise<string> {
    const out = await LlmClient.translateBatch([text], target, cfg);
    return out[0];
  }

  // ── 自定义接口 ──────────────────────────────────────────────

  private static async translateCustom(text: string, target: string, cfg: LlmTranslateConfig): Promise<string> {
    const template = cfg.customUrl.trim();
    if (template.length === 0) {
      throw new Error('custom endpoint empty');
    }
    if (!/^https?:\/\//i.test(template)) {
      throw new Error('custom endpoint must be http(s)');
    }
    const method = cfg.customMethod === 'GET' ? http.RequestMethod.GET : http.RequestMethod.POST;
    let url = TranslationService.fillTemplate(template, text, target, cfg.apiKey, true);
    if (method === http.RequestMethod.GET && template.indexOf('{text}') < 0) {
      url += (url.indexOf('?') >= 0 ? '&' : '?')
        + `text=${encodeURIComponent(text)}&target=${encodeURIComponent(target)}&source=auto`;
    }
    const headers = TranslationService.parseHeaders(cfg.customHeaders);
    if (Object.keys(headers).length === 0) {
      headers['Content-Type'] = 'application/json';
    }
    headers['User-Agent'] = 'YourPipe-Translation';
    let body: string | undefined = undefined;
    if (method === http.RequestMethod.POST) {
      const templateBody = cfg.customBody.trim().length > 0
        ? cfg.customBody
        : '{"text":"{text}","target_lang":"{target}"}';
      body = TranslationService.fillTemplate(templateBody, text, target, cfg.apiKey, false);
    }
    const response = await TranslationService.request(url, method, headers, body, 30000);
    TranslationService.ensureOk(response, 'custom');
    const responseText = TranslationService.asText(response.result);
    const path = cfg.customResponsePath.trim();
    if (path.length === 0) {
      return responseText;
    }
    const json = TranslationService.asJson(response.result);
    const value = TranslationService.getByPath(json, path);
    if (typeof value === 'string') {
      return value;
    }
    if (Array.isArray(value) && value.length > 0 && typeof value[0] === 'string') {
      return value[0] as string;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return `${value}`;
    }
    throw new Error(`custom response path "${path}" did not resolve to text`);
  }

  private static fillTemplate(
    template: string,
    text: string,
    target: string,
    apiKey: string,
    encodeText: boolean
  ): string {
    const encodedText = encodeText ? encodeURIComponent(text) : text;
    const encodedTarget = encodeText ? encodeURIComponent(target) : target;
    const encodedKey = encodeText ? encodeURIComponent(apiKey) : apiKey;
    return template
      .split('{text}').join(encodedText)
      .split('{target}').join(encodedTarget)
      .split('{source}').join('auto')
      .split('{apiKey}').join(encodedKey);
  }

  private static parseHeaders(raw: string): Record<string, string> {
    const out: Record<string, string> = {};
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      return out;
    }
    if (trimmed.startsWith('{')) {
      const parsed = JSON.parse(trimmed) as Record<string, Object>;
      for (const key of Object.keys(parsed)) {
        out[key] = `${parsed[key]}`;
      }
      return out;
    }
    trimmed.split(/\r?\n/).forEach((line: string) => {
      const idx = line.indexOf(':');
      if (idx > 0) {
        out[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
      }
    });
    return out;
  }

  private static getByPath(root: Object, path: string): Object | undefined {
    let current: Object | undefined = root;
    const parts = path.split('.');
    for (const part of parts) {
      if (current === undefined || current === null) {
        return undefined;
      }
      if (Array.isArray(current)) {
        const index = Number(part);
        if (!Number.isInteger(index) || index < 0) {
          return undefined;
        }
        current = (current as Array<Object>)[index];
      } else {
        current = (current as Record<string, Object>)[part];
      }
    }
    return current;
  }

  // ── HTTP / parsing helpers ─────────────────────────────────

  private static async request(
    url: string,
    method: http.RequestMethod,
    header: Record<string, string>,
    body: string | undefined,
    readTimeout: number
  ): Promise<http.HttpResponse> {
    const request = http.createHttp();
    const options: http.HttpRequestOptions = {
      method,
      header,
      connectTimeout: 10000,
      readTimeout
    };
    if (body !== undefined) {
      options.extraData = body;
    }
    HttpDownloader.applyProxyToOptions(options, url);
    try {
      return await request.request(url, options);
    } finally {
      request.destroy();
    }
  }

  private static endpointOf(cfg: LlmTranslateConfig, fallback: string): string {
    const configured = cfg.endpoint.trim();
    return configured.length > 0 ? configured : fallback;
  }

  private static ensureOk(response: http.HttpResponse, provider: string): void {
    if (response.responseCode !== 200) {
      throw new Error(`${provider} HTTP ${response.responseCode}`);
    }
  }

  private static asText(body: string | Object | ArrayBuffer): string {
    if (typeof body === 'string') {
      return body;
    }
    if (body instanceof ArrayBuffer) {
      return new util.TextDecoder('utf-8').decodeWithStream(new Uint8Array(body));
    }
    return JSON.stringify(body);
  }

  private static asJson(body: string | Object | ArrayBuffer): Record<string, Object> {
    return JSON.parse(TranslationService.asText(body)) as Record<string, Object>;
  }

  private static asJsonArray(body: string | Object | ArrayBuffer): Array<Object> {
    return JSON.parse(TranslationService.asText(body)) as Array<Object>;
  }

  private static chunkText(text: string, maxLen: number): string[] {
    const chunks: string[] = [];
    let rest = text;
    while (rest.length > maxLen) {
      let cut = maxLen;
      const space = rest.lastIndexOf(' ', maxLen);
      if (space > maxLen / 2) {
        cut = space;
      }
      chunks.push(rest.substring(0, cut).trim());
      rest = rest.substring(cut).trim();
    }
    if (rest.length > 0) {
      chunks.push(rest);
    }
    return chunks;
  }

  private static decodeHtml(text: string): string {
    return text
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>');
  }

  private static toMyMemoryCode(target: string): string {
    if (target === 'zh-CN') {
      return 'zh-CN';
    }
    if (target === 'zh-HK') {
      return 'zh-HK';
    }
    if (target === 'zh-TW') {
      return 'zh-TW';
    }
    return target;
  }

  private static toLingvaCode(target: string): string {
    if (target === 'zh-CN') {
      return 'zh';
    }
    if (target === 'zh-HK' || target === 'zh-TW') {
      return 'zh_HANT';
    }
    return target.split('-')[0];
  }

  private static toLibreCode(target: string): string {
    if (target === 'zh-CN') {
      return 'zh';
    }
    if (target === 'zh-HK' || target === 'zh-TW') {
      return 'zt';
    }
    return target.split('-')[0];
  }

  private static toDeepLCode(target: string): string {
    if (target === 'zh-CN') {
      return 'ZH-HANS';
    }
    if (target === 'zh-HK' || target === 'zh-TW') {
      return 'ZH-HANT';
    }
    if (target.startsWith('en')) {
      return 'EN-US';
    }
    if (target.startsWith('pt')) {
      return 'PT-BR';
    }
    return target.toUpperCase();
  }

  private static toAzureCode(target: string): string {
    if (target === 'zh-CN') {
      return 'zh-Hans';
    }
    if (target === 'zh-HK' || target === 'zh-TW') {
      return 'zh-Hant';
    }
    return target.split('-')[0].toLowerCase();
  }

  private static keyOf(text: string): string {
    const cfg = LlmTranslateConfig.get();
    return `${cfg.engine}|${cfg.endpoint}|${cfg.baseUrl}|${cfg.model}|${cfg.customUrl}|`
      + `${TranslationService.targetLanguage()}:${text}`;
  }

  private static putCache(key: string, value: string): void {
    if (TranslationService.cache.size >= TranslationService.MAX_CACHE_ENTRIES) {
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

  /** gtx 返回 [[[译文,原文,...], 每源行一段], null, "srcLang", ...]，取所有段的首元素。 */
  private static parseGtxSegments(body: string | Object | ArrayBuffer): string[] {
    const parsed = JSON.parse(TranslationService.asText(body)) as Object;
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

  /** 段 → 输入行对齐：编号优先，缺失过多时顺序兜底，未覆盖回填原文。 */
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
    const stripped = segments.map((s: string) => s.replace(/^(\d+)[\t ]+/, '').trim());
    return texts.map((t: string, i: number) => (i < stripped.length && stripped[i].length > 0) ? stripped[i] : t);
  }

  /** gtx returns nested arrays: [[["译文","原文",...],...],...,"srcLang"]. */
  private static parseGtxResponse(body: string | Object | ArrayBuffer): string {
    const parsed = JSON.parse(TranslationService.asText(body)) as Object;
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
