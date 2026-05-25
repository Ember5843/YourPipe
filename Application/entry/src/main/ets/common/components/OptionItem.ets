import { customAnimationUtil } from '../../common/AnimationUtil';
import { UIConfig } from '../AppState';

@Component
export struct OptionItem {
  @Prop icons: Resource | undefined = undefined;
  @Prop title: ResourceStr = '';
  @Prop subtitle: ResourceStr = '';
  @Prop isPrimaryIcons: boolean = true;
  @Prop showChevron: boolean = true;
  @Prop iconColor: ResourceColor = $r('app.color.yourtube_theme_primary');
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  onClickAction?: () => void;

  @Styles
  RowStyle() {
    .width('100%')
    .borderRadius(16)
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
  }

  build() {
    Row({ space: 12 }) {
      if (this.icons) {
        SymbolGlyph(this.icons)
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

      Blank()

      if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(20)
          .fontColor([$r('app.color.yourtube_icon_hint')])
      }
    }
    .RowStyle()
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .onClick(() => {
      if (this.onClickAction) {
        this.onClickAction();
      }
    })
  }
}
