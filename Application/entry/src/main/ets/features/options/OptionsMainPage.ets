import { OptionItem } from '../../common/components/OptionItem';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { UIConfig } from '../../common/AppState';
import { PlaybackConfig } from '../../common/PlaybackConfig';

const APP_VERSION: string = '0.4.1';

interface OptionsMainPageParams {
  uiConfig: UIConfig;
  playbackConfig: PlaybackConfig;
  clickEffectEnabled: ClickEffect | null;
  getGoogleAccountSubtitle: () => string;
  getLanguageAndRegionSubtitle: (cfg: UIConfig) => string;
  getPlaybackSubtitle: (cfg: PlaybackConfig) => string;
  getAppearanceSubtitle: (cfg: UIConfig) => string;
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
  @Prop params: OptionsMainPageParams = {
    uiConfig: new UIConfig(),
    playbackConfig: new PlaybackConfig(),
    clickEffectEnabled: null,
    getGoogleAccountSubtitle: () => '',
    getLanguageAndRegionSubtitle: () => '',
    getPlaybackSubtitle: () => '',
    getAppearanceSubtitle: () => '',
    onGoogleAccountClick: () => {},
    onLanguageClick: () => {},
    onPlaybackClick: () => {},
    onAppearanceClick: () => {},
    onLogClick: () => {},
    onRecoveryClick: () => {},
    onAboutClick: () => {}
  };

  build() {
    Column() {
      Scroll() {
        Column({ space: 6 }) {
          PlaybackSectionTitle({ title: '首选项' })

          OptionItem({
            icon: $r('sys.symbol.info_circle'),
            title: 'Google 登录',
            subtitle: this.params.getGoogleAccountSubtitle(),
            iconColor: $r('app.color.yourtube_theme_primary'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onGoogleAccountClick
          })

          PlaybackSectionTitle({ title: $r('app.string.yt_option_group_settings') })

          OptionItem({
            icon: $r('sys.symbol.translate_c2e'),
            title: $r('app.string.yt_section_language_region'),
            subtitle: this.params.getLanguageAndRegionSubtitle(this.params.uiConfig),
            iconColor: $r('app.color.yourtube_option_icon_language'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onLanguageClick
          })

          OptionItem({
            icon: $r('sys.symbol.play_circle'),
            title: $r('app.string.yt_section_playback'),
            subtitle: this.params.getPlaybackSubtitle(this.params.playbackConfig),
            iconColor: $r('app.color.yourtube_theme_primary'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onPlaybackClick
          })

          OptionItem({
            icon: $r('sys.symbol.paintpalette_fill'),
            title: $r('app.string.yt_option_appearance'),
            subtitle: this.params.getAppearanceSubtitle(this.params.uiConfig),
            iconColor: $r('app.color.yourtube_option_icon_palette'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onAppearanceClick
          })

          PlaybackSectionTitle({ title: $r('app.string.yt_option_group_others') })

          OptionItem({
            icon: $r('sys.symbol.doc_text'),
            title: $r('app.string.yt_option_log'),
            subtitle: $r('app.string.yt_option_log_subtitle'),
            iconColor: $r('app.color.yourtube_option_icon_log'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onLogClick
          })

          OptionItem({
            icon: $r('sys.symbol.arrow_counterclockwise'),
            title: $r('app.string.yt_option_recovery'),
            subtitle: $r('app.string.yt_option_reset_settings_subtitle'),
            iconColor: $r('app.color.yourtube_option_icon_palette'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onRecoveryClick
          })

          OptionItem({
            icon: $r('sys.symbol.info_circle'),
            title: $r('app.string.yt_option_about'),
            subtitle: 'v' + APP_VERSION,
            iconColor: $r('app.color.yourtube_option_icon_about'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onAboutClick
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }
}
