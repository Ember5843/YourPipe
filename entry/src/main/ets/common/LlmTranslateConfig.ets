import { PreferencesStore } from './PreferencesStore';

/**
 * AI 字幕翻译配置（P2）。PreferencesStore 持久化，内存单例缓存。
 * 目标语言不在此处：与评论翻译共用 TranslationService.targetLanguage()
 * （Options → 语言与地区 → 内容翻译语言）。
 *
 * 引擎：
 * - gtx：Google 免费翻译端点（复用 TranslationService 通道），零配置默认；
 * - llm：用户自带 key 的 OpenAI 兼容端点，质量更高。
 */
export class LlmTranslateConfig {
  engine: string = 'gtx';
  baseUrl: string = 'https://api.deepseek.com';
  model: string = 'deepseek-chat';
  apiKey: string = '';
  bilingual: boolean = true;

  private static instance: LlmTranslateConfig | null = null;

  static get(): LlmTranslateConfig {
    if (!LlmTranslateConfig.instance) {
      LlmTranslateConfig.instance = LlmTranslateConfig.load();
    }
    return LlmTranslateConfig.instance;
  }

  static load(): LlmTranslateConfig {
    const cfg = new LlmTranslateConfig();
    cfg.engine = PreferencesStore.getString('cfg_ai_translate_engine', 'gtx');
    cfg.baseUrl = PreferencesStore.getString('cfg_ai_translate_base_url', 'https://api.deepseek.com');
    cfg.model = PreferencesStore.getString('cfg_ai_translate_model', 'deepseek-chat');
    cfg.apiKey = PreferencesStore.getString('cfg_ai_translate_api_key', '');
    cfg.bilingual = PreferencesStore.getString('cfg_ai_translate_bilingual', 'true') === 'true';
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
    PreferencesStore.setString('cfg_ai_translate_base_url', this.baseUrl);
    PreferencesStore.setString('cfg_ai_translate_model', this.model);
    PreferencesStore.setString('cfg_ai_translate_api_key', this.apiKey);
    PreferencesStore.setString('cfg_ai_translate_bilingual', this.bilingual ? 'true' : 'false');
  }

  isLlmReady(): boolean {
    return this.engine === 'llm'
      && this.baseUrl.trim().length > 0
      && this.model.trim().length > 0
      && this.apiKey.trim().length > 0;
  }
}
