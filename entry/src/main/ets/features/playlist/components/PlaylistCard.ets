import { SearchPlaylistItem } from 'youtube_core';
import { ActionHub } from '../../../common/ActionHub';
import { PlaylistItem } from '../../../common/PlaylistModel';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { customVibrator } from '../../../common/VibratorUtil';
import { UIConfig } from '../../../common/AppState';
import { Callback } from '@ohos.base';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { MediaThumb } from '../../../common/components/MediaThumb';
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
} from '../../../common/components/MediaCardTokens';
import { resolveResourceStr } from '../../../common/utils/ResourceStrUtil';

interface ContextMenuItem {
  symbolStartIcon?: SymbolGlyphModifier;
  content: ResourceStr;
  contentColor?: ResourceColor;
  callback: Callback<void>;
}

const SYMBOL_FONT_SIZE: number = 16;

@Component
export struct PlaylistCard {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop playlist: SearchPlaylistItem;
  @Prop typeLabel: ResourceStr = $r('app.string.yt_tab_playlists');
  @Prop enableOpen: boolean = true;
  @Prop forceActionLabel: ResourceStr = '';
  @StorageLink('playlists') playlists: PlaylistItem[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @State isShowContextMenu: boolean = false;

  private getPlaylistId(): string {
    return (this.playlist.playlistId || '').trim();
  }

  /** 本地播放列表的 id 带 local_ 前缀，与联机播放列表区分。 */
  private isLocal(): boolean {
    return this.getPlaylistId().startsWith('local_');
  }

  private isFavorited(): boolean {
    const playlistId = this.getPlaylistId();
    if (!playlistId) {
      return false;
    }
    return this.playlists.some((item: PlaylistItem) => item.playlistId === playlistId);
  }

  private getActionLabel(): ResourceStr {
    if (this.isLocal()) {
      return $r('app.string.yt_action_delete');
    }
    if (typeof this.forceActionLabel === 'string' && this.forceActionLabel.length > 0) {
      return this.forceActionLabel;
    }
    return this.isFavorited() ? $r('app.string.yt_action_unfavorite') : $r('app.string.yt_action_favorite');
  }

  private handleAction(): void {
    const playlistId = this.getPlaylistId();
    if (!playlistId) {
      return;
    }
    if (this.isLocal()) {
      this.actionHub.deleteLocalQueue(playlistId);
      return;
    }
    if (this.isFavorited()) {
      this.actionHub.removePlaylist(playlistId);
    } else {
      this.actionHub.addPlaylist(this.playlist);
    }
  }

  private getContextMenus(): ContextMenuItem[] {
    const items: ContextMenuItem[] = [];
    if (this.isLocal()) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_delete'),
        callback: () => {
          const playlistId = this.getPlaylistId();
          if (playlistId) {
            this.actionHub.deleteLocalQueue(playlistId);
          }
        }
      });
      return items;
    }
    if (this.isFavorited()) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.heart_fill'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_unfavorite'),
        callback: () => {
          const playlistId = this.getPlaylistId();
          if (playlistId) {
            this.actionHub.removePlaylist(playlistId);
          }
        }
      });
    } else {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.heart'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_favorite'),
        callback: () => {
          this.actionHub.addPlaylist(this.playlist);
        }
      });
    }
    items.push({
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.share'))
        .fontSize(SYMBOL_FONT_SIZE)
        .fontColor([$r('sys.color.font_primary')]),
      content: $r('app.string.yt_action_share'),
      callback: () => {
        this.actionHub.sharePlaylist(this.playlist);
      }
    });
    return items;
  }

  @Builder
  contextMenuBuilder() {
    Scroll() {
      Column() {
        // 信息区（与视频卡菜单同范式）：名称 / 上传者·视频数 / 简介
        Column() {
          Text(this.playlist.name || 'Untitled')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.yourtube_text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          if ((this.playlist.uploaderName && this.playlist.uploaderName.length > 0)
            || (this.playlist.videoCountText && this.playlist.videoCountText.length > 0)) {
            Text([
              this.playlist.uploaderName || '',
              this.playlist.videoCountText || ''
            ].filter((s: string) => s.length > 0).join(' · '))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 4 })
          }

          if (this.playlist.description && this.playlist.description.length > 0) {
            Text(this.playlist.description)
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 2 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })

        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.comp_divider'))

        Menu() {
          ForEach(this.getContextMenus(), (item: ContextMenuItem) => {
            MenuItem({
              symbolStartIcon: item.symbolStartIcon,
              content: item.content
            })
              .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
              .contentFontColor(item.contentColor ?? $r('sys.color.font_primary'))
              .onClick(() => {
                item.callback();
              });
          });
        }
        .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
        .width('100%')
        .height('auto')
      }
      .backgroundColor($r('app.color.yourtube_bg_surface'))
      .borderRadius(MEDIA_CARD_RADIUS)
      .clip(true)
      // 与视频卡菜单统一 220vp（原 180vp）
      .width(220)
    }
    .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .edgeEffect(EdgeEffect.Spring);
  }

  private getTypeLabelText(): string {
    // Resource 形式的标签（如搜索页传入的 $r）需解析成字符串，否则角标为空
    return resolveResourceStr(this.typeLabel);
  }

  build() {
    Row() {
      MediaThumb({
        imageUrl: this.playlist.coverUrl || '',
        placeholderColor: this.playlist.thumbnailColor || '',
        widthVp: MEDIA_LIST_THUMB_WIDTH,
        heightVp: MEDIA_LIST_THUMB_HEIGHT,
        borderRadiusVp: MEDIA_THUMB_RADIUS,
        typeLabel: this.getTypeLabelText()
      })
        .margin({ right: MEDIA_LIST_THUMB_GAP });

      Column() {
        Text(this.playlist.name || 'Untitled')
          .fontSize(MEDIA_TITLE_SIZE)
          .fontColor($r('app.color.yourtube_text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 2 });

        Row() {
          if (this.playlist.uploaderName && this.playlist.uploaderName.length > 0) {
            Text(this.playlist.uploaderName)
              .fontSize(MEDIA_META_SIZE)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '60%' });
          }
          if (this.playlist.videoCountText && this.playlist.videoCountText.length > 0) {
            Text(this.playlist.uploaderName && this.playlist.uploaderName.length > 0
              ? ` · ${this.playlist.videoCountText}`
              : this.playlist.videoCountText)
              .fontSize(MEDIA_META_SIZE)
              .fontColor($r('app.color.yourtube_text_hint'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        if (this.playlist.description && this.playlist.description.length > 0) {
          Text(this.playlist.description)
            .fontSize(10)
            .fontColor($r('app.color.yourtube_text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(14)
            .margin({ top: 4 });
        }

        Blank();
        Row() {
          Button(this.getActionLabel())
            .fontSize(12)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .backgroundColor(this.isFavorited() ? $r('app.color.yourtube_button_disabled') : this.themePrimary)
            .height(28)
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.handleAction();
            });
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ bottom: 2 });
      }
      .layoutWeight(1)
      .height(MEDIA_LIST_THUMB_HEIGHT)
      .alignItems(HorizontalAlign.Start);
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
    .bindContextMenu(this.isShowContextMenu, this.contextMenuBuilder, {
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
    .onClick(() => {
      if (this.enableOpen) {
        this.actionHub.openPlaylist(this.playlist);
      }
    })
    .gesture(LongPressGesture()
      .onAction(() => {
        this.isShowContextMenu = true;
      }));
  }
}
