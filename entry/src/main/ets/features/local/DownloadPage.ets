import { DownloadManager, DownloadTask, DownloadStatus } from '../../common/DownloadManager';
import { fileUri, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { MediaThumb } from '../../common/components/MediaThumb';
import {
  MEDIA_CARD_RADIUS,
  MEDIA_CARD_SHADOW_OFFSET_Y,
  MEDIA_CARD_SHADOW_RADIUS,
  MEDIA_LIST_THUMB_GAP,
  MEDIA_LIST_THUMB_HEIGHT,
  MEDIA_LIST_THUMB_WIDTH,
  MEDIA_META_SIZE,
  MEDIA_THUMB_RADIUS,
  MEDIA_TITLE_LINE_HEIGHT,
  MEDIA_TITLE_SIZE
} from '../../common/components/MediaCardTokens';

function isActiveStatus(status: DownloadStatus): boolean {
  return status === DownloadStatus.DOWNLOADING_VIDEO ||
    status === DownloadStatus.DOWNLOADING_AUDIO ||
    status === DownloadStatus.MERGING ||
    status === DownloadStatus.PENDING;
}

@Component
export struct DownloadPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @StorageLink('downloadTasks') tasks: DownloadTask[] = [];

  build() {
    if (this.tasks.length === 0) {
      Column() {
        SymbolGlyph($r('sys.symbol.download_fill'))
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
      List({ space: 4 }) {
        ForEach(this.tasks, (task: DownloadTask) => {
          ListItem() {
            DownloadTaskRow({ task: task })
          }
        }, (task: DownloadTask) => task.id)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 10, right: 10, top: 4, bottom: 12 })
      .edgeEffect(EdgeEffect.Spring)
    }
  }
}

@Component
struct DownloadTaskRow {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @ObjectLink task: DownloadTask;
  private downloadManager: DownloadManager = DownloadManager.getInstance();
  @State exporting: boolean = false;

  build() {
    Row() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        MediaThumb({
          imageUrl: this.task.thumbnailUrl || '',
          placeholderColor: '#1A1A1A',
          widthVp: MEDIA_LIST_THUMB_WIDTH,
          heightVp: MEDIA_LIST_THUMB_HEIGHT,
          borderRadiusVp: MEDIA_THUMB_RADIUS
        })

        if (this.task.status === DownloadStatus.COMPLETED) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(18)
            .fontColor([this.themePrimary])
            .position({ x: 4, y: 4 })
        } else if (this.task.status === DownloadStatus.FAILED) {
          SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
            .fontSize(18)
            .fontColor(['#FF4444'])
            .position({ x: 4, y: 4 })
        }

        if (isActiveStatus(this.task.status)) {
          Column() {
            SymbolGlyph($r('sys.symbol.waveform'))
              .fontSize(20)
              .fontColor([Color.White])
          }
          .width(MEDIA_LIST_THUMB_WIDTH)
          .height(MEDIA_LIST_THUMB_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor('rgba(0,0,0,0.4)')
          .borderRadius(MEDIA_THUMB_RADIUS)
        }
      }
      .width(MEDIA_LIST_THUMB_WIDTH)
      .height(MEDIA_LIST_THUMB_HEIGHT)
      .margin({ right: MEDIA_LIST_THUMB_GAP })

      Column() {
        Text(this.task.title)
          .fontSize(MEDIA_TITLE_SIZE)
          .fontColor(isActiveStatus(this.task.status)
            ? this.themePrimary
            : $r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
          .width('100%')
          .margin({ bottom: 2 })

        if (this.task.author && this.task.author.length > 0) {
          Text(this.task.author)
            .fontSize(MEDIA_META_SIZE)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ bottom: 2 })
        }

        Text(this.getSubtitle())
          .fontSize(MEDIA_META_SIZE)
          .fontColor(this.getStatusColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: MEDIA_LIST_THUMB_HEIGHT })
      .alignItems(HorizontalAlign.Start)

      this.ProgressRing()
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
    .borderRadius(MEDIA_CARD_RADIUS)
    .backgroundColor(isActiveStatus(this.task.status)
      ? $r('app.color.yourtube_bg_surface_muted')
      : $r('app.color.yourtube_bg_surface'))
    .shadow({
      radius: MEDIA_CARD_SHADOW_RADIUS,
      color: $r('app.color.yourtube_shadow'),
      offsetX: 0,
      offsetY: MEDIA_CARD_SHADOW_OFFSET_Y
    })
    .onClick(() => {
      if (this.task.status === DownloadStatus.COMPLETED) {
        this.exportTaskToDownloads();
      }
    })
  }

  @Builder
  ProgressRing() {
    Stack({ alignContent: Alignment.Center }) {
      Progress({
        value: this.getRingValue(),
        total: 100,
        type: ProgressType.Ring
      })
        .width(42)
        .height(42)
        .color(this.getStatusColor())
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .style({ strokeWidth: 5 })

      if (this.task.status === DownloadStatus.COMPLETED) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(16)
          .fontColor([this.themePrimary])
      } else if (this.task.status === DownloadStatus.FAILED) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor(['#FF4444'])
      } else if (this.task.status === DownloadStatus.CANCELLED) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(13)
          .fontColor([$r('app.color.yourtube_text_hint')])
      } else {
        Text(`${this.getRingValue()}%`)
          .fontSize(10)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
      }
    }
    .width(52)
    .height(52)
  }

  private getSubtitle(): ResourceStr {
    if (this.task.status === DownloadStatus.FAILED) {
      return this.task.errorMessage || $r('app.string.yt_download_status_failed');
    }
    if (this.task.status === DownloadStatus.COMPLETED) {
      return $r('app.string.yt_download_status_completed');
    }
    if (this.task.status === DownloadStatus.PENDING) {
      return $r('app.string.yt_download_status_waiting');
    }
    if (this.task.status === DownloadStatus.CANCELLED) {
      return $r('app.string.yt_download_status_cancelled');
    }
    const label = this.task.status === DownloadStatus.DOWNLOADING_VIDEO
      ? getContext().resourceManager.getStringSync($r('app.string.yt_download_status_video').id)
      : this.task.status === DownloadStatus.DOWNLOADING_AUDIO
        ? getContext().resourceManager.getStringSync($r('app.string.yt_download_status_audio').id)
        : getContext().resourceManager.getStringSync($r('app.string.yt_download_status_merging').id);
    const progressText = this.task.getProgressText();
    return progressText ? `${label} · ${progressText}` : label;
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
        message: $r('app.string.yt_download_saved_to_downloads'),
        duration: 2000
      });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({
        message: (error as Error).message || $r('app.string.yt_download_save_failed'),
        duration: 2000
      });
    } finally {
      this.exporting = false;
    }
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
      return this.themePrimary;
    }
    return $r('app.color.yourtube_text_hint');
  }
}
