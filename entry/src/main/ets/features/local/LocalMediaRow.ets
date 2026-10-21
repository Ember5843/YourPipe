import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { LocalMediaItem } from '../../common/LocalMediaStore';
import { formatBytes } from '../../common/utils/FormatUtils';
import {
  MEDIA_CARD_RADIUS,
  MEDIA_CARD_SHADOW_OFFSET_Y,
  MEDIA_CARD_SHADOW_RADIUS,
  MEDIA_META_SIZE,
  MEDIA_TITLE_LINE_HEIGHT,
  MEDIA_TITLE_SIZE
} from '../../common/components/MediaCardTokens';

/** 「本地媒体」里的导入文件行（与下载任务行同一视觉骨架）。 */
@Component
export struct LocalMediaRow {
  @Prop item: LocalMediaItem = new LocalMediaItem('', '', '', '', 0, 0);
  @Prop themePrimary: string = '#E53935';
  @StorageProp('uiConfig') uiConfig: UIConfig = new UIConfig();
  onOpen: (item: LocalMediaItem) => void = () => {};
  onDelete: (item: LocalMediaItem) => void = () => {};

  build() {
    Row() {
      Stack() {
        SymbolGlyph($r('sys.symbol.play_circle'))
          .fontSize(30)
          .fontColor([this.themePrimary])
      }
      .width(120)
      .height(68)
      .borderRadius(8)
      .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
      .margin({ right: 10 })

      Column() {
        Text(this.item.title)
          .fontSize(MEDIA_TITLE_SIZE)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
          .width('100%')

        Text(`${formatBytes(this.item.sizeBytes)}`)
          .fontSize(MEDIA_META_SIZE)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .margin({ top: 4 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)

      Button() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(18)
          .fontColor([$r('app.color.yourtube_text_hint')])
      }
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .onClick(() => { this.onDelete(this.item); })
    }
    .width('100%')
    .padding({ left: 10, right: 6, top: 8, bottom: 8 })
    .borderRadius(MEDIA_CARD_RADIUS)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .shadow({
      radius: MEDIA_CARD_SHADOW_RADIUS,
      color: $r('app.color.yourtube_shadow'),
      offsetX: 0,
      offsetY: MEDIA_CARD_SHADOW_OFFSET_Y
    })
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .onClick(() => { this.onOpen(this.item); })
  }
}
