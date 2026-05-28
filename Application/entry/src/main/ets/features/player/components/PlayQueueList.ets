import { VideoItem } from 'youtube_core';
import { PlayQueueManager, QueueSourceType, QueueChangeListener } from '../PlayQueueManager';
import { UIConfig } from '../../../common/AppState';

/**
 * Listener that bridges PlayQueueManager → PlayQueueList component state.
 * Named class required by ArkTS (no inline object literals).
 */
class PlayQueueListListener extends QueueChangeListener {
  private component: PlayQueueList;
  constructor(comp: PlayQueueList) {
    super();
    this.component = comp;
  }
  onQueueChanged(): void {
    this.component.syncStateToComponent();
    setTimeout(() => {
      this.component.scrollToCurrent();
    }, 100);
  }
  onCurrentIndexChanged(_index: number): void {
    this.component.currentIndex = _index;
    setTimeout(() => {
      this.component.scrollToCurrent();
    }, 100);
  }
}

/**
 * Play queue list shown in PlayerPage Tab 3.
 *
 * Uses VideoCard/VideoCardGrid (same as Home/Search) and respects uiConfig.homeLayoutMode.
 * Clicking a queue item switches the video via AppStorage — does NOT go through
 * actionHub.openVideo to avoid unnecessary navPathStack operations.
 */
@Component
export struct PlayQueueList {
  @State queue: VideoItem[] = [];
  @State currentIndex: number = -1;
  @State sourceType: QueueSourceType = QueueSourceType.NONE;
  @State sourceName: string = '';
  @State isLoadingMore: boolean = false;
  @State canLoadMore: boolean = false;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;

  private manager: PlayQueueManager = PlayQueueManager.getInstance();
  private scroller: Scroller = new Scroller();
  private readonly THEME_COLOR: ResourceColor = $r('app.color.yourtube_theme_primary');
  private readonly GRID_SIDE_PADDING: number = 12;

  syncStateToComponent(): void {
    this.queue = this.manager.queue.slice();
    this.currentIndex = this.manager.currentIndex;
    this.sourceType = this.manager.sourceType;
    this.sourceName = this.manager.sourceName;
    this.isLoadingMore = this.manager.isLoadingNextPage;
    this.canLoadMore = this.manager.hasMoreRemotePages;
  }

  scrollToCurrent(): void {
    if (this.currentIndex >= 0 && this.currentIndex < this.queue.length) {
      this.scroller.scrollToIndex(this.currentIndex, true, ScrollAlign.CENTER);
    }
  }

  aboutToAppear(): void {
    this.syncStateToComponent();
    const listener: PlayQueueListListener = new PlayQueueListListener(this);
    this.manager.addListener(listener);
  }

  /** Switch to a different video in the queue */
  private switchToVideo(_video: VideoItem, index: number): void {
    if (index === this.currentIndex) {
      return;
    }
    // moveTo fires PlayQueueManager.onSwitchVideo → PlayerPage reloads
    this.manager.moveTo(index);

    // PipePipe-style auto-play: when reaching the last item, append a related video
    if (index >= this.manager.queue.length - 1) {
      this.manager.appendAutoQueueNext();
    }
  }

  /** Load more for remote playlists */
  private async handleLoadMore(): Promise<void> {
    if (this.isLoadingMore || !this.canLoadMore) {
      return;
    }
    this.isLoadingMore = true;
    try {
      await this.manager.loadMore();
    } finally {
      this.syncStateToComponent();
    }
  }

  /** Responsive grid column count (same logic as PlaylistDetailPage) */
  private getGridColumnCount(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : 360;
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - this.GRID_SIDE_PADDING * 2);
    if (contentWidth >= 1440) return 5;
    if (contentWidth >= 1080) return 4;
    if (contentWidth >= 760) return 3;
    if (contentWidth >= 520) return 2;
    return 1;
  }

  /** Header text */
  private getHeaderText(): string | Resource {
    if (this.sourceType === QueueSourceType.REMOTE) {
      return this.sourceName || $r('app.string.yt_tab_playlists');
    }
    if (this.sourceType === QueueSourceType.LOCAL) {
      return this.sourceName || 'Local Playlist';
    }
    if (this.queue.length <= 1) {
      return 'Current Video';
    }
    return `${this.queue.length} videos in queue`;
  }

  @Builder
  QueueHeader() {
    Row() {
      Text(this.getHeaderText())
        .fontSize(13)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      if (this.sourceType === QueueSourceType.REMOTE && this.canLoadMore) {
        Text(`${this.queue.length}+`)
          .fontSize(11)
          .fontColor($r('app.color.yourtube_text_quaternary'))
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 6 })
    .backgroundColor($r('app.color.yourtube_bg_surface'))
  }

  @Builder
  EmptyState() {
    Column() {
      SymbolGlyph($r('sys.symbol.list_bullet'))
        .fontSize(36)
        .fontColor([$r('app.color.yourtube_text_hint')])
        .margin({ bottom: 8 })
      Text($r('app.string.yt_empty_no_content'))
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_hint'))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 40 })
  }

  @Builder
  LoadingFooter() {
    Row() {
      LoadingProgress()
        .color(this.THEME_COLOR)
        .width(22)
        .height(22)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 12 })
  }

  /** Compact queue item row — tighter than full VideoCard */
  @Builder
  QueueItemRow(item: VideoItem, index: number) {
    Row() {
      // Current-item highlight bar
      if (index === this.currentIndex) {
        Row()
          .width(3)
          .height('100%')
          .backgroundColor(this.THEME_COLOR)
          .position({ x: 0, y: 0 })
          .zIndex(5)
      }

      // Thumbnail
      if (item.thumbnailUrl) {
        Image(item.thumbnailUrl)
          .width(80)
          .height(45)
          .objectFit(ImageFit.Cover)
          .borderRadius(4)
          .backgroundColor(item.thumbnailColor || $r('app.color.yourtube_icon_hint'))
      } else {
        Rect()
          .width(80)
          .height(45)
          .fill(item.thumbnailColor || $r('app.color.yourtube_icon_hint'))
          .radius(4)
      }

      // Info
      Column() {
        Text(item.title || '')
          .fontSize(13)
          .fontColor(index === this.currentIndex ? this.THEME_COLOR : $r('app.color.yourtube_text_primary'))
          .fontWeight(index === this.currentIndex ? FontWeight.Medium : FontWeight.Normal)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)

        Row() {
          if (item.author) {
            Text(item.author)
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 140 })
          }
          if (item.isLive) {
            Text(' · LIVE')
              .fontSize(10)
              .fontColor(Color.Red)
              .fontWeight(FontWeight.Bold)
          }
        }
        .margin({ top: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 10 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Top)
    .backgroundColor(index === this.currentIndex
      ? $r('app.color.yourtube_bg_surface')
      : Color.Transparent)
    .onClick(() => {
      this.switchToVideo(item, index);
    })
  }

  /** List-mode: compact queue items, scrolls when overflow */
  @Builder
  QueueListMode() {
    Scroll(this.scroller) {
      Column() {
        ForEach(this.queue, (item: VideoItem, index: number) => {
          this.QueueItemRow(item, index)
        }, (item: VideoItem, index: number) => item.videoId + '_r' + index)

        if (this.isLoadingMore) {
          this.LoadingFooter()
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .onReachEnd(() => {
      if (!this.isLoadingMore && this.canLoadMore) {
        this.handleLoadMore();
      }
    })
  }

  /** Grid-mode: compact queue items in a responsive grid */
  @Builder
  QueueGridMode() {
    Scroll(this.scroller) {
      Column() {
        GridRow({
          columns: this.getGridColumnCount(),
          gutter: { x: 4, y: 4 }
        }) {
          ForEach(this.queue, (item: VideoItem, index: number) => {
            GridCol({ span: 1 }) {
              this.QueueItemRow(item, index)
            }
          }, (item: VideoItem, index: number) => item.videoId + '_g' + index)
        }
        .width('100%')

        if (this.isLoadingMore) {
          this.LoadingFooter()
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 10 })
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .onReachEnd(() => {
      if (!this.isLoadingMore && this.canLoadMore) {
        this.handleLoadMore();
      }
    })
  }

  build() {
    Column() {
      if (this.queue.length === 0) {
        this.EmptyState()
      } else {
        this.QueueHeader()

        if (this.uiConfig.homeLayoutMode === 'grid') {
          this.QueueGridMode()
        } else {
          this.QueueListMode()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
