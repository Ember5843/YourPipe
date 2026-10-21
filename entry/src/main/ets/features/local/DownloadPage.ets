import { DownloadManager, DownloadTask, DownloadStatus } from '../../common/DownloadManager';
import { StreamInfo, PlayerModel } from 'mediaservice';
import { YouTubePlayService } from '../player/YouTubePlayService';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { MediaThumb } from '../../common/components/MediaThumb';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { VideoItem } from 'youtube_core';
import { ActionHub } from '../../common/ActionHub';
import { AppLog } from '../../common/AppLog';
import { LocalMediaItem, LocalMediaStore } from '../../common/LocalMediaStore';
import { LocalMediaRow } from './LocalMediaRow';
import { PlayQueueSourceHint } from '../player/PlayQueueManager';
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

const logger = AppLog.getInstance('DownloadPage');

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

interface RetryStreams {
  video: StreamInfo | undefined;
  audio: StreamInfo | null;
}

/**
 * 重试时挑选要用的流：优先选回原来的 itag（分辨率 / 音轨不变），
 * 取不到就退回该分类里最佳的一条。SABR 的直链同样按 itag 选，
 * 重新提取带来的新鲜 sabrInfo 会替换掉过期的 bootstrap。
 */
function pickRetryStreams(streams: StreamInfo[], task: DownloadTask): RetryStreams {
  const categories = PlayerModel.classifyForDownload(streams);
  const wantVideoItag = task.videoStream?.itag;
  const wantAudioItag = task.audioStream?.itag;
  let video: StreamInfo | undefined;
  if (wantVideoItag !== undefined) {
    video = categories.video.find((s: StreamInfo) => s.itag === wantVideoItag)
      || categories.progressive.find((s: StreamInfo) => s.itag === wantVideoItag)
      || categories.hlsManifest.find((s: StreamInfo) => s.itag === wantVideoItag);
  }
  if (!video) {
    video = categories.progressive[0] || categories.video[0] || categories.hlsManifest[0];
  }
  let audio: StreamInfo | null = null;
  if (wantAudioItag !== undefined) {
    audio = categories.audio.find((s: StreamInfo) => s.itag === wantAudioItag) || null;
  }
  if (!audio && task.audioStream) {
    audio = categories.audio[0] || null;
  }
  return { video: video, audio: audio };
}

@Component
export struct DownloadPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('downloadTasks') tasks: DownloadTask[] = [];
  @StorageLink('localMedia') localItems: LocalMediaItem[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub;
  @State importing: boolean = false;

  /** 本地导入文件 → 播放队列（与下载库分开的 localFiles 来源）。 */
  private playLocal(item: LocalMediaItem): void {
    const all: VideoItem[] = [];
    let startIndex = 0;
    this.localItems.forEach((entry: LocalMediaItem) => {
      if (entry.id === item.id) {
        startIndex = all.length;
      }
      all.push(LocalMediaStore.toVideoItem(entry));
    });
    if (all.length === 0) {
      return;
    }
    const hint: PlayQueueSourceHint = {
      type: 'localFiles',
      playlistId: 'local_files',
      playlistName: 'local_files',
      loadedItems: all,
      startIndex
    };
    logger.info(`play local index=${startIndex}/${all.length}`);
    this.actionHub.openVideo(all[startIndex], hint, false);
  }

  private async importFiles(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const filePicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 10;
      options.fileSuffixFilters = ['.mp4', '.m4v', '.mkv', '.webm', '.mov', '.ts', '.flv', '.avi'];
      const uris = await filePicker.select(options);
      if (!uris || uris.length === 0) {
        return;
      }
      const result = await LocalMediaStore.importFromUris(uris);
      if (result.added > 0) {
        const message = context.resourceManager.getStringSync(
          $r('app.string.yt_local_import_success').id, result.added);
        this.getUIContext().getPromptAction().showToast({ message, duration: 2000 });
      } else {
        this.getUIContext().getPromptAction().showToast({
          message: $r('app.string.yt_local_import_failed'),
          duration: 2000
        });
      }
    } catch (e) {
      logger.error(`import picker failed: ${(e as Error).message || e}`);
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.yt_local_import_failed'),
        duration: 2000
      });
    } finally {
      this.importing = false;
    }
  }

  private confirmDeleteLocal(item: LocalMediaItem): void {
    AlertDialog.show({
      title: $r('app.string.yt_local_delete_title'),
      message: $r('app.string.yt_local_delete_message'),
      primaryButton: {
        value: $r('app.string.yt_action_delete'),
        fontColor: this.themePrimary,
        action: () => {
          LocalMediaStore.delete(item);
        }
      },
      secondaryButton: {
        value: $r('app.string.yt_action_cancel'),
        action: () => {}
      }
    });
  }

  @Builder
  ImportHeader() {
    Row() {
      Text($r('app.string.yt_local_files_hint'))
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_hint'))
        .layoutWeight(1)
      Button(this.importing ? $r('app.string.yt_local_importing') : $r('app.string.yt_local_import'))
        .fontSize(13)
        .height(34)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.themePrimary)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .enabled(!this.importing)
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => { this.importFiles(); })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 4, right: 4, top: 8, bottom: 4 })
  }

  @Builder
  SectionTitle(title: ResourceStr, count: number) {
    Row() {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.yourtube_text_secondary'))
      Text(`${count}`)
        .fontSize(11)
        .fontColor($r('app.color.yourtube_text_hint'))
        .margin({ left: 6 })
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 14, bottom: 4 })
  }

  build() {
    if (this.tasks.length === 0 && this.localItems.length === 0) {
      Column() {
        SymbolGlyph($r('sys.symbol.download_fill'))
          .fontSize(48)
          .fontColor([$r('app.color.yourtube_text_hint')])
          .margin({ bottom: 12 })
        Text($r('app.string.yt_local_empty_media'))
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_secondary'))
        Text($r('app.string.yt_local_empty_media_hint'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_hint'))
          .margin({ top: 4 })
        Button(this.importing ? $r('app.string.yt_local_importing') : $r('app.string.yt_local_import'))
          .fontSize(13)
          .height(34)
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.themePrimary)
          .fontColor($r('app.color.yourtube_text_inverse'))
          .enabled(!this.importing)
          .margin({ top: 16 })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .onClick(() => { this.importFiles(); })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ bottom: 60 })
    } else {
      List({ space: 4 }) {
        ListItem() {
          this.ImportHeader()
        }

        if (this.tasks.length > 0) {
          ListItem() {
            this.SectionTitle($r('app.string.yt_download_title'), this.tasks.length)
          }
          ForEach(this.tasks, (task: DownloadTask) => {
            ListItem() {
              DownloadTaskRow({ task: task })
            }
            .transition(customAnimationUtil.isScaleTran(task.id, this.uiConfig))
          }, (task: DownloadTask) => task.id)
        }

        if (this.localItems.length > 0) {
          ListItem() {
            this.SectionTitle($r('app.string.yt_local_files'), this.localItems.length)
          }
          ForEach(this.localItems, (item: LocalMediaItem) => {
            ListItem() {
              LocalMediaRow({
                item,
                themePrimary: this.themePrimary,
                onOpen: (it: LocalMediaItem) => { this.playLocal(it); },
                onDelete: (it: LocalMediaItem) => { this.confirmDeleteLocal(it); }
              })
            }
          }, (item: LocalMediaItem) => item.id)
        }
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
  @Consume('actionHub') actionHub: ActionHub;
  @ObjectLink task: DownloadTask;
  private downloadManager: DownloadManager = DownloadManager.getInstance();
  @State exporting: boolean = false;
  @State isShowContextMenu: boolean = false;
  @State retrying: boolean = false;
  @State resuming: boolean = false;

  /** 任务行 → 视频语义（channelId 未入库，"查看作者"项会自动隐藏）。 */
  private toVideoItem(): VideoItem {
    const item = new VideoItem(
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
    // 菜单里的「仅音频播放」等动作要落在本地文件上，而不是再去线上提取一遍。
    if (this.task.outputPath) {
      item.localMediaPath = this.task.outputPath;
    }
    return item;
  }

  /** 扫盘回收的条目没有 YouTube id：收藏 / 分享这类线上动作不适用。 */
  private hasYouTubeId(): boolean {
    const id = (this.task.videoId || '').trim();
    return id.length > 0 && !id.startsWith('local:');
  }

  /**
   * 任务特有项：进行中 / 已暂停 = 停止并删除（暂停/继续走主操作按钮，
   * 破坏性动作只留在长按菜单里）；已完成 = 导出 + 删除。
   */
  private buildTaskMenuExtras(): VideoMenuExtraItem[] {
    const items: VideoMenuExtraItem[] = [];
    if (isActiveStatus(this.task.status) || this.task.status === DownloadStatus.PAUSED) {
      const stopItem: VideoMenuExtraItem = {
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.xmark_circle'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_download_stop_delete'),
        contentColor: this.themePrimary,
        callback: () => {
          // 停止 = 取消在飞请求 + 删除条目与分片文件（分片留着只会占空间）。
          this.downloadManager.deleteTask(this.task.id);
          this.isShowContextMenu = false;
        }
      };
      items.push(stopItem);
    } else {
      if (this.task.status === DownloadStatus.COMPLETED) {
        const exportItem: VideoMenuExtraItem = {
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.arrowshape_down_to_line_fill'))
            .fontSize(16)
            .fontColor([$r('sys.color.font_primary')]),
          content: $r('app.string.yt_download_export'),
          callback: () => {
            this.isShowContextMenu = false;
            this.exportTaskToDownloads();
          }
        };
        items.push(exportItem);
      }
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
      showFavorite: this.hasYouTubeId(),
      showShare: this.hasYouTubeId(),
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
        this.playTask();
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
          // 主操作 = 暂停（可继续，分片保留 → 继续时从断点接着下）。
          // 停止/删除只在长按菜单里。
          this.downloadManager.pauseTask(this.task.id);
        })
    } else if (this.task.status === DownloadStatus.PAUSED) {
      // 已暂停：主操作 = 继续（重新提取新鲜流 → 从断点接着下）。
      Button(this.resuming ? $r('app.string.yt_download_resuming') : $r('app.string.yt_download_resume'))
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .backgroundColor(this.resuming
          ? $r('app.color.yourtube_button_disabled')
          : this.themePrimary)
        .height(ACTION_BTN_HEIGHT)
        .padding({ left: 10, right: 10 })
        .enabled(!this.resuming)
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.resumePausedTask();
        })
    } else if (this.task.status === DownloadStatus.COMPLETED) {
      // 主操作 = 应用内播放；导出降为长按菜单里的次操作。
      Button($r('app.string.yt_local_play'))
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .backgroundColor(this.themePrimary)
        .height(ACTION_BTN_HEIGHT)
        .padding({ left: 10, right: 10 })
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.playTask();
        })
    } else if (this.task.status === DownloadStatus.FAILED) {
      // 失败任务：主操作 = 重试（重新提取新鲜流后再入队），删除降为长按菜单。
      Button(this.retrying ? $r('app.string.yt_download_retrying') : $r('app.string.yt_action_retry'))
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .backgroundColor(this.retrying
          ? $r('app.color.yourtube_button_disabled')
          : $r('app.color.yourtube_error'))
        .height(ACTION_BTN_HEIGHT)
        .padding({ left: 10, right: 10 })
        .enabled(!this.retrying)
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.retryFailedTask();
        })
    } else {
      Button($r('app.string.yt_action_delete'))
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .backgroundColor($r('app.color.yourtube_button_disabled'))
        .height(ACTION_BTN_HEIGHT)
        .padding({ left: 10, right: 10 })
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.downloadManager.deleteTask(this.task.id);
        })
    }
  }

  /**
   * 重试失败任务：先重新提取一次拿到**新鲜**的流地址（googlevideo 直链带
   * `expire`，SABR bootstrap 的流地址也很短命），再把任务放回队列。
   * 分辨率优先选回原来的 itag，取不到就退回最佳可用流。
   */
  private async retryFailedTask(): Promise<void> {
    if (this.retrying) {
      return;
    }
    const task = this.task;
    if (task.status !== DownloadStatus.FAILED) {
      return;
    }
    this.retrying = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const result = await YouTubePlayService.getInstance(ctx).extractForDownload(task.videoId);
      if (!result.success || !result.playerStreams || result.playerStreams.length === 0) {
        this.showRetryFailed();
        return;
      }
      const picked = pickRetryStreams(result.playerStreams, task);
      if (!picked.video) {
        this.showRetryFailed();
        return;
      }
      if (!this.downloadManager.retryTask(task.id, picked.video, picked.audio)) {
        this.showRetryFailed();
        return;
      }
      logger.info(`retry queued video=${task.videoId} itag=${picked.video.itag}`);
    } catch (e) {
      logger.warn(`retry exception video=${task.videoId}: ${(e as Error).message || e}`);
      this.showRetryFailed();
    } finally {
      this.retrying = false;
    }
  }

  private showRetryFailed(): void {
    this.getUIContext().getPromptAction().showToast({
      message: $r('app.string.yt_download_retry_failed'),
      duration: 2000
    });
  }

  /**
   * 继续一个暂停的任务：重新提取一次拿到**新鲜**的流地址（直链带 `expire`），
   * 再放回队列 —— 分片文件还在，DownloadManager 会从断点接着下。
   */
  private async resumePausedTask(): Promise<void> {
    if (this.resuming) {
      return;
    }
    const task = this.task;
    if (task.status !== DownloadStatus.PAUSED) {
      return;
    }
    this.resuming = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const result = await YouTubePlayService.getInstance(ctx).extractForDownload(task.videoId);
      if (!result.success || !result.playerStreams || result.playerStreams.length === 0) {
        this.showRetryFailed();
        return;
      }
      const picked = pickRetryStreams(result.playerStreams, task);
      if (!picked.video) {
        this.showRetryFailed();
        return;
      }
      if (!this.downloadManager.resumeTask(task.id, picked.video, picked.audio)) {
        this.showRetryFailed();
        return;
      }
      logger.info(`resume queued video=${task.videoId} itag=${picked.video.itag}`);
    } catch (e) {
      logger.warn(`resume exception video=${task.videoId}: ${(e as Error).message || e}`);
      this.showRetryFailed();
    } finally {
      this.resuming = false;
    }
  }

  private getProgressValue(): number {
    if (this.task.status === DownloadStatus.COMPLETED) {
      return 100;
    }
    // PENDING 也保留已有进度：刚"继续"的暂停任务在排队时不该显示 0%。
    return Math.max(0, Math.min(100, this.task.progress || 0));
  }

  private getSubtitle(): ResourceStr {
    if (this.task.status === DownloadStatus.FAILED) {
      return this.task.errorMessage || $r('app.string.yt_download_status_failed');
    }
    if (this.task.status === DownloadStatus.PAUSED) {
      return $r('app.string.yt_download_status_paused');
    }
    if (this.task.status === DownloadStatus.COMPLETED) {
      return $r('app.string.yt_download_status_completed');
    }
    if (this.task.status === DownloadStatus.CANCELLED) {
      return $r('app.string.yt_download_status_cancelled');
    }
    return '';
  }

  /** 已下载条目 → 可播放 VideoItem（独立 videoId 兼作续播键，路径直交 MPV）。 */
  private static toLocalVideoItem(task: DownloadTask, path: string): VideoItem {
    const item = new VideoItem(
      0,
      `local:${task.id}`,
      task.title,
      task.author,
      '',
      task.thumbnailUrl,
      false,
      '#1A1A1A',
      '',
      '',
      ''
    );
    item.localMediaPath = path;
    return item;
  }

  /**
   * 主操作：在应用内直接播放已下载的文件（沙箱路径交给 MPV，不经过代理）。
   * 整份下载库一起入队、点击项为起点 —— 打开「自动连播」后会顺着列表放下去。
   */
  private playTask(): void {
    if (this.task.status !== DownloadStatus.COMPLETED || !this.task.outputPath) {
      return;
    }
    let exists = true;
    try {
      exists = fs.accessSync(this.task.outputPath);
    } catch (_e) {
      exists = false;
    }
    if (!exists) {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.yt_local_file_missing'),
        duration: 2000
      });
      return;
    }
    const all = AppStorage.get<DownloadTask[]>('downloadTasks') ?? [];
    const items: VideoItem[] = [];
    let startIndex = 0;
    all.forEach((task: DownloadTask) => {
      if (task.status !== DownloadStatus.COMPLETED || !task.outputPath) {
        return;
      }
      let playable = true;
      try {
        playable = fs.accessSync(task.outputPath);
      } catch (_e) {
        playable = false;
      }
      if (!playable) {
        return;
      }
      if (task.id === this.task.id) {
        startIndex = items.length;
      }
      items.push(DownloadTaskRow.toLocalVideoItem(task, task.outputPath));
    });
    if (items.length === 0) {
      items.push(DownloadTaskRow.toLocalVideoItem(this.task, this.task.outputPath));
      startIndex = 0;
    }
    const hint: PlayQueueSourceHint = {
      type: 'downloads',
      playlistId: 'downloads',
      playlistName: 'downloads',
      loadedItems: items,
      startIndex
    };
    logger.info(`DownloadPage play start index=${startIndex}/${items.length}`);
    this.actionHub.openVideo(items[startIndex], hint, false);
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
    if (this.task.status === DownloadStatus.PAUSED) {
      return $r('app.color.yourtube_text_hint');
    }
    if (this.task.status === DownloadStatus.COMPLETED || isActiveStatus(this.task.status)) {
      return this.themePrimary;
    }
    return $r('app.color.yourtube_text_hint');
  }
}
