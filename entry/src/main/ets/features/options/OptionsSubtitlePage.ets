import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { UIConfig } from '../../common/AppState';
import {
  PlaybackConfig,
  SUBTITLE_FONT_SCALE_LABELS, SUBTITLE_BOTTOM_MARGIN_LABELS,
  SUBTITLE_FONT_COLOR_LABELS, SUBTITLE_BACKGROUND_LABELS, SUBTITLE_OFFSET_VALUES,
  getSubtitleFontColorDisplay, getSubtitleBackgroundDisplay, getSubtitleOffsetDisplay,
} from '../../common/PlaybackConfig';
import { LanguagePickerItem, buildExtendedLanguageItems } from '../../common/components/LanguagePickerDialog';

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
    return SUBTITLE_FONT_SCALE_LABELS.map(v => ({ value: `${v}x` } as SelectOption));
  }

  private getSubtitleBottomMarginOptions(): SelectOption[] {
    return SUBTITLE_BOTTOM_MARGIN_LABELS.map(v => ({ value: v } as SelectOption));
  }

  private getSubtitleFontColorOptions(): SelectOption[] {
    return SUBTITLE_FONT_COLOR_LABELS.map(v => ({ value: getSubtitleFontColorDisplay(v) } as SelectOption));
  }

  private getSubtitleBackgroundOptions(): SelectOption[] {
    return SUBTITLE_BACKGROUND_LABELS.map(v => ({ value: getSubtitleBackgroundDisplay(v) } as SelectOption));
  }

  private getSubtitleOffsetOptions(): SelectOption[] {
    return SUBTITLE_OFFSET_VALUES.map(v => ({ value: getSubtitleOffsetDisplay(v) } as SelectOption));
  }

  /** tlang 自动翻译字幕目标语言：'default' 项显示为「跟随翻译语言」 */
  private getSubtitleTranslateLangItems(): LanguagePickerItem[] {
    const followTranslation =
      getContext().resourceManager.getStringSync($r('app.string.yt_follow_translation_language').id);
    return buildExtendedLanguageItems(this.params.appLangItems, followTranslation);
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_player_subtitles') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_size'),
              options: this.getSubtitleFontScaleOptions(),
              selectedIndex: SUBTITLE_FONT_SCALE_LABELS.indexOf(this.playbackConfig.subtitleFontScale),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_FONT_SCALE_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.subtitleFontScale = v);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_bottom_margin'),
              options: this.getSubtitleBottomMarginOptions(),
              selectedIndex: SUBTITLE_BOTTOM_MARGIN_LABELS.indexOf(this.playbackConfig.subtitleBottomMarginVp),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_BOTTOM_MARGIN_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.subtitleBottomMarginVp = v);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_color'),
              options: this.getSubtitleFontColorOptions(),
              selectedIndex: SUBTITLE_FONT_COLOR_LABELS.indexOf(this.playbackConfig.subtitleFontColor),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_FONT_COLOR_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.subtitleFontColor = v);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_background'),
              options: this.getSubtitleBackgroundOptions(),
              selectedIndex: SUBTITLE_BACKGROUND_LABELS.indexOf(this.playbackConfig.subtitleBackground),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_BACKGROUND_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.subtitleBackground = v);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_offset'),
              options: this.getSubtitleOffsetOptions(),
              selectedIndex: SUBTITLE_OFFSET_VALUES.indexOf(this.playbackConfig.subtitleOffsetMs),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const v = SUBTITLE_OFFSET_VALUES[index];
                this.params.updatePlaybackConfig(cfg => cfg.subtitleOffsetMs = v);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_subtitle_translate_language'),
              options: this.getSubtitleTranslateLangItems().map(item => ({ value: item.localizedName } as SelectOption)),
              selectedIndex: Math.max(0, this.getSubtitleTranslateLangItems()
                .findIndex(it => it.code === this.uiConfig.subtitleTranslateLanguage)),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const code = this.getSubtitleTranslateLangItems()[index].code;
                this.params.updateUiConfig(cfg => cfg.subtitleTranslateLanguage = code);
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
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
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
