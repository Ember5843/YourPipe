import { UIConfig } from '../AppState';

@Component
export struct ErrorPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @State errorMessage: ResourceStr = '';
  onRetry?: () => void = undefined;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  
    private readonly ERROR_ICON_SIZE: number = 80;
  private readonly ERROR_ICON_COLOR: ResourceColor = $r('app.color.yourtube_text_disabled');
  private readonly TITLE_FONT_SIZE: number = 16;
  private readonly MESSAGE_FONT_SIZE: number = 14;
  private readonly MESSAGE_MAX_WIDTH: number = 300;

  build() {
    Column() {
      Column() {
        // 灰色叉叉图标
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(this.ERROR_ICON_SIZE)
          .fontColor([this.ERROR_ICON_COLOR])
          .margin({ bottom: 24 })

        // 错误标题
        Text($r('app.string.yt_error_load_failed'))
          .fontSize(this.TITLE_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_text_primary'))
          .margin({ bottom: 12 })

        // 错误信息
        Text(this.errorMessage)
          .fontSize(this.MESSAGE_FONT_SIZE)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width(this.MESSAGE_MAX_WIDTH)
          .margin({ bottom: 32 })

        // 重试按钮（如果有重试回调）
        if (this.onRetry) {
          Button() {
            Row() {
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontSize(18)
                .fontColor([Color.White])
                .margin({ right: 6 })
              Text($r('app.string.yt_action_retry'))
                .fontSize(14)
                .fontColor(Color.White)
                .fontWeight(FontWeight.Medium)
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
          }
          .width(120)
          .height(40)
          .backgroundColor(this.themePrimary)
          .borderRadius(20)
          .onClick(() => {
            if (this.onRetry) {
              this.onRetry();
            }
          })
        }
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
