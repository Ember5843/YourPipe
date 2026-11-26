import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { UIConfig } from '../../common/AppState';
import { PlayerSession } from '../../common/PlayerSession';
import {
  PlaybackConfig,
  SubtitleFontScale, SubtitleBottomMargin, SubtitleFontColor, SubtitleEdgeStyle,
  SUBTITLE_FONT_SCALE_LABELS, SUBTITLE_BOTTOM_MARGIN_LABELS,
  SUBTITLE_FONT_COLOR_LABELS, SUBTITLE_FONT_COLOR_VALUES,
  SUBTITLE_EDGE_STYLE_LABELS, SUBTITLE_BG_OPACITY_VALUES,
  SUBTITLE_OFFSET_MIN_MS, SUBTITLE_OFFSET_MAX_MS,
  clampSubtitleOffsetMs, normalizeSubtitleBgOpacity,
  getSubtitleFontColorDisplay, getSubtitleOffsetDisplay,
} from '../../common/PlaybackConfig';
import { LanguagePickerItem, buildExtendedLanguageItems } from '../../common/components/LanguagePickerDialog';

const SUBTITLE_OFFSET_STEP_MS: number = 100;

interface OptionsSubtitlePageParams {
  themeColor: ResourceColor;
  clickEffectEnabled: ClickEffect | null;
  /** 应用语言列表（字幕翻译目标语言选项的数据源） */
  appLangItems: LanguagePickerItem[];
  updatePlaybackConfig: (updater: (cfg: PlaybackConfig) => void) => void;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
}

@Component
export struct OptionsSubtitlePage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();

  @Prop params: OptionsSubtitlePageParams = {
    themeColor: '#E53935',
    clickEffectEnabled: null,
    appLangItems: [] as LanguagePickerItem[],
    updatePlaybackConfig: () => {},
    updateUiConfig: () => {}
  };

  private getSubtitleFontScaleOptions(): SelectOption[] {
    return SUBTITLE_FONT_SCALE_LABELS.map((v: SubtitleFontScale): SelectOption => ({ value: `${v}x` }));
  }

  private getSubtitleBottomMarginOptions(): SelectOption[] {
    return SUBTITLE_BOTTOM_MARGIN_LABELS.map((v: SubtitleBottomMargin): SelectOption => ({ value: v }));
  }

  private getSubtitleFontColorOptions(): SelectOption[] {
    return SUBTITLE_FONT_COLOR_LABELS.map((v: SubtitleFontColor): SelectOption => ({ value: getSubtitleFontColorDisplay(v) }));
  }

  private getSubtitleEdgeStyleDisplay(style: SubtitleEdgeStyle): Resource {
    if (style === 'outline') {
      return $r('app.string.yt_subtitle_edge_outline');
    }
    if (style === 'shadow') {
      return $r('app.string.yt_subtitle_edge_shadow');
    }
    if (style === 'none') {
      return $r('app.string.yt_subtitle_edge_none');
    }
    return $r('app.string.yt_subtitle_edge_outline_shadow');
  }

  private getSubtitleEdgeStyleOptions(): SelectOption[] {
    return SUBTITLE_EDGE_STYLE_LABELS.map((s: SubtitleEdgeStyle): SelectOption => ({
      value: this.getSubtitleEdgeStyleDisplay(s)
    }));
  }

  private getSubtitleBgOpacityOptions(): SelectOption[] {
    return SUBTITLE_BG_OPACITY_VALUES.map((v: number): SelectOption => ({
      value: `${Math.round(v * 100)}%`
    }));
  }

  private applySubtitleOffset(nextMs: number): void {
    const clamped = clampSubtitleOffsetMs(nextMs);
    this.params.updatePlaybackConfig((cfg: PlaybackConfig) => {
      cfg.subtitleOffsetMs = clamped;
    });
    PlayerSession.getInstance().refreshSubtitleOverlay();
  }

  /** tlang 自动翻译字幕目标语言：'default' 项显示为「跟随翻译语言」 */
  private getSubtitleTranslateLangItems(): LanguagePickerItem[] {
    const followTranslation =
      getContext().resourceManager.getStringSync($r('app.string.yt_follow_translation_language').id);
    return buildExtendedLanguageItems(this.params.appLangItems, followTranslation);
  }

  private getPreviewPrimaryFontSize(): number {
    return 14 * Number(this.playbackConfig.subtitleFontScale);
  }

  private getPreviewSecondaryFontSize(): number {
    return Math.max(10, Math.round(this.getPreviewPrimaryFontSize() * 0.82 * 10) / 10);
  }

  private getPreviewPrimaryColor(): string {
    return SUBTITLE_FONT_COLOR_VALUES[this.playbackConfig.subtitleFontColor] || '#FFFFFF';
  }

  private getPreviewSecondaryColor(): string {
    const key = this.playbackConfig.subtitleFontColor;
    if (key === 'yellow') {
      return '#FFF59D';
    }
    if (key === 'green') {
      return '#A5D6A7';
    }
    if (key === 'cyan') {
      return '#B2EBF2';
    }
    return '#E8E8E8';
  }

  private getPreviewPillBackground(): string {
    const opacity = normalizeSubtitleBgOpacity(this.playbackConfig.subtitleBgOpacity);
    if (opacity <= 0) {
      return 'rgba(0, 0, 0, 0)';
    }
    return `rgba(0, 0, 0, ${opacity})`;
  }

  private getPreviewLineHeight(fontSize: number): number {
    return Math.round(fontSize * 1.32);
  }

  private getPreviewPillPadding(fontSize: number): Padding {
    const h = Math.max(8, Math.round(fontSize * 0.55));
    const v = Math.max(2, Math.round(fontSize * 0.18));
    return { left: h, right: h, top: v, bottom: v };
  }

  private getPreviewPillRadius(fontSize: number): number {
    return Math.max(4, Math.round(fontSize * 0.28));
  }

  private getPreviewTextShadow(): ShadowOptions | ShadowOptions[] {
    const style: SubtitleEdgeStyle = this.playbackConfig.subtitleEdgeStyle;
    if (style === 'none') {
      return { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 };
    }
    if (style === 'shadow') {
      return [{ radius: 4, color: '#CC000000', offsetX: 0, offsetY: 1.5 }];
    }
    if (style === 'outline') {
      return [
        { radius: 1.5, color: '#E6000000', offsetX: -1.2, offsetY: -1.2 },
        { radius: 1.5, color: '#E6000000', offsetX: 1.2, offsetY: -1.2 },
        { radius: 1.5, color: '#E6000000', offsetX: -1.2, offsetY: 1.2 },
        { radius: 1.5, color: '#E6000000', offsetX: 1.2, offsetY: 1.2 }
      ];
    }
    return [
      { radius: 1.5, color: '#E6000000', offsetX: -1.2, offsetY: -1.2 },
      { radius: 1.5, color: '#E6000000', offsetX: 1.2, offsetY: -1.2 },
      { radius: 1.5, color: '#E6000000', offsetX: -1.2, offsetY: 1.2 },
      { radius: 1.5, color: '#E6000000', offsetX: 1.2, offsetY: 1.2 },
      { radius: 4, color: '#B3000000', offsetX: 0, offsetY: 1.5 }
    ];
  }

  @Builder
  SubtitlePreviewCard() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 4 }) {
        Text($r('app.string.yt_subtitle_preview_primary'))
          .fontColor(this.getPreviewPrimaryColor())
          .fontSize(this.getPreviewPrimaryFontSize())
          .lineHeight(this.getPreviewLineHeight(this.getPreviewPrimaryFontSize()))
          .fontWeight(this.playbackConfig.subtitleBold ? FontWeight.Bold : FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: '94%' })
          .textShadow(this.getPreviewTextShadow())
          .padding(this.getPreviewPillPadding(this.getPreviewPrimaryFontSize()))
          .backgroundColor(this.getPreviewPillBackground())
          .borderRadius(this.getPreviewPillRadius(this.getPreviewPrimaryFontSize()))

        Text($r('app.string.yt_subtitle_preview_secondary'))
          .fontColor(this.getPreviewSecondaryColor())
          .fontSize(this.getPreviewSecondaryFontSize())
          .lineHeight(this.getPreviewLineHeight(this.getPreviewSecondaryFontSize()))
          .fontWeight(this.playbackConfig.subtitleBold ? FontWeight.Bold : FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .constraintSize({ maxWidth: '94%' })
          .textShadow(this.getPreviewTextShadow())
          .padding(this.getPreviewPillPadding(this.getPreviewSecondaryFontSize()))
          .backgroundColor(this.getPreviewPillBackground())
          .borderRadius(this.getPreviewPillRadius(this.getPreviewSecondaryFontSize()))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 12, right: 12, top: 20, bottom: 16 })
    }
    .width('100%')
    .constraintSize({ minHeight: 126 })
    .borderRadius(SECTION_CARD_RADIUS)
    .clip(true)
    .linearGradient({
      angle: 135,
      colors: [
        ['#1F2A38', 0.0],
        ['#3B4C63', 0.48],
        ['#1A212C', 1.0]
      ]
    })
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          this.SubtitlePreviewCard()
        }
        .padding({ top: 6, bottom: 4 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_player_subtitles') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_size'),
              options: this.getSubtitleFontScaleOptions(),
              selectedIndex: Math.max(0, SUBTITLE_FONT_SCALE_LABELS.indexOf(this.playbackConfig.subtitleFontScale)),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_FONT_SCALE_LABELS[index];
                this.params.updatePlaybackConfig((cfg: PlaybackConfig) => {
                  cfg.subtitleFontScale = v;
                });
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_bottom_margin'),
              options: this.getSubtitleBottomMarginOptions(),
              selectedIndex: Math.max(0, SUBTITLE_BOTTOM_MARGIN_LABELS.indexOf(this.playbackConfig.subtitleBottomMarginVp)),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_BOTTOM_MARGIN_LABELS[index];
                this.params.updatePlaybackConfig((cfg: PlaybackConfig) => {
                  cfg.subtitleBottomMarginVp = v;
                });
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_color'),
              options: this.getSubtitleFontColorOptions(),
              selectedIndex: Math.max(0, SUBTITLE_FONT_COLOR_LABELS.indexOf(this.playbackConfig.subtitleFontColor)),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_FONT_COLOR_LABELS[index];
                this.params.updatePlaybackConfig((cfg: PlaybackConfig) => {
                  cfg.subtitleFontColor = v;
                });
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_edge_style'),
              options: this.getSubtitleEdgeStyleOptions(),
              selectedIndex: Math.max(0, SUBTITLE_EDGE_STYLE_LABELS.indexOf(this.playbackConfig.subtitleEdgeStyle)),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_EDGE_STYLE_LABELS[index];
                this.params.updatePlaybackConfig((cfg: PlaybackConfig) => {
                  cfg.subtitleEdgeStyle = v;
                });
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_setting_subtitle_bold'),
              subtitle: $r('app.string.yt_setting_subtitle_bold_subtitle'),
              isOn: this.playbackConfig.subtitleBold,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig((cfg: PlaybackConfig) => {
                  cfg.subtitleBold = val;
                });
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_bg_opacity'),
              options: this.getSubtitleBgOpacityOptions(),
              selectedIndex: Math.max(0, SUBTITLE_BG_OPACITY_VALUES.indexOf(
                normalizeSubtitleBgOpacity(this.playbackConfig.subtitleBgOpacity))),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_BG_OPACITY_VALUES[index];
                this.params.updatePlaybackConfig((cfg: PlaybackConfig) => {
                  cfg.subtitleBgOpacity = v;
                  cfg.subtitleBackground = v <= 0 ? 'none' : (v >= 0.85 ? 'solid' : 'semi');
                });
              }
            })
          }

          ListItem() {
            Column({ space: 10 }) {
              Row({ space: 12 }) {
                Column() {
                  Text($r('app.string.yt_setting_subtitle_offset'))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.yourtube_text_primary'))
                  Text($r('app.string.yt_setting_subtitle_offset_subtitle'))
                    .fontSize(12)
                    .fontColor($r('app.color.yourtube_text_quaternary'))
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text(getSubtitleOffsetDisplay(this.playbackConfig.subtitleOffsetMs))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.playbackConfig.subtitleOffsetMs !== 0
                    ? this.params.themeColor
                    : $r('app.color.yourtube_text_secondary'))
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Row({ space: 8 }) {
                Button() {
                  SymbolGlyph($r('sys.symbol.minus'))
                    .fontSize(16)
                    .fontColor([$r('app.color.yourtube_text_primary')])
                }
                .width(40)
                .height(34)
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .borderRadius(17)
                .enabled(this.playbackConfig.subtitleOffsetMs > SUBTITLE_OFFSET_MIN_MS)
                .opacity(this.playbackConfig.subtitleOffsetMs > SUBTITLE_OFFSET_MIN_MS ? 1 : 0.4)
                .onClick(() => {
                  this.applySubtitleOffset(this.playbackConfig.subtitleOffsetMs - SUBTITLE_OFFSET_STEP_MS);
                })

                Button() {
                  SymbolGlyph($r('sys.symbol.plus'))
                    .fontSize(16)
                    .fontColor([$r('app.color.yourtube_text_primary')])
                }
                .width(40)
                .height(34)
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .borderRadius(17)
                .enabled(this.playbackConfig.subtitleOffsetMs < SUBTITLE_OFFSET_MAX_MS)
                .opacity(this.playbackConfig.subtitleOffsetMs < SUBTITLE_OFFSET_MAX_MS ? 1 : 0.4)
                .onClick(() => {
                  this.applySubtitleOffset(this.playbackConfig.subtitleOffsetMs + SUBTITLE_OFFSET_STEP_MS);
                })

                Blank()

                if (this.playbackConfig.subtitleOffsetMs !== 0) {
                  Button($r('app.string.yt_setting_subtitle_offset_reset'))
                    .height(34)
                    .padding({ left: 14, right: 14 })
                    .fontSize(13)
                    .fontColor(this.params.themeColor)
                    .backgroundColor($r('sys.color.comp_background_tertiary'))
                    .borderRadius(17)
                    .onClick(() => {
                      this.applySubtitleOffset(0);
                    })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_translate_language'),
              options: this.getSubtitleTranslateLangItems().map((item: LanguagePickerItem): SelectOption => ({
                value: item.localizedName
              })),
              selectedIndex: Math.max(0, this.getSubtitleTranslateLangItems()
                .findIndex((it: LanguagePickerItem): boolean => it.code === this.uiConfig.subtitleTranslateLanguage)),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const code = this.getSubtitleTranslateLangItems()[index].code;
                this.params.updateUiConfig((cfg: UIConfig) => {
                  cfg.subtitleTranslateLanguage = code;
                });
              }
            })
          }

          // [DISABLED] 系统 AI 字幕（P1，Speech Kit AICaptionComponent）：实测面板占据
          // 画面过大、体验不佳，设置项隐藏；播放器挂载点（AVPlayer）同步注释，代码保留。
          // ListItem() {
          //   PlaybackToggleRow({
          //     title: $r('app.string.yt_setting_system_ai_caption'),
          //     subtitle: $r('app.string.yt_setting_system_ai_caption_subtitle'),
          //     isOn: this.playbackConfig.systemAiCaption,
          //     themeColor: this.params.themeColor,
          //     transparentBackground: true,
          //     onChange: (val: boolean) => {
          //       this.params.updatePlaybackConfig(cfg => cfg.systemAiCaption = val);
          //     }
          //   })
          // }
          // if (this.playbackConfig.systemAiCaption) {
          //   ListItem() {
          //     PlaybackSelectRow({
          //       title: $r('app.string.yt_setting_system_ai_caption_source'),
          //       options: [
          //         { value: 'English' } as SelectOption,
          //         { value: $r('app.string.yt_setting_system_ai_caption_source_zh') } as SelectOption
          //       ],
          //       selectedIndex: this.playbackConfig.systemAiCaptionSource === 'zh' ? 1 : 0,
          //       fontColor: this.params.themeColor,
          //       transparentBackground: true,
          //       onChange: (index: number) => {
          //         const v = index === 1 ? 'zh' : 'en';
          //         this.params.updatePlaybackConfig(cfg => cfg.systemAiCaptionSource = v);
          //       }
          //     })
          //   }
          // }
        }
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          Column().height(24)
        }
        .padding({ left: 0, right: 0 })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
      .edgeEffect(EdgeEffect.Spring)
      .alignListItem(ListItemAlign.Start)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
