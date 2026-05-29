import { ActionHub } from '../../common/ActionHub';
import { VideoItem } from 'youtube_core';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { customVibrator } from '../../common/VibratorUtil';
import { UIConfig } from '../AppState';
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
export struct VideoCard {
  @Prop video: VideoItem;
  @Prop actionLabel: ResourceStr = '';
  @Prop actionType: string = '';
  @Prop enableOpen: boolean = true;
  @Prop typeLabel: ResourceStr = '';
  @Prop showAuthor: boolean = true;
  @Prop showViewCount: boolean = true;
  @Prop showLiveTag: boolean = true;
  @Prop useFavoriteToggle: boolean = false;
  onOpenVideo?: (video: VideoItem) => void;
  @StorageLink('favorites') favorites: VideoItem[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @State isShowContextMenu: boolean = false;

  private getThumbWidth(): number {
    return 160;
  }

  private getThumbHeight(): number {
    return 90;
  }

  private getVideoId(): string {
    return (this.video.videoId || '').trim();
  }

  private isFavorited(): boolean {
    const videoId = this.getVideoId();
    if (!videoId) {
      return false;
    }
    return this.favorites.some((item: VideoItem) => item.videoId === videoId);
  }

  private getActionLabel(): ResourceStr {
    if (this.useFavoriteToggle) {
      return this.isFavorited() ? $r('app.string.yt_action_unfavorite') : $r('app.string.yt_action_favorite');
    }
    return this.actionLabel;
  }

  private getActionColor(): ResourceColor {
    if (this.useFavoriteToggle) {
      return this.isFavorited() ? $r('app.color.yourtube_button_disabled') : $r('app.color.yourtube_theme_primary');
    }
    return this.actionType === 'remove' ? $r('app.color.yourtube_button_disabled') : $r('app.color.yourtube_theme_primary');
  }

  private handleAction(): void {
    if (this.useFavoriteToggle) {
      const videoId = this.getVideoId();
      if (!videoId) {
        return;
      }
      if (this.isFavorited()) {
        this.actionHub.removeFavorite(videoId);
      } else {
        this.actionHub.addFavorite(this.video);
      }
      return;
    }
    if (this.actionType === 'favorite') {
      this.actionHub.addFavorite(this.video);
    } else if (this.actionType === 'remove') {
      const targetId = this.video.videoId || this.video.id.toString();
      this.actionHub.removeFavorite(targetId);
    }
  }

  private handleOpen(): void {
    if (!this.enableOpen) {
      return;
    }
    if (this.onOpenVideo) {
      this.onOpenVideo(this.video);
      return;
    }
    this.actionHub.openVideo(this.video);
  }

  private getContextMenus(): ContextMenuItem[] {
    const items: ContextMenuItem[] = [];
    if (this.isFavorited()) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.star_fill'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_unfavorite'),
        callback: () => {
          const videoId = this.getVideoId();
          if (videoId) {
            this.actionHub.removeFavorite(videoId);
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
          this.actionHub.addFavorite(this.video);
        }
      });
    }
    const channelId = (this.video.channelId || '').trim();
    if (channelId.length > 0) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.person'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_view_author'),
        callback: () => {
          this.actionHub.openChannelById(channelId, this.video.author || '', this.video.channelAvatarUrl || '', this.video.channelHandle || '');
        }
      });
    }
    items.push({
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.share'))
        .fontSize(SYMBOL_FONT_SIZE)
        .fontColor([$r('sys.color.font_primary')]),
      content: $r('app.string.yt_action_share'),
      callback: () => {
        this.actionHub.shareVideo(this.video);
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
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.video.thumbnailUrl && this.video.thumbnailUrl.length > 0) {
          Image(this.video.thumbnailUrl)
            .id('thumb_' + this.video.id)
            .width(this.getThumbWidth())
            .height(this.getThumbHeight())
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
            .backgroundColor(this.video.thumbnailColor || $r('app.color.yourtube_icon_hint'));
        } else {
          Rect()
            .width(this.getThumbWidth())
            .height(this.getThumbHeight())
            .fill(this.video.thumbnailColor || $r('app.color.yourtube_icon_hint'))
            .radius(6);
        }

        if (this.showLiveTag && this.video.isLive) {
          Text($r('app.string.yt_label_live'))
            .fontSize(8)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .backgroundColor($r('app.color.yourtube_bg_live_tag'))
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .borderRadius({ topLeft: 4, bottomRight: 6 });
        }

        if (typeof this.typeLabel === 'string' && this.typeLabel.length > 0) {
          Text(this.typeLabel)
            .fontSize(8)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .backgroundColor($r('app.color.yourtube_bg_tag'))
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .borderRadius({ topLeft: 6, bottomRight: 6 })
            .position({ x: 0, y: 0 });
        }
      }
      .width(this.getThumbWidth())
      .height(this.getThumbHeight())
      .margin({ right: 12 });

      Column() {
        Text(this.video.title)
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 2 });

        Row() {
          if (this.showAuthor) {
            Text(this.video.author)
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '60%' });
          }

          if (this.showViewCount && this.video.viewCount) {
            Text(`${this.showAuthor ? ' · ' : ''}${this.video.viewCount}`)
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_hint'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        if (this.useFavoriteToggle || (typeof this.actionLabel === 'string' && this.actionLabel.length > 0)) {
          Blank();
          Row() {
            Button(this.getActionLabel())
              .fontSize(10)
              .fontColor($r('app.color.yourtube_text_inverse'))
              .backgroundColor(this.getActionColor())
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
      }
      .layoutWeight(1)
      .height(this.getThumbHeight())
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
      this.handleOpen();
    })
    .gesture(LongPressGesture()
      .onAction(() => {
        this.isShowContextMenu = true;
      }));
  }
}
