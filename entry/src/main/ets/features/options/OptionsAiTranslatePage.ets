import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { LlmTranslateConfig } from '../../common/LlmTranslateConfig';
import { LlmClient } from '../player/translate/LlmClient';
import { AsrModelManager, AsrModelStatus } from '../player/asr/AsrModelManager';
import { SelectOption } from 'mediaservice';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsAiTranslatePage');

export interface OptionsAiTranslatePageParams {
  themeColor: ResourceColor;
}

/**
 * AI 字幕翻译设置页（P2）：引擎选择（gtx 免费 / 用户自带 key 的 LLM）、
 * LLM 端点配置与连通性测试、双语对照开关。目标语言与评论翻译共用
 * 「内容翻译语言」设置，不在此重复。
 */
@Component
export struct OptionsAiTranslatePage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop params: OptionsAiTranslatePageParams = { themeColor: '#E53935' };

  @State private engine: string = 'gtx';
  @State private baseUrl: string = '';
  @State private model: string = '';
  @State private apiKey: string = '';
  @State private bilingual: boolean = true;
  @State private testing: boolean = false;
  @State private testMessage: ResourceStr = '';
  @State private modelStatus: AsrModelStatus = 'not_downloaded';
  @State private modelPercent: number = 0;

  private modelListener = (status: AsrModelStatus, percent: number): void => {
    this.modelStatus = status;
    this.modelPercent = percent;
  }

  aboutToAppear(): void {
    const cfg = LlmTranslateConfig.get();
    this.engine = cfg.engine;
    this.baseUrl = cfg.baseUrl;
    this.model = cfg.model;
    this.apiKey = cfg.apiKey;
    this.bilingual = cfg.bilingual;
    const mgr = AsrModelManager.getInstance();
    this.modelStatus = mgr.getStatus();
    this.modelPercent = mgr.getPercent();
    mgr.addListener(this.modelListener);
  }

  aboutToDisappear(): void {
    AsrModelManager.getInstance().removeListener(this.modelListener);
  }

  private getModelStatusText(): ResourceStr {
    if (this.modelStatus === 'ready') {
      return $r('app.string.yt_asr_model_status_ready');
    }
    if (this.modelStatus === 'downloading') {
      return `${getContext().resourceManager.getStringSync($r('app.string.yt_asr_model_downloading').id)} ${this.modelPercent}%`;
    }
    return $r('app.string.yt_asr_model_status_none');
  }

  private persist(): void {
    const next = new LlmTranslateConfig();
    next.engine = this.engine;
    next.baseUrl = this.baseUrl.trim();
    next.model = this.model.trim();
    next.apiKey = this.apiKey.trim();
    next.bilingual = this.bilingual;
    LlmTranslateConfig.update(next);
  }

  private getEngineOptions(): SelectOption[] {
    return [
      { value: $r('app.string.yt_ai_translate_engine_gtx') } as SelectOption,
      { value: $r('app.string.yt_ai_translate_engine_llm') } as SelectOption
    ];
  }

  private runTest(): void {
    this.persist();
    this.testing = true;
    this.testMessage = '';
    const cfg = LlmTranslateConfig.get();
    LlmClient.testConnection(cfg)
      .then(() => {
        this.testMessage = $r('app.string.yt_ai_translate_test_ok');
      })
      .catch((e: Error) => {
        logger.warn(`llm test failed: ${e.message || e}`);
        this.testMessage = $r('app.string.yt_ai_translate_test_fail');
      })
      .finally(() => {
        this.testing = false;
      });
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
              selectedIndex: this.engine === 'llm' ? 1 : 0,
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                this.engine = index === 1 ? 'llm' : 'gtx';
                this.persist();
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)

        if (this.engine === 'llm') {
          ListItem() {
            PlaybackSectionTitle({ title: $r('app.string.yt_ai_translate_llm_section') })
          }
          .padding({ left: 0, right: 0 })

          ListItemGroup() {
            ListItem() {
              TextInput({
                text: this.baseUrl,
                placeholder: $r('app.string.yt_ai_translate_base_url')
              })
                .width('100%')
                .height(56)
                .fontSize(15)
                .fontColor($r('app.color.yourtube_text_primary'))
                .padding({ left: 16, right: 16 })
                .backgroundColor(Color.Transparent)
                .onChange((v: string) => {
                  this.baseUrl = v;
                })
                .onSubmit(() => {
                  this.persist();
                })
            }

            ListItem() {
              TextInput({
                text: this.model,
                placeholder: $r('app.string.yt_ai_translate_model')
              })
                .width('100%')
                .height(56)
                .fontSize(15)
                .fontColor($r('app.color.yourtube_text_primary'))
                .padding({ left: 16, right: 16 })
                .backgroundColor(Color.Transparent)
                .onChange((v: string) => {
                  this.model = v;
                })
                .onSubmit(() => {
                  this.persist();
                })
            }

            ListItem() {
              TextInput({
                text: this.apiKey,
                placeholder: $r('app.string.yt_ai_translate_api_key')
              })
                .width('100%')
                .height(56)
                .fontSize(15)
                .fontColor($r('app.color.yourtube_text_primary'))
                .padding({ left: 16, right: 16 })
                .type(InputType.Password)
                .backgroundColor(Color.Transparent)
                .onChange((v: string) => {
                  this.apiKey = v;
                })
                .onSubmit(() => {
                  this.persist();
                })
            }
          }
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
          .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

          ListItem() {
            Button(this.testing ? $r('app.string.yt_ai_translate_testing') : $r('app.string.yt_ai_translate_test'))
              .width('100%')
              .height(48)
              .fontSize(16)
              .backgroundColor(this.themePrimary)
              .fontColor(Color.White)
              .borderRadius(16)
              .enabled(!this.testing)
              .onClick(() => {
                this.runTest();
              })
          }
          .padding({ left: 0, right: 0, top: 8 })

          if (!(typeof this.testMessage === 'string' && this.testMessage.length === 0)) {
            ListItem() {
              Text(this.testMessage)
                .fontSize(13)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .width('100%')
                .padding({ left: 4, right: 4 })
            }
          }
        }

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_ai_translate_display_section') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_ai_translate_bilingual'),
              subtitle: $r('app.string.yt_ai_translate_bilingual_subtitle'),
              isOn: this.bilingual,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.bilingual = val;
                this.persist();
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_asr_model_section') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            Column({ space: 10 }) {
              Text(this.getModelStatusText())
                .fontSize(14)
                .fontColor($r('app.color.yourtube_text_primary'))
                .width('100%')
              Row({ space: 12 }) {
                if (this.modelStatus !== 'ready') {
                  Button(this.modelStatus === 'downloading'
                    ? $r('app.string.yt_ai_action_cancel')
                    : $r('app.string.yt_asr_model_download'))
                    .height(40)
                    .fontSize(14)
                    .backgroundColor(this.modelStatus === 'downloading'
                      ? $r('app.color.yourtube_bg_surface_muted') : this.themePrimary)
                    .fontColor(this.modelStatus === 'downloading'
                      ? $r('app.color.yourtube_text_primary') : Color.White)
                    .borderRadius(12)
                    .onClick(() => {
                      const mgr = AsrModelManager.getInstance();
                      if (this.modelStatus === 'downloading') {
                        mgr.cancelDownload();
                      } else {
                        mgr.download().then((ok: boolean) => {
                          logger.info(`ASR model download result: ${ok}`);
                        });
                      }
                    })
                } else {
                  Button($r('app.string.yt_asr_model_delete'))
                    .height(40)
                    .fontSize(14)
                    .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
                    .fontColor($r('app.color.yourtube_text_primary'))
                    .borderRadius(12)
                    .onClick(() => {
                      AsrModelManager.getInstance().deleteModel();
                    })
                }
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .alignItems(HorizontalAlign.Start)
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)

        ListItem() {
          Text($r('app.string.yt_ai_translate_note'))
            .fontSize(12)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .width('100%')
            .padding({ left: 4, right: 4, top: 8 })
        }

        ListItem() {
          Column().height(24)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, bottom: 12 })
      .edgeEffect(EdgeEffect.Spring)
      .alignListItem(ListItemAlign.Start)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
