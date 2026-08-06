import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { OptionItem } from '../../common/components/OptionItem';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';

interface OptionsRecoveryPageParams {
  onResetSettingsClick: () => void;
  onClearAllDataClick: () => void;
}

@Component
export struct OptionsRecoveryPage {
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';

  @Prop params: OptionsRecoveryPageParams = {
    onResetSettingsClick: () => {},
    onClearAllDataClick: () => {}
  };

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_option_recovery') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            OptionItem({
              icon: $r('sys.symbol.arrow_counterclockwise_clock'),
              title: $r('app.string.yt_option_reset_settings'),
              subtitle: $r('app.string.yt_option_reset_settings_subtitle'),
              iconColor: this.themePrimary,
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              transparentBackground: true,
              onClickAction: this.params.onResetSettingsClick
            })
          }

          ListItem() {
            OptionItem({
              icon: $r('sys.symbol.trash'),
              title: $r('app.string.yt_option_clear_all_data'),
              subtitle: $r('app.string.yt_option_clear_all_data_subtitle'),
              iconColor: $r('app.color.yourtube_text_warning'),
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              transparentBackground: true,
              onClickAction: this.params.onClearAllDataClick
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })
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
