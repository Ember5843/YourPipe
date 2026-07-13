import { ActionHub } from '../../common/ActionHub';
import { VideoItem } from 'youtube_core';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { customVibrator } from '../../common/VibratorUtil';
import { UIConfig } from '../AppState';
import { Callback } from '@ohos.base';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { MediaThumb } from './MediaThumb';

interface ContextMenuItem {
  symbolStartIcon?: SymbolGlyphModifier;
  content: ResourceStr;
  contentColor?: ResourceColor;
  callback: Callback<void>;
}

const SYMBOL_FONT_SIZE: number = 16;
const LIST_THUMB_WIDTH: number = 160;
const LIST_THUMB_HEIGHT: number = 90;

/**
 * Shared video content shell.
 * layoutMode: 'list' = horizontal row, 'grid' = vertical card.
 */
@Component
export struct VideoMediaCard {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @Prop video: VideoItem;
  /** 'list' | 'grid' */
  @Prop layoutMode: string = 'list';
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

  private isGrid(): boolean {
    return this.layoutMode === 'grid';
  }

  private getVideoId(): string {
    return (this.video.videoId || '').trim();
  }

  private getTypeLabelText(): string {
    if (typeof this.typeLabel === 'string') {
      return this.typeLabel;
    }
    return '';
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
      return this.isFavorited() ? $r('app.color.yourtube_button_disabled') : this.themePrimary;
    }
    return this.actionType === 'remove' ? $r('app.color.yourtube_button_disabled') : this.themePrimary;
  }

  private hasActionButton(): boolean {
    return this.useFavoriteToggle || (typeof this.actionLabel === 'string' && this.actionLabel.length > 0);
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
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.heart_fill'))
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
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.heart'))
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
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_view_author'),
        callback: () => {
          this.actionHub.openChannelById(
            channelId,
            this.video.author || '',
            this.video.channelAvatarUrl || '',
            this.video.channelHandle || ''
          );
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
    }
    .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .edgeEffect(EdgeEffect.Spring);
  }

  @Builder
  ThumbBlockGrid() {
    MediaThumb({
      imageUrl: this.video.thumbnailUrl || '',
      placeholderColor: this.video.thumbnailColor || '',
      thumbId: 'thumb_' + this.video.id,
      fillParent: true,
      useAspectRatio: true,
      borderRadiusVp: 11,
      showLive: this.showLiveTag,
      isLive: this.video.isLive,
      isPremium: this.video.isPremium,
      requiresMembership: this.video.requiresMembership,
      typeLabel: this.getTypeLabelText()
    })
  }

  @Builder
  ThumbBlockList() {
    MediaThumb({
      imageUrl: this.video.thumbnailUrl || '',
      placeholderColor: this.video.thumbnailColor || '',
      thumbId: 'thumb_' + this.video.id,
      widthVp: LIST_THUMB_WIDTH,
      heightVp: LIST_THUMB_HEIGHT,
      borderRadiusVp: 6,
      showLive: this.showLiveTag,
      isLive: this.video.isLive,
      isPremium: this.video.isPremium,
      requiresMembership: this.video.requiresMembership,
      typeLabel: this.getTypeLabelText()
    })
      .margin({ right: 12 })
  }

  @Builder
  MetaBlockList() {
    Column() {
      Text(this.video.title)
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(18)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 2 })

      Row() {
        if (this.showAuthor) {
          Text(this.video.author)
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
        }

        if (this.showViewCount && this.video.viewCount) {
          Text(`${this.showAuthor ? ' · ' : ''}${this.video.viewCount}`)
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_hint'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.hasActionButton()) {
        Blank()
        Row() {
          Button(this.getActionLabel())
            .fontSize(10)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .backgroundColor(this.getActionColor())
            .height(24)
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.handleAction();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ bottom: 2 })
      }
    }
    .layoutWeight(1)
    .height(LIST_THUMB_HEIGHT)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MetaBlockGrid() {
    Column() {
      Text(this.video.title)
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(18)
        .fontWeight(FontWeight.Medium)

      Row() {
        if (this.showAuthor) {
          Text(this.video.author)
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
        }

        if (this.showViewCount && this.video.viewCount) {
          Text(`${this.showAuthor ? ' · ' : ''}${this.video.viewCount}`)
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_hint'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.hasActionButton()) {
        Row() {
          Button(this.getActionLabel())
            .fontSize(10)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .backgroundColor(this.getActionColor())
            .height(24)
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.handleAction();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8, left: 4, right: 4 })
  }

  build() {
    if (this.isGrid()) {
      Column() {
        this.ThumbBlockGrid()
        this.MetaBlockGrid()
      }
      .width('100%')
      .padding(8)
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
        }))
    } else {
      Row() {
        this.ThumbBlockList()
        this.MetaBlockList()
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
        }))
    }
  }
}
