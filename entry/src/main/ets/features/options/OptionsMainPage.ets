import { OptionItem } from '../../common/components/OptionItem';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { UIConfig, YourtubeDarkMode } from '../../common/AppState';
import { PlaybackConfig, VideoQualityCap } from '../../common/PlaybackConfig';
import { NetworkProxyConfig } from '../../common/NetworkProxyConfig';
import { AuthAccountStatus, AuthStage } from 'youtube_core';
import { LanguagePickerItem } from '../../common/components/LanguagePickerDialog';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../../common/AppLog';
import { APPGALLERY_TEST_URL, UpdateChecker, UpdateCheckResult } from '../../common/UpdateChecker';

const logger = AppLog.getInstance('OptionsMainPage');

const APP_VERSION: string = '0.5.8';

interface OptionsMainPageParams {
  clickEffectEnabled: ClickEffect | null;
  appLangItems: LanguagePickerItem[];
  contentLangItems: LanguagePickerItem[];
  contentCountryItems: LanguagePickerItem[];
  onDataAccountClick: () => void;
  onLanguageClick: () => void;
  onPlaybackClick: () => void;
  onNetworkClick: () => void;
  onAppearanceClick: () => void;
  onLogClick: () => void;
  onHelpClick: () => void;
  onRecoveryClick: () => void;
  onAboutClick: () => void;
}

@Component
export struct OptionsMainPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  @StorageLink('networkProxyConfig') networkProxyConfig: NetworkProxyConfig = new NetworkProxyConfig();
  @StorageProp('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();

  @Prop params: OptionsMainPageParams = {
    clickEffectEnabled: null,
    appLangItems: [] as LanguagePickerItem[],
    contentLangItems: [] as LanguagePickerItem[],
    contentCountryItems: [] as LanguagePickerItem[],
    onDataAccountClick: () => {},
    onLanguageClick: () => {},
    onPlaybackClick: () => {},
    onNetworkClick: () => {},
    onAppearanceClick: () => {},
    onLogClick: () => {},
    onHelpClick: () => {},
    onRecoveryClick: () => {},
    onAboutClick: () => {}
  };

  private getItemDisplay(items: LanguagePickerItem[], code: string): ResourceStr {
    const found = items.find((it: LanguagePickerItem): boolean => it.code === code);
    return found ? found.localizedName : $r('app.string.yt_follow_system');
  }

  private getDataAccountSubtitle(): ResourceStr {
    const hasCred = this.authStatus.hasCredential
      || this.authStatus.hasCookieCredential
      || this.authStatus.hasRefreshToken
      || this.authStatus.stage === AuthStage.SIGNED_IN;
    if (!hasCred) {
      return $r('app.string.yt_data_account_manage_sign_in');
    }
    if (this.authStatus.authEnabled === false) {
      return $r('app.string.yt_data_account_incognito');
    }
    if (this.authStatus.authMode === 'cookie' || this.authStatus.authMode === 'both') {
      return $r('app.string.yt_data_account_cookie');
    }
    return $r('app.string.yt_data_account_signed_in');
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

  private updateChecking: boolean = false;

  private async checkForUpdates(): Promise<void> {
    if (this.updateChecking) {
      return;
    }
    this.updateChecking = true;
    this.getUIContext().getPromptAction().showToast({
      message: $r('app.string.yt_update_checking'),
      duration: 1500
    });
    try {
      const result: UpdateCheckResult = await UpdateChecker.check();
      if (result.status === 'failed') {
        this.getUIContext().getPromptAction().showToast({
          message: $r('app.string.yt_update_check_failed'),
          duration: 2500
        });
        return;
      }
      if (result.status === 'upToDate') {
        this.getUIContext().getPromptAction().showToast({
          message: $r('app.string.yt_update_up_to_date'),
          duration: 2000
        });
        return;
      }
      const res = getContext(this).resourceManager;
      const versionLine = `v${result.remoteVersionName}`
        + (result.remoteVersionCode > 0 ? ` (${result.remoteVersionCode})` : '');
      const lines: string[] = [
        `${res.getStringSync($r('app.string.yt_update_current_version').id)} `
          + `v${result.localVersionName} (${result.localVersionCode})`,
        `${res.getStringSync($r('app.string.yt_update_new_version').id)} ${versionLine}`
      ];
      if (result.publishedAt) {
        lines.push(`${res.getStringSync($r('app.string.yt_update_release_time').id)} ${result.publishedAt}`);
      }
      AlertDialog.show({
        title: $r('app.string.yt_update_available_title'),
        message: lines.join('\n'),
        alignment: DialogAlignment.Center,
        primaryButton: {
          value: $r('app.string.yt_update_open_appgallery'),
          fontColor: this.themePrimary,
          action: () => {
            this.openExternalLink(APPGALLERY_TEST_URL);
          }
        },
        secondaryButton: {
          value: $r('app.string.yt_update_open_github'),
          action: () => {
            this.openExternalLink(result.releaseUrl);
          }
        }
      });
    } finally {
      this.updateChecking = false;
    }
  }

  private openExternalLink(url: string): void {
    try {
      logger.info(`openExternalLink url=${url}`);
      const context = getContext(this) as common.UIAbilityContext;
      context.openLink(url, { appLinkingOnly: false });
    } catch (e) {
      logger.error(`openExternalLink failed: ${String(e)}`);
    }
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_option_preferences') })
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
            icon: $r('sys.symbol.wifi'),
            title: $r('app.string.yt_option_network'),
            subtitle: this.networkProxyConfig.subtitle(),
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onNetworkClick
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
            icon: $r('sys.symbol.questionmark_circle'),
            title: $r('app.string.yt_option_help'),
            subtitle: $r('app.string.yt_option_help_subtitle'),
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onHelpClick
          })
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
            icon: $r('sys.symbol.download_fill'),
            title: $r('app.string.yt_about_check_update'),
            subtitle: $r('app.string.yt_about_check_update_subtitle'),
            iconColor: this.themePrimary,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: () => { this.checkForUpdates(); }
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
