import { AppLog } from '../../common/AppLog';
import { AuthSessionManager } from 'youtube_core';
import { VideoItem } from 'youtube_core';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { HomeRecommendSwiper } from './components/HomeRecommendSwiper';
import { MediaFeedItemSlot, MediaVideoFeed } from '../../common/components/MediaVideoFeed';
import { FeedDataSource } from '../../common/model/FeedDataSource';
import { getFeedContentWidthVp, getVideoGridColumnCount } from '../../common/utils/ListLayoutUtils';
import { ErrorPage } from '../../common/components/ErrorPage';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { UIConfig } from '../../common/AppState';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { WatchHistoryStore } from '../../common/WatchHistoryStore';
import { COLOR_PRESETS } from '../../common/ThemeManager';
import { HomeFeedChip, HomeFeedSection } from './model/FeedResult';

const logger = AppLog.getInstance('HomeTabContent');

/** 前置固定官方分类标签（排在最前，「全部」后紧跟「我的分类」）。 */
const FRONT_OFFICIAL_CHIPS: Array<HomeFeedChip> = [
  { label: '全部', continuationToken: '', isSelected: true },
  { label: '我的分类', continuationToken: '', isSelected: false, isMyCategories: true },
  { label: '音乐', continuationToken: '', isSelected: false, searchQuery: '音乐' },
  { label: '游戏', continuationToken: '', isSelected: false, searchQuery: '游戏' },
  { label: '直播', continuationToken: '', isSelected: false, searchQuery: '直播' }
];

/** 后置补充分类标签（排在推荐流动态分类之后）。 */
const TAIL_OFFICIAL_CHIPS: Array<HomeFeedChip> = [
  { label: '自然', continuationToken: '', isSelected: false, searchQuery: '自然 4K' },
  { label: '旅游', continuationToken: '', isSelected: false, searchQuery: '旅游 Vlog' },
  { label: '动画', continuationToken: '', isSelected: false, searchQuery: '动画' },
  { label: '动作冒险游戏', continuationToken: '', isSelected: false, searchQuery: '动作冒险游戏' },
  { label: '最近上传', continuationToken: '', isSelected: false, searchQuery: '最近上传' },
  { label: '已观看', continuationToken: '', isSelected: false, searchQuery: '热门视频' },
  { label: '发现新视频', continuationToken: '', isSelected: false, searchQuery: '推荐视频' }
];

const FALLBACK_CHIPS: Array<HomeFeedChip> = FRONT_OFFICIAL_CHIPS.concat(TAIL_OFFICIAL_CHIPS);

/** 短视频列表少于该条数时，继续翻首页 feed 去收短视频（短视频就在这份混合 feed 里）。 */
const HOME_SHORTS_TOPUP_THRESHOLD: number = 12;
/** 单次补收最多额外翻几页首页 feed。 */
const HOME_SHORTS_HARVEST_PAGES: number = 5;
/** 短视频攒够这个数就停手（首页 feed 的 Shorts 货架位置不固定，多翻几页才碰得到）。 */
const HOME_SHORTS_HARVEST_TARGET: number = 24;
/** feed 到顶后，最多取多少个"我的频道"的 /shorts 标签页。 */
const HOME_SHORTS_MAX_CHANNELS: number = 20;
/**
 * 一轮补货同时查多少个频道。
 * 频道池整体查一遍（串行 await）要十几秒，首屏会被拖死；这里改成
 * **并发查 N 个**、频道池按游标轮转，每轮只花一两秒。
 */
const HOME_SHORTS_CHANNEL_FETCH_PER_ROUND: number = 6;
/** 一轮频道补货最多并入多少条短视频。 */
const HOME_SHORTS_CHANNEL_BATCH: number = 60;

/** 短视频补收用的频道游标（每个频道独立分页）。 */
interface ShortsChannelState {
  channelId: string;
  token: string;
  visitor: string;
  exhausted: boolean;
}

/** 一页 feed 按 isShort 拆分的结果。 */
interface HomeFeedSplit {
  long: VideoItem[];
  short: VideoItem[];
}

/**
 * 首页 tab 与 Index 之间的控制句柄：feed 重置（启动 / 登录态变化 / 搜索地区
 * 语言切换共用）与滚动容器（HdsNavigation.bindToScrollable 共用同一实例）。
 * 实现由 HomeTabContent 挂载时注册；注册前的 reset 调用排队一次，挂载后立即补放。
 */
export class HomeTabController {
  gridScroller: Scroller = new Scroller();
  listScroller: Scroller = new Scroller();
  private resetImpl: ((clearList: boolean, reload: boolean) => void) | null = null;
  private queuedClearList: boolean = false;
  private queuedReload: boolean = false;
  private hasQueuedReset: boolean = false;
  private modeSwitchImpl: ((mode: string) => void) | null = null;

  registerReset(impl: (clearList: boolean, reload: boolean) => void): void {
    this.resetImpl = impl;
    if (this.hasQueuedReset) {
      this.hasQueuedReset = false;
      impl(this.queuedClearList, this.queuedReload);
    }
  }

  resetFeed(clearList: boolean, reload: boolean): void {
    if (this.resetImpl) {
      this.resetImpl(clearList, reload);
      return;
    }
    this.queuedClearList = clearList;
    this.queuedReload = reload;
    this.hasQueuedReset = true;
  }

  /**
   * 首页维度切换（长视频 / 短视频）：数据源要换一份（两个列表是分开的），
   * 由首页内容侧同步 + 回到顶部。
   */
  registerModeSwitch(impl: (mode: string) => void): void {
    this.modeSwitchImpl = impl;
  }

  switchMode(mode: string): void {
    if (this.modeSwitchImpl) {
      this.modeSwitchImpl(mode);
    }
  }
}

/**
 * 首页 tab 内容宿主：feed 加载状态机（kiosk/推荐双轨 + 分页 + 下拉刷新）、
 * 错误格式化、分类 Chip 栏、错误页 / 信息流 / 初始加载遮罩三档视图。
 * 原 Index.TabContentSection(0) 分支纯迁移；Index 经 HomeTabController 触发 reset。
 */
@Component
export struct HomeTabContent {
  controller: HomeTabController = new HomeTabController();
  @Prop feedMode: string = 'long';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @StorageProp('themePrimaryColor') themePrimary: string = COLOR_PRESETS[0].primary;
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @State longList: VideoItem[] = [];
  @State shortList: VideoItem[] = [];
  @State chips: HomeFeedChip[] = FALLBACK_CHIPS;
  @State selectedChipIndex: number = 0;
  /** 分类 Chip 栏是否展开显示（下滑列表隐藏，上滑列表展开） */
  @State isChipBarVisible: boolean = true;
  /** 列表纵向滑动方向累计位移（用于防抖触发隐藏/展开） */
  private chipScrollAccumY: number = 0;
  @State myCategorySections: HomeFeedSection[] = [];
  @State isMyCategoriesLoading: boolean = false;
  private serverSections: HomeFeedSection[] = [];
  /** 官方推荐流动态返回/提取的额外分类条目（仅展示在「我的分类」展开列表中，不含固定预设分类）。 */
  private recommendedExtraChips: HomeFeedChip[] = [];
  private myCategoriesSeenTitles: Set<string> = new Set<string>();
  private myCategoriesIdCursor: number = 500000;
  private myCategoriesFetched: boolean = false;
  /** 正在进行的 feed 拉取（"多翻几页收短视频"要串行等它）。 */
  private feedLoadInFlight: Promise<void> = Promise.resolve();
  /** 短视频补收（多翻 feed 页）的 in-flight 标记。 */
  private shortsHarvestInFlight: boolean = false;
  /** 频道补货（feed 到顶后接"我的频道"）的状态与 in-flight 标记。 */
  private shortsChannels: ShortsChannelState[] = [];
  private shortsChannelTopUpInFlight: boolean = false;
  /** 频道池轮转游标：每轮从这里开始挑频道。 */
  private shortsChannelCursor: number = 0;
  private shortsIdCursor: number = 1000000;
  @State isLoadingMore: boolean = false;
  @State isInitialLoading: boolean = false;
  @State isHomeRefreshing: boolean = false;
  @State homeErrorMessage: string = '';
  @State homeModeNoticeMessage: string = '';
  /** 每次首页 reset 成功后 +1：仅驱动推荐位 banner 重建；列表刷新由 DataChangeListener 全量通知负责 */
  @State homeFeedEpoch: number = 0;
  @State kioskNextPageToken: string | null = null;
  @State kioskVisitorData: string = '';
  @State homeFeedSource: string = 'kiosk';
  @State homeMode: string = 'kiosk';
  /** 当前是否处于分类 Chip 搜索兜底分页模式。 */
  private activeChipSearchMode: boolean = false;
  private chipScroller: Scroller = new Scroller();
  /** 首页信息流 LazyForEach 数据源：当前维度的列表变更后由 syncHomeFeedDataSource 同步 */
  private homeFeedDataSource: FeedDataSource = new FeedDataSource();
  private homeBannerMax: number = 6;
  /**
   * 首页 feed 请求代次：每次 reset/刷新递增。旧请求晚返回时不得覆盖新结果
   * （登录态/内容源切换与启动加载并发时，旧的 kiosk 响应会把推荐列表顶掉）。
   */
  private homeLoadGeneration: number = 0;
  /** 本会话下拉刷新已曝光过的视频 ID 集合，用于下拉刷新优先推送全新视频（真换一批）。 */
  private seenRefreshIds: Set<string> = new Set<string>();

  private recordSeenRefreshItems(items: VideoItem[]): void {
    const cap = Math.min(items.length, 30);
    for (let i = 0; i < cap; i++) {
      const vid = (items[i].videoId || '').trim();
      if (vid.length > 0) {
        this.seenRefreshIds.add(vid);
      }
    }
    if (this.seenRefreshIds.size > 400) {
      this.seenRefreshIds.clear();
      for (let i = 0; i < cap; i++) {
        const vid = (items[i].videoId || '').trim();
        if (vid.length > 0) {
          this.seenRefreshIds.add(vid);
        }
      }
    }
  }

  aboutToAppear() {
    this.controller.registerReset((clearList: boolean, reload: boolean) => {
      this.resetHomeFeed(clearList, reload);
    });
    this.controller.registerModeSwitch((mode: string) => {
      this.onHomeModeSwitched(mode);
    });
  }

  /**
   * 首页维度切换（长视频 ↔ 短视频）：两个列表是分开维护的，切换只换显示的
   * 那一份（数据源换 key 序列 → 整列重建），不回顶部、不重新请求。
   */
  private onHomeModeSwitched(mode: string): void {
    logger.info(`[HomeFeed] stage=mode_switch mode=${mode} `
      + `long=${this.longList.length} short=${this.shortList.length}`);
    this.syncHomeFeedDataSource();
    this.scrollHomeFeedToTop();
    if (mode === 'short') {
      if (this.shortList.length < HOME_SHORTS_TOPUP_THRESHOLD) {
        this.harvestShortsFromFeed().catch(() => undefined);
      } else if (!this.kioskNextPageToken) {
        this.topUpShortsFromChannels().catch(() => undefined);
      }
    }
  }

  /**
   * 首页 feed 重置单一入口（启动 / 登录态变化 / 搜索地区语言切换共用）：
   * 清空分页状态与（可选）列表后按需立即重载。
   * 下拉刷新（refreshHomeFeed）刻意不走这里——它要保留当前 rail
   * （homeFeedSource 可能是 recommended）和旧列表防白屏。
   */
  private resetHomeFeed(clearList: boolean, reload: boolean): void {
    this.homeMode = 'kiosk';
    this.kioskNextPageToken = null;
    this.kioskVisitorData = '';
    this.homeFeedSource = 'kiosk';
    this.homeErrorMessage = '';
    this.homeModeNoticeMessage = '';
    this.activeChipSearchMode = false;
    this.selectedChipIndex = 0;
    this.myCategoriesFetched = false;
    this.seenRefreshIds.clear();
    if (clearList) {
      this.longList = [];
      this.shortList = [];
      this.serverSections = [];
      this.recommendedExtraChips = [];
      this.myCategoriesSeenTitles.clear();
      this.myCategorySections = [];
      this.syncHomeFeedDataSource();
    }
    if (reload) {
      this.loadLiveVideos(true);
    }
  }

  private isMyCategoriesSelected(): boolean {
    return !this.isShortMode()
      && this.selectedChipIndex >= 0
      && this.selectedChipIndex < this.chips.length
      && this.chips[this.selectedChipIndex].isMyCategories === true;
  }

  /** 点击顶部分类 Chip 切换内容。 */
  private onSelectChip(index: number): void {
    if (index < 0 || index >= this.chips.length) {
      return;
    }
    if (this.selectedChipIndex === index && (this.longList.length > 0 || this.myCategorySections.length > 0)) {
      this.scrollHomeFeedToTop();
      return;
    }
    this.selectedChipIndex = index;
    const chip = this.chips[index];
    logger.info(`[HomeFeed] stage=chip_select index=${index} label=${chip.label} hasToken=${chip.continuationToken.length > 0} isMyCat=${chip.isMyCategories === true}`);
    if (index === 0) {
      this.activeChipSearchMode = false;
      this.loadLiveVideos(true);
      return;
    }
    if (chip.isMyCategories === true) {
      this.activeChipSearchMode = false;
      this.loadMyCategoriesSections(false).catch(() => undefined);
      return;
    }
    const task = this.doLoadChipVideos(chip);
    this.feedLoadInFlight = task;
  }

  /**
   * 加载「我的分类」展开带 Header 的视频分组列表：
   * 仅纳入官方推荐给我们的动态分类/货架条目（serverSections + recommendedExtraChips），
   * 不把顶部固定预设页签（音乐 / 游戏 / 合辑 / 直播 / 自然 / 旅游等）全部搬进来。
   */
  private async loadMyCategoriesSections(forceRefresh: boolean): Promise<void> {
    if (this.isMyCategoriesLoading) {
      return;
    }
    if (this.myCategoriesFetched && !forceRefresh && this.myCategorySections.length > 0) {
      return;
    }
    this.isMyCategoriesLoading = true;
    this.homeErrorMessage = '';
    const startedAt = Date.now();
    try {
      this.myCategoriesSeenTitles.clear();
      for (let i = 0; i < FALLBACK_CHIPS.length; i++) {
        this.myCategoriesSeenTitles.add(FALLBACK_CHIPS[i].label);
      }

      const resultSections: Array<HomeFeedSection> = [];

      // 1. 推荐流原生货架分组（跳过与顶部固定预设同名项）
      for (let i = 0; i < this.serverSections.length; i++) {
        const sec = this.serverSections[i];
        const title = (sec.title || '').trim();
        if (title.length > 0 && sec.items.length > 0 && !this.myCategoriesSeenTitles.has(title)) {
          this.myCategoriesSeenTitles.add(title);
          resultSections.push({
            title: title,
            items: sec.items.slice(0, 8)
          });
        }
      }
      this.myCategorySections = resultSections.slice();

      // 2. 拉取首屏官方推荐给我们的动态分类条目（首批 6 个分组）
      await this.appendNextMyCategoriesBatch(6);

      this.myCategoriesFetched = true;
      logger.info(`[HomeFeed] stage=my_categories_done sections=${this.myCategorySections.length} elapsed=${Date.now() - startedAt}ms`);
    } finally {
      this.isMyCategoriesLoading = false;
    }
  }

  /**
   * 「我的分类」滑到底部时继续刷新加载更多官方推荐分类分组：
   * 1. 若 recommendedExtraChips 中剩余未展示的推荐条目不足，先继续向后翻一页官方推荐流，
   *    并入新返回的原生货架（sections）并从新推荐视频提取更多 #话题 与推荐频道；
   * 2. 再并发拉取下一批推荐分类分组追加到底部。
   */
  private async loadMoreMyCategoriesSections(): Promise<void> {
    if (this.isMyCategoriesLoading || !this.myCategoriesFetched) {
      return;
    }
    this.isMyCategoriesLoading = true;
    const startedAt = Date.now();
    try {
      let remaining = this.countUnseenExtraChips();
      const homeService = FeedServiceProvider.getInstance().getHomeFeedService();
      const useAuth = this.homeFeedSource.indexOf('recommended') === 0;

      // 若待展示的官方推荐分类不足 4 个，向后翻一页官方推荐流补充
      if (remaining < 4 && this.kioskNextPageToken && this.kioskNextPageToken.length > 0) {
        try {
          const startId = this.longList.length + this.shortList.length + 1;
          const nextRes = await homeService.fetchHomeKioskNext(
            this.kioskNextPageToken,
            this.kioskVisitorData,
            startId,
            useAuth,
            this.homeFeedSource
          );
          this.kioskNextPageToken = nextRes.nextPageToken;
          if (nextRes.visitorData && nextRes.visitorData.length > 0) {
            this.kioskVisitorData = nextRes.visitorData;
          }
          const split = this.splitByType(nextRes.items);
          this.longList = this.longList.concat(split.long);
          this.shortList = this.shortList.concat(split.short);
          this.syncHomeFeedDataSource();

          if (nextRes.sections && nextRes.sections.length > 0) {
            const nextSections = this.myCategorySections.slice();
            for (let i = 0; i < nextRes.sections.length; i++) {
              const sec = nextRes.sections[i];
              const title = (sec.title || '').trim();
              if (title.length > 0 && sec.items.length > 0 && !this.myCategoriesSeenTitles.has(title)) {
                this.myCategoriesSeenTitles.add(title);
                nextSections.push({
                  title: title,
                  items: sec.items.slice(0, 8)
                });
              }
            }
            this.myCategorySections = nextSections;
          }

          this.appendExtraChipsFromItems(nextRes.items);
          remaining = this.countUnseenExtraChips();
        } catch (e) {
          logger.warn(`[HomeFeed] stage=my_categories_next_feed_failed ${this.describeThrowable(e)}`);
        }
      }

      // 若翻页后仍不足，从已加载的推荐流全量条目中继续挖掘未展示的推荐话题/频道
      if (remaining < 4 && this.longList.length > 0) {
        this.appendExtraChipsFromItems(this.longList);
      }

      await this.appendNextMyCategoriesBatch(4);
      logger.info(`[HomeFeed] stage=my_categories_more_done sections=${this.myCategorySections.length} elapsed=${Date.now() - startedAt}ms`);
    } finally {
      this.isMyCategoriesLoading = false;
    }
  }

  private countUnseenExtraChips(): number {
    let count = 0;
    for (let i = 0; i < this.recommendedExtraChips.length; i++) {
      const lbl = (this.recommendedExtraChips[i].label || '').trim();
      if (lbl.length > 0 && !this.myCategoriesSeenTitles.has(lbl)) {
        count += 1;
      }
    }
    return count;
  }

  private async appendNextMyCategoriesBatch(maxCount: number): Promise<void> {
    const candidates: Array<HomeFeedChip> = [];
    for (let i = 0; i < this.recommendedExtraChips.length && candidates.length < maxCount; i++) {
      const c = this.recommendedExtraChips[i];
      const lbl = (c.label || '').trim();
      if (!lbl || this.myCategoriesSeenTitles.has(lbl)) {
        continue;
      }
      this.myCategoriesSeenTitles.add(lbl);
      candidates.push(c);
    }
    if (candidates.length === 0) {
      return;
    }

    const homeService = FeedServiceProvider.getInstance().getHomeFeedService();
    const searchService = FeedServiceProvider.getInstance().getSearchService();
    const useAuth = this.homeFeedSource.indexOf('recommended') === 0;
    const batchSize = 4;
    const currentSections = this.myCategorySections.slice();

    for (let offset = 0; offset < candidates.length; offset += batchSize) {
      const batch = candidates.slice(offset, offset + batchSize);
      const batchResults: Array<HomeFeedSection | null> = await Promise.all(
        batch.map(async (chip: HomeFeedChip): Promise<HomeFeedSection | null> => {
          this.myCategoriesIdCursor += 100;
          const baseId = this.myCategoriesIdCursor;
          try {
            if (chip.continuationToken && chip.continuationToken.length > 0) {
              const res = await homeService.fetchHomeKioskNext(
                chip.continuationToken,
                this.kioskVisitorData,
                baseId,
                useAuth,
                this.homeFeedSource
              );
              const split = this.splitByType(res.items);
              const list = (split.long.length > 0 ? split.long : res.items).slice(0, 8);
              if (list.length > 0) {
                return {
                  title: chip.label,
                  items: list
                };
              }
            }
            const query = chip.searchQuery && chip.searchQuery.length > 0
              ? chip.searchQuery
              : chip.label;
            const sRes = await searchService.fetchInitial(query, baseId);
            const split = this.splitByType(sRes.items);
            const list = (split.long.length > 0 ? split.long : sRes.items).slice(0, 8);
            if (list.length > 0) {
              return {
                title: chip.label,
                items: list
              };
            }
            return null;
          } catch (e) {
            logger.warn(`[HomeFeed] stage=my_categories_item_failed label=${chip.label} ${this.describeThrowable(e)}`);
            return null;
          }
        })
      );
      for (let k = 0; k < batchResults.length; k++) {
        const sec = batchResults[k];
        if (sec && sec.items.length > 0) {
          currentSections.push(sec);
        }
      }
      this.myCategorySections = currentSections.slice();
    }
  }

  private async doLoadChipVideos(chip: HomeFeedChip): Promise<void> {
    this.homeLoadGeneration += 1;
    const generation = this.homeLoadGeneration;
    this.isLoadingMore = false;
    this.isInitialLoading = true;
    this.homeErrorMessage = '';
    const startedAt = Date.now();
    try {
      if (chip.continuationToken && chip.continuationToken.length > 0) {
        this.activeChipSearchMode = false;
        const homeService = FeedServiceProvider.getInstance().getHomeFeedService();
        const useAuth = this.homeFeedSource.indexOf('recommended') === 0;
        const result = await homeService.fetchHomeKioskNext(
          chip.continuationToken,
          this.kioskVisitorData,
          1,
          useAuth,
          this.homeFeedSource
        );
        if (generation !== this.homeLoadGeneration) {
          return;
        }
        const split = this.splitByType(result.items);
        this.longList = split.long.length > 0 ? split.long : result.items;
        if (split.short.length > 0) {
          this.shortList = split.short;
        }
        this.kioskNextPageToken = result.nextPageToken;
        if (result.visitorData && result.visitorData.length > 0) {
          this.kioskVisitorData = result.visitorData;
        }
        this.syncHomeFeedDataSource();
        this.scrollHomeFeedToTop();
        logger.info(`[HomeFeed] stage=chip_done mode=continuation label=${chip.label} items=${result.items.length} elapsed=${Date.now() - startedAt}ms`);
        return;
      }

      // 兜底：使用搜索接口按分类词拉取视频列表
      this.activeChipSearchMode = true;
      const searchService = FeedServiceProvider.getInstance().getSearchService();
      const query = chip.searchQuery && chip.searchQuery.length > 0 ? chip.searchQuery : chip.label;
      const searchRes = await searchService.fetchInitial(query, 1);
      if (generation !== this.homeLoadGeneration) {
        return;
      }
      const split = this.splitByType(searchRes.items);
      this.longList = split.long.length > 0 ? split.long : searchRes.items;
      this.kioskNextPageToken = searchRes.nextPageToken;
      this.syncHomeFeedDataSource();
      this.scrollHomeFeedToTop();
      logger.info(`[HomeFeed] stage=chip_done mode=search label=${chip.label} items=${searchRes.items.length} elapsed=${Date.now() - startedAt}ms`);
    } catch (err) {
      if (generation !== this.homeLoadGeneration) {
        return;
      }
      logger.error(`[HomeFeed] stage=chip_failed label=${chip.label} ${this.describeThrowable(err)}`);
      this.homeErrorMessage = this.formatHomeRequestError(
        err as Object,
        getContext().resourceManager.getStringSync($r('app.string.yt_home_load_error').id)
      );
    } finally {
      if (generation === this.homeLoadGeneration) {
        this.isInitialLoading = false;
        this.isLoadingMore = false;
      }
    }
  }

  /** 记录在飞的 feed 请求：短视频补收要串行等它结束再要下一页。 */
  private loadLiveVideos(reset: boolean = false, preferFreshOnRefresh: boolean = false): Promise<void> {
    const task = this.doLoadLiveVideos(reset, preferFreshOnRefresh);
    this.feedLoadInFlight = task;
    return task;
  }

  private async doLoadLiveVideos(reset: boolean = false, preferFreshOnRefresh: boolean = false) {
    if (reset) {
      this.homeLoadGeneration += 1;
      this.isLoadingMore = false;
      this.isInitialLoading = this.activeList().length === 0;
      this.homeErrorMessage = '';
      this.activeChipSearchMode = false;
    } else {
      if (this.isLoadingMore) {
        return;
      }
    }
    const generation = this.homeLoadGeneration;

    const startId = reset ? 1 : (this.longList.length + this.shortList.length + 1);
    const loadStartedAt = Date.now();
    logger.info(`[HomeFeed] stage=load_start reset=${reset} mode=${this.homeMode} `
      + `source=${this.homeFeedSource} startId=${startId} long=${this.longList.length} `
      + `short=${this.shortList.length}`);
    try {
      if (!reset && this.activeChipSearchMode) {
        if (!this.kioskNextPageToken) {
          return;
        }
        this.isLoadingMore = true;
        const searchService = FeedServiceProvider.getInstance().getSearchService();
        const searchRes = await searchService.fetchNext(this.kioskNextPageToken, startId);
        if (generation !== this.homeLoadGeneration) {
          return;
        }
        const split = this.splitByType(searchRes.items);
        this.longList = this.longList.concat(split.long.length > 0 ? split.long : searchRes.items);
        this.kioskNextPageToken = searchRes.nextPageToken;
        this.syncHomeFeedDataSource();
        return;
      }

      if (this.homeMode === 'kiosk') {
        if (!reset) {
          if (!this.kioskNextPageToken) {
            return;
          }
          this.isLoadingMore = true;
        }
        const homeService = FeedServiceProvider.getInstance().getHomeFeedService();
        const useAuthContinuation = this.homeFeedSource.indexOf('recommended') === 0;
        const feedStyle = UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle);
        const kioskResult = reset
          ? await homeService.fetchHomeKioskInitial(startId, feedStyle)
          : await homeService.fetchHomeKioskNext(
            this.kioskNextPageToken ?? '',
            this.kioskVisitorData,
            startId,
            useAuthContinuation,
            this.homeFeedSource
          );
        if (generation !== this.homeLoadGeneration) {
          logger.info(`[HomeFeed] stage=stale_drop reset=${reset} generation=${generation} `
            + `current=${this.homeLoadGeneration}`);
          return;
        }
        if (reset) {
          let effectiveItems: VideoItem[] = kioskResult.items;
          let effectiveNextToken: string | null = kioskResult.nextPageToken;
          let effectiveVisitor: string = kioskResult.visitorData || '';
          const effectiveSource: string = kioskResult.source || 'kiosk';

          if (preferFreshOnRefresh && this.seenRefreshIds.size > 0) {
            const unseen: VideoItem[] = [];
            const seenFallback: VideoItem[] = [];
            const pickedIds: Set<string> = new Set<string>();
            const isShortTarget = this.isShortMode();
            const countTargetMatches = (arr: VideoItem[]): number => {
              let n = 0;
              for (let i = 0; i < arr.length; i++) {
                if ((arr[i].isShort === true) === isShortTarget) {
                  n++;
                }
              }
              return n;
            };
            for (let i = 0; i < effectiveItems.length; i++) {
              const it = effectiveItems[i];
              const vid = (it.videoId || '').trim();
              if (vid.length > 0 && pickedIds.has(vid)) {
                continue;
              }
              if (vid.length > 0) {
                pickedIds.add(vid);
              }
              if (vid.length > 0 && this.seenRefreshIds.has(vid)) {
                seenFallback.push(it);
              } else {
                unseen.push(it);
              }
            }

            // 若 YouTube 首屏强缓存导致全新视频不足一屏，自动顺着 continuation 多拉 1-2 页补齐新内容。
            const useAuthForExtra = effectiveSource.indexOf('recommended') === 0;
            for (let extra = 0; extra < 2 && countTargetMatches(unseen) < 12 && effectiveNextToken && effectiveNextToken.length > 0; extra++) {
              try {
                const extraRes = await homeService.fetchHomeKioskNext(
                  effectiveNextToken,
                  effectiveVisitor,
                  startId + unseen.length + seenFallback.length + 1,
                  useAuthForExtra,
                  effectiveSource
                );
                if (generation !== this.homeLoadGeneration) {
                  return;
                }
                effectiveNextToken = extraRes.nextPageToken;
                if (extraRes.visitorData && extraRes.visitorData.length > 0) {
                  effectiveVisitor = extraRes.visitorData;
                }
                for (let k = 0; k < extraRes.items.length; k++) {
                  const it = extraRes.items[k];
                  const vid = (it.videoId || '').trim();
                  if (vid.length > 0 && pickedIds.has(vid)) {
                    continue;
                  }
                  if (vid.length > 0) {
                    pickedIds.add(vid);
                  }
                  if (vid.length > 0 && this.seenRefreshIds.has(vid)) {
                    seenFallback.push(it);
                  } else {
                    unseen.push(it);
                  }
                }
              } catch (extraErr) {
                logger.warn(`[HomeRefresh] extra page ${extra + 1} failed: ${this.describeThrowable(extraErr)}`);
                break;
              }
            }

            if (countTargetMatches(unseen) > 0) {
              // 全新视频排在最前；若不足 6 条才在末尾补老视频，避免首屏空白。
              effectiveItems = countTargetMatches(unseen) >= 6 ? unseen : unseen.concat(seenFallback);
            } else {
              // 连续刷新把当前推荐池刷完：清空已看记录自然回卷。
              this.seenRefreshIds.clear();
            }
          }

          const split = this.splitByType(effectiveItems);
          this.longList = split.long;
          this.shortList = split.short;
          this.homeFeedSource = effectiveSource;
          this.homeFeedEpoch += 1;
          this.serverSections = kioskResult.sections ?? [];
          this.myCategoriesFetched = false;
          this.myCategorySections = [];
          this.chips = this.buildMergedChips(kioskResult.chips ?? [], effectiveItems);
          this.selectedChipIndex = 0;
          this.kioskNextPageToken = effectiveNextToken;
          if (effectiveVisitor.length > 0) {
            this.kioskVisitorData = effectiveVisitor;
          }
          this.recordSeenRefreshItems(this.activeList());
          this.scrollHomeFeedToTop();
        } else {
          const split = this.splitByType(kioskResult.items);
          this.longList = this.longList.concat(split.long);
          this.shortList = this.shortList.concat(split.short);
          this.kioskNextPageToken = kioskResult.nextPageToken;
          if (kioskResult.visitorData && kioskResult.visitorData.length > 0) {
            this.kioskVisitorData = kioskResult.visitorData;
          }
        }
        this.syncHomeFeedDataSource();
        this.homeErrorMessage = '';
        this.homeModeNoticeMessage = '';
        if (reset && kioskResult.source === 'kiosk' && feedStyle === 'recommended') {
          const authRejected = AuthSessionManager.getInstance()?.consumeAuthRejectionNotice() === true;
          if (authRejected) {
            // 登录态被拒后已回落到游客 kiosk，提示用户重新登录。
            this.homeModeNoticeMessage = getContext().resourceManager.getStringSync(
              $r('app.string.yt_home_auth_expired_notice').id);
          } else if (AuthSessionManager.getInstance()?.hasAuthForUserData() === true) {
            // 有用户数据权限但推荐源失败/为空时已回退 kiosk：明确提示，
            // 否则用户会以为「推荐/直播」设置没有生效。
            this.homeModeNoticeMessage = getContext().resourceManager.getStringSync(
              $r('app.string.yt_home_recommended_error').id);
          }
        }
        logger.info(`[HomeFeed] stage=load_done reset=${reset} mode=kiosk source=${this.homeFeedSource} `
          + `items=${kioskResult.items.length} long=${this.longList.length} `
          + `short=${this.shortList.length} elapsed=${Date.now() - loadStartedAt}ms`);
        // 短视频维度：
        // - 短视频还不够 → 往后再翻几页 feed，把 Shorts 货架收进来；
        // - feed 已经翻到头（continuation 有限）→ 换「我的频道」的 /shorts 续上。
        if (this.isShortMode()) {
          if (this.shortList.length < HOME_SHORTS_TOPUP_THRESHOLD) {
            this.harvestShortsFromFeed().catch(() => undefined);
          } else if (!this.kioskNextPageToken) {
            this.topUpShortsFromChannels().catch(() => undefined);
          }
        }
        return;
      }
    } catch (err) {
      if (generation !== this.homeLoadGeneration) {
        logger.info(`[HomeFeed] stage=stale_error_drop reset=${reset} generation=${generation} `
          + `current=${this.homeLoadGeneration}`);
        return;
      }
      // Never JSON.stringify(Error) alone — enumerable fields are empty → "{}" in user logs.
      logger.error(`[HomeFeed] stage=failed reset=${reset} mode=${this.homeMode} `
        + `source=${this.homeFeedSource} ${this.describeThrowable(err)}`);
      if (reset && this.homeMode === 'kiosk') {
        const wantedRecommended = UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle) === 'recommended'
          && AuthSessionManager.getInstance()?.hasAuthForUserData() === true;
        const fallbackRes = wantedRecommended
          ? $r('app.string.yt_home_recommended_error')
          : $r('app.string.yt_home_kiosk_error');
        this.homeErrorMessage = this.formatHomeRequestError(
          err as Object,
          getContext().resourceManager.getStringSync(fallbackRes.id)
        );
        if (wantedRecommended) {
          // Keep dual-rail prefix so banner gating (indexOf recommended) still works after error.
          this.homeFeedSource = 'recommended';
        }
      } else {
        this.homeErrorMessage = this.formatHomeRequestError(err as Object, getContext().resourceManager.getStringSync($r('app.string.yt_home_load_error').id));
      }
      // 保留已有列表，避免加载失败时清空
    } finally {
      // 旧代次的收尾不得清掉新请求的 loading 状态。
      if (generation === this.homeLoadGeneration) {
        this.isLoadingMore = false;
        if (reset) {
          this.isInitialLoading = false;
        }
      }
    }
  }

  private async refreshHomeFeed(): Promise<void> {
    // Refresh sets the two-way bound value before invoking onRefreshing.
    // Always perform the work and clear it in finally.
    logger.info(`[HomeRefresh] stage=start mode=${this.homeMode} source=${this.homeFeedSource}`);
    const startedAt = Date.now();
    const prevHead = this.activeList().length > 0
      ? (this.activeList()[0].videoId || this.activeList()[0].id.toString())
      : '';
    try {
      this.recordSeenRefreshItems(this.activeList());
      this.kioskNextPageToken = null;
      this.kioskVisitorData = '';
      if (this.isMyCategoriesSelected()) {
        const homeService = FeedServiceProvider.getInstance().getHomeFeedService();
        const feedStyle = UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle);
        const kioskResult = await homeService.fetchHomeKioskInitial(1, feedStyle);
        this.serverSections = kioskResult.sections ?? [];
        this.chips = this.buildMergedChips(kioskResult.chips ?? [], kioskResult.items);
        await this.loadMyCategoriesSections(true);
      } else if (this.selectedChipIndex > 0 && this.selectedChipIndex < this.chips.length) {
        await this.doLoadChipVideos(this.chips[this.selectedChipIndex]);
      } else {
        await this.loadLiveVideos(true, true);
      }
      const nextHead = this.activeList().length > 0
        ? (this.activeList()[0].videoId || this.activeList()[0].id.toString())
        : '';
      logger.info(`[HomeRefresh] stage=complete mode=${this.homeMode} source=${this.homeFeedSource} `
        + `elapsed=${Date.now() - startedAt}ms items=${this.activeList().length} head=${nextHead} `
        + `changed=${prevHead !== nextHead} error=${this.homeErrorMessage.length > 0 ? 'yes' : 'no'}`);
    } catch (e) {
      logger.error(`[HomeRefresh] stage=failed elapsed=${Date.now() - startedAt}ms ${this.describeThrowable(e)}`);
    } finally {
      this.isHomeRefreshing = false;
    }
  }

  private scrollHomeFeedToTop(): void {
    this.isChipBarVisible = true;
    this.chipScrollAccumY = 0;
    try {
      if (this.uiConfig.homeLayoutMode === 'grid') {
        this.controller.gridScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
      } else {
        this.controller.listScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
      }
    } catch (e) {
      logger.warn(`[HomeRefresh] scrollToTop failed: ${JSON.stringify(e)}`);
    }
  }

  /** LazyForEach 稳定 key：videoId 即身份；下拉刷新的整列重建由数据源 onDataReloaded 负责 */
  private homeListItemKey(item: VideoItem): string {
    const videoId = (item.videoId || '').trim();
    return videoId.length > 0 ? videoId : item.id.toString();
  }

  /**
   * feed 到顶后的续供：取「我的频道」的 /shorts 标签页。
   *
   * 频道池 = 订阅频道 → 观看历史里的频道（去重，最多 20 个）。这些频道跟账号
   * 相关，不是泛搜索那种批量内容；每个频道的 Shorts 标签独立分页，能一直翻。
   *
   * **每轮只并发查 N 个频道**（`HOME_SHORTS_CHANNEL_FETCH_PER_ROUND`），
   * 频道池按游标轮转 —— 把整个池子串行查一遍要十几秒，滑动会被拖死。
   *
   * 多频道的条目**轮转交织**后再并入列表 —— 否则一个频道的几十条会把
   * 列表前半段刷成"同一个作者"（这正是全屏 Shorts 页当初的问题）。
   */
  private async topUpShortsFromChannels(): Promise<void> {
    if (this.shortsChannelTopUpInFlight) {
      return;
    }
    this.shortsChannelTopUpInFlight = true;
    const startedAt = Date.now();
    try {
      if (this.shortsChannels.length === 0) {
        this.shortsChannels = this.buildAccountChannelStates();
        logger.info(`[HomeFeed] stage=shorts_channels pool=${this.shortsChannels.length}`);
      }
      if (this.shortsChannels.length === 0) {
        return;
      }
      const picked = this.pickChannelsForRound();
      if (picked.length === 0) {
        logger.info(`[HomeFeed] stage=shorts_channel_topup skipped=all_exhausted`);
        return;
      }
      const service = FeedServiceProvider.getInstance().getChannelService();
      // 并发查本轮选中的频道（browse 请求彼此独立，可以并发）。
      const pages: Array<Array<VideoItem>> = await Promise.all(
        picked.map(async (state: ShortsChannelState): Promise<Array<VideoItem>> => {
          try {
            const result = state.token.length > 0
              ? await service.fetchChannelShortsNext(state.token, state.visitor, this.shortsIdCursor)
              : await service.fetchChannelShortsInitial(state.channelId, this.shortsIdCursor);
            state.token = result.nextPageToken ?? '';
            state.visitor = result.visitorData || state.visitor;
            if (state.token.length === 0) {
              state.exhausted = true;
            }
            // /shorts 标签页里的东西按定义就是短视频。
            const shorts: Array<VideoItem> = [];
            for (let k = 0; k < result.items.length; k++) {
              result.items[k].isShort = true;
              shorts.push(result.items[k]);
            }
            return shorts;
          } catch (e) {
            logger.warn(`[HomeFeed] stage=shorts_channel_failed channel=${state.channelId} `
              + `${this.describeThrowable(e)}`);
            state.exhausted = true;
            return [];
          }
        })
      );
      const nonEmpty: Array<Array<VideoItem>> = [];
      for (let i = 0; i < pages.length; i++) {
        if (pages[i].length > 0) {
          nonEmpty.push(pages[i]);
        }
      }
      const merged = this.interleaveByChannel(nonEmpty, HOME_SHORTS_CHANNEL_BATCH);
      const seen = new Set<string>();
      for (let i = 0; i < this.shortList.length; i++) {
        seen.add(this.shortList[i].videoId);
      }
      const added: Array<VideoItem> = [];
      for (let i = 0; i < merged.length; i++) {
        const videoId = merged[i].videoId;
        if (!videoId || seen.has(videoId)) {
          continue;
        }
        seen.add(videoId);
        added.push(merged[i]);
      }
      if (added.length > 0) {
        this.shortList = this.shortList.concat(added);
        if (this.isShortMode()) {
          this.syncHomeFeedDataSource();
        }
      }
      logger.info(`[HomeFeed] stage=shorts_channel_topup added=${added.length} `
        + `total=${this.shortList.length} channels=${nonEmpty.length}/${picked.length} `
        + `elapsed=${Date.now() - startedAt}ms`);
    } catch (e) {
      logger.warn(`[HomeFeed] stage=shorts_channel_topup_failed ${this.describeThrowable(e)}`);
    } finally {
      this.shortsChannelTopUpInFlight = false;
    }
  }

  /**
   * 本轮要查的频道：从游标开始轮转，跳过已翻完的，最多 N 个。
   * 游标推进 → 下一轮自然换一批频道（既能持续供给，作者也更多样）。
   */
  private pickChannelsForRound(): ShortsChannelState[] {
    const picked: ShortsChannelState[] = [];
    const total = this.shortsChannels.length;
    for (let i = 0; i < total && picked.length < HOME_SHORTS_CHANNEL_FETCH_PER_ROUND; i++) {
      const index = (this.shortsChannelCursor + i) % total;
      const state = this.shortsChannels[index];
      if (!state.exhausted) {
        picked.push(state);
      }
    }
    if (total > 0) {
      this.shortsChannelCursor = (this.shortsChannelCursor + picked.length) % total;
    }
    return picked;
  }

  /** 频道池：订阅频道优先，其次观看历史里的频道（去重、限量）。 */
  private buildAccountChannelStates(): ShortsChannelState[] {
    const ids: string[] = [];
    const push = (id: string): void => {
      const trimmed = (id || '').trim();
      if (trimmed.length > 0 && ids.indexOf(trimmed) < 0) {
        ids.push(trimmed);
      }
    };
    try {
      const subs = AppStorage.get<Array<SubscriptionUser>>('subscriptions');
      if (subs) {
        for (let i = 0; i < subs.length; i++) {
          push(subs[i].channelId);
        }
      }
    } catch (e) {
      logger.warn(`[HomeFeed] stage=shorts_channels_subs_failed ${this.describeThrowable(e)}`);
    }
    try {
      const history = WatchHistoryStore.getAll();
      for (let i = 0; i < history.length; i++) {
        push(history[i].channelId);
      }
    } catch (e) {
      logger.warn(`[HomeFeed] stage=shorts_channels_history_failed ${this.describeThrowable(e)}`);
    }
    const states: ShortsChannelState[] = [];
    for (let i = 0; i < ids.length && states.length < HOME_SHORTS_MAX_CHANNELS; i++) {
      states.push({ channelId: ids[i], token: '', visitor: '', exhausted: false });
    }
    return states;
  }

  /** 多个频道的条目轮转交织（每个频道轮流出一条），避免整屏同一个作者。 */
  private interleaveByChannel(lists: Array<Array<VideoItem>>, limit: number): Array<VideoItem> {
    const out: Array<VideoItem> = [];
    let index = 0;
    while (out.length < limit) {
      let progressed = false;
      for (let i = 0; i < lists.length; i++) {
        if (index < lists[i].length) {
          out.push(lists[i][index]);
          progressed = true;
        }
        if (out.length >= limit) {
          break;
        }
      }
      if (!progressed) {
        break;
      }
      index += 1;
    }
    return out;
  }

  /**
   * 一页 feed 按 `isShort` 拆成两份：长视频列表 + 短视频列表。
   *
   * 两份列表来自**同一次请求**（首页 feed 的 Shorts 货架就在里面），所以切换
   * 维度不需要重新请求；短视频那份的作者分布也跟首页一致（多作者），不会
   * 出现"整页都是同一个频道"。
   */
  private splitByType(items: VideoItem[]): HomeFeedSplit {
    const long: VideoItem[] = [];
    const short: VideoItem[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].isShort === true) {
        short.push(items[i]);
      } else {
        long.push(items[i]);
      }
    }
    if (short.length > 0) {
      logger.info(`[HomeFeed] stage=split long=${long.length} short=${short.length}`);
    }
    return { long: long, short: short };
  }

  /** 当前维度（'long' | 'short'）。 */
  private isShortMode(): boolean {
    return this.feedMode === 'short';
  }

  /** 当前维度对应的列表。 */
  private activeList(): VideoItem[] {
    return this.isShortMode() ? this.shortList : this.longList;
  }

  /**
   * 短视频补收：**只从首页那份混合 feed 里收**（长视频 + 短视频本来就混在一页里）。
   *
   * 首页 feed 的 Shorts 货架位置不固定（有时在首屏、有时要往后翻几页才碰到），
   * 所以短视频维度下会自动多翻几页，把里面的短视频收进 `shortList`。
   *
   * 不用泛搜索（搜 "shorts" 的关键词结果）补货 —— 那些内容跟账号无关，
   * 混进来会破坏"短视频列表 = 我的 feed 里的短视频"这个语义。
   */
  private async harvestShortsFromFeed(): Promise<void> {
    if (this.shortsHarvestInFlight) {
      return;
    }
    this.shortsHarvestInFlight = true;
    const startedAt = Date.now();
    let pages = 0;
    try {
      for (let i = 0; i < HOME_SHORTS_HARVEST_PAGES; i++) {
        if (this.shortList.length >= HOME_SHORTS_HARVEST_TARGET) {
          break;
        }
        // 等当前分页请求结束再要下一页（loadLiveVideos 对并发请求会直接返回）。
        await this.feedLoadInFlight;
        if (!this.kioskNextPageToken) {
          // feed 翻到头了（YouTube 的推荐流 continuation 是有限的）→ 换成
          // 「我的频道」的 /shorts 标签页续上（见 topUpShortsFromChannels）。
          await this.topUpShortsFromChannels();
          break;
        }
        const before = this.shortList.length;
        await this.loadLiveVideos(false);
        pages += 1;
        if (this.shortList.length > before) {
          // 这一页带出了短视频（Shorts 货架找到了）→ 不用再往后翻。
          break;
        }
      }
      logger.info(`[HomeFeed] stage=shorts_harvest short=${this.shortList.length} `
        + `pages=${pages} elapsed=${Date.now() - startedAt}ms`);
    } catch (e) {
      logger.warn(`[HomeFeed] stage=shorts_harvest_failed ${this.describeThrowable(e)}`);
    } finally {
      this.shortsHarvestInFlight = false;
    }
  }

  /** 首页列表数据 → LazyForEach 数据源；追加=增量，reset=全量刷新 */
  private syncHomeFeedDataSource(): void {
    this.homeFeedDataSource.setData(this.getHomeListVideos(), (item: Object) => this.homeListItemKey(item as VideoItem));
  }

  /** Safe one-line error for hilog / exported app logs (Error → not "{}"). */
  private describeThrowable(err: Object | Error | string | undefined | null): string {
    if (err === undefined || err === null) {
      return 'error=null';
    }
    if (typeof err === 'string') {
      return `error=${err}`;
    }
    if (err instanceof Error) {
      const name = err.name || 'Error';
      const msg = err.message || '';
      return `name=${name} message=${msg}`;
    }
    if (typeof err === 'object') {
      const anyErr = err as Record<string, Object>;
      const parts: string[] = [];
      const name = anyErr['name'];
      const message = anyErr['message'];
      const code = anyErr['code'];
      const errorType = anyErr['errorType'];
      const url = anyErr['url'];
      const method = anyErr['method'];
      if (typeof name === 'string' && name.length > 0) {
        parts.push(`name=${name}`);
      }
      if (typeof message === 'string' && message.length > 0) {
        parts.push(`message=${message}`);
      }
      if (typeof code === 'number' || typeof code === 'string') {
        parts.push(`code=${String(code)}`);
      }
      if (typeof errorType === 'string' && errorType.length > 0) {
        parts.push(`errorType=${errorType}`);
      }
      if (typeof method === 'string' && method.length > 0) {
        parts.push(`method=${method}`);
      }
      if (typeof url === 'string' && url.length > 0) {
        // Host+path only — no query/cookies.
        const m = /^(https?:\/\/[^/?#]+)([^?#]*)/.exec(url);
        parts.push(`target=${m ? `${m[1]}${m[2] || '/'}` : '(url)'}`);
      }
      if (parts.length > 0) {
        return parts.join(' ');
      }
      try {
        const raw = JSON.stringify(err);
        if (raw && raw !== '{}' && raw !== 'null') {
          return `error=${raw}`;
        }
      } catch (_e) {
        // ignore
      }
    }
    return `error=${String(err)}`;
  }

  private formatHomeRequestError(err: Object, fallback: string): string {
    let code = '';
    let message = '';
    if (err instanceof Error) {
      message = err.message || '';
      const name = err.name || '';
      if (name.length > 0 && name !== 'Error') {
        code = name;
      }
    } else if (err && typeof err === 'object') {
      const anyErr = err as Record<string, Object>;
      const errorCode = anyErr['code'];
      const errorMessage = anyErr['message'];
      const errorType = anyErr['errorType'];
      if (typeof errorCode === 'number' || typeof errorCode === 'string') {
        code = String(errorCode);
      } else if (typeof errorType === 'string' && errorType.length > 0) {
        code = errorType;
      }
      if (typeof errorMessage === 'string') {
        message = errorMessage;
      }
    }
    if (!message || message.length === 0) {
      message = fallback;
    }
    return code.length > 0 ? `[${code}] ${message}` : message;
  }

  /**
   * 组合顶部分类栏与「我的分类」动态推荐项：
   * 1. 顶部栏（this.chips）保持固定预设分类（全部 / 我的分类 / 音乐 / 游戏 / 合辑 / 直播 / 自然 / 旅游 / ...），
   *    若服务端返回同名 Chip 则复用其 continuationToken；
   * 2. 官方推荐流返回的动态分类 Chip、货架类别及推荐视频中的热门 #话题 / 频道主题单独存入
   *    this.recommendedExtraChips，供「我的分类」页签展开成带 Header 的分组视频列表展示。
   */
  private buildMergedChips(serverChips: Array<HomeFeedChip>, items: Array<VideoItem>): Array<HomeFeedChip> {
    const serverByLabel = new Map<string, HomeFeedChip>();
    for (let i = 0; i < serverChips.length; i++) {
      const sc = serverChips[i];
      const lbl = (sc.label || '').trim();
      if (lbl.length > 0 && !serverByLabel.has(lbl)) {
        serverByLabel.set(lbl, sc);
      }
    }

    const merged: Array<HomeFeedChip> = [];
    const seenPreset = new Set<string>();

    // 1. 顶部栏：前置官方核心分类（含「全部」与「我的分类」）+ 尾部预设分类
    const allPresets = FRONT_OFFICIAL_CHIPS.concat(TAIL_OFFICIAL_CHIPS);
    for (let i = 0; i < allPresets.length; i++) {
      const base = allPresets[i];
      if (seenPreset.has(base.label)) {
        continue;
      }
      const matched = serverByLabel.get(base.label);
      seenPreset.add(base.label);
      merged.push({
        label: base.label,
        continuationToken: (i === 0 || base.isMyCategories) ? '' : (matched?.continuationToken ?? base.continuationToken),
        isSelected: i === 0,
        searchQuery: base.searchQuery || base.label,
        isMyCategories: base.isMyCategories
      });
    }

    // 2. 提取官方推荐给我们的额外分类条目（仅放入「我的分类」recommendedExtraChips）
    this.recommendedExtraChips = [];
    const seenExtra = new Set<string>(seenPreset);
    seenExtra.add('合辑');
    seenExtra.add('Mixes');

    for (let i = 0; i < serverChips.length; i++) {
      const sc = serverChips[i];
      const lbl = (sc.label || '').trim();
      if (!lbl || seenExtra.has(lbl) || lbl.toLowerCase() === 'all') {
        continue;
      }
      seenExtra.add(lbl);
      this.recommendedExtraChips.push({
        label: lbl,
        continuationToken: sc.continuationToken || '',
        isSelected: false,
        searchQuery: sc.searchQuery || lbl
      });
    }

    this.appendExtraChipsFromItems(items);
    return merged;
  }

  /**
   * 从推荐流视频条目中提取热门 #话题 标签与推荐频道/主题词，追加至 recommendedExtraChips。
   */
  private appendExtraChipsFromItems(items: Array<VideoItem>): void {
    if (!items || items.length === 0) {
      return;
    }
    const existing = new Set<string>();
    for (let i = 0; i < FALLBACK_CHIPS.length; i++) {
      existing.add(FALLBACK_CHIPS[i].label);
    }
    for (let i = 0; i < this.recommendedExtraChips.length; i++) {
      existing.add(this.recommendedExtraChips[i].label);
    }

    const tagRegex = /#([\u4e00-\u9fa5A-Za-z0-9_]{2,12})/g;
    for (let i = 0; i < items.length; i++) {
      const title = items[i].title || '';
      let match: RegExpExecArray | null = tagRegex.exec(title);
      while (match !== null) {
        const tag = match[1].trim();
        if (tag.length >= 2 && tag.toLowerCase() !== 'shorts' && !existing.has(tag)) {
          existing.add(tag);
          this.recommendedExtraChips.push({
            label: tag,
            continuationToken: '',
            isSelected: false,
            searchQuery: tag
          });
        }
        match = tagRegex.exec(title);
      }
    }

    for (let i = 0; i < items.length; i++) {
      const author = (items[i].author || '').trim();
      if (author.length >= 2 && author.length <= 18 && !existing.has(author)) {
        existing.add(author);
        this.recommendedExtraChips.push({
          label: author,
          continuationToken: '',
          isSelected: false,
          searchQuery: author
        });
      }
    }
  }

  private gridColumns(): number {
    return getVideoGridColumnCount(getFeedContentWidthVp(this.getUIContext(), this.deviceWidth),
      UIConfig.gridDensityOffset(this.uiConfig.homeGridDensity));
  }

  private shouldShowHomeRecommendBanner(): boolean {
    return false;
  }

  private getHomeBannerVideos(): VideoItem[] {
    return [];
  }

  private getHomeListVideos(): VideoItem[] {
    return this.activeList();
  }

  @LocalBuilder
  HomeVideoGridCard(slot: MediaFeedItemSlot) {
    VideoCardGrid({
      video: slot.item as VideoItem,
      actionLabel: $r('app.string.yt_action_favorite'),
      actionType: 'favorite',
      useFavoriteToggle: true
    })
  }

  /** 条式卡片：卡片左右 12vp 内边距按原行为在卡片侧（banner 不被内缩） */
  @LocalBuilder
  HomeVideoListCard(slot: MediaFeedItemSlot) {
    Column() {
      VideoCard({
        video: slot.item as VideoItem,
        actionLabel: $r('app.string.yt_action_favorite'),
        actionType: 'favorite',
        useFavoriteToggle: true
      })
    }
    .padding({ left: 12, right: 12 })
  }

  /** 推荐位 banner：已替换为顶部分类 Chip 栏 */
  @LocalBuilder
  HomeBannerHeader() {
    HomeRecommendSwiper({
      videos: this.getHomeBannerVideos(),
      feedEpoch: this.homeFeedEpoch
    })
  }

  /**
   * 列表滚动联动顶部分类 Chip 栏：向下浏览时平滑收起，向上回滚时立即唤出。
   */
  private handleFeedWillScroll(yOffset: number): void {
    if (Math.abs(yOffset) < 0.5) {
      return;
    }
    const scroller = (!this.isMyCategoriesSelected() && this.uiConfig.homeLayoutMode === 'grid')
      ? this.controller.gridScroller
      : this.controller.listScroller;
    let currentY = 999;
    try {
      const offset = scroller.currentOffset();
      if (offset && typeof offset.yOffset === 'number') {
        currentY = offset.yOffset;
      }
    } catch (_e) {
      // ignore
    }
    // 处于列表顶部附近时始终展开分类栏
    if (currentY <= 12) {
      this.chipScrollAccumY = 0;
      if (!this.isChipBarVisible) {
        this.isChipBarVisible = true;
      }
      return;
    }
    if ((this.chipScrollAccumY > 0 && yOffset < 0) || (this.chipScrollAccumY < 0 && yOffset > 0)) {
      this.chipScrollAccumY = 0;
    }
    this.chipScrollAccumY += yOffset;
    if (this.chipScrollAccumY > 28 && this.isChipBarVisible) {
      this.isChipBarVisible = false;
      this.chipScrollAccumY = 0;
    } else if (this.chipScrollAccumY < -14 && !this.isChipBarVisible) {
      this.isChipBarVisible = true;
      this.chipScrollAccumY = 0;
    }
  }

  @Builder
  ChipFilterBar() {
    Column() {
      Scroll(this.chipScroller) {
        Row({ space: 10 }) {
          ForEach(this.chips, (chip: HomeFeedChip, index: number) => {
            Text(chip.label)
              .fontSize(14)
              .fontWeight(this.selectedChipIndex === index ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.selectedChipIndex === index
                ? $r('app.color.yourtube_text_inverse')
                : $r('app.color.yourtube_text_primary'))
              .backgroundColor(this.selectedChipIndex === index
                ? this.themePrimary
                : Color.Transparent)
              .borderRadius(8)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
              .onClick(() => {
                this.onSelectChip(index);
              })
          }, (chip: HomeFeedChip, index: number) => `${index}_${chip.label}`)
        }
        .padding({ left: 16, right: 16, top: 6, bottom: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .nestedScroll({
        scrollForward: NestedScrollMode.SELF_ONLY,
        scrollBackward: NestedScrollMode.SELF_ONLY
      })
      .width('100%')
    }
    .width('100%')
    .height(this.isChipBarVisible ? 44 : 0)
    .opacity(this.isChipBarVisible ? 1 : 0)
    .clip(true)
    .animation({ duration: 200, curve: Curve.FastOutSlowIn })
    .backgroundColor($r('app.color.yourtube_bg_page'))
    .zIndex(10)
  }

  @Builder LoadingBuilder() {
    LoadingProgress()
      .color(this.themePrimary)
      .width(40)
      .height(40)
      .margin({ bottom: 15 })
  }

  /**
   * 「我的分类」展开式分组大列表：
   * 每个分组由上方的页签/分类名称 Header 与下方的视频卡片（网格或条式）共同组成。
   */
  @Builder
  MyCategoriesSectionedView() {
    if (this.isMyCategoriesLoading && this.myCategorySections.length === 0) {
      Column() {
        this.LoadingBuilder()
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      List({ scroller: this.controller.listScroller, space: 18 }) {
        ForEach(this.myCategorySections, (section: HomeFeedSection, secIndex: number) => {
          ListItem() {
            Column({ space: 10 }) {
              // 分组顶部 Header（页签名称 + 跳转当前分类）
              Row() {
                Row()
                  .width(4)
                  .height(18)
                  .borderRadius(2)
                  .backgroundColor(this.themePrimary)
                  .margin({ right: 8 })

                Text(section.title)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.yourtube_text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)

                if (section.chipIndex !== undefined && section.chipIndex >= 2) {
                  Row({ space: 4 }) {
                    Text('更多')
                      .fontSize(13)
                      .fontColor($r('app.color.yourtube_text_secondary'))
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(13)
                      .fontColor([$r('app.color.yourtube_text_secondary')])
                  }
                  .padding({ left: 8, right: 4, top: 4, bottom: 4 })
                  .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
                  .onClick(() => {
                    if (section.chipIndex !== undefined) {
                      this.onSelectChip(section.chipIndex);
                    }
                  })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 4, right: 4, top: 4 })

              // 分组下方视频条目（跟随首页网格/列表布局）
              if (this.uiConfig.homeLayoutMode === 'grid') {
                GridRow({
                  columns: this.gridColumns(),
                  gutter: { x: 8, y: 8 }
                }) {
                  ForEach(section.items, (video: VideoItem, vIndex: number) => {
                    GridCol({ span: 1 }) {
                      VideoCardGrid({
                        video: video,
                        actionLabel: $r('app.string.yt_action_favorite'),
                        actionType: 'favorite',
                        useFavoriteToggle: true
                      })
                    }
                  }, (video: VideoItem, vIndex: number) => `${secIndex}_${vIndex}_${video.videoId || video.id}`)
                }
                .width('100%')
              } else {
                Column({ space: 4 }) {
                  ForEach(section.items, (video: VideoItem, vIndex: number) => {
                    VideoCard({
                      video: video,
                      actionLabel: $r('app.string.yt_action_favorite'),
                      actionType: 'favorite',
                      useFavoriteToggle: true
                    })
                  }, (video: VideoItem, vIndex: number) => `${secIndex}_${vIndex}_${video.videoId || video.id}`)
                }
                .width('100%')
              }
            }
            .width('100%')
          }
        }, (section: HomeFeedSection, secIndex: number) => `sec_${secIndex}_${section.title}_${section.items.length}`)

        if (this.isMyCategoriesLoading) {
          ListItem() {
            Row() {
              LoadingProgress()
                .color(this.themePrimary)
                .width(28)
                .height(28)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 12, bottom: 12 })
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 12, right: 12, top: 4, bottom: this.safeAreaBottom + 72 })
      .clip(true)
      .edgeEffect(EdgeEffect.Spring)
      .onWillScroll((yOffset: number) => {
        this.handleFeedWillScroll(yOffset);
      })
      .onReachEnd(() => {
        this.loadMoreMyCategoriesSections().catch(() => undefined);
      })
    }
  }

  build() {
    Stack() {
      if (this.homeErrorMessage.length > 0 && this.activeList().length === 0) {
        // 显示完整页面的错误页面
        ErrorPage({
          errorMessage: this.homeErrorMessage,
          onRetry: () => {
            this.loadLiveVideos(true);
          }
        })
      } else {
        Column() {
          if (!this.isShortMode() && this.chips.length > 0) {
            this.ChipFilterBar()
          }

          Refresh({ refreshing: $$this.isHomeRefreshing }) {
            Column() {
              if (this.homeModeNoticeMessage.length > 0) {
                Text(this.homeModeNoticeMessage)
                  .fontSize(12)
                  .fontColor(this.themePrimary)
                  .margin({ top: 4, bottom: 4, left: 16, right: 16 })
              }

              if (this.isMyCategoriesSelected()) {
                this.MyCategoriesSectionedView()
              } else {
                MediaVideoFeed({
                  dataSource: this.homeFeedDataSource,
                  gridScroller: this.controller.gridScroller,
                  listScroller: this.controller.listScroller,
                  itemKey: (item: Object) => this.homeListItemKey(item as VideoItem),
                  gridItemBuilder: this.HomeVideoGridCard,
                  itemBuilder: this.HomeVideoListCard,
                  headerBuilder: this.HomeBannerHeader,
                  onWillScroll: (yOffset: number) => {
                    this.handleFeedWillScroll(yOffset);
                  },
                  onReachEnd: () => {
                    this.loadLiveVideos(false);
                    // 短视频维度：往后再翻几页混合 feed，把里面的短视频收进来。
                    if (this.isShortMode()) {
                      this.harvestShortsFromFeed().catch(() => undefined);
                    }
                  },
                  params: {
                    layoutPreference: this.uiConfig.homeLayoutMode,
                    gridColumns: this.gridColumns(),
                    // 首页条式恒单列（无宽列分支）
                    listColumns: 1,
                    isLoading: false,
                    // 原网格分支无加载更多 footer，保持不显示
                    isLoadingMore: this.uiConfig.homeLayoutMode === 'grid' ? false : this.isLoadingMore,
                    errorMessage: '',
                    emptyText: '',
                    hasHeader: false,
                    headerHorizontalBleed: 12,
                    gridContentPadding: { left: 12, right: 12, top: 4, bottom: this.safeAreaBottom + 72 },
                    listContentEndOffset: this.safeAreaBottom + 72,
                    // 空列表也保持可滚动（下拉刷新可用）
                    stateScrollable: true,
                    // 上方有 homeModeNoticeMessage 兄弟节点
                    useLayoutWeight: true,
                    // 严格裁剪顶部边界，防止下滑时视频卡片越界遮挡置顶的 ChipFilterBar
                    clipContent: true,
                    scrollBarOff: false
                  }
                })
              }
            }
            .width('100%')
            .height('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .pullToRefresh(true)
          .refreshOffset(64)
          .onRefreshing(() => {
            this.refreshHomeFeed();
          })
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.safeAreaTop + 56 })
      }

      if (this.isInitialLoading) {
        Column() {
          this.LoadingBuilder()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.yourtube_bg_overlay'))
      }
    }
  }
}
