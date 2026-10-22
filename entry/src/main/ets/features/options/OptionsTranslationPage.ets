import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import {
  getTranslationEngineDisplay,
  LlmTranslateConfig,
  TRANSLATION_ENGINES
} from '../../common/LlmTranslateConfig';
import { TranslationService } from '../../common/TranslationService';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsTranslationPage');

export interface OptionsTranslationPageParams {
  themeColor: ResourceColor;
}

/**
 * 翻译服务设置：评论与简介翻译的接口选择与配置。
 *
 * 免 key：Google gtx、MyMemory、Lingva；
 * 需配置：Google Cloud / DeepL / Microsoft Translator（key，Azure 另需 region）、
 * LibreTranslate（地址 / 可选 key）、OpenAI 兼容 LLM、自定义接口。
 */
@Component
export struct OptionsTranslationPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop params: OptionsTranslationPageParams = { themeColor: '#E53935' };

  @State private engine: string = 'gtx';
  @State private endpoint: string = '';
  @State private baseUrl: string = 'https://api.deepseek.com';
  @State private model: string = 'deepseek-chat';
  @State private apiKey: string = '';
  @State private region: string = '';
  @State private customUrl: string = '';
  @State private customMethod: string = 'POST';
  @State private customHeaders: string = '{"Content-Type": "application/json"}';
  @State private customBody: string = '{"text":"{text}","target_lang":"{target}"}';
  @State private customResponsePath: string = 'translatedText';
  @State private testing: boolean = false;
  private testTimer: number = -1;
  private testGeneration: number = 0;

  aboutToAppear(): void {
    const cfg = LlmTranslateConfig.get();
    this.engine = cfg.engine;
    this.endpoint = cfg.endpoint;
    this.baseUrl = cfg.baseUrl;
    this.model = cfg.model;
    this.apiKey = cfg.apiKey;
    this.region = cfg.region;
    this.customUrl = cfg.customUrl;
    this.customMethod = cfg.customMethod;
    this.customHeaders = cfg.customHeaders;
    this.customBody = cfg.customBody;
    this.customResponsePath = cfg.customResponsePath;
  }

  aboutToDisappear(): void {
    this.testGeneration++;
    if (this.testTimer >= 0) {
      clearTimeout(this.testTimer);
      this.testTimer = -1;
    }
    this.persist();
  }

  private persist(): void {
    const next = new LlmTranslateConfig();
    next.engine = this.engine;
    next.endpoint = this.endpoint.trim();
    next.baseUrl = this.baseUrl.trim();
    next.model = this.model.trim();
    next.apiKey = this.apiKey.trim();
    next.region = this.region.trim();
    next.customUrl = this.customUrl.trim();
    next.customMethod = this.customMethod === 'GET' ? 'GET' : 'POST';
    next.customHeaders = this.customHeaders;
    next.customBody = this.customBody;
    next.customResponsePath = this.customResponsePath.trim();
    // 双语对照属于字幕显示偏好，不在本页编辑；保留原值。
    next.bilingual = LlmTranslateConfig.get().bilingual;
    LlmTranslateConfig.update(next);
    TranslationService.clearCache();
  }

  private getEngineOptions(): SelectOption[] {
    return TRANSLATION_ENGINES.map((engine: string): SelectOption => {
      return { value: getTranslationEngineDisplay(engine) } as SelectOption;
    });
  }

  private getMethodOptions(): SelectOption[] {
    return [
      { value: 'POST' } as SelectOption,
      { value: 'GET' } as SelectOption
    ];
  }

  private endpointPlaceholder(): string {
    return LlmTranslateConfig.defaultEndpoint(this.engine);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2200 });
    } catch (e) {
      logger.warn(`show toast failed: ${(e as Error).message || e}`);
    }
  }

  private runTest(): void {
    if (this.testing) {
      return;
    }
    try {
      this.persist();
    } catch (e) {
      logger.warn(`translation persist failed: ${(e as Error).message || e}`);
      this.toast(getContext().resourceManager.getStringSync(
        $r('app.string.yt_ai_translate_test_fail').id));
      return;
    }
    this.testing = true;
    const generation = ++this.testGeneration;
    this.toast(getContext().resourceManager.getStringSync(
      $r('app.string.yt_ai_translate_testing').id));
    if (this.testTimer >= 0) {
      clearTimeout(this.testTimer);
    }
    // 网络请求本身有 10–30s 超时；这里再加一道总超时，按钮不会永久卡在“测试中”。
    this.testTimer = setTimeout(() => {
      if (generation !== this.testGeneration) {
        return;
      }
      this.testGeneration++;
      this.testing = false;
      this.toast(getContext().resourceManager.getStringSync(
        $r('app.string.yt_ai_translate_test_fail').id));
      logger.warn(`translation test timeout engine=${this.engine}`);
    }, 40000);
    TranslationService.testProvider()
      .then(() => {
        if (generation !== this.testGeneration) {
          return;
        }
        this.toast(getContext().resourceManager.getStringSync(
          $r('app.string.yt_ai_translate_test_ok').id));
      })
      .catch((e: Error) => {
        if (generation !== this.testGeneration) {
          return;
        }
        logger.warn(`translation test failed engine=${this.engine}: ${e.message || e}`);
        this.toast(getContext().resourceManager.getStringSync(
          $r('app.string.yt_ai_translate_test_fail').id));
      })
      .finally(() => {
        if (generation !== this.testGeneration) {
          return;
        }
        if (this.testTimer >= 0) {
          clearTimeout(this.testTimer);
          this.testTimer = -1;
        }
        this.testing = false;
      });
  }

  @Builder
  FieldRow(label: ResourceStr, text: string, placeholder: string, isPassword: boolean,
    onChange: (value: string) => void) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_hint'))
        .width('100%')
      TextInput({ text, placeholder })
        .width('100%')
        .height(46)
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_primary'))
        .padding({ left: 12, right: 12 })
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .borderRadius(10)
        .type(isPassword ? InputType.Password : InputType.Normal)
        .onChange((value: string) => { onChange(value); })
        .onSubmit(() => { this.persist(); })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
  }

  @Builder
  CustomField(label: ResourceStr, text: string, placeholder: string,
    onChange: (value: string) => void, height: number) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_hint'))
        .width('100%')
      TextArea({ text, placeholder })
        .width('100%')
        .height(height)
        .fontSize(13)
        .fontColor($r('app.color.yourtube_text_primary'))
        .padding(10)
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .borderRadius(10)
        .onChange((value: string) => { onChange(value); })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_ai_translate_engine') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_ai_translate_engine'),
              options: this.getEngineOptions(),
              selectedIndex: Math.max(0, TRANSLATION_ENGINES.indexOf(this.engine)),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                this.engine = TRANSLATION_ENGINES[index];
                this.persist();
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)

        if (this.engine === 'libretranslate' || this.engine === 'lingva' || this.engine === 'deepl'
          || this.engine === 'google' || this.engine === 'azure') {
          ListItem() {
            PlaybackSectionTitle({ title: $r('app.string.yt_translation_endpoint') })
          }
          .padding({ left: 0, right: 0 })

          ListItemGroup() {
            ListItem() {
              this.FieldRow($r('app.string.yt_translation_endpoint'), this.endpoint,
                this.endpointPlaceholder(), false, (value: string) => { this.endpoint = value; })
            }
            if (this.engine === 'libretranslate' || this.engine === 'deepl' || this.engine === 'google'
              || this.engine === 'azure') {
              ListItem() {
                this.FieldRow($r('app.string.yt_ai_translate_api_key'), this.apiKey, '', true,
                  (value: string) => { this.apiKey = value; })
              }
            }
            if (this.engine === 'azure') {
              ListItem() {
                this.FieldRow($r('app.string.yt_translation_region'), this.region, 'eastasia',
                  false, (value: string) => { this.region = value; })
              }
            }
          }
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
          .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })
        } else if (this.engine === 'llm') {
          ListItem() {
            PlaybackSectionTitle({ title: $r('app.string.yt_ai_translate_llm_section') })
          }
          .padding({ left: 0, right: 0 })

          ListItemGroup() {
            ListItem() {
              this.FieldRow($r('app.string.yt_ai_translate_base_url'), this.baseUrl,
                'https://api.deepseek.com', false, (value: string) => { this.baseUrl = value; })
            }
            ListItem() {
              this.FieldRow($r('app.string.yt_ai_translate_model'), this.model,
                'deepseek-chat', false, (value: string) => { this.model = value; })
            }
            ListItem() {
              this.FieldRow($r('app.string.yt_ai_translate_api_key'), this.apiKey, '', true,
                (value: string) => { this.apiKey = value; })
            }
          }
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
          .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })
        } else if (this.engine === 'custom') {
          ListItem() {
            PlaybackSectionTitle({ title: $r('app.string.yt_translation_engine_custom') })
          }
          .padding({ left: 0, right: 0 })

          ListItemGroup() {
            ListItem() {
              this.FieldRow($r('app.string.yt_translation_custom_url'), this.customUrl,
                'https://example.com/translate', false, (value: string) => { this.customUrl = value; })
            }
            ListItem() {
              PlaybackSelectRow({
                title: $r('app.string.yt_translation_custom_method'),
                options: this.getMethodOptions(),
                selectedIndex: this.customMethod === 'GET' ? 1 : 0,
                fontColor: this.params.themeColor,
                transparentBackground: true,
                onChange: (index: number) => {
                  this.customMethod = index === 1 ? 'GET' : 'POST';
                  this.persist();
                }
              })
            }
            ListItem() {
              this.CustomField($r('app.string.yt_translation_custom_headers'), this.customHeaders,
                '{"Content-Type": "application/json"}',
                (value: string) => { this.customHeaders = value; }, 78)
            }
            ListItem() {
              this.CustomField($r('app.string.yt_translation_custom_body'), this.customBody,
                '{"text":"{text}","target_lang":"{target}"}',
                (value: string) => { this.customBody = value; }, 92)
            }
            ListItem() {
              this.FieldRow($r('app.string.yt_translation_custom_response_path'), this.customResponsePath,
                'translatedText', false, (value: string) => { this.customResponsePath = value; })
            }
          }
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
          .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })
        }

        ListItem() {
          Button(this.testing ? $r('app.string.yt_ai_translate_testing') : $r('app.string.yt_ai_translate_test'))
            .width('100%')
            .height(46)
            .fontSize(15)
            .backgroundColor(this.themePrimary)
            .fontColor(Color.White)
            .borderRadius(14)
            .enabled(!this.testing)
            .onClick(() => { this.runTest(); })
        }
        .padding({ top: 8 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
  }
}
