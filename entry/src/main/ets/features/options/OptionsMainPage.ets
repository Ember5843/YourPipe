import { OptionItem } from '../../common/components/OptionItem';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { UIConfig, YourtubeDarkMode } from '../../common/AppState';
import { PlaybackConfig, VideoQualityCap } from '../../common/PlaybackConfig';
import { AuthAccountStatus, AuthStage } from 'youtube_core';
import { LanguagePickerItem } from '../../common/components/LanguagePickerDialog';

const APP_VERSION: string = '0.5.1';

interface OptionsMainPageParams {
  clickEffectEnabled: ClickEffect | null;
  appLangItems: LanguagePickerItem[];
  contentLangItems: LanguagePickerItem[];
  contentCountryItems: LanguagePickerItem[];
  onGoogleAccountClick: () => void;
  onLanguageClick: () => void;
  onPlaybackClick: () => void;
  onAppearanceClick: () => void;
  onLogClick: () => void;
  onRecoveryClick: () => void;
  onAboutClick: () => void;
}

@Component
export struct OptionsMainPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  @StorageProp('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();

  @Prop params: OptionsMainPageParams = {
    clickEffectEnabled: null,
    appLangItems: [] as LanguagePickerItem[],
    contentLangItems: [] as LanguagePickerItem[],
    contentCountryItems: [] as LanguagePickerItem[],
    onGoogleAccountClick: () => {},
    onLanguageClick: () => {},
    onPlaybackClick: () => {},
    onAppearanceClick: () => {},
    onLogClick: () => {},
    onRecoveryClick: () => {},
    onAboutClick: () => {}
  };

  private getItemDisplay(items: LanguagePickerItem[], code: string): string {
    const found = items.find((it: LanguagePickerItem): boolean => it.code === code);
    return found ? found.localizedName : '跟随系统';
  }

  private getGoogleAccountSubtitle(): string {
    if (this.authStatus.stage === AuthStage.SIGNED_IN) {
      return this.authStatus.authMode === 'cookie' ? '已登录 (Cookie)' : '已登录';
    }
    return '登录以获取个性化推荐';
  }

  private getLanguageAndRegionSubtitle(): string {
    const appLang = this.getItemDisplay(this.params.appLangItems, this.uiConfig.userLanguage);
    const contentLang = this.getItemDisplay(this.params.contentLangItems, this.uiConfig.searchLanguage);
    const region = this.getItemDisplay(this.params.contentCountryItems, this.uiConfig.searchCountry);
    return `${appLang} / ${contentLang} / ${region}`;
  }

  private getPlaybackSubtitle(): string {
    return this.playbackConfig.defaultQuality;
  }

  private getAppearanceSubtitle(): ResourceStr {
    switch (this.uiConfig.darkMode) {
      case YourtubeDarkMode.LIGHT:
        return $r('app.string.yt_dark_mode_light');
      case YourtubeDarkMode.DARK:
        return $r('app.string.yt_dark_mode_dark');
      case YourtubeDarkMode.SYSTEM:
      default:
        return $r('app.string.yt_dark_mode_system');
    }
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          PlaybackSectionTitle({ title: '首选项' })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.info_circle'),
            title: 'Google 登录',
            subtitle: this.getGoogleAccountSubtitle(),
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onGoogleAccountClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_option_group_settings') })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.translate_c2e'),
            title: $r('app.string.yt_section_language_region'),
            subtitle: this.getLanguageAndRegionSubtitle(),
            iconColor: $r('app.color.yourtube_option_icon_language'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onLanguageClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.play_circle'),
            title: $r('app.string.yt_section_playback'),
            subtitle: this.getPlaybackSubtitle(),
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onPlaybackClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.paintpalette_fill'),
            title: $r('app.string.yt_option_appearance'),
            subtitle: this.getAppearanceSubtitle(),
            iconColor: $r('app.color.yourtube_option_icon_palette'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onAppearanceClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_option_group_others') })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.doc_text'),
            title: $r('app.string.yt_option_log'),
            subtitle: $r('app.string.yt_option_log_subtitle'),
            iconColor: $r('app.color.yourtube_option_icon_log'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onLogClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.arrow_counterclockwise'),
            title: $r('app.string.yt_option_recovery'),
            subtitle: $r('app.string.yt_option_reset_settings_subtitle'),
            iconColor: $r('app.color.yourtube_option_icon_palette'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onRecoveryClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.info_circle'),
            title: $r('app.string.yt_option_about'),
            subtitle: 'v' + APP_VERSION,
            iconColor: $r('app.color.yourtube_option_icon_about'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onAboutClick
          })
        }
        .padding({ left: 0, right: 0 })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      .edgeEffect(EdgeEffect.Spring)
      .alignListItem(ListItemAlign.Start)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }
}
