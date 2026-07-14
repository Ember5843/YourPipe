import { OptionItem } from '../../common/components/OptionItem';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { UIConfig, YourtubeDarkMode } from '../../common/AppState';
import { PlaybackConfig, VideoQualityCap } from '../../common/PlaybackConfig';
import { AuthAccountStatus, AuthStage } from 'youtube_core';
import { LanguagePickerItem } from '../../common/components/LanguagePickerDialog';

const APP_VERSION: string = '0.5.2';

interface OptionsMainPageParams {
  clickEffectEnabled: ClickEffect | null;
  appLangItems: LanguagePickerItem[];
  contentLangItems: LanguagePickerItem[];
  contentCountryItems: LanguagePickerItem[];
  onDataAccountClick: () => void;
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
    onDataAccountClick: () => {},
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

  private getDataAccountSubtitle(): string {
    const hasCred = this.authStatus.hasCredential
      || this.authStatus.hasCookieCredential
      || this.authStatus.hasRefreshToken
      || this.authStatus.stage === AuthStage.SIGNED_IN;
    if (!hasCred) {
      return '管理数据与登录状态';
    }
    if (this.authStatus.authEnabled === false) {
      return '已保存登录 · 无痕浏览中';
    }
    if (this.authStatus.authMode === 'cookie') {
      return '已登录 (Cookie) · 管理数据与账号';
    }
    return '已登录 · 管理数据与账号';
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
            icon: $r('sys.symbol.person_crop_circle_fill'),
            title: $r('app.string.yt_option_data_account'),
            subtitle: this.getDataAccountSubtitle(),
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onDataAccountClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_option_group_settings') })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.globe_and_keyboard'),
            title: $r('app.string.yt_section_language_region'),
            subtitle: this.getLanguageAndRegionSubtitle(),
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onLanguageClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.play_circle_fill'),
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
            iconColor: this.themePrimary,
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
            icon: $r('sys.symbol.doc_plaintext'),
            title: $r('app.string.yt_option_log'),
            subtitle: $r('app.string.yt_option_log_subtitle'),
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onLogClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.arrow_counterclockwise_clock'),
            title: $r('app.string.yt_option_recovery'),
            subtitle: $r('app.string.yt_option_reset_settings_subtitle'),
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onRecoveryClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.info_circle_fill'),
            title: $r('app.string.yt_option_about'),
            subtitle: 'v' + APP_VERSION,
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onAboutClick
          })
        }
        .padding({ left: 0, right: 0 })

        ListItem() {
          Column().height(24)
        }
        .padding({ left: 0, right: 0 })
      }
      .width('100%')
      .height('100%')
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
