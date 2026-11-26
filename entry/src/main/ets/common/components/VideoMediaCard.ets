import { ActionHub } from '../../common/ActionHub';
import { VideoItem } from 'youtube_core';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { UIConfig } from '../AppState';
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

const MORE_BTN_SIZE: number = 28;

/**
 * Shared video content shell.
 * layoutMode: 'list' = horizontal row (title + top-right more button / author / meta),
 * 'grid' = vertical card (title + top-right more button / full-width author · meta).
 */
@Reusable
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
  @StorageProp('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @State isShowContextMenu: boolean = false;

  aboutToReuse(_params: Record<string, Object>): void {
    this.isShowContextMenu = false;
  }

  private isGrid(): boolean {
    return this.layoutMode === 'grid';
  }

  private getTypeLabelText(): string {
    // Resource 形式的标签（如搜索页传入的 $r）需解析成字符串，否则角标为空
    return resolveResourceStr(this.typeLabel);
  }

  /** AiSList 角标：block=红，warn=橙；未命中返回空串。 */
  private aiBadgeText(): string {
    if (this.video.aiListFlag.length === 0) {
      return '';
    }
    try {
      return getContext().resourceManager.getStringSync($r('app.string.yt_exp_ai_badge').id);
    } catch (_e) {
      return 'AI';
    }
  }

  private aiBadgeColor(): string {
    return this.video.aiListFlag === 'warn' ? '#F59E0B' : '#E53935';
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
    // 菜单内容统一由共享组件渲染（大图标指标区 + 快捷栏 + 标准项）；宿主管毛玻璃与触觉选项。
    VideoItemContextMenu({
      video: this.video,
      onClose: () => {
        this.isShowContextMenu = false;
      }
    })
  }

  @Builder
  MoreMenuButton() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor([$r('sys.color.icon_primary')])
    }
    .width(MORE_BTN_SIZE)
    .height(MORE_BTN_SIZE)
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
      typeLabel: this.getTypeLabelText(),
      fallbackImageUrl: this.video.originalThumbnailUrl || '',
      cornerLabel: this.aiBadgeText(),
      cornerLabelColor: this.aiBadgeColor()
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
      typeLabel: this.getTypeLabelText(),
      fallbackImageUrl: this.video.originalThumbnailUrl || '',
      cornerLabel: this.aiBadgeText(),
      cornerLabelColor: this.aiBadgeColor()
    })
      .margin({ right: MEDIA_LIST_THUMB_GAP })
  }

  /** Title (full width) / bottom row: [author + meta] + bottom-right circular '+' button. */
  @Builder
  MetaBlockList() {
    Column() {
      Text(this.video.title)
        .fontSize(MEDIA_TITLE_SIZE)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 4 })

      Blank()

      Row({ space: 8 }) {
        Column({ space: 2 }) {
          if (this.showAuthor && this.video.author && this.video.author.length > 0) {
            Text(this.video.author)
              .fontSize(MEDIA_META_SIZE)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }

          if (this.showViewCount && this.listMetaText().length > 0) {
            Text(this.listMetaText())
              .fontSize(MEDIA_META_SIZE)
              .fontColor($r('sys.color.font_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.MoreMenuButton()
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .layoutWeight(1)
    .height(MEDIA_LIST_THUMB_HEIGHT)
    .alignItems(HorizontalAlign.Start)
  }

  /** grid meta 行的作者段（showAuthor 关闭或缺失时为空）。 */
  private gridMetaAuthor(): string {
    return this.showAuthor && this.video.author ? this.video.author : '';
  }

  /**
   * 列表模式第三行：播放量 · 发布时间。
   * 列表模式原先只显示播放量（网格模式才有日期兜底），这里补上发布时间。
   */
  private listMetaText(): string {
    const parts: string[] = [];
    if (this.video.viewCount && this.video.viewCount.length > 0) {
      parts.push(this.video.viewCount);
    }
    if (this.video.publishedTimeText && this.video.publishedTimeText.length > 0) {
      parts.push(this.video.publishedTimeText);
    }
    return parts.join(' · ');
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
    // 上下分布卡片的信息栏：通宽标题(≤2行) / 底部 meta 行[作者 · 统计 + 右下纯圆 '+' 按钮]。
    Column() {
      Text(this.video.title)
        .fontSize(MEDIA_TITLE_SIZE)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      Row({ space: 8 }) {
        if (this.bottomMetaRowHasContent()) {
          Text() {
            if (this.gridMetaAuthor().length > 0) {
              Span(this.gridMetaAuthor())
                .fontColor($r('sys.color.font_secondary'))
            }
            if (this.gridMetaAuthor().length > 0 && this.gridMetaStat().length > 0) {
              Span(' · ')
                .fontColor($r('sys.color.font_tertiary'))
            }
            if (this.gridMetaStat().length > 0) {
              Span(this.gridMetaStat())
                .fontColor($r('sys.color.font_tertiary'))
            }
          }
          .fontSize(MEDIA_META_SIZE)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        } else {
          Blank().layoutWeight(1)
        }

        this.MoreMenuButton()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
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
      .padding({ left: 10, right: 6, top: 8, bottom: 8 })
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
        this.handleOpen();
      })
      .gesture(LongPressGesture()
        .onAction(() => {
          this.isShowContextMenu = true;
        }))
    }
  }
}
