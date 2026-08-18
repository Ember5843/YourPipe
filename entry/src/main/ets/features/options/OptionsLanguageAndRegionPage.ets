import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { OptionItem } from '../../common/components/OptionItem';
import { UIConfig } from '../../common/AppState';
import { LanguagePickerItem } from '../../common/components/LanguagePickerDialog';

interface OptionsLanguageAndRegionPageParams {
  appLangItems: LanguagePickerItem[];
  contentLangItems: LanguagePickerItem[];
  contentCountryItems: LanguagePickerItem[];
  themeColor: ResourceColor;
  clickEffectEnabled: ClickEffect | null;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
  reloadHomeForSearchLocaleChange: () => void;
  applyLanguageSelection: (code: string) => void;
}

@Component
export struct OptionsLanguageAndRegionPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

  @Prop params: OptionsLanguageAndRegionPageParams = {
    appLangItems: [] as LanguagePickerItem[],
    contentLangItems: [] as LanguagePickerItem[],
    contentCountryItems: [] as LanguagePickerItem[],
    themeColor: '#E53935',
    clickEffectEnabled: null,
    updateUiConfig: () => {},
    reloadHomeForSearchLocaleChange: () => {},
    applyLanguageSelection: () => {}
  };

  private getItemDisplay(items: LanguagePickerItem[], code: string): string {
    const found = items.find((it: LanguagePickerItem): boolean => it.code === code);
    return found ? found.localizedName
      : getContext().resourceManager.getStringSync($r('app.string.yt_follow_system').id);
  }

  private getAppLanguageSubtitle(): string {
    return this.getItemDisplay(this.params.appLangItems, this.uiConfig.userLanguage);
  }

  private openAppLanguageDialog(): void {
    const items = this.params.appLangItems;
    const currentCode = this.uiConfig.userLanguage;
    const selectedIndex = Math.max(0, items.findIndex(it => it.code === currentCode));
    const range = items.map(it => it.localizedName);

    this.getUIContext().showTextPickerDialog({
      range: range,
      selected: selectedIndex,
      defaultPickerItemHeight: 36,
      canLoop: false,
      onAccept: (value: TextPickerResult) => {
        const index = Array.isArray(value.index) ? value.index[0] : value.index;
        const code = items[index].code;
        this.params.applyLanguageSelection(code);
      },
      onCancel: () => {},
      onChange: (_value: TextPickerResult) => {}
    });
  }

  private getContentLangOptions(): SelectOption[] {
    return this.params.contentLangItems.map(item => ({ value: item.localizedName } as SelectOption));
  }

  private getContentCountryOptions(): SelectOption[] {
    return this.params.contentCountryItems.map(item => ({ value: item.localizedName } as SelectOption));
  }

  /** 'default' + 应用支持的语言 + 额外翻译目标语言；default 项显示为「跟随应用语言」 */
  private getTranslationLangItems(): LanguagePickerItem[] {
    const followApp = getContext().resourceManager.getStringSync($r('app.string.yt_follow_app_language').id);
    const items: LanguagePickerItem[] = [new LanguagePickerItem('default', followApp, followApp)];
    for (const item of this.params.appLangItems) {
      if (item.code !== 'default') {
        items.push(item);
      }
    }
    // Extra translation targets that are not app UI languages.
    items.push(new LanguagePickerItem('it', 'Italiano', 'Italiano'));
    return items;
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_section_language') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            OptionItem({
              title: $r('app.string.yt_setting_ui_language'),
              subtitle: this.getAppLanguageSubtitle(),
              showChevron: true,
              clickEffectEnabled: this.params.clickEffectEnabled,
              transparentBackground: true,
              onClickAction: () => {
                this.openAppLanguageDialog();
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_content_language'),
              options: this.getContentLangOptions(),
              selectedIndex: this.params.contentLangItems.findIndex(it => it.code === this.uiConfig.searchLanguage),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const code = this.params.contentLangItems[index].code;
                this.params.updateUiConfig(cfg => cfg.searchLanguage = code === 'default' ? 'default' : code);
                this.params.reloadHomeForSearchLocaleChange();
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_content_region'),
              options: this.getContentCountryOptions(),
              selectedIndex: this.params.contentCountryItems.findIndex(it => it.code === this.uiConfig.searchCountry),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const code = this.params.contentCountryItems[index].code;
                this.params.updateUiConfig(cfg => cfg.searchCountry = code === 'default' ? 'default' : code.toUpperCase());
                this.params.reloadHomeForSearchLocaleChange();
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_section_content_translation') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_translation_language'),
              options: this.getTranslationLangItems().map(item => ({ value: item.localizedName } as SelectOption)),
              selectedIndex: Math.max(0, this.getTranslationLangItems().findIndex(it => it.code === this.uiConfig.translationLanguage)),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const code = this.getTranslationLangItems()[index].code;
                this.params.updateUiConfig(cfg => cfg.translationLanguage = code);
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
