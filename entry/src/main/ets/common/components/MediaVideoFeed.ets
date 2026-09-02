import { UIConfig } from '../AppState';
import { customAnimationUtil } from '../AnimationUtil';
import { resolveResourceStr } from '../utils/ResourceStrUtil';
import { FeedDataSource, FeedItemKeyOf } from '../model/FeedDataSource';
import { BasicPrefetcher, IPrefetcher } from '@kit.ArkUI';
import { defaultFeedThumbUrl, FeedThumbUrlOf } from '../model/ThumbPrefetcher';

/** 卡片 builder 的单参数（§3 对象字面量范式：by-reference 刷新） */
export interface MediaFeedItemSlot {
  item: Object;
  index: number;
}

export type MediaFeedItemBuilder = (slot: MediaFeedItemSlot) => void;
export type MediaFeedSectionBuilder = () => void;
export type MediaFeedSpanOf = (item: Object) => number;

/**
 * 易变展示态：父级每次重渲染给新对象字面量，@Prop 单向同步。
 * 数据源 / scroller / 回调身份稳定，是组件普通成员而非这里
 * （@Prop 的拷贝语义不适合带 listener 的数据源与 Scroller 实例）。
 */
export interface MediaVideoFeedParams {
  /** 布局偏好（UIConfig.homeLayoutMode）：'grid' = 网格卡片；其他 = 条式卡片 */
  layoutPreference: string;
  /** 网格列数（getVideoGridColumnCount），layoutPreference='grid' 时生效 */
  gridColumns: number;
  /** 宽屏条式列数（getWideListColumnCount）；<=1 时退化为单列 List */
  listColumns: number;
  isLoading: boolean;
  /** 加载更多 footer 开关；某布局不想显示时父级传 false */
  isLoadingMore: boolean;
  errorMessage: ResourceStr;
  /** 空态文案；解析为空串时空态渲染空白（首页空列表场景） */
  emptyText: ResourceStr;
  /** 是否渲染 header（配合 headerBuilder；显式开关避免空 GridItem/ListItem 占位） */
  hasHeader: boolean;
  /** Grid 分支 header 抵消左右 gridContentPadding 的负 margin（如首页全宽 banner） */
  headerHorizontalBleed: number;
  /** Grid / 宽列条式分支的容器 padding */
  gridContentPadding?: Padding;
  /** 单列 List 分支的容器 padding */
  listContentPadding?: Padding;
  /** 单列 List 分支的 contentEndOffset */
  listContentEndOffset: number;
  /** loading / error / empty 外包一层 Scroll（外层 Refresh 在空态也能下拉） */
  stateScrollable: boolean;
  /** 根节点尺寸策略：true = layoutWeight(1)（外层 Column 内还有兄弟节点，如首页通知条） */
  useLayoutWeight: boolean;
  /** 滚动容器 clip：false = 允许内容（卡片阴影/banner peek）画出边界（首页原行为）；缺省 true */
  clipContent?: boolean;
  /** 滚动条：false = BarState.Auto（首页原行为未显式关闭）；缺省 true = Off */
  scrollBarOff?: boolean;
}

/**
 * 共享信息流骨架：loading / error / empty / 网格 / 宽列条式 / 单列列表。
 * 网格与宽列条式用 Grid + LazyForEach（columnsTemplate 按断点列数），
 * 单列用 List + LazyForEach —— 替代 Scroll + GridRow + ForEach，
 * 无限分页下组件树不再线性膨胀。
 *
 * 迁移自原 Index 首页 / SearchPage / PlaylistDetailPage / UserPage
 * （ChannelVideoTab + PlaylistsTab）/ SubscriptionFeedPage 五分支骨架。
 */
@Component
export struct MediaVideoFeed {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

  // ── 身份稳定成员（创建时赋值一次）──
  dataSource: FeedDataSource = new FeedDataSource();
  gridScroller?: Scroller = undefined;
  listScroller?: Scroller = undefined;
  itemKey: FeedItemKeyOf = (_item: Object, index: number) => index.toString();
  /** 网格/宽列分支单卡占列数（默认 1；SearchPage 的频道/播放列表卡占满整行） */
  gridItemSpan?: MediaFeedSpanOf = undefined;
  onReachEnd?: () => void = undefined;
  /** 仅单列 List 分支（PlaylistDetailPage 提前预加载） */
  onScrollIndex?: (first: number, last: number) => void = undefined;
  /** 缩略图预取 URL 提取器（缺省 defaultFeedThumbUrl，覆盖 MediaVideoFeed 全部现有 item 形态） */
  itemThumbUrl?: FeedThumbUrlOf = undefined;
  /** Tabs / 外层 Scroll 嵌套场景：scrollForward=PARENT_FIRST, scrollBackward=SELF_FIRST */
  nestedScrollParentFirst: boolean = false;

  /** 条式卡片（单列 List 与宽列条式共用） */
  @BuilderParam itemBuilder: MediaFeedItemBuilder = this.defaultItemBuilder;
  /** 网格卡片（layoutPreference='grid' 时必传） */
  @BuilderParam gridItemBuilder: MediaFeedItemBuilder = this.defaultItemBuilder;
  /** 滚动内容头部（banner / 结果说明），由 params.hasHeader 开关 */
  @BuilderParam headerBuilder: MediaFeedSectionBuilder = this.defaultSectionBuilder;
  @BuilderParam loadingBuilder: MediaFeedSectionBuilder = this.DefaultLoadingState;
  @BuilderParam errorBuilder: MediaFeedSectionBuilder = this.DefaultErrorState;
  @BuilderParam emptyBuilder: MediaFeedSectionBuilder = this.DefaultEmptyState;

  @Prop params: MediaVideoFeedParams = {
    layoutPreference: 'list',
    gridColumns: 1,
    listColumns: 1,
    isLoading: false,
    isLoadingMore: false,
    errorMessage: '',
    emptyText: '',
    hasHeader: false,
    headerHorizontalBleed: 0,
    listContentEndOffset: 0,
    stateScrollable: false,
    useLayoutWeight: false,
    clipContent: true,
    scrollBarOff: true
  };

  /** 数据源 0↔N 跨界计数：驱动骨架分支重评估（追加由 LazyForEach 自身增量处理） */
  @State private dataVersion: number = 0;
  private lastFeedEmpty: boolean = true;
  /** 滑动预取器：aboutToAppear 绑定 dataSource，onScrollIndex 上报可见区 */
  private prefetcher: IPrefetcher | null = null;
  private feedListener: DataChangeListener = {
    onDataReloaded: () => {
      this.onFeedDataChanged();
    },
    onDataAdd: (_index: number) => {
      this.onFeedDataChanged();
    },
    onDataAdded: (_index: number) => {
      this.onFeedDataChanged();
    },
    onDataDelete: (_index: number) => {
      this.onFeedDataChanged();
    },
    onDataDeleted: (_index: number) => {
      this.onFeedDataChanged();
    },
    onDataChange: (_index: number) => {
      this.onFeedDataChanged();
    },
    onDataChanged: (_index: number) => {
      this.onFeedDataChanged();
    },
    onDataMove: (_from: number, _to: number) => {
      this.onFeedDataChanged();
    },
    onDataMoved: (_from: number, _to: number) => {
      this.onFeedDataChanged();
    },
    onDatasetChange: (_operations: DataOperation[]) => {
      this.onFeedDataChanged();
    }
  };

  aboutToAppear(): void {
    this.dataSource.registerDataChangeListener(this.feedListener);
    this.dataSource.thumbUrlOf = this.itemThumbUrl ?? defaultFeedThumbUrl;
    this.prefetcher = new BasicPrefetcher(this.dataSource);
  }

  aboutToDisappear(): void {
    this.dataSource.unregisterDataChangeListener(this.feedListener);
    this.prefetcher = null;
  }

  private onFeedDataChanged(): void {
    const empty: boolean = this.dataSource.totalCount() === 0;
    if (empty !== this.lastFeedEmpty) {
      this.lastFeedEmpty = empty;
      this.dataVersion += 1;
    }
  }

  /** dataVersion<0 永不成立，仅建立 @State 依赖，保证空↔非空切换时骨架分支重算 */
  private feedItemCount(): number {
    if (this.dataVersion < 0) {
      return 0;
    }
    return this.dataSource.totalCount();
  }

  private gridSpanOf(item: Object, columns: number): number {
    const span: number = this.gridItemSpan ? this.gridItemSpan(item) : 1;
    return Math.max(1, Math.min(columns, span));
  }

  private gridColumnsTemplate(columns: number): string {
    return '1fr '.repeat(columns).trim();
  }

  private feedNestedScroll(): NestedScrollOptions {
    return this.nestedScrollParentFirst
      ? { scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST }
      : { scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST };
  }

  private handleReachEnd(): void {
    if (this.onReachEnd) {
      this.onReachEnd();
    }
  }

  /**
   * onScrollIndex 上报的是容器项索引：hasHeader 时 header 占第 0 项，
   * LazyForEach 数据项整体偏移 1；换算回数据源索引并钳位后交给 Prefetcher。
   */
  private handleVisibleAreaChanged(first: number, last: number): void {
    if (!this.prefetcher) {
      return;
    }
    const count: number = this.dataSource.totalCount();
    if (count <= 0) {
      return;
    }
    const offset: number = this.params.hasHeader ? 1 : 0;
    const min: number = Math.max(0, Math.min(first - offset, count - 1));
    const max: number = Math.max(0, Math.min(last - offset, count - 1));
    if (min > max) {
      return;
    }
    this.prefetcher.visibleAreaChanged(min, max);
  }

  @Builder
  defaultItemBuilder(_slot: MediaFeedItemSlot) {
    // 占位：调用方必须提供 itemBuilder
    Blank().width('100%').height(0)
  }

  @Builder
  defaultSectionBuilder() {
    Blank().width('100%').height(0)
  }

  /** LoadingMoreFooter（雏形来自原 ChannelVideoTab） */
  @Builder
  LoadingMoreFooter() {
    Row() {
      LoadingProgress()
        .color(this.themePrimary)
        .width(26)
        .height(26)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  DefaultLoadingState() {
    Row() {
      LoadingProgress()
        .color(this.themePrimary)
        .width(30)
        .height(30)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 20 })
  }

  @Builder
  DefaultErrorState() {
    Text(resolveResourceStr(this.params.errorMessage))
      .fontSize(12)
      .fontColor(this.themePrimary)
      .margin({ left: 16, top: 12 })
  }

  @Builder
  DefaultEmptyState() {
    if (resolveResourceStr(this.params.emptyText).length > 0) {
      Text(this.params.emptyText)
        .fontSize(13)
        .fontColor($r('app.color.yourtube_text_quaternary'))
        .margin({ top: 20 })
        .width('100%')
        .textAlign(TextAlign.Center)
    }
  }

  @Builder
  StateArea(kind: string) {
    if (this.params.stateScrollable) {
      Scroll() {
        Column() {
          if (kind === 'loading') {
            this.loadingBuilder()
          } else if (kind === 'error') {
            this.errorBuilder()
          } else {
            this.emptyBuilder()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    } else {
      if (kind === 'loading') {
        this.loadingBuilder()
      } else if (kind === 'error') {
        this.errorBuilder()
      } else {
        this.emptyBuilder()
      }
    }
  }

  /** 当前 Grid 分支列数：grid 模式用网格列数，宽列条式用条式列数。 */
  private gridColumnCount(): number {
    return Math.max(1,
      this.params.layoutPreference === 'grid' ? this.params.gridColumns : this.params.listColumns);
  }

  @Builder
  FeedCardContent(item: Object, index: number) {
    if (this.params.layoutPreference === 'grid') {
      this.gridItemBuilder({ item: item, index: index })
    } else {
      this.itemBuilder({ item: item, index: index })
    }
  }

  /**
   * 网格（grid 布局）与宽列条式（宽屏 list 布局）共用的 Grid + LazyForEach。
   * 零参数 + 体内直读 @Prop params：@Builder 按值参数不随状态刷新（见 §3
   * SubTabBar 约定同款坑），列数/间距必须实时读，横竖屏、折叠、分屏切换时
   * 断点列数才能自适应。
   */
  @Builder
  GridFeed() {
    Grid(this.gridScroller) {
      if (this.params.hasHeader) {
        GridItem() {
          this.headerBuilder()
        }
        .columnStart(0)
        .columnEnd(this.gridColumnCount() - 1)
        .margin({ left: -this.params.headerHorizontalBleed, right: -this.params.headerHorizontalBleed })
      }
      LazyForEach(this.dataSource, (item: Object, index: number) => {
        if (this.gridSpanOf(item, this.gridColumnCount()) > 1) {
          // 跨列卡（占满整行）：显式定位到整行
          GridItem() {
            this.FeedCardContent(item, index)
          }
          .columnStart(0)
          .columnEnd(this.gridSpanOf(item, this.gridColumnCount()) - 1)
          .transition(customAnimationUtil.isScaleTran(this.itemKey(item, index), this.uiConfig))
        } else {
          // 普通卡：不得设置 columnStart/columnEnd —— 显式定位会脱离自动流式
          // 排列，全部钉在第 0 列，视觉上退化为单列
          GridItem() {
            this.FeedCardContent(item, index)
          }
          .transition(customAnimationUtil.isScaleTran(this.itemKey(item, index), this.uiConfig))
        }
      }, (item: Object, index: number) => this.itemKey(item, index))
      if (this.params.isLoadingMore) {
        GridItem() {
          this.LoadingMoreFooter()
        }
        .columnStart(0)
        .columnEnd(this.gridColumnCount() - 1)
      }
    }
    .columnsTemplate(this.gridColumnsTemplate(this.gridColumnCount()))
    .columnsGap(8)
    .rowsGap(this.params.layoutPreference === 'grid' ? 8 : 4)
    .width('100%')
    .layoutWeight(1)
    .padding(this.params.gridContentPadding ?? 0)
    .clip(this.params.clipContent ?? true)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar((this.params.scrollBarOff ?? true) ? BarState.Off : BarState.Auto)
    .nestedScroll(this.feedNestedScroll())
    .onScrollIndex((first: number, last: number) => {
      this.handleVisibleAreaChanged(first, last);
    })
    .onReachEnd(() => {
      this.handleReachEnd();
    })
  }

  @Builder
  ListFeed() {
    List({ space: 4, scroller: this.listScroller }) {
      if (this.params.hasHeader) {
        ListItem() {
          this.headerBuilder()
        }
      }
      LazyForEach(this.dataSource, (item: Object, index: number) => {
        ListItem() {
          this.itemBuilder({ item: item, index: index })
        }
        .transition(customAnimationUtil.isScaleTran(this.itemKey(item, index), this.uiConfig))
      }, (item: Object, index: number) => this.itemKey(item, index))
      if (this.params.isLoadingMore) {
        ListItem() {
          this.LoadingMoreFooter()
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding(this.params.listContentPadding ?? 0)
    .contentEndOffset(this.params.listContentEndOffset)
    .clip(this.params.clipContent ?? true)
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar((this.params.scrollBarOff ?? true) ? BarState.Off : BarState.Auto)
    .nestedScroll(this.feedNestedScroll())
    .onScrollIndex((first: number, last: number) => {
      this.handleVisibleAreaChanged(first, last);
      if (this.onScrollIndex) {
        this.onScrollIndex(first, last);
      }
    })
    .onReachEnd(() => {
      this.handleReachEnd();
    })
  }

  build() {
    Column() {
      if (this.params.isLoading) {
        this.StateArea('loading')
      } else if (resolveResourceStr(this.params.errorMessage).length > 0) {
        this.StateArea('error')
      } else if (this.feedItemCount() === 0) {
        this.StateArea('empty')
      } else if (this.params.layoutPreference === 'grid' || this.params.listColumns > 1) {
        this.GridFeed()
      } else {
        this.ListFeed()
      }
    }
    .width('100%')
    .height('100%')
    .layoutWeight(this.params.useLayoutWeight ? 1 : 0)
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
