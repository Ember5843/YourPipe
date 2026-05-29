import { VideoItem } from 'youtube_core';
import { PlayQueueManager, QueueSourceType, QueueChangeListener } from '../PlayQueueManager';

class PlayQueueListListener extends QueueChangeListener {
  private component: PlayQueueList;

  constructor(comp: PlayQueueList) {
    super();
    this.component = comp;
  }

  onQueueChanged(): void {
    this.component.syncStateToComponent();
  }

  onCurrentIndexChanged(index: number): void {
    this.component.currentIndex = index;
    setTimeout(() => {
      this.component.scrollToCurrent();
    }, 100);
  }
}

@Component
export struct PlayQueueList {
  @State queue: VideoItem[] = [];
  @State currentIndex: number = -1;
  @State sourceType: QueueSourceType = QueueSourceType.NONE;
  @State sourceName: string = '';
  @State isLoadingMore: boolean = false;
  @State canLoadMore: boolean = false;

  private manager: PlayQueueManager = PlayQueueManager.getInstance();
  private listScroller: Scroller = new Scroller();
  private readonly THEME_COLOR: ResourceColor = $r('app.color.yourtube_theme_primary');
  private boundListener: PlayQueueListListener | null = null;

  syncStateToComponent(): void {
    this.queue = this.manager.queue.slice();
    this.currentIndex = this.manager.currentIndex;
    this.sourceType = this.manager.sourceType;
    this.sourceName = this.manager.sourceName;
    this.isLoadingMore = this.manager.isLoadingNextPage;
    this.canLoadMore = this.manager.hasMorePages;
  }

  scrollToCurrent(): void {
    if (this.currentIndex >= 0 && this.currentIndex < this.queue.length) {
      this.listScroller.scrollToIndex(this.currentIndex, true, ScrollAlign.CENTER);
    }
  }

  aboutToAppear(): void {
    this.syncStateToComponent();
    if (!this.boundListener) {
      this.boundListener = new PlayQueueListListener(this);
      this.manager.addListener(this.boundListener);
    }
  }

  aboutToDisappear(): void {
    if (this.boundListener) {
      this.manager.removeListener(this.boundListener);
      this.boundListener = null;
    }
  }

  private switchToVideo(_video: VideoItem, index: number): void {
    if (index === this.currentIndex) {
      return;
    }
    this.manager.moveTo(index);
  }

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

  private handleBottomReached(): void {
    if (this.isLoadingMore || !this.canLoadMore) {
      return;
    }
    this.handleLoadMore();
  }

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

  private getMetaText(item: VideoItem): string {
    const parts: string[] = [];
    if (item.author && item.author.length > 0) {
      parts.push(item.author);
    }
    if (item.viewCount && item.viewCount.length > 0) {
      parts.push(item.viewCount);
    }
    return parts.join('  ');
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

      if (this.canLoadMore) {
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

  @Builder
  LoadMoreSentinel() {
    if (this.isLoadingMore) {
      this.LoadingFooter()
    } else {
      Row()
        .width('100%')
        .height(24)
    }
  }

  @Builder
  Thumbnail(item: VideoItem) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (item.thumbnailUrl && item.thumbnailUrl.length > 0) {
        Image(item.thumbnailUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .backgroundColor(item.thumbnailColor || $r('app.color.yourtube_icon_hint'))
      } else {
        Rect()
          .width('100%')
          .height('100%')
          .fill(item.thumbnailColor || $r('app.color.yourtube_icon_hint'))
      }

      if (item.isLive) {
        Text('LIVE')
          .fontSize(9)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .backgroundColor('#D93025')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ right: 4, bottom: 4 })
      }
    }
    .width(104)
    .height(58)
    .borderRadius(4)
    .clip(true)
  }

  @Builder
  QueueRow(item: VideoItem, index: number) {
    Row() {
      if (index === this.currentIndex) {
        Column()
          .width(3)
          .height(52)
          .backgroundColor(this.THEME_COLOR)
          .borderRadius(2)
          .margin({ right: 8 })
      } else {
        Column()
          .width(3)
          .height(52)
          .margin({ right: 8 })
      }

      this.Thumbnail(item)

      Column() {
        Row() {
          Text(item.title || '')
            .fontSize(13)
            .fontColor($r('app.color.yourtube_text_primary'))
            .fontWeight(index === this.currentIndex ? FontWeight.Medium : FontWeight.Regular)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(17)
            .layoutWeight(1)

          if (index === this.currentIndex) {
            Text('NOW')
              .fontSize(9)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.THEME_COLOR)
              .borderRadius(3)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Text(this.getMetaText(item))
          .fontSize(11)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 5 })
      }
      .layoutWeight(1)
      .margin({ left: 10 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(76)
    .padding({ left: 8, right: 10, top: 8, bottom: 8 })
    .backgroundColor(index === this.currentIndex ? $r('app.color.yourtube_bg_surface') : Color.Transparent)
    .onClick(() => {
      this.switchToVideo(item, index);
    })
  }

  @Builder
  QueueListMode() {
    List({ space: 0, scroller: this.listScroller }) {
      ForEach(this.queue, (item: VideoItem, index: number) => {
        ListItem() {
          this.QueueRow(item, index)
        }
      }, (item: VideoItem, index: number) => `${item.videoId}_${index}`)

      if (this.isLoadingMore || this.canLoadMore) {
        ListItem() {
          this.LoadMoreSentinel()
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 8, right: 8, top: 6, bottom: 12 })
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .onScrollIndex((_firstIndex: number, lastIndex: number) => {
      if (lastIndex >= this.queue.length - 1) {
        this.handleBottomReached();
      }
    })
    .onReachEnd(() => {
      this.handleBottomReached();
    })
  }

  build() {
    Column() {
      if (this.queue.length === 0) {
        this.EmptyState()
      } else {
        this.QueueHeader()
        this.QueueListMode()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
