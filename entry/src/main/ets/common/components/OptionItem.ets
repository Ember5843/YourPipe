@Component
export struct OptionItem {
  @Prop icon: Resource | undefined = undefined;
  /** When set, rendered as a 24x24 image instead of SymbolGlyph. */
  @Prop imageIcon: Resource | undefined = undefined;
  @Prop title: ResourceStr = '';
  @Prop subtitle: ResourceStr = '';
  @Prop showChevron: boolean = true;
  @Prop iconColor: ResourceColor = '#E53935';
  @Prop clickEffectEnabled: ClickEffect | null = null;
  @Prop transparentBackground: boolean = false;
  @Prop subtitleMaxLines: number = 1;
  /** Image logo size; default matches title+subtitle text block height. */
  @Prop imageIconSize: number = 36;
  onClickAction?: () => void;

  @Styles
  RowStyle() {
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  build() {
    Row({ space: 12 }) {
      if (this.imageIcon) {
        Image(this.imageIcon)
          .width(this.imageIconSize)
          .height(this.imageIconSize)
          .objectFit(ImageFit.Cover)
          .borderRadius(8)
          .flexShrink(0)
      } else if (this.icon) {
        SymbolGlyph(this.icon)
          .fontSize(24)
          .fontColor([this.iconColor])
      }

      Column() {
        Text(this.title)
          .fontWeight(FontWeight.Medium)
          .fontSize(16)
          .fontColor($r('sys.color.font_primary'))

        if (this.subtitle) {
          Text(this.subtitle)
            .fontWeight(FontWeight.Normal)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(this.subtitleMaxLines)
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
          .fontColor([$r('sys.color.icon_fourth')])
      }
    }
    .RowStyle()
    .alignItems(VerticalAlign.Center)
    .borderRadius(this.transparentBackground ? 0 : 16)
    .backgroundColor(this.transparentBackground ? Color.Transparent : $r('sys.color.comp_background_list_card'))
    .clickEffect(this.clickEffectEnabled)
    .onClick(() => {
      if (this.onClickAction) {
        this.onClickAction();
      }
    })
  }
}
