import { SearchPlaylistItem } from 'youtube_core';
import { ActionHub } from '../../../common/ActionHub';
import { PlaylistItem } from '../../../common/PlaylistModel';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { customVibrator } from '../../../common/VibratorUtil';
import { UIConfig } from '../../../common/AppState';
import { Callback } from '@ohos.base';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';

interface ContextMenuItem {
  symbolStartIcon?: SymbolGlyphModifier;
  content: ResourceStr;
  contentColor?: ResourceColor;
  callback: Callback<void>;
}

const SYMBOL_FONT_SIZE: number = 16;

@Component
export struct PlaylistCard {
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
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.star_fill'))
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
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.star'))
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
      .backgroundColor($r('app.color.yourtube_bg_surface'))
      .borderRadius(12)
      .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
      .width(180)
      .height('auto')
      //.transition(customAnimationUtil.isMenuTransition(this.uiConfig));
    }
    .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .edgeEffect(EdgeEffect.Spring);
  }

  build() {
    Row() {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.playlist.coverUrl && this.playlist.coverUrl.length > 0) {
          Image(this.playlist.coverUrl)
            .width(160)
            .height(90)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
            .backgroundColor(this.playlist.thumbnailColor || $r('app.color.yourtube_icon_hint'));
        } else {
          Rect()
            .width(160)
            .height(90)
            .fill(this.playlist.thumbnailColor || $r('app.color.yourtube_icon_hint'))
            .radius(6);
        }

        if (typeof this.typeLabel === 'string' && this.typeLabel.length > 0) {
          Text(this.typeLabel)
            .fontSize(8)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .backgroundColor($r('app.color.yourtube_bg_tag'))
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .borderRadius({ topLeft: 6, bottomRight: 6 });
        }
      }
      .width(160)
      .height(90)
      .margin({ right: 12 });

      Column() {
        Text(this.playlist.name || 'Untitled')
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 2 });

        Row() {
          if (this.playlist.uploaderName && this.playlist.uploaderName.length > 0) {
            Text(this.playlist.uploaderName)
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '60%' });
          }
          if (this.playlist.videoCountText && this.playlist.videoCountText.length > 0) {
            Text(this.playlist.uploaderName && this.playlist.uploaderName.length > 0
              ? ` · ${this.playlist.videoCountText}`
              : this.playlist.videoCountText)
              .fontSize(11)
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
            .fontSize(10)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .backgroundColor(this.isFavorited() ? $r('app.color.yourtube_button_disabled') : $r('app.color.yourtube_theme_primary'))
            .height(24)
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
      .height(90)
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
    .borderRadius(12)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .shadow({ radius: 4, color: $r('app.color.yourtube_shadow'), offsetX: 0, offsetY: 2 })
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
