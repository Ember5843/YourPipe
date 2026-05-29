import { DownloadManager, DownloadTask, DownloadStatus } from '../../common/DownloadManager';
import { fileUri, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

function formatRelativeTime(ts: number): string {
  const diff = Date.now() - ts;
  const min = Math.floor(diff / 60000);
  if (min < 1) return 'Just now';
  if (min < 60) return `${min} min ago`;
  const hour = Math.floor(min / 60);
  if (hour < 24) return `${hour} hours ago`;
  return `${Math.floor(hour / 24)} days ago`;
}

function isActiveStatus(status: DownloadStatus): boolean {
  return status === DownloadStatus.DOWNLOADING_VIDEO ||
    status === DownloadStatus.DOWNLOADING_AUDIO ||
    status === DownloadStatus.MERGING ||
    status === DownloadStatus.PENDING;
}

@Component
export struct DownloadPage {
  @StorageLink('downloadTasks') tasks: DownloadTask[] = [];

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
      List({ space: 6 }) {
        ForEach(this.tasks, (task: DownloadTask) => {
          ListItem() {
            DownloadTaskRow({ task: task })
          }
        }, (task: DownloadTask) => task.id)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 12 })
      .edgeEffect(EdgeEffect.Spring)
    }
  }
}

@Component
struct DownloadTaskRow {
  @ObjectLink task: DownloadTask;
  private downloadManager: DownloadManager = DownloadManager.getInstance();
  @State exporting: boolean = false;

  build() {
    Row({ space: 10 }) {
      Stack() {
        if (this.task.thumbnailUrl && this.task.thumbnailUrl.length > 0) {
          Image(this.task.thumbnailUrl)
            .width(96)
            .height(54)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
            .backgroundColor('#1A1A1A')
        } else {
          Rect()
            .width(96)
            .height(54)
            .fill('#1A1A1A')
            .radius(6)
        }

        if (this.task.status === DownloadStatus.COMPLETED) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(18)
            .fontColor([$r('app.color.yourtube_theme_primary')])
            .position({ x: 4, y: 4 })
        } else if (this.task.status === DownloadStatus.FAILED) {
          SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
            .fontSize(18)
            .fontColor(['#FF4444'])
            .position({ x: 4, y: 4 })
        }
      }
      .width(96)
      .height(54)

      Column() {
        Text(this.task.title)
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.task.author || this.task.getStatusLabel())
          .fontSize(11)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })

        Text(this.getSubtitle())
          .fontSize(10)
          .fontColor(this.getStatusColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .height(64)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start)

      Column() {
        if (isActiveStatus(this.task.status)) {
          this.ProgressRing()

          this.IconButton($r('sys.symbol.xmark'), () => {
            this.downloadManager.cancelTask(this.task.id);
          })
        } else {
          this.ProgressRing()

          if (this.task.status === DownloadStatus.COMPLETED) {
            this.IconButton($r('sys.symbol.arrowshape_down_to_line_fill'), () => {
              this.exportTaskToDownloads();
            })
          } else {
            this.IconButton($r('sys.symbol.trash'), () => {
              this.downloadManager.deleteTask(this.task.id);
            })
          }
        }
      }
      .width(64)
      .height(64)
      .alignItems(HorizontalAlign.End)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(78)
    .padding({ left: 8, right: 8 })
    .borderRadius(8)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
  }

  @Builder
  ProgressRing() {
    Stack({ alignContent: Alignment.Center }) {
      Progress({
        value: this.getRingValue(),
        total: 100,
        type: ProgressType.Ring
      })
        .value(this.getRingValue())
        .width(42)
        .height(42)
        .color(this.getStatusColor())
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .style({ strokeWidth: 5 })

      if (this.task.status === DownloadStatus.COMPLETED) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(16)
          .fontColor([$r('app.color.yourtube_theme_primary')])
      } else if (this.task.status === DownloadStatus.FAILED) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor(['#FF4444'])
      } else if (this.task.status === DownloadStatus.CANCELLED) {
        SymbolGlyph($r('sys.symbol.minus'))
          .fontSize(16)
          .fontColor([$r('app.color.yourtube_text_hint')])
      } else {
        Text(`${this.getRingValue()}%`)
          .fontSize(10)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
      }
    }
    .width(48)
    .height(48)
    .margin({ bottom: 2 })
  }

  @Builder
  IconButton(icon: Resource, action: () => void) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(icon)
        .fontSize(15)
        .fontColor([$r('app.color.yourtube_text_hint')])
    }
    .width(30)
    .height(30)
    .backgroundColor(Color.Transparent)
    .onClick(() => action())
  }

  private getSubtitle(): string {
    if (this.task.status === DownloadStatus.FAILED) {
      return this.task.errorMessage || 'Download failed';
    }
    if (this.task.status === DownloadStatus.COMPLETED) {
      return this.task.outputPath || 'Saved in app downloads';
    }
    if (this.task.status === DownloadStatus.PENDING) {
      return this.task.getStatusLabel();
    }
    const progressText = this.task.getProgressText();
    return progressText ? `${this.task.getStatusLabel()} · ${progressText}` : this.task.getStatusLabel();
  }

  private async exportTaskToDownloads(): Promise<void> {
    if (this.exporting || this.task.status !== DownloadStatus.COMPLETED) {
      return;
    }
    this.exporting = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentViewPicker = new picker.DocumentViewPicker(context);
      const documentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const result = await documentViewPicker.save(documentSaveOptions);
      if (!result || result.length === 0) {
        return;
      }
      const destinationDir = new fileUri.FileUri(result[0]).path;
      await this.downloadManager.exportCompletedTask(this.task.id, destinationDir);
      this.getUIContext().getPromptAction().showToast({
        message: 'Saved to Downloads',
        duration: 2000
      });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({
        message: (error as Error).message || 'Save failed',
        duration: 2000
      });
    } finally {
      this.exporting = false;
    }
  }

  private getRightLabel(): string {
    if (this.task.status === DownloadStatus.COMPLETED) {
      return '100%';
    }
    if (this.task.status === DownloadStatus.FAILED) {
      return 'Failed';
    }
    if (this.task.status === DownloadStatus.CANCELLED) {
      return 'Cancelled';
    }
    return formatRelativeTime(this.task.createdAt);
  }

  private getRingValue(): number {
    if (this.task.status === DownloadStatus.COMPLETED) {
      return 100;
    }
    if (this.task.status === DownloadStatus.FAILED || this.task.status === DownloadStatus.CANCELLED) {
      return Math.max(0, Math.min(100, this.task.progress || 0));
    }
    if (this.task.status === DownloadStatus.PENDING) {
      return 0;
    }
    return Math.max(0, Math.min(100, this.task.progress || 0));
  }

  private getStatusColor(): ResourceColor {
    if (this.task.status === DownloadStatus.FAILED) {
      return '#FF4444';
    }
    if (this.task.status === DownloadStatus.COMPLETED || isActiveStatus(this.task.status)) {
      return $r('app.color.yourtube_theme_primary');
    }
    return $r('app.color.yourtube_text_hint');
  }
}
