@Component
export struct PlaybackToggleRow {
  @Prop title: ResourceStr;
  @Prop subtitle: ResourceStr = '';
  @Prop isOn: boolean;
  @Prop themeColor: ResourceColor = $r('app.color.yourtube_theme_primary');
  onChange?: (val: boolean) => void;

  build() {
    Row({ space: 12 }) {
      Column() {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_text_primary'))
        if (typeof this.subtitle === 'string' && this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .margin({ top: 3 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(this.themeColor)
        .onChange((val: boolean) => {
          if (this.onChange) {
            this.onChange(val);
          }
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
    .borderRadius(16)
  }
}
