import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { UIConfig, YourtubeDarkMode } from '../../common/AppState';
import { ColorPresetItem, COLOR_PRESETS, ThemeManager } from '../../common/ThemeManager';

interface OptionsAppearancePageParams {
  themeColor: ResourceColor;
  applyDarkModeSelection: (mode: YourtubeDarkMode) => void;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
}

@Component
export struct OptionsAppearancePage {
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = COLOR_PRESETS[0].primary;

  @Prop params: OptionsAppearancePageParams = {
    themeColor: '#F1680D',
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

  private applyColorPreset(preset: ColorPresetItem): void {
    this.params.updateUiConfig(cfg => { cfg.colorPreset = preset.id; });
    ThemeManager.apply(preset.id);
  }

  @Builder
  ColorSwatch(preset: ColorPresetItem) {
    Stack() {
      Circle({ width: 36, height: 36 })
        .fill(preset.primary)

      if (this.uiConfig.colorPreset === preset.id) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([Color.White])
      }
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .border(this.uiConfig.colorPreset === preset.id
      ? { width: 2, color: preset.primary, style: BorderStyle.Solid }
      : { width: 0 })
    .padding(this.uiConfig.colorPreset === preset.id ? 2 : 4)
    .onClick(() => {
      this.applyColorPreset(preset);
    })
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_dark_mode_title') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_dark_mode_title'),
              options: this.getDarkModeOptions(),
              selectedIndex: this.getDarkModeIndex(),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const mode = [YourtubeDarkMode.SYSTEM, YourtubeDarkMode.LIGHT, YourtubeDarkMode.DARK][index];
                this.params.applyDarkModeSelection(mode);
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)

        ListItem() {
          PlaybackSectionTitle({ title: '主题色' })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            Column({ space: 12 }) {
              Row() {
                Text('当前')
                  .fontSize(13)
                  .fontColor($r('app.color.yourtube_text_secondary'))
                  .layoutWeight(1)

                Text(ThemeManager.getPreset(this.uiConfig.colorPreset).displayName)
                  .fontSize(13)
                  .fontColor(this.themePrimary)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')

              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                ForEach(COLOR_PRESETS, (preset: ColorPresetItem) => {
                  this.ColorSwatch(preset)
                }, (preset: ColorPresetItem) => preset.id)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_setting_home_layout') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_layout_grid'),
              subtitle: this.uiConfig.homeLayoutMode === 'grid' ? '卡片模式' : '列表模式',
              isOn: this.uiConfig.homeLayoutMode === 'grid',
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updateUiConfig(cfg => { cfg.homeLayoutMode = val ? 'grid' : 'list'; });
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)
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
