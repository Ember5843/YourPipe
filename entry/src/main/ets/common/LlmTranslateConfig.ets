import { PreferencesStore } from './PreferencesStore';

/** 评论/简介/字幕翻译可选的接口。 */
export const TRANSLATION_ENGINES: string[] = [
  'gtx',
  'google',
  'mymemory',
  'lingva',
  'libretranslate',
  'deepl',
  'azure',
  'llm',
  'custom'
];

export function getTranslationEngineDisplay(engine: string): Resource {
  switch (engine) {
    case 'google': return $r('app.string.yt_translation_engine_google');
    case 'mymemory': return $r('app.string.yt_translation_engine_mymemory');
    case 'lingva': return $r('app.string.yt_translation_engine_lingva');
    case 'libretranslate': return $r('app.string.yt_translation_engine_libre');
    case 'deepl': return $r('app.string.yt_translation_engine_deepl');
    case 'azure': return $r('app.string.yt_translation_engine_azure');
    case 'llm': return $r('app.string.yt_ai_translate_engine_llm');
    case 'custom': return $r('app.string.yt_translation_engine_custom');
    case 'gtx':
    default: return $r('app.string.yt_ai_translate_engine_gtx');
  }
}

/**
 * 翻译服务配置（评论 / 简介共用）。
 *
 * - gtx / mymemory / lingva：免 key 的公共端点；
 * - google / deepl / azure：官方接口，需 API Key（Azure 还需 Region）；
 * - libretranslate：自填官方/自建实例地址；
 * - llm：OpenAI 兼容 /v1/chat/completions；
 * - custom：URL / 方法 / 请求头 / 请求体 / 响应路径全部由用户模板决定。
 *
 * 目标语言不在这里：与内容翻译共用 TranslationService.targetLanguage()。
 */
export class LlmTranslateConfig {
  engine: string = 'gtx';
  /** 非 LLM 接口的地址（LibreTranslate / Lingva / DeepL / Azure；空 = 默认）。 */
  endpoint: string = '';
  /** LLM 的 OpenAI 兼容 Base URL。 */
  baseUrl: string = 'https://api.deepseek.com';
  model: string = 'deepseek-chat';
  apiKey: string = '';
  /** Microsoft Translator 区域（例如 eastasia / global）；其他接口忽略。 */
  region: string = '';
  bilingual: boolean = true;
  /** 自定义接口。 */
  customUrl: string = '';
  customMethod: string = 'POST';
  customHeaders: string = '{"Content-Type": "application/json"}';
  customBody: string = '{"text":"{text}","target_lang":"{target}"}';
  customResponsePath: string = 'translatedText';

  private static instance: LlmTranslateConfig | null = null;

  static get(): LlmTranslateConfig {
    if (!LlmTranslateConfig.instance) {
      LlmTranslateConfig.instance = LlmTranslateConfig.load();
    }
    return LlmTranslateConfig.instance;
  }

  /** 各接口的默认地址；UI 占位与 TranslationService 共用。 */
  static defaultEndpoint(engine: string): string {
    switch (engine) {
      case 'google': return 'https://translation.googleapis.com/language/translate/v2';
      case 'mymemory': return 'https://api.mymemory.translated.net';
      case 'lingva': return 'https://lingva.ml';
      case 'libretranslate': return 'https://libretranslate.com';
      case 'deepl': return 'https://api-free.deepl.com';
      case 'azure': return 'https://api.cognitive.microsofttranslator.com';
      case 'llm': return 'https://api.deepseek.com';
      default: return '';
    }
  }

  static load(): LlmTranslateConfig {
    const cfg = new LlmTranslateConfig();
    const engine = PreferencesStore.getString('cfg_ai_translate_engine', 'gtx');
    cfg.engine = TRANSLATION_ENGINES.includes(engine) ? engine : 'gtx';
    cfg.endpoint = PreferencesStore.getString('cfg_ai_translate_endpoint', '');
    cfg.baseUrl = PreferencesStore.getString('cfg_ai_translate_base_url', 'https://api.deepseek.com');
    cfg.model = PreferencesStore.getString('cfg_ai_translate_model', 'deepseek-chat');
    cfg.apiKey = PreferencesStore.getString('cfg_ai_translate_api_key', '');
    cfg.region = PreferencesStore.getString('cfg_ai_translate_region', '');
    cfg.bilingual = PreferencesStore.getString('cfg_ai_translate_bilingual', 'true') === 'true';
    cfg.customUrl = PreferencesStore.getString('cfg_ai_translate_custom_url', '');
    cfg.customMethod = PreferencesStore.getString('cfg_ai_translate_custom_method', 'POST') === 'GET'
      ? 'GET' : 'POST';
    cfg.customHeaders = PreferencesStore.getString('cfg_ai_translate_custom_headers',
      '{"Content-Type": "application/json"}');
    cfg.customBody = PreferencesStore.getString('cfg_ai_translate_custom_body',
      '{"text":"{text}","target_lang":"{target}"}');
    cfg.customResponsePath = PreferencesStore.getString('cfg_ai_translate_custom_response_path', 'translatedText');
    return cfg;
  }

  /** 恢复默认设置：内存与持久化一起复位（含 apiKey）。 */
  static reset(): void {
    LlmTranslateConfig.instance = new LlmTranslateConfig();
    LlmTranslateConfig.instance.save();
  }

  /** 配置变更后调用：替换单例并持久化。 */
  static update(next: LlmTranslateConfig): void {
    LlmTranslateConfig.instance = next;
    next.save();
  }

  save(): void {
    PreferencesStore.setString('cfg_ai_translate_engine', this.engine);
    PreferencesStore.setString('cfg_ai_translate_endpoint', this.endpoint);
    PreferencesStore.setString('cfg_ai_translate_base_url', this.baseUrl);
    PreferencesStore.setString('cfg_ai_translate_model', this.model);
    PreferencesStore.setString('cfg_ai_translate_api_key', this.apiKey);
    PreferencesStore.setString('cfg_ai_translate_bilingual', this.bilingual ? 'true' : 'false');
    PreferencesStore.setString('cfg_ai_translate_custom_url', this.customUrl);
    PreferencesStore.setString('cfg_ai_translate_custom_method', this.customMethod);
    PreferencesStore.setString('cfg_ai_translate_custom_headers', this.customHeaders);
    PreferencesStore.setString('cfg_ai_translate_custom_body', this.customBody);
    PreferencesStore.setString('cfg_ai_translate_custom_response_path', this.customResponsePath);
  }

  isLlmReady(): boolean {
    return this.engine === 'llm'
      && this.baseUrl.trim().length > 0
      && this.model.trim().length > 0
      && this.apiKey.trim().length > 0;
  }

  isCustomReady(): boolean {
    return this.engine === 'custom' && this.customUrl.trim().length > 0;
  }
}
