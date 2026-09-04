import { ActionHub } from '../../common/ActionHub';
import { VideoItem } from 'youtube_core';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { customVibrator } from '../../common/VibratorUtil';
import { UIConfig } from '../AppState';
import { curves } from '@kit.ArkUI';
import { MediaThumb } from './MediaThumb';
import { VideoItemContextMenu } from './VideoItemContextMenu';
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

const ACTION_BTN_HEIGHT: number = 28;
const ACTION_BTN_RESERVE: number = 28;

/**
 * Shared video content shell.
 * layoutMode: 'list' = horizontal row (meta stacked: title / author / viewCount),
 * 'grid' = vertical card (title + meta 行：作者 · 统计，action button 在行右端)。
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

  @Builder
  contextMenuBuilder() {
    // 菜单内容统一由共享组件渲染（信息区 + 标准项 + 下载）；宿主管 anchor 与 preview 选项。
    VideoItemContextMenu({
      video: this.video
    })
  }

  @Builder
  ThumbBlockGrid() {
    // 通栏图：自身不带圆角，由卡片根的 borderRadius+clip 裁出圆角
    MediaThumb({
      imageUrl: this.video.thumbnailUrl || '',
      placeholderColor: this.video.thumbnailColor || '',
      thumbId: 'thumb_' + this.video.id,
      fillParent: true,
      useAspectRatio: true,
      borderRadiusVp: 0,
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

  /** grid meta 行的作者段（showAuthor 关闭或缺失时为空）。 */
  private gridMetaAuthor(): string {
    return this.showAuthor && this.video.author ? this.video.author : '';
  }

  /**
   * grid 统计槽内容：播放数优先，缺失时回退发布时间/时长
   * （收藏页等 showViewCount=false 的表面用其补位，避免只剩按钮）。
   */
  private gridMetaStat(): string {
    if (this.showViewCount && this.video.viewCount && this.video.viewCount.length > 0) {
      return this.video.viewCount;
    }
    if (this.video.publishedTimeText && this.video.publishedTimeText.length > 0) {
      return this.video.publishedTimeText;
    }
    return this.video.durationText || '';
  }

  /** meta 行是否有任何文本内容（作者段或统计段）。 */
  private bottomMetaRowHasContent(): boolean {
    return this.gridMetaAuthor().length > 0 || this.gridMetaStat().length > 0;
  }

  @Builder
  MetaBlockGrid() {
    // 上下分布卡片的底部信息栏：标题(≤2行) / meta 行[作者 · 统计 + 按钮]。
    // 作者段与统计段（播放数→发布时间→时长，首个可用）有数据即渲染；
    // 超宽由省略号截断，全量信息走长按菜单。
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

      if (this.bottomMetaRowHasContent() || this.hasActionButton()) {
        Row({ space: 8 }) {
          if (this.bottomMetaRowHasContent()) {
            Text() {
              if (this.gridMetaAuthor().length > 0) {
                Span(this.gridMetaAuthor())
                  .fontColor($r('app.color.yourtube_text_quaternary'))
              }
              if (this.gridMetaAuthor().length > 0 && this.gridMetaStat().length > 0) {
                Span(' · ')
                  .fontColor($r('app.color.yourtube_text_hint'))
              }
              if (this.gridMetaStat().length > 0) {
                Span(this.gridMetaStat())
                  .fontColor($r('app.color.yourtube_text_hint'))
              }
            }
            .fontSize(MEDIA_META_SIZE)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          } else {
            Blank().layoutWeight(1)
          }
          if (this.hasActionButton()) {
            this.ActionButton()
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 10, bottom: 8 })
  }

  build() {
    if (this.isGrid()) {
      Column() {
        this.ThumbBlockGrid()
        this.MetaBlockGrid()
      }
      .width('100%')
      .borderRadius(MEDIA_CARD_RADIUS)
      // clip 让顶部通栏图服从卡片圆角（ThumbBlockGrid 的图自身圆角已归零）
      .clip(true)
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
