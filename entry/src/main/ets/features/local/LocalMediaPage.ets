import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { VideoItem } from 'youtube_core';
import { ActionHub } from '../../common/ActionHub';
import { AppLog } from '../../common/AppLog';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { LocalMediaItem, LocalMediaStore } from '../../common/LocalMediaStore';
import { PlayQueueSourceHint } from '../player/PlayQueueManager';
import { formatBytes } from '../../common/utils/FormatUtils';
import {
  MEDIA_CARD_RADIUS,
  MEDIA_CARD_SHADOW_OFFSET_Y,
  MEDIA_CARD_SHADOW_RADIUS,
  MEDIA_META_SIZE,
  MEDIA_TITLE_LINE_HEIGHT,
  MEDIA_TITLE_SIZE
} from '../../common/components/MediaCardTokens';

const logger = AppLog.getInstance('LocalMediaPage');

@Component
struct LocalMediaRow {
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

/**
 * 「本地 → 本地文件」：系统文件选择器导入 + 应用内播放 + 删除。
 * 与下载库完全独立：独立索引（local_media_json）、独立目录
 * （filesDir/local_media）、独立队列来源（localFiles）。
 */
@Component
export struct LocalMediaPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageProp('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('localMedia') items: LocalMediaItem[] = [];
  @Consume('actionHub') actionHub: ActionHub;
  @State importing: boolean = false;

  private play(item: LocalMediaItem): void {
    const all: VideoItem[] = [];
    let startIndex = 0;
    this.items.forEach((entry: LocalMediaItem) => {
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
      startIndex: startIndex
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
        const message = this.getUIContext().getHostContext()!
          .resourceManager.getStringSync($r('app.string.yt_local_import_success').id, result.added);
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

  private confirmDelete(item: LocalMediaItem): void {
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

  build() {
    List({ space: 8 }) {
      ListItem() {
        Column() {
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
          .padding({ left: 4, right: 4, top: 12, bottom: 4 })
        }
        .width('100%')
      }

      if (this.items.length === 0) {
        ListItem() {
          Column() {
            SymbolGlyph($r('sys.symbol.play_circle'))
              .fontSize(48)
              .fontColor([$r('app.color.yourtube_text_hint')])
              .margin({ bottom: 12 });
            Text($r('app.string.yt_local_empty_title'))
              .fontSize(14)
              .fontColor($r('app.color.yourtube_text_secondary'));
            Text($r('app.string.yt_local_empty_hint'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .margin({ top: 4 });
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .padding({ top: 60, bottom: 40 })
        }
      }

      ForEach(this.items, (item: LocalMediaItem) => {
        ListItem() {
          LocalMediaRow({
            item,
            themePrimary: this.themePrimary,
            onOpen: (it: LocalMediaItem) => { this.play(it); },
            onDelete: (it: LocalMediaItem) => { this.confirmDelete(it); }
          })
        }
      }, (item: LocalMediaItem) => item.id)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 4, right: 4 })
    .edgeEffect(EdgeEffect.Spring)
  }
}
