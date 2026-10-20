import { SelectOption } from 'mediaservice';
import { ThemeColorUtil } from '../ThemeColorUtil';

@Component
export struct PlaybackSelectRow {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop title: ResourceStr;
  @Prop options: Array<SelectOption>;
  @Prop @Watch('onSelectedIndexChange') selectedIndex: number;
  @State selectedValue: string = '';
  @Prop fontColor: ResourceColor = '#E53935';
  @Prop transparentBackground: boolean = false;
  onChange?: (index: number) => void;

  aboutToAppear() {
    this.syncValue();
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
      Text(this.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.yourtube_text_primary'))
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
    .backgroundColor(this.transparentBackground ? Color.Transparent : $r('app.color.yourtube_bg_surface_muted'))
  }
}
