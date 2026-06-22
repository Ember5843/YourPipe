/**
 * Tab 内错误面板组件
 * 用于评论区、相关视频、播放列表等 Tab 内的错误展示
 *
 * 特点：
 * - 轻量级，不遮挡其他 Tab
 * - 自带重试按钮
 * - 可复用
 */

@Component
export struct TabErrorPanel {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  /** 错误消息（支持字符串或资源 ID） */
  @Prop errorMessage: string | Resource = '';

  /** 是否显示重试按钮 */
  @Prop showRetry: boolean = true;

  /** 重试回调 */
  onRetry?: () => void;

  /** 自定义图标（可选） */
  @Prop customIcon: Resource | undefined = undefined;

  // 防抖相关
  private lastRetryTime: number = 0;
  private readonly DEBOUNCE_MS: number = 300;

  private handleRetryClick(): void {
    // 防抖：300ms 内多次点击只执行一次
    const now = Date.now();
    if (now - this.lastRetryTime < this.DEBOUNCE_MS) {
      return;
    }
    this.lastRetryTime = now;

    if (this.onRetry) {
      this.onRetry();
    }
  }

  build() {
    Column({ space: 16 }) {
      // 错误图标
      SymbolGlyph(this.customIcon ?? $r('sys.symbol.exclamationmark_triangle'))
        .fontSize(40)
        .fontColor([$r('app.color.yourtube_text_disabled')])
        .margin({ bottom: 4 })

      // 错误消息
      Text(this.errorMessage)
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 32, right: 32 })

      // 重试按钮
      if (this.showRetry && this.onRetry) {
        Button() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(16)
              .fontColor([Color.White])
            Text($r('app.string.yt_action_retry'))
              .fontSize(14)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
          }
          .justifyContent(FlexAlign.Center)
        }
        .height(36)
        .padding({ left: 20, right: 20 })
        .backgroundColor(this.themePrimary)
        .borderRadius(18)
        .onClick(() => {
          this.handleRetryClick();
        })
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 60, bottom: 60, left: 16, right: 16 })
  }
}
