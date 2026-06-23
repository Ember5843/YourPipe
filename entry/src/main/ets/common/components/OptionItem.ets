@Component
export struct OptionItem {
  @Prop icon: Resource | undefined = undefined;
  @Prop title: ResourceStr = '';
  @Prop subtitle: ResourceStr = '';
  @Prop showChevron: boolean = true;
  @Prop iconColor: ResourceColor = '#F1680D';
  @Prop clickEffectEnabled: ClickEffect | null = null;
  @Prop transparentBackground: boolean = false;
  onClickAction?: () => void;

  @Styles
  RowStyle() {
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  build() {
    Row({ space: 12 }) {
      if (this.icon) {
        SymbolGlyph(this.icon)
          .fontSize(24)
          .fontColor([this.iconColor])
      }

      Column() {
        Text(this.title)
          .fontWeight(FontWeight.Medium)
          .fontSize(16)
          .fontColor($r('app.color.yourtube_text_primary'))

        if (this.subtitle) {
          Text(this.subtitle)
            .fontWeight(FontWeight.Normal)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
            .fontSize(13)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(20)
          .fontColor([$r('app.color.yourtube_icon_hint')])
      }
    }
    .RowStyle()
    .borderRadius(this.transparentBackground ? 0 : 16)
    .backgroundColor(this.transparentBackground ? Color.Transparent : $r('app.color.yourtube_bg_surface_muted'))
    .clickEffect(this.clickEffectEnabled)
    .onClick(() => {
      if (this.onClickAction) {
        this.onClickAction();
      }
    })
  }
}
