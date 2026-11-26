import { SearchPlaylistItem } from 'youtube_core';
import { ActionHub } from '../../../common/ActionHub';
import { PlaylistItem } from '../../../common/PlaylistModel';
import { customAnimationUtil } from '../../../common/AnimationUtil';
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

const SYMBOL_FONT_SIZE: number = 20;
const MENU_WIDTH_VP: number = 268;
const CIRCLE_ACTION_SIZE: number = 28;

@Component
export struct PlaylistCard {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop playlist: SearchPlaylistItem;
  @Prop typeLabel: ResourceStr = $r('app.string.yt_tab_playlists');
  @Prop enableOpen: boolean = true;
  @Prop forceActionLabel: ResourceStr = '';
  @StorageLink('playlists') playlists: PlaylistItem[] = [];
  @StorageProp('uiConfig') uiConfig: UIConfig = new UIConfig();
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
          .fontColor([this.themePrimary]),
        content: $r('app.string.yt_action_delete'),
        contentColor: this.themePrimary,
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
          .fontColor([this.themePrimary]),
        content: $r('app.string.yt_action_unfavorite'),
        contentColor: this.themePrimary,
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
          .fontColor([$r('sys.color.icon_primary')]),
        content: $r('app.string.yt_action_favorite'),
        callback: () => {
          this.actionHub.addPlaylist(this.playlist);
        }
      });
    }
    items.push({
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.share'))
        .fontSize(SYMBOL_FONT_SIZE)
        .fontColor([$r('sys.color.icon_primary')]),
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
        // 信息区（与视频卡菜单同范式）：名称 / 上传者 / 大实心图标视频数 / 简介
        Column() {
          Text(this.playlist.name || 'Untitled')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(20)
            .width('100%')

          if (this.playlist.uploaderName && this.playlist.uploaderName.length > 0) {
            Text(this.playlist.uploaderName)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 4 })
          }

          if (this.playlist.videoCountText && this.playlist.videoCountText.length > 0) {
            Row({ space: 8 }) {
              Column({ space: 4 }) {
                SymbolGlyph($r('sys.symbol.play_circle_fill'))
                  .fontSize(26)
                  .fontColor([this.themePrimary])
                Text(this.playlist.videoCountText)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                  .fontFeature('"tnum" 1')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 10 })
          }

          if (this.playlist.description && this.playlist.description.length > 0) {
            Text(this.playlist.description)
              .fontSize(12)
              .fontColor($r('sys.color.font_tertiary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 8 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })

        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.comp_divider'))

        Menu() {
          ForEach(this.getContextMenus(), (item: ContextMenuItem, idx: number) => {
            MenuItem({
              symbolStartIcon: item.symbolStartIcon,
              content: item.content
            })
              .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
              .contentFont({ size: 15, weight: FontWeight.Medium })
              .contentFontColor(item.contentColor ?? $r('sys.color.font_primary'))
              .onClick(() => {
                this.isShowContextMenu = false;
                item.callback();
              });
          }, (_item: ContextMenuItem, idx: number) => `pl_menu_${idx}`);
        }
        .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
        .width('100%')
        .height('auto')
      }
      .backgroundColor(Color.Transparent)
      .borderRadius(MEDIA_CARD_RADIUS)
      .clip(true)
      .width(MENU_WIDTH_VP)
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
        Row({ space: 8 }) {
          Blank().layoutWeight(1)
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor([$r('sys.color.icon_primary')])
          }
          .width(CIRCLE_ACTION_SIZE)
          .height(CIRCLE_ACTION_SIZE)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .shadow({
            radius: 4,
            color: '#18000000',
            offsetX: 0,
            offsetY: 1
          })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .onClick(() => {
            this.isShowContextMenu = true;
          });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
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
      previewAnimationOptions: { scale: [1.0, 1.06] },
      placement: Placement.BottomRight,
      enableArrow: false,
      backgroundBlurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
      hapticFeedbackMode: this.uiConfig.isVibrate ? HapticFeedbackMode.ENABLED : HapticFeedbackMode.DISABLED,
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
