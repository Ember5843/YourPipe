import { DownloadManager, DownloadTask, DownloadStatus } from '../../common/DownloadManager';
import { fileUri, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { MediaThumb } from '../../common/components/MediaThumb';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { VideoItem } from 'youtube_core';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { customVibrator } from '../../common/VibratorUtil';
import { VideoItemContextMenu, VideoMenuExtraItem } from '../../common/components/VideoItemContextMenu';
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

/** Match VideoMediaCard list action geometry. */
const ACTION_BTN_HEIGHT: number = 28;
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
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
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
      // LocalPage 外层 Scroll 先消费上滑（Tab 栏跟随上移），到顶后列表自身再滚
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    }
  }
}

@Component
struct DownloadTaskRow {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @ObjectLink task: DownloadTask;
  private downloadManager: DownloadManager = DownloadManager.getInstance();
  @State exporting: boolean = false;
  @State isShowContextMenu: boolean = false;

  /** 任务行 → 视频语义（channelId 未入库，"查看作者"项会自动隐藏）。 */
  private toVideoItem(): VideoItem {
    return new VideoItem(
      0,
      this.task.videoId,
      this.task.title,
      this.task.author,
      '',
      this.task.thumbnailUrl,
      false,
      '#1A1A1A',
      '',
      '',
      ''
    );
  }

  /** 任务特有项：进行中 = 取消任务；其它 = 删除任务（主题色强调）。 */
  private buildTaskMenuExtras(): VideoMenuExtraItem[] {
    const items: VideoMenuExtraItem[] = [];
    if (isActiveStatus(this.task.status)) {
      const cancelItem: VideoMenuExtraItem = {
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.xmark_circle'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_cancel'),
        callback: () => {
          this.downloadManager.cancelTask(this.task.id);
          this.isShowContextMenu = false;
        }
      };
      items.push(cancelItem);
    } else {
      const deleteItem: VideoMenuExtraItem = {
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_delete'),
        contentColor: this.themePrimary,
        callback: () => {
          this.downloadManager.deleteTask(this.task.id);
          this.isShowContextMenu = false;
        }
      };
      items.push(deleteItem);
    }
    return items;
  }

  @Builder
  taskMenuBuilder() {
    // 任务行复用视频统一菜单；任务本身即下载产物，关闭"下载"项
    VideoItemContextMenu({
      video: this.toVideoItem(),
      showDownload: false,
      extraItems: this.buildTaskMenuExtras()
    })
  }

  build() {
    // Layout mirrors VideoMediaCard list: thumb | meta stack (title/author/status) + action bottom-end.
    Row() {
      this.ThumbBlock()

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

          // Third meta line = status (same slot as viewCount on VideoCard).
          // Active downloads keep this empty; progress lives in the action capsule.
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
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .onClick(() => {
      if (this.task.status === DownloadStatus.COMPLETED) {
        this.exportTaskToDownloads();
      }
    })
    .bindContextMenu(this.isShowContextMenu, this.taskMenuBuilder, {
      preview: MenuPreviewMode.IMAGE,
      previewAnimationOptions: { scale: [1.0, 1.1] },
      placement: Placement.BottomRight,
      aboutToAppear: () => {
        if (this.uiConfig.isVibrate) {
          customVibrator.vibratorTriggerOfHapticClockTimer();
        }
      },
      aboutToDisappear: () => {
        this.isShowContextMenu = false;
      }
    })
    .gesture(LongPressGesture()
      .onAction(() => {
        this.isShowContextMenu = true;
      }))
  }

  @Builder
  ThumbBlock() {
    // Same MediaThumb geometry as VideoMediaCard list thumbs.
    Stack({ alignContent: Alignment.TopStart }) {
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
          .margin({ left: 6, top: 6 })
      } else if (this.task.status === DownloadStatus.FAILED) {
        SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
          .fontSize(16)
          .fontColor([$r('app.color.yourtube_error')])
          .margin({ left: 6, top: 6 })
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
          font: { size: 12, weight: FontWeight.Medium },
          fontColor: this.getProgressValue() >= 45
            ? Color.White
            : $r('app.color.yourtube_text_primary'),
          enableSmoothEffect: true,
          showDefaultPercentage: false
        })
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.downloadManager.cancelTask(this.task.id);
        })
    } else if (this.task.status === DownloadStatus.COMPLETED) {
      // Same action button tokens as VideoMediaCard.ActionButton
      Button($r('app.string.yt_download_status_completed'))
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .backgroundColor(this.themePrimary)
        .height(ACTION_BTN_HEIGHT)
        .padding({ left: 10, right: 10 })
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.exportTaskToDownloads();
        })
    } else {
      Button($r('app.string.yt_action_delete'))
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .backgroundColor(this.task.status === DownloadStatus.FAILED
          ? $r('app.color.yourtube_error')
          : $r('app.color.yourtube_button_disabled'))
        .height(ACTION_BTN_HEIGHT)
        .padding({ left: 10, right: 10 })
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
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
      return $r('app.color.yourtube_error');
    }
    if (this.task.status === DownloadStatus.COMPLETED || isActiveStatus(this.task.status)) {
      return this.themePrimary;
    }
    return $r('app.color.yourtube_text_hint');
  }
}
