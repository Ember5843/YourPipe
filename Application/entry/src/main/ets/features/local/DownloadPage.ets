import { DownloadManager, DownloadTask, DownloadStatus } from '../../common/DownloadManager';
import { ActionHub } from '../../common/ActionHub';
import { VideoItem } from 'youtube_core';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { customVibrator } from '../../common/VibratorUtil';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';

const SYMBOL_FONT_SIZE: number = 16;

/** 格式化文件大小 */
function formatBytes(bytes: number): string {
  if (bytes <= 0) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

function formatRelativeTime(ts: number): string {
  const diff = Date.now() - ts;
  const min = Math.floor(diff / 60000);
  if (min < 1) return '刚刚';
  if (min < 60) return `${min} 分钟前`;
  const h = Math.floor(min / 60);
  if (h < 24) return `${h} 小时前`;
  return `${Math.floor(h / 24)} 天前`;
}

@Component
export struct DownloadPage {
  @StorageLink('downloadTasks') tasks: DownloadTask[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub;
  private downloadManager: DownloadManager = DownloadManager.getInstance();

  build() {
    if (this.tasks.length === 0) {
      Column() {
        SymbolGlyph($r('sys.symbol.arrowshape_down_to_line_fill'))
          .fontSize(48)
          .fontColor([$r('app.color.yourtube_text_hint')])
          .margin({ bottom: 12 })
        Text($r('app.string.yt_download_empty'))
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_secondary'))
        Text($r('app.string.yt_download_empty_hint'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_hint'))
          .margin({ top: 4 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ bottom: 60 })
    } else {
      List({ space: 8 }) {
        ForEach(this.tasks, (task: DownloadTask) => {
          ListItem() {
            this.DownloadCard(task)
          }
        }, (task: DownloadTask) => task.id + task.progress)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 12 })
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  DownloadCard(task: DownloadTask) {
    Column() {
      // 标题行
      Row() {
        // 缩略图
        Stack() {
          if (task.thumbnailUrl && task.thumbnailUrl.length > 0) {
            Image(task.thumbnailUrl)
              .width(64)
              .height(36)
              .objectFit(ImageFit.Cover)
              .borderRadius(4)
              .backgroundColor('#1A1A1A')
          } else {
            Rect()
              .width(64)
              .height(36)
              .fill('#1A1A1A')
              .radius(4)
          }

          // 状态角标
          if (task.status === DownloadStatus.COMPLETED) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
              .fontSize(14)
              .fontColor([$r('app.color.yourtube_theme_primary')])
              .position({ x: -4, y: -4 })
          } else if (task.status === DownloadStatus.FAILED) {
            SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
              .fontSize(14)
              .fontColor(['#FF4444'])
              .position({ x: -4, y: -4 })
          }
        }
        .width(64)
        .height(36)
        .margin({ right: 10 })

        Column() {
          Text(task.title)
            .fontSize(14)
            .fontColor($r('app.color.yourtube_text_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(task.author)
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .height(36)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .margin({ bottom: 8 })

      // 进度和状态
      if (task.status === DownloadStatus.DOWNLOADING_VIDEO ||
        task.status === DownloadStatus.DOWNLOADING_AUDIO ||
        task.status === DownloadStatus.MERGING) {
        Column() {
          // 进度条
          Row() {
            Row()
              .height(3)
              .backgroundColor($r('app.color.yourtube_theme_primary'))
              .layoutWeight(Math.max(task.progress, 1))
              .borderRadius(2)
            Row()
              .height(3)
              .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
              .layoutWeight(Math.max(100 - task.progress, 0))
              .borderRadius(2)
          }
          .width('100%')
          .borderRadius(2)
          .margin({ bottom: 4 })

          Row() {
            Text(task.getStatusLabel())
              .fontSize(11)
              .fontColor($r('app.color.yourtube_theme_primary'))

            Blank()

            Text(`${task.progress}%`)
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')

          // 文件大小
          if (task.totalSize > 0) {
            Text(task.getProgressText())
              .fontSize(10)
              .fontColor($r('app.color.yourtube_text_hint'))
              .width('100%')
              .margin({ top: 2 })
          }
        }
        .width('100%')
      } else if (task.status === DownloadStatus.COMPLETED) {
        Row() {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(12)
            .fontColor([$r('app.color.yourtube_theme_primary')])
          Text('已完成')
            .fontSize(11)
            .fontColor($r('app.color.yourtube_theme_primary'))
            .margin({ left: 4 })

          Blank()

          Text(formatRelativeTime(task.createdAt))
            .fontSize(10)
            .fontColor($r('app.color.yourtube_text_hint'))

          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(14)
              .fontColor([$r('app.color.yourtube_text_hint')])
          }
          .width(28)
          .height(28)
          .backgroundColor(Color.Transparent)
          .margin({ left: 8 })
          .onClick(() => {
            this.downloadManager.deleteTask(task.id);
          })
        }
        .width('100%')
      } else if (task.status === DownloadStatus.FAILED) {
        Row() {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(12)
            .fontColor(['#FF4444'])
          Text(task.errorMessage || '下载失败')
            .fontSize(11)
            .fontColor('#FF4444')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ left: 4 })

          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(14)
              .fontColor([$r('app.color.yourtube_text_hint')])
          }
          .width(28)
          .height(28)
          .backgroundColor(Color.Transparent)
          .margin({ left: 8 })
          .onClick(() => {
            this.downloadManager.deleteTask(task.id);
          })
        }
        .width('100%')
      } else if (task.status === DownloadStatus.CANCELLED) {
        Row() {
          SymbolGlyph($r('sys.symbol.xmark_circle'))
            .fontSize(12)
            .fontColor([$r('app.color.yourtube_text_hint')])
          Text('已取消')
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_hint'))
            .margin({ left: 4 })

          Blank()

          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(14)
              .fontColor([$r('app.color.yourtube_text_hint')])
          }
          .width(28)
          .height(28)
          .backgroundColor(Color.Transparent)
          .margin({ left: 8 })
          .onClick(() => {
            this.downloadManager.deleteTask(task.id);
          })
        }
        .width('100%')
      } else if (task.status === DownloadStatus.PENDING) {
        Row() {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(12)
            .fontColor([$r('app.color.yourtube_text_hint')])
          Text('等待中')
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_hint'))
            .margin({ left: 4 })

          Blank()

          Text(formatRelativeTime(task.createdAt))
            .fontSize(10)
            .fontColor($r('app.color.yourtube_text_hint'))

          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(14)
              .fontColor([$r('app.color.yourtube_text_hint')])
          }
          .width(28)
          .height(28)
          .backgroundColor(Color.Transparent)
          .margin({ left: 8 })
          .onClick(() => {
            this.downloadManager.cancelTask(task.id);
          })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 12, bottom: 12 })
    .borderRadius(12)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .shadow({ radius: 4, color: $r('app.color.yourtube_shadow'), offsetX: 0, offsetY: 2 })
  }
}
