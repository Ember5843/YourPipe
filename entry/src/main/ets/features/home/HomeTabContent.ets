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
import { COLOR_PRESETS } from '../../common/ThemeManager';

const logger = AppLog.getInstance('HomeTabContent');

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
}

/**
 * 首页 tab 内容宿主：feed 加载状态机（kiosk/推荐双轨 + 分页 + 下拉刷新）、
 * 错误格式化、推荐位 banner、错误页 / 信息流 / 初始加载遮罩三档视图。
 * 原 Index.TabContentSection(0) 分支纯迁移；Index 经 HomeTabController 触发 reset。
 */
@Component
export struct HomeTabContent {
  controller: HomeTabController = new HomeTabController();
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @StorageProp('themePrimaryColor') themePrimary: string = COLOR_PRESETS[0].primary;
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @State videoList: VideoItem[] = [];
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
  /** 首页信息流 LazyForEach 数据源：videoList 变更后由 syncHomeFeedDataSource 同步 */
  private homeFeedDataSource: FeedDataSource = new FeedDataSource();
  private homeBannerMax: number = 6;

  aboutToAppear() {
    this.controller.registerReset((clearList: boolean, reload: boolean) => {
      this.resetHomeFeed(clearList, reload);
    });
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
    if (clearList) {
      this.videoList = [];
      this.syncHomeFeedDataSource();
    }
    if (reload) {
      this.loadLiveVideos(true);
    }
  }

  private async loadLiveVideos(reset: boolean = false) {
    if (reset) {
      this.isLoadingMore = false;
      this.isInitialLoading = this.videoList.length === 0;
      this.homeErrorMessage = '';
    } else {
      if (this.isLoadingMore) {
        return;
      }
    }

    const startId = reset ? 1 : (this.videoList.length + 1);
    const loadStartedAt = Date.now();
    logger.info(`[HomeFeed] stage=load_start reset=${reset} mode=${this.homeMode} `
      + `source=${this.homeFeedSource} startId=${startId} listLen=${this.videoList.length}`);
    try {
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
        if (reset) {
          this.videoList = kioskResult.items;
          this.homeFeedSource = kioskResult.source || 'kiosk';
          this.homeFeedEpoch += 1;
          this.scrollHomeFeedToTop();
        } else {
          this.videoList = this.videoList.concat(kioskResult.items);
        }
        this.syncHomeFeedDataSource();
        this.kioskNextPageToken = kioskResult.nextPageToken;
        if (kioskResult.visitorData && kioskResult.visitorData.length > 0) {
          this.kioskVisitorData = kioskResult.visitorData;
        }
        this.homeErrorMessage = '';
        this.homeModeNoticeMessage = '';
        if (reset
          && kioskResult.source === 'kiosk'
          && feedStyle === 'recommended'
          && AuthSessionManager.getInstance()?.consumeAuthRejectionNotice() === true) {
          // 登录态被拒后已回落到游客 kiosk，提示用户重新登录。
          this.homeModeNoticeMessage = getContext().resourceManager.getStringSync(
            $r('app.string.yt_home_auth_expired_notice').id);
        }
        logger.info(`[HomeFeed] stage=load_done reset=${reset} mode=kiosk source=${this.homeFeedSource} `
          + `items=${kioskResult.items.length} listLen=${this.videoList.length} `
          + `elapsed=${Date.now() - loadStartedAt}ms`);
        return;
      }
    } catch (err) {
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
      this.isLoadingMore = false;
      if (reset) {
        this.isInitialLoading = false;
      }
    }
  }

  private async refreshHomeFeed(): Promise<void> {
    // Refresh sets the two-way bound value before invoking onRefreshing.
    // Always perform the work and clear it in finally.
    logger.info(`[HomeRefresh] stage=start mode=${this.homeMode} source=${this.homeFeedSource}`);
    const startedAt = Date.now();
    const prevHead = this.videoList.length > 0
      ? (this.videoList[0].videoId || this.videoList[0].id.toString())
      : '';
    try {
      this.kioskNextPageToken = null;
      this.kioskVisitorData = '';
      await this.loadLiveVideos(true);
      const nextHead = this.videoList.length > 0
        ? (this.videoList[0].videoId || this.videoList[0].id.toString())
        : '';
      logger.info(`[HomeRefresh] stage=complete mode=${this.homeMode} source=${this.homeFeedSource} `
        + `elapsed=${Date.now() - startedAt}ms items=${this.videoList.length} head=${nextHead} `
        + `changed=${prevHead !== nextHead} error=${this.homeErrorMessage.length > 0 ? 'yes' : 'no'}`);
    } catch (e) {
      logger.error(`[HomeRefresh] stage=failed elapsed=${Date.now() - startedAt}ms ${this.describeThrowable(e)}`);
    } finally {
      this.isHomeRefreshing = false;
    }
  }

  private scrollHomeFeedToTop(): void {
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

  /** 首页列表数据（过滤 banner 后）→ LazyForEach 数据源；追加=增量，reset=全量刷新 */
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

  private gridColumns(): number {
    return getVideoGridColumnCount(getFeedContentWidthVp(this.getUIContext(), this.deviceWidth));
  }

  private shouldShowHomeRecommendBanner(): boolean {
    // Dual-rail sources: recommended | recommended-web | recommended-tv
    return this.homeMode === 'kiosk'
      && this.homeFeedSource.indexOf('recommended') === 0
      && this.videoList.length > 0;
  }

  private getHomeBannerVideos(): VideoItem[] {
    if (!this.shouldShowHomeRecommendBanner()) {
      return [];
    }
    const limit = Math.min(this.homeBannerMax, this.videoList.length);
    return this.videoList.slice(0, limit);
  }

  private getHomeListVideos(): VideoItem[] {
    if (!this.shouldShowHomeRecommendBanner()) {
      return this.videoList;
    }
    const bannerIds: string[] = [];
    const banners = this.getHomeBannerVideos();
    for (let i = 0; i < banners.length; i++) {
      const id = (banners[i].videoId || banners[i].id.toString()).trim();
      if (id.length > 0) {
        bannerIds.push(id);
      }
    }
    return this.videoList.filter((item: VideoItem) => {
      const id = (item.videoId || item.id.toString()).trim();
      return bannerIds.indexOf(id) < 0;
    });
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

  /** 推荐位 banner：grid 模式经 headerHorizontalBleed 抵消容器左右 12vp 内边距保持全宽；底部间距补齐到原 12vp */
  @LocalBuilder
  HomeBannerHeader() {
    HomeRecommendSwiper({
      videos: this.getHomeBannerVideos(),
      feedEpoch: this.homeFeedEpoch
    })
      .padding({ bottom: this.uiConfig.homeLayoutMode === 'grid' ? 4 : 8 })
      // 插入-only 转场：禁止删除方向缩放（Grid 骨架切换/hasHeader 翻转时不再播"缩小消失"幽灵）
      .transition(customAnimationUtil.isScaleTranEnter(`home_recommend_banner_${this.homeFeedEpoch}`, this.uiConfig))
  }

  @Builder LoadingBuilder() {
    LoadingProgress()
      .color(this.themePrimary)
      .width(40)
      .height(40)
      .margin({ bottom: 15 })
  }

  build() {
    Stack() {
      if (this.homeErrorMessage.length > 0 && this.videoList.length === 0) {
        // 显示完整页面的错误页面
        ErrorPage({
          errorMessage: this.homeErrorMessage,
          onRetry: () => {
            this.loadLiveVideos(true);
          }
        })
      } else {
        Refresh({ refreshing: $$this.isHomeRefreshing }) {
          Column() {
          if (this.homeModeNoticeMessage.length > 0) {
            Text(this.homeModeNoticeMessage)
              .fontSize(12)
              .fontColor(this.themePrimary)
              .margin({ top: 8, left: 16, right: 16 })
          }

          MediaVideoFeed({
            dataSource: this.homeFeedDataSource,
            gridScroller: this.controller.gridScroller,
            listScroller: this.controller.listScroller,
            itemKey: (item: Object) => this.homeListItemKey(item as VideoItem),
            gridItemBuilder: this.HomeVideoGridCard,
            itemBuilder: this.HomeVideoListCard,
            headerBuilder: this.HomeBannerHeader,
            onReachEnd: () => {
              this.loadLiveVideos(false);
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
              hasHeader: this.shouldShowHomeRecommendBanner(),
              headerHorizontalBleed: 12,
              gridContentPadding: { left: 12, right: 12, bottom: this.safeAreaBottom + 72 },
              listContentEndOffset: this.safeAreaBottom + 72,
              // 空列表也保持可滚动（下拉刷新可用）
              stateScrollable: true,
              // 上方有 homeModeNoticeMessage 兄弟节点
              useLayoutWeight: true,
              // 原首页两个分支均为 clip(false) 且未显式关滚动条
              clipContent: false,
              scrollBarOff: false
            }
          })
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: this.safeAreaTop + 56 })
        .pullToRefresh(true)
        .refreshOffset(64)
        .onRefreshing(() => {
          this.refreshHomeFeed();
        })
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
