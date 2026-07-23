import { DownloadManager, DownloadTask, DownloadStatus } from '../../common/DownloadManager';
import { fileUri, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { MediaThumb } from '../../common/components/MediaThumb';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
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

const ACTION_BTN_HEIGHT: number = 24;
const ACTION_BTN_WIDTH: number = 72;
const ACTION_BTN_RESERVE: number = 28;

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
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

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
          .transition(customAnimationUtil.isScaleTran(task.id, this.uiConfig))
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
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @ObjectLink task: DownloadTask;
  private downloadManager: DownloadManager = DownloadManager.getInstance();
  @State exporting: boolean = false;

  build() {
    Row() {
      this.ThumbBlock()

      // 与 VideoMediaCard 列表一致：文字顶对齐，操作按钮钉在右下角
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() {
          Text(this.task.title)
            .fontSize(MEDIA_TITLE_SIZE)
            .fontColor($r('app.color.yourtube_text_primary'))
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

          // 下载中不显示流量/状态行；进度只在右下角胶囊内显示百分比
          if (!isActiveStatus(this.task.status)) {
            Text(this.getSubtitle())
              .fontSize(MEDIA_META_SIZE)
              .fontColor(this.getStatusColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Start)
        .padding({ bottom: ACTION_BTN_RESERVE })

        this.ActionCapsule()
      }
      .layoutWeight(1)
      .height(MEDIA_LIST_THUMB_HEIGHT)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
    .borderRadius(MEDIA_CARD_RADIUS)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
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
  ThumbBlock() {
    Stack({ alignContent: Alignment.Center }) {
      MediaThumb({
        imageUrl: this.task.thumbnailUrl || '',
        placeholderColor: '#1A1A1A',
        widthVp: MEDIA_LIST_THUMB_WIDTH,
        heightVp: MEDIA_LIST_THUMB_HEIGHT,
        borderRadiusVp: MEDIA_THUMB_RADIUS
      })

      if (this.task.status === DownloadStatus.COMPLETED) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(16)
          .fontColor([this.themePrimary])
          .position({ x: 6, y: 6 })
      } else if (this.task.status === DownloadStatus.FAILED) {
        SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
          .fontSize(16)
          .fontColor(['#FF4444'])
          .position({ x: 6, y: 6 })
      }
    }
    .width(MEDIA_LIST_THUMB_WIDTH)
    .height(MEDIA_LIST_THUMB_HEIGHT)
    .margin({ right: MEDIA_LIST_THUMB_GAP })
    .clip(true)
    .borderRadius(MEDIA_THUMB_RADIUS)
  }

  @Builder
  ActionCapsule() {
    if (isActiveStatus(this.task.status)) {
      // 下载中：胶囊进度条，点击取消
      Progress({
        value: this.getProgressValue(),
        total: 100,
        type: ProgressType.Capsule
      })
        .width(ACTION_BTN_WIDTH)
        .height(ACTION_BTN_HEIGHT)
        .color(this.themePrimary)
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .style({
          content: `${this.getProgressValue()}%`,
          font: { size: 10, weight: FontWeight.Medium },
          fontColor: this.getProgressValue() >= 45
            ? Color.White
            : $r('app.color.yourtube_text_primary'),
          enableSmoothEffect: true,
          showDefaultPercentage: false
        })
        .onClick(() => {
          this.downloadManager.cancelTask(this.task.id);
        })
    } else if (this.task.status === DownloadStatus.COMPLETED) {
      Button($r('app.string.yt_download_status_completed'))
        .fontSize(10)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .backgroundColor(this.themePrimary)
        .height(ACTION_BTN_HEIGHT)
        .constraintSize({ minWidth: ACTION_BTN_WIDTH })
        .padding({ left: 10, right: 10 })
        .onClick(() => {
          this.exportTaskToDownloads();
        })
    } else {
      // 失败 / 已取消：删除
      Button($r('app.string.yt_action_delete'))
        .fontSize(10)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .backgroundColor(this.task.status === DownloadStatus.FAILED
          ? '#FF4444'
          : $r('app.color.yourtube_button_disabled'))
        .height(ACTION_BTN_HEIGHT)
        .constraintSize({ minWidth: ACTION_BTN_WIDTH })
        .padding({ left: 10, right: 10 })
        .onClick(() => {
          this.downloadManager.deleteTask(this.task.id);
        })
    }
  }

  private getProgressValue(): number {
    if (this.task.status === DownloadStatus.COMPLETED) {
      return 100;
    }
    if (this.task.status === DownloadStatus.PENDING) {
      return 0;
    }
    return Math.max(0, Math.min(100, this.task.progress || 0));
  }

  private getSubtitle(): ResourceStr {
    if (this.task.status === DownloadStatus.FAILED) {
      return this.task.errorMessage || $r('app.string.yt_download_status_failed');
    }
    if (this.task.status === DownloadStatus.COMPLETED) {
      return $r('app.string.yt_download_status_completed');
    }
    if (this.task.status === DownloadStatus.CANCELLED) {
      return $r('app.string.yt_download_status_cancelled');
    }
    return '';
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
