import { VideoItem } from 'youtube_core';
import {
  PlayQueueManager,
  QueueSourceType,
  QueueChangeListener,
  QueueLoopMode
} from '../PlayQueueManager';
import { PlayerSession } from '../../../common/PlayerSession';
import { ActionHub } from '../../../common/ActionHub';
import { MediaThumb } from '../../../common/components/MediaThumb';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { UIConfig } from '../../../common/AppState';
import { customVibrator } from '../../../common/VibratorUtil';
import { customAnimationUtil } from '../../../common/AnimationUtil';
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

const QUEUE_MENU_SYMBOL_SIZE: number = 16;
const QUEUE_LIST_ITEM_SPACE_VP: number = 8;
const QUEUE_DEFAULT_ROW_HEIGHT_VP: number = MEDIA_LIST_THUMB_HEIGHT + 16;
const DRAG_EDGE_ZONE_VP: number = 56;
const DRAG_SCROLL_MIN_STEP_VP: number = 4;
const DRAG_SCROLL_MAX_STEP_VP: number = 18;
const DRAG_SCROLL_TICK_MS: number = 16;
const UNDO_BAR_DURATION_MS: number = 5000;

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
    if (this.component.isDragging) {
      return;
    }
    setTimeout(() => {
      if (!this.component.isDragging) {
        this.component.scrollToCurrent();
      }
    }, 100);
  }
}

/**
 * 队列条目行。独立 @Component：长按菜单的 bindContextMenu 需要每行自己的
 * 布尔状态，@Builder 共享 @State 会让所有行的菜单联动。
 * 菜单统一走 VideoItemContextMenu；队列语义差异：关闭"纯音频播放"和"加入队列"，
 * 保留"下一首播放"（非当前且非紧邻下一首时），追加特有项"从队列移除"。
 * 右侧拖拽手柄与左侧点击/长按区拆为同级子树，彻底消除长按菜单与拖拽排序的手势冲突。
 */
@Component
struct QueueRowItem {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop item: VideoItem;
  @Prop index: number = 0;
  /** 是否当前播放项（标题染色 + 缩略图波形遮罩）；父级 currentIndex 变化时随 @Prop 刷新。 */
  @Prop isCurrent: boolean = false;
  @Prop canPlayNext: boolean = false;
  @Prop isDraggingThis: boolean = false;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @State isShowContextMenu: boolean = false;
  onSwitch: (index: number) => void = (_index: number) => {};
  onRemove: (index: number) => void = (_index: number) => {};
  onRowDragHandleTouch: (active: boolean) => void = (_active: boolean) => {};
  onRowDragStart: (item: VideoItem, globalY: number) => void = (_item: VideoItem, _globalY: number) => {};
  onRowDragUpdate: (offsetY: number, globalY: number) => void = (_offsetY: number, _globalY: number) => {};
  onRowDragEnd: () => void = () => {};

  private buildExtraMenuItems(): VideoMenuExtraItem[] {
    const items: VideoMenuExtraItem[] = [];
    if (this.canPlayNext) {
      const playNext: VideoMenuExtraItem = {
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.play_circle'))
          .fontSize(QUEUE_MENU_SYMBOL_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_play_next'),
        callback: () => {
          this.isShowContextMenu = false;
          PlayQueueManager.getInstance().insertNext(this.item);
        }
      };
      items.push(playNext);
    }
    const remove: VideoMenuExtraItem = {
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.minus_circle'))
        .fontSize(QUEUE_MENU_SYMBOL_SIZE)
        .fontColor([$r('sys.color.font_primary')]),
      content: $r('app.string.yt_action_remove_from_queue'),
      contentColor: this.themePrimary,
      callback: () => {
        this.isShowContextMenu = false;
        this.onRemove(this.index);
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
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)
      .onClick(() => {
        if (!this.isDraggingThis) {
          this.onSwitch(this.index);
        }
      })
      .gesture(LongPressGesture()
        .onAction(() => {
          if (!this.isDraggingThis) {
            this.isShowContextMenu = true;
          }
        }))

      Column() {
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(18)
          .fontColor([this.isDraggingThis
            ? this.themePrimary
            : $r('app.color.yourtube_text_hint')])
      }
      .width(34)
      .height(MEDIA_LIST_THUMB_HEIGHT)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin({ left: 4 })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.onRowDragHandleTouch(true);
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.onRowDragHandleTouch(false);
        }
      })
      .gesture(
        PanGesture({ direction: PanDirection.Vertical, distance: 2 })
          .onActionStart((event: GestureEvent) => {
            const gy: number = event.fingerList.length > 0 ? event.fingerList[0].globalY : 0;
            this.onRowDragStart(this.item, gy);
          })
          .onActionUpdate((event: GestureEvent) => {
            const gy: number = event.fingerList.length > 0 ? event.fingerList[0].globalY : 0;
            this.onRowDragUpdate(event.offsetY, gy);
          })
          .onActionEnd(() => {
            this.onRowDragEnd();
          })
          .onActionCancel(() => {
            this.onRowDragEnd();
          })
      )
    }
    .width('100%')
    .padding({ left: 10, right: 6, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .borderRadius(MEDIA_CARD_RADIUS)
    .border(this.isDraggingThis
      ? { width: 1.5, color: this.themePrimary }
      : { width: 0, color: Color.Transparent })
    .backgroundColor(this.isCurrent
      ? $r('app.color.yourtube_bg_surface_muted')
      : $r('app.color.yourtube_bg_surface'))
    .shadow({
      radius: this.isDraggingThis ? 14 : MEDIA_CARD_SHADOW_RADIUS,
      color: $r('app.color.yourtube_shadow'),
      offsetX: 0,
      offsetY: this.isDraggingThis ? 6 : MEDIA_CARD_SHADOW_OFFSET_Y
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
  }
}

@Component
export struct PlayQueueList {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @State queue: VideoItem[] = [];
  @State currentIndex: number = -1;
  @State sourceType: QueueSourceType = QueueSourceType.NONE;
  @State sourceName: string = '';
  @State isLoadingMore: boolean = false;
  @State canLoadMore: boolean = false;
  @State totalLoadedCount: number = 0;
  @State loopMode: QueueLoopMode = 'none';
  @State isShuffled: boolean = false;
  @State isLocalFileOnly: boolean = false;
  @StorageLink('autoPlayQueue') autoPlayEnabled: boolean = true;

  // Save queue as local playlist sheet
  @State showSaveQueueSheet: boolean = false;
  @State savePlaylistName: string = '';

  // Drag-to-reorder state
  @State isDragging: boolean = false;
  @State isDragHandleActive: boolean = false;
  @State dragItemKey: string = '';
  @State dragOffsetY: number = 0;

  // Undo bar state
  @State showUndoBar: boolean = false;
  @State undoRemovedTitle: string = '';

  private manager: PlayQueueManager = PlayQueueManager.getInstance();
  private listScroller: Scroller = new Scroller();
  private boundListener: PlayQueueListListener | null = null;
  private itemKeyMap: Map<VideoItem, string> = new Map<VideoItem, string>();
  private nextItemUid: number = 1;
  private rowHeightMap: Map<string, number> = new Map<string, number>();

  private dragIndex: number = -1;
  private dragBaseOffsetY: number = 0;
  private dragScrollAccumY: number = 0;
  private lastPanOffsetY: number = 0;
  private listTopWindowY: number = 0;
  private listHeightVp: number = 0;
  private edgeScrollTimerId: number = -1;
  private edgeScrollVelocity: number = 0;

  private undoRemovedItem: VideoItem | null = null;
  private undoRemovedIndex: number = -1;
  private undoRemovedWasCurrent: boolean = false;
  private undoTimerId: number = -1;
  private lastSessionId: number = -1;

  private getItemKey(item: VideoItem): string {
    const existing = this.itemKeyMap.get(item);
    if (existing !== undefined) {
      return existing;
    }
    const created = `${item.videoId || 'item'}_${this.nextItemUid++}`;
    this.itemKeyMap.set(item, created);
    return created;
  }

  private pruneItemKeyMaps(): void {
    const liveSet: Set<VideoItem> = new Set<VideoItem>(this.queue);
    const liveKeys: Set<string> = new Set<string>();
    this.itemKeyMap.forEach((key: string, item: VideoItem) => {
      if (liveSet.has(item)) {
        liveKeys.add(key);
      } else {
        this.itemKeyMap.delete(item);
      }
    });
    this.rowHeightMap.forEach((_h: number, key: string) => {
      if (!liveKeys.has(key)) {
        this.rowHeightMap.delete(key);
      }
    });
  }

  private recordRowHeight(item: VideoItem, heightVp: number): void {
    const key = this.getItemKey(item);
    this.rowHeightMap.set(key, heightVp);
  }

  private getRowStepHeight(index: number): number {
    if (index >= 0 && index < this.queue.length) {
      const key = this.getItemKey(this.queue[index]);
      const h = this.rowHeightMap.get(key);
      if (h !== undefined && h > 20) {
        return h + QUEUE_LIST_ITEM_SPACE_VP;
      }
    }
    return QUEUE_DEFAULT_ROW_HEIGHT_VP + QUEUE_LIST_ITEM_SPACE_VP;
  }

  syncStateToComponent(): void {
    const sid = this.manager.boundSessionId;
    if (this.lastSessionId >= 0 && this.lastSessionId !== sid) {
      this.dismissUndoBar();
    }
    this.lastSessionId = sid;
    this.queue = this.manager.queue.slice();
    this.currentIndex = this.manager.currentIndex;
    this.sourceType = this.manager.sourceType;
    this.sourceName = this.manager.sourceName;
    this.isLoadingMore = this.manager.isLoadingNextPage;
    this.canLoadMore = this.manager.hasMorePages;
    this.totalLoadedCount = this.manager.totalLoadedCount;
    this.loopMode = this.manager.loopMode;
    this.isShuffled = this.manager.isShuffled;
    this.isLocalFileOnly = this.manager.isLocalFileOnlyQueue();
    if (!this.isDragging) {
      this.pruneItemKeyMaps();
    }
  }

  scrollToCurrent(): void {
    if (this.isDragging) {
      return;
    }
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
    this.stopEdgeAutoScroll();
    this.dismissUndoBar();
    this.isDragging = false;
    this.isDragHandleActive = false;
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

  private handleRemoveItem(index: number): void {
    const removed = this.manager.removeAt(index);
    if (!removed) {
      return;
    }
    this.clearUndoTimer();
    this.undoRemovedItem = removed.item;
    this.undoRemovedIndex = removed.index;
    this.undoRemovedWasCurrent = removed.wasCurrent;
    this.undoRemovedTitle = removed.item.title || '';
    this.showUndoBar = true;
    this.undoTimerId = setTimeout(() => {
      this.undoTimerId = -1;
      this.dismissUndoBar();
    }, UNDO_BAR_DURATION_MS);
  }

  private handleUndoRemove(): void {
    const item = this.undoRemovedItem;
    const idx = this.undoRemovedIndex;
    const wasCurrent = this.undoRemovedWasCurrent;
    this.dismissUndoBar();
    if (item && idx >= 0) {
      const playingId = PlayerSession.getInstance().currentVideo?.videoId || '';
      const restoreAsCurrent = wasCurrent && (playingId.length === 0 || playingId === item.videoId);
      this.manager.insertAt(idx, item, restoreAsCurrent);
    }
  }

  private clearUndoTimer(): void {
    if (this.undoTimerId >= 0) {
      clearTimeout(this.undoTimerId);
      this.undoTimerId = -1;
    }
  }

  private dismissUndoBar(): void {
    this.clearUndoTimer();
    this.showUndoBar = false;
    this.undoRemovedItem = null;
    this.undoRemovedIndex = -1;
    this.undoRemovedWasCurrent = false;
    this.undoRemovedTitle = '';
  }

  private showQueueToast(message: Resource, duration: number = 1500): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: duration });
    } catch (_e) {
      // Ignore UI context toast failure during teardown
    }
  }

  private handleCycleLoopMode(): void {
    const nextMode = this.manager.cycleLoopMode();
    if (this.uiConfig.isVibrate) {
      customVibrator.vibratorTriggerOfHapticClockTimer();
    }
    const toastMsg: Resource = nextMode === 'all'
      ? $r('app.string.yt_queue_loop_all')
      : (nextMode === 'one'
        ? $r('app.string.yt_queue_loop_one')
        : $r('app.string.yt_queue_loop_none'));
    this.showQueueToast(toastMsg, 1500);
  }

  private handleToggleShuffle(): void {
    const enabled = this.manager.toggleShuffle();
    if (this.uiConfig.isVibrate) {
      customVibrator.vibratorTriggerOfHapticClockTimer();
    }
    this.showQueueToast(
      enabled ? $r('app.string.yt_queue_shuffle_on') : $r('app.string.yt_queue_shuffle_off'),
      1500
    );
  }

  private isSaveQueueDisabled(): boolean {
    return this.queue.length === 0 || this.isLocalFileOnly;
  }

  private openSaveQueueSheet(): void {
    if (this.isSaveQueueDisabled()) {
      return;
    }
    this.savePlaylistName = this.sourceName || '';
    this.showSaveQueueSheet = true;
  }

  private confirmSaveQueue(): void {
    const name = this.savePlaylistName.trim();
    if (name.length === 0) {
      return;
    }
    this.actionHub.saveCurrentQueueAsLocal(name);
    this.showSaveQueueSheet = false;
    this.savePlaylistName = '';
    this.showQueueToast($r('app.string.yt_queue_saved_toast'), 1800);
  }

  private handleDragStart(item: VideoItem, windowY: number): void {
    const idx = this.queue.indexOf(item);
    if (idx < 0) {
      return;
    }
    this.dragIndex = idx;
    this.dragItemKey = this.getItemKey(item);
    this.dragBaseOffsetY = 0;
    this.dragScrollAccumY = 0;
    this.lastPanOffsetY = 0;
    this.dragOffsetY = 0;
    this.isDragging = true;
    this.isDragHandleActive = true;
    if (this.uiConfig.isVibrate) {
      customVibrator.vibratorTriggerOfHapticClockTimer();
    }
    this.updateEdgeAutoScroll(windowY);
  }

  private handleDragUpdate(offsetY: number, windowY: number): void {
    if (!this.isDragging || this.dragIndex < 0) {
      return;
    }
    this.lastPanOffsetY = offsetY;
    this.applyDragDisplacement(offsetY + this.dragScrollAccumY);
    this.updateEdgeAutoScroll(windowY);
  }

  private applyDragDisplacement(totalDisplacementY: number): void {
    if (this.dragIndex < 0 || this.dragIndex >= this.queue.length) {
      return;
    }
    let delta = totalDisplacementY - this.dragBaseOffsetY;

    while (this.dragIndex < this.queue.length - 1) {
      const nextStep = this.getRowStepHeight(this.dragIndex + 1);
      if (delta >= nextStep * 0.55) {
        this.manager.reorder(this.dragIndex, this.dragIndex + 1);
        this.dragIndex += 1;
        this.dragBaseOffsetY += nextStep;
        delta -= nextStep;
        if (this.uiConfig.isVibrate) {
          customVibrator.vibratorTriggerOfHapticClockTimer();
        }
      } else {
        break;
      }
    }

    while (this.dragIndex > 0) {
      const prevStep = this.getRowStepHeight(this.dragIndex - 1);
      if (delta <= -prevStep * 0.55) {
        this.manager.reorder(this.dragIndex, this.dragIndex - 1);
        this.dragIndex -= 1;
        this.dragBaseOffsetY -= prevStep;
        delta += prevStep;
        if (this.uiConfig.isVibrate) {
          customVibrator.vibratorTriggerOfHapticClockTimer();
        }
      } else {
        break;
      }
    }

    this.dragOffsetY = delta;
  }

  private updateEdgeAutoScroll(windowY: number): void {
    if (!this.isDragging || this.listHeightVp <= DRAG_EDGE_ZONE_VP * 2 || windowY <= 0) {
      this.stopEdgeAutoScroll();
      return;
    }
    const relY = windowY - this.listTopWindowY;
    let velocity = 0;
    if (relY < DRAG_EDGE_ZONE_VP) {
      const ratio = Math.min(1, Math.max(0, (DRAG_EDGE_ZONE_VP - relY) / DRAG_EDGE_ZONE_VP));
      velocity = -(DRAG_SCROLL_MIN_STEP_VP + (DRAG_SCROLL_MAX_STEP_VP - DRAG_SCROLL_MIN_STEP_VP) * ratio);
    } else if (relY > this.listHeightVp - DRAG_EDGE_ZONE_VP) {
      const ratio = Math.min(1, Math.max(0, (relY - (this.listHeightVp - DRAG_EDGE_ZONE_VP)) / DRAG_EDGE_ZONE_VP));
      velocity = DRAG_SCROLL_MIN_STEP_VP + (DRAG_SCROLL_MAX_STEP_VP - DRAG_SCROLL_MIN_STEP_VP) * ratio;
    }

    if (velocity === 0) {
      this.stopEdgeAutoScroll();
      return;
    }
    this.edgeScrollVelocity = velocity;
    if (this.edgeScrollTimerId < 0) {
      this.edgeScrollTimerId = setInterval(() => {
        this.performEdgeScrollTick();
      }, DRAG_SCROLL_TICK_MS);
    }
  }

  private performEdgeScrollTick(): void {
    if (!this.isDragging || this.edgeScrollVelocity === 0) {
      this.stopEdgeAutoScroll();
      return;
    }
    let beforeY = 0;
    let afterY = 0;
    try {
      beforeY = this.listScroller.currentOffset()?.yOffset ?? 0;
      this.listScroller.scrollBy(0, this.edgeScrollVelocity);
      afterY = this.listScroller.currentOffset()?.yOffset ?? beforeY;
    } catch (_e) {
      return;
    }
    const scrolled = afterY - beforeY;
    if (Math.abs(scrolled) > 0.01) {
      this.dragScrollAccumY += scrolled;
      this.applyDragDisplacement(this.lastPanOffsetY + this.dragScrollAccumY);
    }
  }

  private stopEdgeAutoScroll(): void {
    this.edgeScrollVelocity = 0;
    if (this.edgeScrollTimerId >= 0) {
      clearInterval(this.edgeScrollTimerId);
      this.edgeScrollTimerId = -1;
    }
  }

  private handleDragEnd(): void {
    this.stopEdgeAutoScroll();
    this.isDragging = false;
    this.isDragHandleActive = false;
    this.dragIndex = -1;
    this.dragItemKey = '';
    this.dragOffsetY = 0;
    this.dragBaseOffsetY = 0;
    this.dragScrollAccumY = 0;
    this.lastPanOffsetY = 0;
    this.syncStateToComponent();
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
      return this.sourceName || $r('app.string.yt_queue_local_playlist');
    }
    if (this.totalLoadedCount <= 1) {
      return $r('app.string.yt_queue_current_video');
    }
    return $r('app.string.yt_queue_video_count', this.totalLoadedCount);
  }

  private getLoopIcon(): Resource {
    return this.loopMode === 'one'
      ? $r('sys.symbol.repeat_1')
      : $r('sys.symbol.repeat');
  }

  private getLoopLabel(): Resource {
    if (this.loopMode === 'all') {
      return $r('app.string.yt_queue_loop_all');
    }
    if (this.loopMode === 'one') {
      return $r('app.string.yt_queue_loop_one');
    }
    return $r('app.string.yt_queue_loop_none');
  }

  private isLoopActive(): boolean {
    return this.loopMode !== 'none';
  }

  @Builder
  SaveQueueSheet() {
    Column() {
      Row() {
        Text($r('app.string.yt_queue_save_sheet_title'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.yourtube_text_primary'))
          .layoutWeight(1)

        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(15)
            .fontColor([$r('app.color.yourtube_text_quaternary')])
        }
        .width(30)
        .height(30)
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .onClick(() => {
          this.showSaveQueueSheet = false;
        })
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 18, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.yt_playlist_video_count', this.totalLoadedCount))
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_quaternary'))
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 10 })

      Row({ space: 10 }) {
        TextInput({ placeholder: $r('app.string.yt_playlist_name_placeholder'), text: this.savePlaylistName })
          .layoutWeight(1)
          .height(42)
          .borderRadius(10)
          .fontSize(14)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .onChange((val: string) => {
            this.savePlaylistName = val;
          })
          .onSubmit(() => {
            this.confirmSaveQueue();
          })

        Button($r('app.string.yt_action_save'))
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_inverse'))
          .backgroundColor(this.savePlaylistName.trim().length > 0
            ? this.themePrimary
            : $r('app.color.yourtube_button_disabled'))
          .height(42)
          .padding({ left: 18, right: 18 })
          .enabled(this.savePlaylistName.trim().length > 0)
          .onClick(() => {
            this.confirmSaveQueue();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 24 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }

  @Builder
  QueueHeader() {
    Column({ space: 6 }) {
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
              PlayerSession.getInstance().setSessionAutoPlay(isOn);
            })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Row({ space: 8 }) {
          Row({ space: 4 }) {
            SymbolGlyph(this.getLoopIcon())
              .fontSize(15)
              .fontColor([this.isLoopActive()
                ? this.themePrimary
                : $r('app.color.yourtube_text_secondary')])
            Text(this.getLoopLabel())
              .fontSize(12)
              .fontColor(this.isLoopActive()
                ? this.themePrimary
                : $r('app.color.yourtube_text_secondary'))
              .fontWeight(this.isLoopActive() ? FontWeight.Medium : FontWeight.Regular)
              .maxLines(1)
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(14)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .border(this.isLoopActive()
            ? { width: 1, color: this.themePrimary }
            : { width: 1, color: Color.Transparent })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .onClick(() => {
            this.handleCycleLoopMode();
          })

          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.shuffle'))
              .fontSize(15)
              .fontColor([this.isShuffled
                ? this.themePrimary
                : $r('app.color.yourtube_text_secondary')])
            Text($r('app.string.yt_queue_shuffle'))
              .fontSize(12)
              .fontColor(this.isShuffled
                ? this.themePrimary
                : $r('app.color.yourtube_text_secondary'))
              .fontWeight(this.isShuffled ? FontWeight.Medium : FontWeight.Regular)
              .maxLines(1)
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(14)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .border(this.isShuffled
            ? { width: 1, color: this.themePrimary }
            : { width: 1, color: Color.Transparent })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .onClick(() => {
            this.handleToggleShuffle();
          })

          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.save'))
              .fontSize(15)
              .fontColor([$r('app.color.yourtube_text_secondary')])
            Text($r('app.string.yt_queue_save_as_playlist'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .maxLines(1)
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(14)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .opacity(this.isSaveQueueDisabled() ? 0.4 : 1.0)
          .enabled(!this.isSaveQueueDisabled())
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .onClick(() => {
            this.openSaveQueueSheet();
          })
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
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
  UndoBar() {
    Row() {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text($r('app.string.yt_queue_removed_item'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.yourtube_text_primary'))
            .maxLines(1)
          if (this.undoRemovedTitle.length > 0) {
            Text(this.undoRemovedTitle)
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.undo'))
            .fontSize(14)
            .fontColor([this.themePrimary])
          Text($r('app.string.yt_action_undo'))
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.themePrimary)
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(8)
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.handleUndoRemove();
        })
      }
      .width('100%')
      .padding({ left: 14, right: 10, top: 10, bottom: 10 })
      .borderRadius(12)
      .backgroundColor($r('app.color.yourtube_bg_surface'))
      .border({ width: 0.5, color: $r('app.color.yourtube_divider') })
      .shadow({
        radius: 12,
        color: $r('app.color.yourtube_shadow'),
        offsetX: 0,
        offsetY: 4
      })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 12 })
  }

  @Builder
  QueueListMode() {
    List({ space: QUEUE_LIST_ITEM_SPACE_VP, scroller: this.listScroller }) {
      ForEach(this.queue, (item: VideoItem, index: number) => {
        ListItem() {
          QueueRowItem({
            item: item,
            index: index,
            isCurrent: index === this.currentIndex,
            canPlayNext: index !== this.currentIndex && index !== this.currentIndex + 1,
            isDraggingThis: this.dragItemKey === this.getItemKey(item),
            onSwitch: (i: number) => {
              this.switchToVideo(item, i);
            },
            onRemove: (i: number) => {
              this.handleRemoveItem(i);
            },
            onRowDragHandleTouch: (active: boolean) => {
              this.isDragHandleActive = active;
            },
            onRowDragStart: (draggedItem: VideoItem, globalY: number) => {
              this.handleDragStart(draggedItem, globalY);
            },
            onRowDragUpdate: (offsetY: number, globalY: number) => {
              this.handleDragUpdate(offsetY, globalY);
            },
            onRowDragEnd: () => {
              this.handleDragEnd();
            }
          })
        }
        .zIndex(this.dragItemKey === this.getItemKey(item) ? 10 : 0)
        .translate({ y: this.dragItemKey === this.getItemKey(item) ? this.dragOffsetY : 0 })
        .scale(this.dragItemKey === this.getItemKey(item) ? { x: 1.02, y: 1.02 } : { x: 1.0, y: 1.0 })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const h = typeof newArea.height === 'number' ? newArea.height : 0;
          if (h > 20) {
            this.recordRowHeight(item, h);
          }
        })
      }, (item: VideoItem): string => this.getItemKey(item))

      if (this.isLoadingMore || this.canLoadMore) {
        ListItem() {
          this.LoadMoreSentinel()
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 10, right: 10, top: 6, bottom: this.showUndoBar ? 76 : 12 })
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Off)
    .enableScrollInteraction(!this.isDragging && !this.isDragHandleActive)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.listHeightVp = typeof newArea.height === 'number' ? newArea.height : 0;
      this.listTopWindowY = typeof newArea.globalPosition.y === 'number' ? newArea.globalPosition.y : 0;
    })
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
    Stack({ alignContent: Alignment.Bottom }) {
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

      if (this.showUndoBar) {
        this.UndoBar()
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showSaveQueueSheet, this.SaveQueueSheet(), {
      detents: [SheetSize.FIT_CONTENT],
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.yourtube_bg_page'),
      preferType: SheetType.CENTER
    })
  }
}
