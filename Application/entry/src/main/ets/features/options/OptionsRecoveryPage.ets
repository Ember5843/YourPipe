import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { OptionItem } from '../../common/components/OptionItem';

interface OptionsRecoveryPageParams {
  clickEffectEnabled: ClickEffect | null;
  onResetSettingsClick: () => void;
  onClearAllDataClick: () => void;
}

@Component
export struct OptionsRecoveryPage {
  @Prop params: OptionsRecoveryPageParams = {
    clickEffectEnabled: null,
    onResetSettingsClick: () => {},
    onClearAllDataClick: () => {}
  };

  build() {
    Column() {
      Scroll() {
        Column({ space: 6 }) {
          PlaybackSectionTitle({ title: $r('app.string.yt_option_recovery') })

          OptionItem({
            icon: $r('sys.symbol.arrow_counterclockwise'),
            title: $r('app.string.yt_option_reset_settings'),
            subtitle: $r('app.string.yt_option_reset_settings_subtitle'),
            iconColor: $r('app.color.yourtube_option_icon_palette'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onResetSettingsClick
          })

          OptionItem({
            icon: $r('sys.symbol.trash'),
            title: $r('app.string.yt_option_clear_all_data'),
            subtitle: $r('app.string.yt_option_clear_all_data_subtitle'),
            iconColor: $r('app.color.yourtube_text_warning'),
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: this.params.onClearAllDataClick
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 12 })
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
