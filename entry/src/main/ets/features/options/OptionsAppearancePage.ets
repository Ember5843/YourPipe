import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { UIConfig, YourtubeDarkMode } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';

interface OptionsAppearancePageParams {
  themeColor: ResourceColor;
  applyDarkModeSelection: (mode: YourtubeDarkMode) => void;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
}

@Component
export struct OptionsAppearancePage {
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

  @Prop params: OptionsAppearancePageParams = {
    themeColor: $r('app.color.yourtube_theme_primary'),
    applyDarkModeSelection: () => {},
    updateUiConfig: () => {}
  };

  private getDarkModeOptions(): SelectOption[] {
    return [
      $r('app.string.yt_dark_mode_system'),
      $r('app.string.yt_dark_mode_light'),
      $r('app.string.yt_dark_mode_dark')
    ].map(label => ({ value: label } as SelectOption));
  }

  private getDarkModeIndex(): number {
    return [YourtubeDarkMode.SYSTEM, YourtubeDarkMode.LIGHT, YourtubeDarkMode.DARK]
      .indexOf(this.uiConfig.darkMode);
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 6 }) {
          PlaybackSectionTitle({ title: $r('app.string.yt_dark_mode_title') })

          PlaybackSelectRow({
            title: $r('app.string.yt_dark_mode_title'),
            options: this.getDarkModeOptions(),
            selectedIndex: this.getDarkModeIndex(),
            fontColor: this.params.themeColor,
            onChange: (index: number) => {
              const mode = [YourtubeDarkMode.SYSTEM, YourtubeDarkMode.LIGHT, YourtubeDarkMode.DARK][index];
              this.params.applyDarkModeSelection(mode);
            }
          })

          PlaybackSectionTitle({ title: $r('app.string.yt_setting_home_layout') })

          PlaybackToggleRow({
            title: $r('app.string.yt_layout_grid'),
            subtitle: this.uiConfig.homeLayoutMode === 'grid' ? '卡片模式' : '列表模式',
            isOn: this.uiConfig.homeLayoutMode === 'grid',
            themeColor: this.params.themeColor,
            onChange: (val: boolean) => {
              this.params.updateUiConfig(cfg => { cfg.homeLayoutMode = val ? 'grid' : 'list'; });
            }
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
