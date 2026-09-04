import { VideoItem } from 'youtube_core';
import { PlayQueueManager, QueueSourceType, QueueChangeListener } from '../PlayQueueManager';
import { MediaThumb } from '../../../common/components/MediaThumb';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { UIConfig } from '../../../common/AppState';
import { customVibrator } from '../../../common/VibratorUtil';
import { VideoItemContextMenu, VideoMenuExtraItem } from '../../../common/components/VideoItemContextMenu';
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

const QUEUE_MENU_SYMBOL_SIZE: number = 16;

/**
 * 队列条目行。独立 @Component：长按菜单的 bindContextMenu 需要每行自己的
 * 布尔状态，@Builder 共享 @State 会让所有行的菜单联动。
 * 菜单统一走 VideoItemContextMenu；队列语义差异：关闭"纯音频播放"
 * （点击即队列内切换，纯音频重开会丢队列上下文），追加特有项"从队列移除"。
 */
@Component
struct QueueRowItem {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop item: VideoItem;
  @Prop index: number = 0;
  /** 是否当前播放项（标题染色 + 缩略图波形遮罩）；父级 currentIndex 变化时随 @Prop 刷新。 */
  @Prop isCurrent: boolean = false;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @State isShowContextMenu: boolean = false;
  onSwitch: (index: number) => void = (_index: number) => {};
  private manager: PlayQueueManager = PlayQueueManager.getInstance();

  private buildExtraMenuItems(): VideoMenuExtraItem[] {
    const items: VideoMenuExtraItem[] = [];
    const remove: VideoMenuExtraItem = {
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.minus_circle'))
        .fontSize(QUEUE_MENU_SYMBOL_SIZE)
        .fontColor([$r('sys.color.font_primary')]),
      content: $r('app.string.yt_action_remove_from_queue'),
      contentColor: this.themePrimary,
      callback: () => {
        this.manager.removeAt(this.index);
        this.isShowContextMenu = false;
      }
    };
    items.push(remove);
    return items;
  }

  @Builder
  queueMenuBuilder() {
    VideoItemContextMenu({
      video: this.item,
      showAudioOnly: false,
      extraItems: this.buildExtraMenuItems()
    })
  }

  @Builder
  Thumbnail(item: VideoItem) {
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

      if (this.isCurrent) {
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

  build() {
    Row() {
      this.Thumbnail(this.item)

      Column() {
        Text(this.item.title || '')
          .fontSize(MEDIA_TITLE_SIZE)
          .fontColor(this.isCurrent
            ? this.themePrimary
            : $r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
          .width('100%')
          .margin({ bottom: 2 })

        if (this.item.author && this.item.author.length > 0) {
          Text(this.item.author)
            .fontSize(MEDIA_META_SIZE)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ bottom: 2 })
        }

        if (this.item.viewCount && this.item.viewCount.length > 0) {
          Text(this.item.viewCount)
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
    .backgroundColor(this.isCurrent
      ? $r('app.color.yourtube_bg_surface_muted')
      : $r('app.color.yourtube_bg_surface'))
    .shadow({
      radius: MEDIA_CARD_SHADOW_RADIUS,
      color: $r('app.color.yourtube_shadow'),
      offsetX: 0,
      offsetY: MEDIA_CARD_SHADOW_OFFSET_Y
    })
    .bindContextMenu(this.isShowContextMenu, this.queueMenuBuilder, {
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
      this.onSwitch(this.index);
    })
    .gesture(LongPressGesture()
      .onAction(() => {
        this.isShowContextMenu = true;
      }))
  }
}

@Component
export struct PlayQueueList {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
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
        Text($r('app.string.yt_label_autoplay'))
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
  QueueListMode() {
    List({ space: 4, scroller: this.listScroller }) {
      ForEach(this.queue, (item: VideoItem, index: number) => {
        ListItem() {
          QueueRowItem({
            item: item,
            index: index,
            isCurrent: index === this.currentIndex,
            onSwitch: (i: number) => {
              this.switchToVideo(item, i);
            }
          })
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
