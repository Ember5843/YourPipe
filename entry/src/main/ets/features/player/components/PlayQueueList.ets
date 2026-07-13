import { VideoItem } from 'youtube_core';
import { PlayQueueManager, QueueSourceType, QueueChangeListener } from '../PlayQueueManager';
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
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @State queue: VideoItem[] = [];
  @State currentIndex: number = -1;
  @State sourceType: QueueSourceType = QueueSourceType.NONE;
  @State sourceName: string = '';
  @State isLoadingMore: boolean = false;
  @State canLoadMore: boolean = false;
  @StorageLink('autoPlayQueue') autoPlayEnabled: boolean = true;

  private manager: PlayQueueManager = PlayQueueManager.getInstance();
  private listScroller: Scroller = new Scroller();
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
          .margin({ right: 10 })
      }

      Row() {
        Text('自动播放')
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_secondary'))
        Toggle({ type: ToggleType.Switch, isOn: this.autoPlayEnabled })
          .selectedColor(this.themePrimary)
          .scale({ x: 0.8, y: 0.8 })
          .margin({ left: 6 })
          .onChange((isOn: boolean) => {
            this.autoPlayEnabled = isOn;
            AppStorage.setOrCreate('autoPlayQueue', isOn);
          })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 6 })
    .backgroundColor($r('app.color.yourtube_bg_surface'))
  }

  @Builder
  EmptyState() {
    Column() {
      SymbolGlyph($r('sys.symbol.list_bullet_square'))
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
        .color(this.themePrimary)
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
  Thumbnail(item: VideoItem, isPlaying: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      MediaThumb({
        imageUrl: item.thumbnailUrl || '',
        placeholderColor: item.thumbnailColor || '',
        widthVp: MEDIA_LIST_THUMB_WIDTH,
        heightVp: MEDIA_LIST_THUMB_HEIGHT,
        borderRadiusVp: MEDIA_THUMB_RADIUS,
        showLive: true,
        isLive: item.isLive
      })

      if (isPlaying) {
        Column() {
          SymbolGlyph($r('sys.symbol.waveform'))
            .fontSize(20)
            .fontColor([Color.White])
        }
        .width(MEDIA_LIST_THUMB_WIDTH)
        .height(MEDIA_LIST_THUMB_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('rgba(0,0,0,0.4)')
        .borderRadius(MEDIA_THUMB_RADIUS)
      }
    }
    .width(MEDIA_LIST_THUMB_WIDTH)
    .height(MEDIA_LIST_THUMB_HEIGHT)
  }

  @Builder
  QueueRow(item: VideoItem, index: number) {
    Row() {
      this.Thumbnail(item, index === this.currentIndex)

      Column() {
        Text(item.title || '')
          .fontSize(MEDIA_TITLE_SIZE)
          .fontColor(index === this.currentIndex
            ? this.themePrimary
            : $r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
          .width('100%')
          .margin({ bottom: 2 })

        if (item.author && item.author.length > 0) {
          Text(item.author)
            .fontSize(MEDIA_META_SIZE)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ bottom: 2 })
        }

        if (item.viewCount && item.viewCount.length > 0) {
          Text(item.viewCount)
            .fontSize(MEDIA_META_SIZE)
            .fontColor($r('app.color.yourtube_text_hint'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: MEDIA_LIST_THUMB_HEIGHT })
      .alignItems(HorizontalAlign.Start)
      .margin({ left: MEDIA_LIST_THUMB_GAP })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
    .borderRadius(MEDIA_CARD_RADIUS)
    .backgroundColor(index === this.currentIndex
      ? $r('app.color.yourtube_bg_surface_muted')
      : $r('app.color.yourtube_bg_surface'))
    .shadow({
      radius: MEDIA_CARD_SHADOW_RADIUS,
      color: $r('app.color.yourtube_shadow'),
      offsetX: 0,
      offsetY: MEDIA_CARD_SHADOW_OFFSET_Y
    })
    .onClick(() => {
      this.switchToVideo(item, index);
    })
  }

  @Builder
  QueueListMode() {
    List({ space: 4, scroller: this.listScroller }) {
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
    .padding({ left: 10, right: 10, top: 6, bottom: 12 })
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
