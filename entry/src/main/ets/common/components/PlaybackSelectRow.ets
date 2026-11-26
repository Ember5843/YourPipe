import { SelectOption } from 'mediaservice';
import { ThemeColorUtil } from '../ThemeColorUtil';
import { HelpBubbleContent } from './HelpBubbleContent';

@Component
export struct PlaybackSelectRow {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop title: ResourceStr;
  @Prop helpText: ResourceStr = '';
  @Prop @Watch('onForcePopupChange') forceShowPopup: boolean = false;
  @Prop options: Array<SelectOption>;
  @Prop @Watch('onSelectedIndexChange') selectedIndex: number;
  @State selectedValue: string = '';
  @State private showHelpPopup: boolean = false;
  @Prop fontColor: ResourceColor = '#E53935';
  @Prop transparentBackground: boolean = false;
  onChange?: (index: number) => void;
  onPopupClosed?: () => void;

  aboutToAppear() {
    this.syncValue();
    if (this.forceShowPopup && this.hasHelpText()) {
      setTimeout(() => {
        this.showHelpPopup = true;
      }, 280);
    }
  }

  onForcePopupChange(): void {
    if (this.forceShowPopup && this.hasHelpText() && !this.showHelpPopup) {
      setTimeout(() => {
        this.showHelpPopup = true;
      }, 220);
    }
  }

  private hasHelpText(): boolean {
    return !(typeof this.helpText === 'string' && this.helpText.length === 0);
  }

  private closeHelpPopup(): void {
    this.showHelpPopup = false;
    if (this.onPopupClosed) {
      this.onPopupClosed();
    }
  }

  @Builder
  private HelpPopupBuilder() {
    HelpBubbleContent({
      helpText: this.helpText,
      accentColor: this.themePrimary,
      onDismiss: () => {
        this.closeHelpPopup();
      }
    })
  }

  onSelectedIndexChange() {
    this.syncValue();
  }

  private syncValue() {
    if (this.selectedIndex >= 0 && this.selectedIndex < this.options.length) {
      const val = this.options[this.selectedIndex].value;
      if (typeof val === 'string') {
        this.selectedValue = val;
      } else {
        try {
          this.selectedValue = getContext().resourceManager.getStringSync(val.id);
        } catch (e) {
          this.selectedValue = '';
        }
      }
    } else {
      this.selectedValue = '';
    }
  }

  build() {
    Row() {
      Row({ space: 6 }) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .constraintSize({ maxWidth: '85%' })

        if (this.hasHelpText()) {
          SymbolGlyph($r('sys.symbol.questionmark_circle'))
            .fontSize(17)
            .fontColor([$r('sys.color.font_secondary')])
            .padding(4)
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => {
              this.showHelpPopup = !this.showHelpPopup;
            })
            .bindPopup(this.showHelpPopup, {
              width: 288,
              builder: () => { this.HelpPopupBuilder(); },
              placement: Placement.Top,
              enableArrow: true,
              autoCancel: true,
              onStateChange: (e) => {
                if (!e.isVisible && this.showHelpPopup) {
                  this.closeHelpPopup();
                }
              }
            })
        }
      }
      .alignItems(VerticalAlign.Center)
      .layoutWeight(1)

      Select(this.options)
        .selected(this.selectedIndex >= 0 ? this.selectedIndex : 0)
        .value($$this.selectedValue)
        .font({ size: 14 })
        .fontColor(this.fontColor)
        .selectedOptionFont({ size: 14 })
        .selectedOptionFontColor(this.themePrimary)
        .selectedOptionBgColor(ThemeColorUtil.selectedBackground(this.themePrimary))
        .optionBgColor(Color.Transparent)
        .optionFont({ size: 14 })
        .backgroundColor(Color.Transparent)
        .onSelect((index: number) => {
          // 父级改了 selectedIndex（预设套用 / 组合回推）也会触发 onSelect。
          // 用户主动选择时 index 与当前 prop 不等；程序化回写时两者相等——
          // 后者必须忽略，否则设置页会形成 回写→回调→再回写 的回路。
          if (index === this.selectedIndex) {
            return;
          }
          if (this.onChange) {
            this.onChange(index);
          }
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 8, top: 4, bottom: 4 })
    .borderRadius(this.transparentBackground ? 0 : 16)
    .backgroundColor(this.transparentBackground ? Color.Transparent : $r('sys.color.comp_background_list_card'))
  }
}
