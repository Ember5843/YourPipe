import { ActionHub } from '../../common/ActionHub';
import { VideoItem } from 'youtube_core';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { customVibrator } from '../../common/VibratorUtil';
import { UIConfig } from '../AppState';
import { Callback } from '@ohos.base';
import { curves, LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { MediaThumb } from './MediaThumb';
import { resolveResourceStr } from '../utils/ResourceStrUtil';
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
} from './MediaCardTokens';

interface ContextMenuItem {
  symbolStartIcon?: SymbolGlyphModifier;
  content: ResourceStr;
  contentColor?: ResourceColor;
  callback: Callback<void>;
}

const SYMBOL_FONT_SIZE: number = 16;
const ACTION_BTN_HEIGHT: number = 28;
const ACTION_BTN_RESERVE: number = 28;

/**
 * Shared video content shell.
 * layoutMode: 'list' = horizontal row, 'grid' = vertical card.
 * Meta is fixed stacked: title / author / viewCount.
 * Action button pins bottom-end of the meta area (not under text flow).
 */
@Component
export struct VideoMediaCard {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
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
  @State actionScale: number = 1;

  private isGrid(): boolean {
    return this.layoutMode === 'grid';
  }

  private getVideoId(): string {
    return (this.video.videoId || '').trim();
  }

  private getTypeLabelText(): string {
    // Resource 形式的标签（如搜索页传入的 $r）需解析成字符串，否则角标为空
    return resolveResourceStr(this.typeLabel);
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

  private playActionToggleAnim(): void {
    if (!this.uiConfig.isAnimation) {
      this.actionScale = 1;
      return;
    }
    // Press-in then spring back so favorite / unfavorite feels responsive.
    this.actionScale = 0.86;
    const duration = Math.max(160, Math.min(this.uiConfig.animationSpeed || 220, 260));
    this.getUIContext().animateTo({
      duration: duration,
      curve: curves.springMotion(0.32, 0.78)
    }, () => {
      this.actionScale = 1;
    });
  }

  private handleAction(): void {
    if (this.useFavoriteToggle) {
      const videoId = this.getVideoId();
      if (!videoId) {
        return;
      }
      this.playActionToggleAnim();
      if (this.isFavorited()) {
        this.actionHub.removeFavorite(videoId);
      } else {
        this.actionHub.addFavorite(this.video);
      }
      return;
    }
    if (this.actionType === 'favorite' || this.actionType === 'remove') {
      this.playActionToggleAnim();
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
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.earphone'))
        .fontSize(SYMBOL_FONT_SIZE)
        .fontColor([$r('sys.color.font_primary')]),
      content: $r('app.string.yt_action_audio_only_play'),
      callback: () => {
        this.actionHub.openVideo(this.video, undefined, true);
      }
    });
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
      Column() {
        // 条目信息区（不可点击）：标题/作者(+认证)/播放数(精确优先)/发布时间/时长/视频ID/标记。
        if (this.hasContextMenuInfo()) {
          Column() {
            Text(this.video.title)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.yourtube_text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            if (this.video.author && this.video.author.length > 0) {
              Row({ space: 4 }) {
                Text(this.video.author)
                  .fontSize(12)
                  .fontColor($r('app.color.yourtube_text_quaternary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .flexShrink(1)
                if (this.video.uploaderVerified) {
                  SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                    .fontSize(12)
                    .fontColor([$r('app.color.yourtube_text_quaternary')])
                }
              }
              .width('100%')
              .margin({ top: 4 })
            }

            if (this.getDisplayViewCount().length > 0) {
              Text(this.getDisplayViewCount())
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }
            if (this.getPublishTimeText().length > 0) {
              Text(this.getPublishTimeText())
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }
            if (this.video.durationText && this.video.durationText.length > 0) {
              Text(this.video.durationText)
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .width('100%')
                .margin({ top: 2 })
            }
            if (this.getVideoId().length > 0) {
              Text(`ID: ${this.getVideoId()}`)
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }

            if (this.hasTypeBadges()) {
              Row({ space: 6 }) {
                if (this.video.isLive) {
                  this.InfoBadge($r('app.string.yt_label_live'))
                }
                if (this.video.isPremium) {
                  this.InfoBadge($r('app.string.yt_label_premium'))
                }
                if (this.video.requiresMembership) {
                  this.InfoBadge($r('app.string.yt_label_members_only'))
                }
              }
              .width('100%')
              .margin({ top: 6 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })

          Divider()
            .strokeWidth(0.5)
            .color($r('sys.color.comp_divider'))
        }

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
      .width(220)
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
      borderRadiusVp: MEDIA_THUMB_RADIUS,
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
      widthVp: MEDIA_LIST_THUMB_WIDTH,
      heightVp: MEDIA_LIST_THUMB_HEIGHT,
      borderRadiusVp: MEDIA_THUMB_RADIUS,
      showLive: this.showLiveTag,
      isLive: this.video.isLive,
      isPremium: this.video.isPremium,
      requiresMembership: this.video.requiresMembership,
      typeLabel: this.getTypeLabelText()
    })
      .margin({ right: MEDIA_LIST_THUMB_GAP })
  }

  /** 发布时间（有则非空）。仅在长按菜单信息区展示，卡片 meta 行保持只显示播放次数。 */
  private getPublishTimeText(): string {
    return this.video.publishedTimeText || '';
  }

  /** 长按菜单信息区是否有可显示内容。 */
  private hasContextMenuInfo(): boolean {
    return (this.video.title && this.video.title.length > 0)
      || (this.video.author && this.video.author.length > 0)
      || this.getDisplayViewCount().length > 0
      || this.getPublishTimeText().length > 0
      || (this.video.durationText && this.video.durationText.length > 0)
      || this.getVideoId().length > 0;
  }

  /** 播放数展示：精确文本（accessibilityLabel / RSS）优先，其次缩写文本。 */
  private getDisplayViewCount(): string {
    if (this.video.viewCountExact && this.video.viewCountExact.length > 0) {
      return this.video.viewCountExact;
    }
    return this.video.viewCount || '';
  }

  private hasTypeBadges(): boolean {
    return this.video.isLive || this.video.isPremium || this.video.requiresMembership;
  }

  /** 信息区小标记 chip（直播/付费/会员）。 */
  @Builder
  InfoBadge(label: Resource) {
    Text(label)
      .fontSize(10)
      .fontColor(this.themePrimary)
      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
      .border({ width: 1, color: this.themePrimary, radius: 4 })
  }

  /** Title / author / viewCount stacked — shared by list and grid. */
  @Builder
  MetaTextStack() {
    Column() {
      Text(this.video.title)
        .fontSize(MEDIA_TITLE_SIZE)
        .fontColor($r('app.color.yourtube_text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 2 })

      if (this.showAuthor && this.video.author && this.video.author.length > 0) {
        Text(this.video.author)
          .fontSize(MEDIA_META_SIZE)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ bottom: 2 })
      }

      if (this.showViewCount && this.video.viewCount && this.video.viewCount.length > 0) {
        Text(this.video.viewCount)
          .fontSize(MEDIA_META_SIZE)
          .fontColor($r('app.color.yourtube_text_hint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ActionButton() {
    Button(this.getActionLabel())
      .fontSize(12)
      .fontColor($r('app.color.yourtube_text_inverse'))
      .backgroundColor(this.getActionColor())
      .height(ACTION_BTN_HEIGHT)
      .padding({ left: 10, right: 10 })
      .scale({ x: this.actionScale, y: this.actionScale })
      .animation(this.uiConfig.isAnimation
        ? { duration: 180, curve: curves.springMotion(0.32, 0.78) }
        : { duration: 0 })
      .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
      .onClick(() => {
        this.handleAction();
      })
  }

  @Builder
  MetaBlockList() {
    // Fixed height matches thumb so action stays bottom-end, independent of text lines.
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.MetaTextStack()
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
      .padding({ bottom: this.hasActionButton() ? ACTION_BTN_RESERVE : 0 })

      if (this.hasActionButton()) {
        this.ActionButton()
      }
    }
    .layoutWeight(1)
    .height(MEDIA_LIST_THUMB_HEIGHT)
  }

  @Builder
  MetaBlockGrid() {
    // Reserve bottom strip for action so it does not sit mid-flow under text.
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.MetaTextStack()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        top: 8,
        left: 4,
        right: 4,
        bottom: this.hasActionButton() ? ACTION_BTN_RESERVE : 4
      })

      if (this.hasActionButton()) {
        Row() {
          this.ActionButton()
        }
        .padding({ right: 4 })
      }
    }
    .width('100%')
  }

  build() {
    if (this.isGrid()) {
      Column() {
        this.ThumbBlockGrid()
        this.MetaBlockGrid()
      }
      .width('100%')
      .padding(8)
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
        this.handleOpen();
      })
      .gesture(LongPressGesture()
        .onAction(() => {
          this.isShowContextMenu = true;
        }))
    }
  }
}
