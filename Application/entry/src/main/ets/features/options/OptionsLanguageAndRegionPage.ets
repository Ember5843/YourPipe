import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { OptionItem } from '../../common/components/OptionItem';
import { UIConfig } from '../../common/AppState';
import { LanguagePickerItem, UIPickerLanguageDialog } from '../../common/components/LanguagePickerDialog';

interface OptionsLanguageAndRegionPageParams {
  uiConfig: UIConfig;
  appLangItems: LanguagePickerItem[];
  contentLangItems: LanguagePickerItem[];
  contentCountryItems: LanguagePickerItem[];
  themeColor: ResourceColor;
  clickEffectEnabled: ClickEffect | null;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
  reloadHomeForSearchLocaleChange: () => void;
  applyLanguageSelection: (code: string) => void;
  getAppLanguageSubtitle: () => string;
}

@Component
export struct OptionsLanguageAndRegionPage {
  @Prop params: OptionsLanguageAndRegionPageParams = {
    uiConfig: new UIConfig(),
    appLangItems: [] as LanguagePickerItem[],
    contentLangItems: [] as LanguagePickerItem[],
    contentCountryItems: [] as LanguagePickerItem[],
    themeColor: $r('app.color.yourtube_theme_primary'),
    clickEffectEnabled: null,
    updateUiConfig: () => {},
    reloadHomeForSearchLocaleChange: () => {},
    applyLanguageSelection: () => {},
    getAppLanguageSubtitle: () => ''
  };

  private appLangDialogCtrl: CustomDialogController | null = null;

  private openAppLanguageDialog(): void {
    this.appLangDialogCtrl = new CustomDialogController({
      builder: UIPickerLanguageDialog({
        title: $r('app.string.yt_setting_ui_language'),
        items: this.params.appLangItems,
        selectedCode: this.params.uiConfig.userLanguage,
        onConfirm: (code: string) => {
          this.params.applyLanguageSelection(code);
        }
      }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      autoCancel: true
    });
    this.appLangDialogCtrl.open();
  }

  private getContentLangOptions(): SelectOption[] {
    return this.params.contentLangItems.map(item => ({ value: item.localizedName } as SelectOption));
  }

  private getContentCountryOptions(): SelectOption[] {
    return this.params.contentCountryItems.map(item => ({ value: item.localizedName } as SelectOption));
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 6 }) {
          PlaybackSectionTitle({ title: $r('app.string.yt_section_language') })

          // 应用UI语言 - 点击弹出 UIPickerComponent 对话框
          OptionItem({
            title: $r('app.string.yt_setting_ui_language'),
            subtitle: this.params.getAppLanguageSubtitle(),
            showChevron: true,
            clickEffectEnabled: this.params.clickEffectEnabled,
            onClickAction: () => {
              this.openAppLanguageDialog();
            }
          })

          PlaybackSelectRow({
            title: $r('app.string.yt_setting_content_language'),
            options: this.getContentLangOptions(),
            selectedIndex: this.params.contentLangItems.findIndex(it => it.code === this.params.uiConfig.searchLanguage),
            fontColor: this.params.themeColor,
            onChange: (index: number) => {
              const code = this.params.contentLangItems[index].code;
              this.params.updateUiConfig(cfg => cfg.searchLanguage = code === 'default' ? 'default' : code);
              this.params.reloadHomeForSearchLocaleChange();
            }
          })

          PlaybackSelectRow({
            title: $r('app.string.yt_setting_content_region'),
            options: this.getContentCountryOptions(),
            selectedIndex: this.params.contentCountryItems.findIndex(it => it.code === this.params.uiConfig.searchCountry),
            fontColor: this.params.themeColor,
            onChange: (index: number) => {
              const code = this.params.contentCountryItems[index].code;
              this.params.updateUiConfig(cfg => cfg.searchCountry = code === 'default' ? 'default' : code.toUpperCase());
              this.params.reloadHomeForSearchLocaleChange();
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
