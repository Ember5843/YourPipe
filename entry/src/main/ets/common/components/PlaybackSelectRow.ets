import { SelectOption } from 'mediaservice';

@Component
export struct PlaybackSelectRow {
  @Prop title: ResourceStr;
  @Prop options: Array<SelectOption>;
  @Prop @Watch('onSelectedIndexChange') selectedIndex: number;
  @State selectedValue: string = '';
  @Prop fontColor: ResourceColor = '#F1680D';
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
        .optionFont({ size: 14 })
        .backgroundColor(Color.Transparent)
        .onSelect((index: number) => {
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
