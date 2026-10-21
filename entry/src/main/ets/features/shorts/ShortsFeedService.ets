import { VideoItem } from 'youtube_core';
import { AuthSessionManager } from 'youtube_core';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { AppLog } from '../../common/AppLog';
import { WatchHistoryStore } from '../../common/WatchHistoryStore';

const logger = AppLog.getInstance('ShortsFeed');
const TAG = '[Shorts]';

/** 会话内已看集合上限（只用于去重，不落盘）。 */
const MAX_SEEN_IDS: number = 500;
/** 剩余未看条目低于该值时由 UI 触发补货。 */
const REFILL_THRESHOLD: number = 3;
/** feed 结果的软缓存时间；过期只影响“是否需要重新拉取”，不清空已展示条目。 */
const CACHE_TTL_MS: number = 5 * 60 * 1000;

enum ShortsSourceKind {
  NONE = 'none',
  CHANNEL = 'channel',
  HOME = 'home',
  SEARCH = 'search'
}

export interface ShortsFeedPage {
  /** 本次新增条数。 */
  added: number;
  /** 合并后的总条数。 */
  total: number;
  /** 本次来源（'channel' | 'home' | 'search' | 'none'）。 */
  source: string;
  /** 所有来源都已耗尽。 */
  exhausted: boolean;
}

interface ShortsSourcePage {
  items: VideoItem[];
  nextPageToken: string | null;
  visitorData: string;
}

/**
 * 多来源 Shorts 拼接 feed（准无限，不做算法无限流）。
 *
 * 来源优先级：频道 Shorts（有 seed channel 时）→ 首页 kiosk 中的 Shorts →
 * 搜索 "shorts" 结果里的 Shorts。每个来源独立保存 continuation，某个来源
 * 失败只跳过该来源；全部失败时返回 added=0，由页面展示可重试空态。
 *
 * 全内存、5 分钟软缓存、登录态变化自动重置；不写任何持久化状态。
 */
export class ShortsFeedService {
  private static instance: ShortsFeedService | null = null;

  static getInstance(): ShortsFeedService {
    if (!ShortsFeedService.instance) {
      ShortsFeedService.instance = new ShortsFeedService();
    }
    return ShortsFeedService.instance;
  }

  private items: VideoItem[] = [];
  private seenIds: Set<string> = new Set();
  private seenOrder: string[] = [];
  private loadedAtMs: number = 0;
  private nextItemId: number = 1;
  private authFingerprint: string = '';

  private sourceOrder: ShortsSourceKind[] = [];
  private sourceIndex: number = 0;
  private sourceToken: string = '';
  private sourceVisitor: string = '';
  private sourceChannelId: string = '';
  private sourceExhausted: boolean = false;
  /** HOME 源实际走的 rail（kiosk / recommended-web / recommended-tv），续页要沿用同一条。 */
  private sourceRail: string = '';

  private loadInFlight: Promise<ShortsFeedPage> | null = null;

  // ---- Read-only surface ----

  getItems(): VideoItem[] {
    return this.items;
  }

  isEmpty(): boolean {
    return this.items.length === 0;
  }

  /** 调用方把某条标记为已看：后续补货不会再拼进来。 */
  markSeen(videoId: string): void {
    if (!videoId || this.seenIds.has(videoId)) {
      return;
    }
    this.seenIds.add(videoId);
    this.seenOrder.push(videoId);
    while (this.seenOrder.length > MAX_SEEN_IDS) {
      const oldest = this.seenOrder.shift();
      if (oldest) {
        this.seenIds.delete(oldest);
      }
    }
  }

  /** 当前 index 之后还有多少条未看内容（含缓存里已加载的）。 */
  remainingAfter(index: number): number {
    const remain = this.items.length - index - 1;
    return remain > 0 ? remain : 0;
  }

  needsRefill(index: number): boolean {
    return this.remainingAfter(index) < REFILL_THRESHOLD;
  }

  // ---- Loading ----

  /**
   * 首次进入 Shorts 页：命中软缓存直接复用；否则按来源顺序拉到至少一条。
   * seedChannelId 非空时把“频道 Shorts”放在首位。
   */
  async ensureInitial(seedChannelId: string = ''): Promise<ShortsFeedPage> {
    this.syncAuthFingerprint();
    if (this.items.length > 0 && Date.now() - this.loadedAtMs < CACHE_TTL_MS) {
      logger.info(`${TAG} feed_cache_hit items=${this.items.length} `
        + `age=${Date.now() - this.loadedAtMs}ms`);
      return {
        added: 0,
        total: this.items.length,
        source: ShortsSourceKind.NONE,
        exhausted: this.isAllSourcesExhausted()
      };
    }
    if (this.sourceOrder.length === 0) {
      this.buildSourceOrder(seedChannelId);
    }
    return this.loadMore();
  }

  /**
   * 补货：沿当前来源继续翻页；来源耗尽/失败自动切到下一个来源。
   * 并发调用共享同一个 in-flight Promise。
   */
  async loadMore(): Promise<ShortsFeedPage> {
    if (this.loadInFlight) {
      return this.loadInFlight;
    }
    const task = this.loadMoreInternal();
    this.loadInFlight = task;
    try {
      return await task;
    } finally {
      if (this.loadInFlight === task) {
        this.loadInFlight = null;
      }
    }
  }

  /** 登录态/配置变化或显式刷新：清空会话缓存，下次进入重新拉取。 */
  invalidate(reason: string): void {
    this.items = [];
    this.seenIds.clear();
    this.seenOrder = [];
    this.loadedAtMs = 0;
    this.nextItemId = 1;
    this.sourceOrder = [];
    this.sourceIndex = 0;
    this.sourceToken = '';
    this.sourceVisitor = '';
    this.sourceChannelId = '';
    this.sourceRail = '';
    this.sourceExhausted = false;
    this.loadInFlight = null;
    logger.info(`${TAG} feed_reset reason=${reason}`);
  }

  // ---- Internals ----

  private async loadMoreInternal(): Promise<ShortsFeedPage> {
    this.syncAuthFingerprint();
    if (this.sourceOrder.length === 0) {
      this.buildSourceOrder(this.sourceChannelId);
    }
    let lastSource: ShortsSourceKind = ShortsSourceKind.NONE;
    let consecutiveFailures = 0;
    let emptyPages = 0;
    while (this.sourceIndex < this.sourceOrder.length) {
      const kind = this.sourceOrder[this.sourceIndex];
      if (this.sourceExhausted) {
        this.advanceSource();
        emptyPages = 0;
        continue;
      }
      lastSource = kind;
      let page: ShortsSourcePage | null = null;
      try {
        page = await this.fetchSource(kind);
      } catch (e) {
        consecutiveFailures += 1;
        logger.warn(`${TAG} feed_error source=${kind} index=${this.items.length} `
          + `failures=${consecutiveFailures} reason=${this.describeError(e)}`);
        this.sourceExhausted = true;
        this.sourceToken = '';
        continue;
      }
      const added = page ? this.mergeItems(page.items) : 0;
      if (page) {
        this.sourceToken = page.nextPageToken ?? '';
        this.sourceVisitor = page.visitorData || this.sourceVisitor;
        this.sourceExhausted = this.sourceToken.length === 0;
      }
      if (added > 0) {
        this.loadedAtMs = Date.now();
        const sample = this.items[this.items.length - added];
        logger.info(`${TAG} feed_source source=${kind} added=${added} `
          + `total=${this.items.length} exhausted=${this.sourceExhausted}`);
        logger.debug(`${TAG} feed_item_sample source=${kind} author="${sample.author}" `
          + `channelId="${sample.channelId}" avatar=${sample.channelAvatarUrl.length > 0 ? 'yes' : 'no'} `
          + `views="${sample.viewCount}" title="${sample.title}"`);
        return {
          added: added,
          total: this.items.length,
          source: kind,
          exhausted: this.isAllSourcesExhausted()
        };
      }
      emptyPages += 1;
      logger.info(`${TAG} feed_skip source=${kind} added=0 emptyPages=${emptyPages} `
        + `exhausted=${this.sourceExhausted}`);
      // 单页没有 Shorts 不代表来源耗尽：最多连翻 2 页再切来源，避免无限空翻。
      if (this.sourceExhausted || emptyPages >= 2) {
        this.advanceSource();
        emptyPages = 0;
      }
    }
    const allDone = this.isAllSourcesExhausted();
    logger.info(`${TAG} feed_more source=${lastSource} added=0 total=${this.items.length} `
      + `exhausted=${allDone} failures=${consecutiveFailures}`);
    return {
      added: 0,
      total: this.items.length,
      source: lastSource,
      exhausted: allDone
    };
  }

  private advanceSource(): void {
    this.sourceIndex += 1;
    this.resetSourceCursor();
  }

  private async fetchSource(kind: ShortsSourceKind): Promise<ShortsSourcePage> {
    const provider = FeedServiceProvider.getInstance();
    if (kind === ShortsSourceKind.CHANNEL) {
      const service = provider.getChannelService();
      const result = this.sourceToken.length > 0
        ? await service.fetchChannelShortsNext(this.sourceToken, this.sourceVisitor, this.nextItemId)
        : await service.fetchChannelShortsInitial(this.sourceChannelId, this.nextItemId);
      return {
        items: result.items,
        nextPageToken: result.nextPageToken,
        visitorData: result.visitorData
      };
    }
    if (kind === ShortsSourceKind.HOME) {
      const service = provider.getHomeFeedService();
      if (this.sourceToken.length > 0) {
        // 续页必须沿用首页实际走的那条 rail（游客 kiosk / 登录推荐流），
        // 否则 token 与 rail 对不上，续页会落到另一个源上。
        const rail = this.sourceRail;
        const result = await service.fetchHomeKioskNext(this.sourceToken, this.sourceVisitor,
          this.nextItemId, rail.indexOf('recommended') === 0, rail);
        return {
          items: result.items,
          nextPageToken: result.nextPageToken,
          visitorData: result.visitorData
        };
      }
      // style='recommended'：登录态优先用个性化首页（含 Shorts 货架），
      // 游客/失败自动回落到游客 kiosk（游客 kiosk 里没有 Shorts 货架）。
      const result = await service.fetchHomeKioskInitial(this.nextItemId, 'recommended');
      this.sourceRail = result.source || 'kiosk';
      return {
        items: result.items,
        nextPageToken: result.nextPageToken,
        visitorData: result.visitorData
      };
    }
    if (kind === ShortsSourceKind.SEARCH) {
      const service = provider.getSearchService();
      const result = this.sourceToken.length > 0
        ? await service.fetchNext(this.sourceToken, this.nextItemId)
        : await service.fetchInitial('shorts', this.nextItemId);
      return {
        items: result.items,
        nextPageToken: result.nextPageToken,
        visitorData: ''
      };
    }
    return { items: [], nextPageToken: null, visitorData: '' };
  }

  private mergeItems(raw: VideoItem[]): number {
    if (!raw || raw.length === 0) {
      return 0;
    }
    let added = 0;
    let dropped = 0;
    for (let i = 0; i < raw.length; i++) {
      const source = raw[i];
      if (!source) {
        continue;
      }
      const videoId = (source.videoId || '').trim();
      if (!videoId) {
        dropped += 1;
        continue;
      }
      if (!source.isShort) {
        dropped += 1;
        continue;
      }
      if (this.seenIds.has(videoId)) {
        dropped += 1;
        continue;
      }
      source.id = this.nextItemId;
      this.nextItemId += 1;
      this.items.push(source);
      this.seenIds.add(videoId);
      this.seenOrder.push(videoId);
      added += 1;
    }
    if (dropped > 0) {
      logger.debug(`${TAG} feed_dedupe dropped=${dropped} added=${added}`);
    }
    return added;
  }

  private buildSourceOrder(seedChannelId: string): void {
    this.sourceChannelId = (seedChannelId || '').trim();
    if (this.sourceChannelId.length === 0) {
      this.sourceChannelId = this.channelIdFromWatchHistory();
    }
    this.sourceOrder = [];
    if (this.sourceChannelId.length > 0) {
      this.sourceOrder.push(ShortsSourceKind.CHANNEL);
    }
    this.sourceOrder.push(ShortsSourceKind.HOME);
    this.sourceOrder.push(ShortsSourceKind.SEARCH);
    this.sourceIndex = 0;
    this.resetSourceCursor();
    logger.info(`${TAG} feed_sources order=${this.sourceOrder.join(',')} `
      + `seedChannel=${this.sourceChannelId.length > 0 ? 'yes' : 'no'}`);
  }

  private resetSourceCursor(): void {
    this.sourceToken = '';
    this.sourceVisitor = '';
    this.sourceRail = '';
    this.sourceExhausted = false;
  }

  /**
   * 频道 Shorts 是最稳定的真实来源：用最近一条观看历史的频道作为 seed。
   * 历史为空（新装/清数据）时返回空串，来源链自动跳过频道。
   */
  private channelIdFromWatchHistory(): string {
    try {
      const history = WatchHistoryStore.getAll();
      for (let i = 0; i < history.length; i++) {
        const channelId = (history[i].channelId || '').trim();
        if (channelId.length > 0) {
          return channelId;
        }
      }
    } catch (e) {
      logger.warn(`${TAG} feed_seed_history_failed reason=${this.describeError(e)}`);
    }
    return '';
  }

  private isAllSourcesExhausted(): boolean {
    if (this.sourceOrder.length === 0) {
      return false;
    }
    if (this.sourceIndex < this.sourceOrder.length - 1) {
      return false;
    }
    return this.sourceExhausted;
  }

  /**
   * 登录态指纹只用于“登录/登出/切换账号后清空重拉”，不记录任何凭据值。
   */
  private syncAuthFingerprint(): void {
    const status = AuthSessionManager.getInstance()?.getStatus();
    const fingerprint = status
      ? `${status.authMode}|${status.hasCredential ? 1 : 0}|${status.canWebUserData ? 1 : 0}|${status.canTvUserData ? 1 : 0}`
      : 'none';
    if (this.authFingerprint.length === 0) {
      this.authFingerprint = fingerprint;
      return;
    }
    if (this.authFingerprint !== fingerprint) {
      this.authFingerprint = fingerprint;
      this.invalidate('auth_changed');
    }
  }

  private describeError(e: Object): string {
    if (e instanceof Error) {
      return (e as Error).message || 'error';
    }
    return `${e}`;
  }
}
