import { VideoItem } from 'youtube_core';
import { PlaybackState } from 'mediaservice';
import { ActionHub } from '../../common/ActionHub';
import { AppLog } from '../../common/AppLog';
import { PlayerSession } from '../../common/PlayerSession';
import { ShortsFeedService, ShortsFeedPage } from './ShortsFeedService';
import { ShortsSurface } from './components/ShortsSurface';

const logger = AppLog.getInstance('ShortsPage');
const TAG = '[Shorts]';

/** 长按 2x 的触发时长（ms）。 */
const HOLD_SPEED_DELAY_MS: number = 400;
/** 长按松手后的保护窗：这段时间内的抬手不再当成「单击」，否则 2x 松手会顺手把播放暂停掉。 */
const HOLD_RELEASE_GUARD_MS: number = 700;
/** 首帧兜底：源提交后超过这个时间还没等到画面信号就把封面撤掉，避免封面卡死不退。 */
const COVER_FALLBACK_MS: number = 1500;
/** 页内按钮点击后的保护窗：窗内的画面单击不再切播放/暂停。 */
const PAGE_BUTTON_TAP_GUARD_MS: number = 400;
/** 长按判定期间允许的最大手指位移（vp）：超过即视为滑动，取消 2x。 */
const HOLD_MOVE_SLOP_VP: number = 10;

/** Swiper 的 LazyForEach 数据源：只追加，不整体替换（避免重播所有页面）。 */
class ShortsDataSource implements IDataSource {
  private items: VideoItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): VideoItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  setItems(items: VideoItem[]): void {
    this.items = items.slice();
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }

  /** 只追加**新增**条目：传入全量列表会让数据源里出现重复条目（LazyForEach 的 key 冲突）。 */
  append(items: VideoItem[]): void {
    if (items.length === 0) {
      return;
    }
    const start = this.items.length;
    this.items = this.items.concat(items);
    this.listeners.forEach((listener: DataChangeListener) => {
      for (let i = start; i < this.items.length; i++) {
        listener.onDataAdd(i);
      }
    });
  }
}

/**
 * Shorts 全屏页（NavDestination）。
 *
 * 结构（自下而上）：
 *   1. 常驻 XComponent surface —— 换条不重建；
 *   2. 当前条封面（首帧前显示，首帧后淡出）；
 *   3. Swiper（纵向）—— 每页只有渐变 + 文案，透明；
 *   4. 顶栏 / 底部信息 / 进度条等 chrome。
 *
 * 手势：上/下滑切条（Swiper）、单击暂停/继续、长按 2x；不做双击点赞。
 */
@Component
export struct ShortsPage {
  private session: PlayerSession = PlayerSession.getInstance();
  private feed: ShortsFeedService = ShortsFeedService.getInstance();
  private dataSource: ShortsDataSource = new ShortsDataSource();
  private swiperController: SwiperController = new SwiperController();
  private switchChain: Promise<void> = Promise.resolve();
  private destroyed: boolean = false;
  /** 当前条的源是否已经提交成功（提交前不撤封面）。 */
  private playResolved: boolean = false;
  /** 封面兜底计时器 id（-1 = 无）。 */
  private coverFallbackTimer: number = -1;
  /** 长按 2x 保护窗截止时间戳：窗内的抬手不再当作单击。 */
  private holdReleaseUntilMs: number = 0;
  /** 页内按钮（分享/频道）点击后的保护窗：窗内的画面单击不再切播放/暂停。 */
  private pageButtonTapUntilMs: number = 0;
  /** 手写长按 2x 的状态。 */
  private holdTimer: number = -1;
  private holdActive: boolean = false;
  private touchDownX: number = 0;
  private touchDownY: number = 0;

  private progressListener = (currentTime: number, durationTime: number): void => {
    this.currentTime = currentTime;
    this.durationTime = durationTime;
  };

  private stateListener = (state: PlaybackState): void => {
    if (state.errorMsg && state.errorMsg.length > 0) {
      this.showCover = true;
      this.isPlaying = false;
      return;
    }
    this.isPlaying = state.isPlaying;
    // 作者/头像是后台补齐的，播放状态回调是它们落地后的刷新时机。
    this.refreshCurrentMeta();
    this.updateCoverVisibility();
  };

  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;

  @State currentIndex: number = 0;
  @State itemCount: number = 0;
  @State isLoading: boolean = true;
  @State loadFailed: boolean = false;
  @State currentFailed: boolean = false;
  @State exhausted: boolean = false;
  @State muted: boolean = false;
  @State showCover: boolean = true;
  @State isPlaying: boolean = false;
  @State switching: boolean = false;
  @State currentTime: number = 0;
  @State durationTime: number = 0;
  /**
   * 当前条的展示态元数据（作者/头像/播放量）。
   *
   * feed 条目不是响应式对象：作者/头像是**后台补齐**的（提取完成后
   * PlayerSession.fetchPlaybackExtrasInBackground 才写回条目），直接读
   * video.author 永远不会触发重渲染 → 一直显示"未知"。这里复制到
   * @State，由播放状态回调驱动刷新。
   */
  @State currentAuthor: string = '';
  @State currentAvatar: string = '';
  @State currentViewCount: string = '';

  aboutToAppear(): void {
    this.destroyed = false;
    logger.info(`${TAG} page_open`);
    this.session.controller.setFileLoop(true);
    this.session.controller.setMuted(this.muted);
    this.session.controller.subscribeProgress(this.progressListener);
    this.session.controller.subscribePlaybackState(this.stateListener);
    this.loadInitial();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    logger.info(`${TAG} page_close items=${this.itemCount} index=${this.currentIndex}`);
    this.clearCoverFallback();
    this.clearHoldTimer();
    this.session.controller.unsubscribeProgress(this.progressListener);
    this.session.controller.unsubscribePlaybackState(this.stateListener);
    this.feed.markSeen(this.currentVideoId());
    // surface 随页面销毁：清掉 AppStorage 里的旧 id，别让别的路径拿到死 surface。
    AppStorage.setOrCreate('shortsSurfaceId', '');
    // 退出 Shorts = 停止短视频播放：关闭循环/静音并释放媒体会话；
    // 回到主页后是长视频模式，下一次打开长视频走正常的 play() 冷启动路径。
    this.session.exitShortsMode();
    this.session.release(true);
  }

  // ---- Data flow ----

  private currentVideo(): VideoItem | undefined {
    const items = this.feed.getItems();
    if (this.currentIndex < 0 || this.currentIndex >= items.length) {
      return undefined;
    }
    return items[this.currentIndex];
  }

  private currentVideoId(): string {
    const video = this.currentVideo();
    return video ? (video.videoId || '') : '';
  }

  /** 把当前条的作者/头像/播放量同步到 @State（feed 条目不是响应式对象）。 */
  private refreshCurrentMeta(): void {
    const video = this.currentVideo();
    if (!video) {
      return;
    }
    const author = video.author || '';
    const avatar = video.channelAvatarUrl || '';
    const views = video.viewCount || '';
    if (author !== this.currentAuthor) {
      this.currentAuthor = author;
    }
    if (avatar !== this.currentAvatar) {
      this.currentAvatar = avatar;
    }
    if (views !== this.currentViewCount) {
      this.currentViewCount = views;
    }
  }

  private async loadInitial(): Promise<void> {
    this.isLoading = true;
    this.loadFailed = false;
    this.currentFailed = false;
    this.exhausted = false;
    const startedAt = Date.now();
    try {
      const page: ShortsFeedPage = await this.feed.ensureInitial('');
      if (this.destroyed) {
        return;
      }
      this.syncFeed(false);
      this.exhausted = page.exhausted;
      if (this.itemCount === 0) {
        logger.warn(`${TAG} feed_empty exhausted=${page.exhausted} elapsed=${Date.now() - startedAt}ms`);
        this.loadFailed = true;
        return;
      }
      logger.info(`${TAG} feed_ready items=${this.itemCount} source=${page.source} `
        + `elapsed=${Date.now() - startedAt}ms`);
      this.currentIndex = 0;
      await this.playAt(0);
      this.prefetchUpcoming(0);
      if (this.feed.needsRefill(0)) {
        this.refill().catch(() => undefined);
      }
    } catch (e) {
      if (this.destroyed) {
        return;
      }
      logger.error(`${TAG} feed_failed reason=${this.describeError(e)}`);
      this.loadFailed = true;
    } finally {
      if (!this.destroyed) {
        this.isLoading = false;
      }
    }
  }

  private async refill(): Promise<void> {
    if (this.exhausted) {
      return;
    }
    const before = this.feed.getItems().length;
    const page = await this.feed.loadMore();
    if (this.destroyed) {
      return;
    }
    this.syncFeed(true);
    this.exhausted = page.exhausted;
    logger.info(`${TAG} feed_refill before=${before} after=${this.itemCount} `
      + `added=${page.added} exhausted=${page.exhausted}`);
  }

  private syncFeed(appendOnly: boolean): void {
    const items = this.feed.getItems();
    if (appendOnly) {
      // 只把**新增**的部分喂给数据源：传全量会在数据源里留下重复条目，
      // LazyForEach 的 key（videoId）随之重复，条目错位且无法再滑动。
      const known = this.dataSource.totalCount();
      if (items.length > known) {
        this.dataSource.append(items.slice(known));
      }
    } else {
      this.dataSource.setItems(items);
    }
    this.itemCount = items.length;
  }

  // ---- Playback ----

  /**
   * 换条播放。
   *
   * 换源走**串行链**：同一时刻只有一次换源在提交，避免两条源同时进
   * `updateVideoSource` 互相覆盖。滑动时的"立刻响应"由
   * `PlayerSession.invalidatePendingPlay()` 提供——它让在飞的那一条在提交前
   * 被丢弃（不会把过期源推到控制器上），滑动因此立刻切到新条目。
   */
  private playAt(index: number): Promise<void> {
    const run = async (): Promise<void> => {
      const items = this.feed.getItems();
      if (this.destroyed || index < 0 || index >= items.length) {
        return;
      }
      const video = items[index];
      if (!video || !video.videoId) {
        return;
      }
      if (index !== this.currentIndex) {
        logger.info(`${TAG} switch_cancel index=${index} current=${this.currentIndex}`);
        return;
      }
      this.showCover = true;
      this.switching = true;
      this.currentFailed = false;
      this.currentTime = 0;
      this.durationTime = 0;
      this.playResolved = false;
      this.clearCoverFallback();
      const startedAt = Date.now();
      logger.info(`${TAG} switch_start video=${video.videoId} index=${index}`);
      try {
        // surface 必须在提交之前就绑好：controller 被重建时（release 之后）
        // 新 controller 没有 surfaceId，先提交会出现"有源无画面"。
        this.bindSurface();
        const source = await this.session.playShorts(video);
        if (this.destroyed || index !== this.currentIndex) {
          logger.info(`${TAG} switch_drop video=${video.videoId} index=${index} current=${this.currentIndex}`);
          return;
        }
        if (!source) {
          logger.warn(`${TAG} switch_failed video=${video.videoId} elapsed=${Date.now() - startedAt}ms`);
          this.showCover = true;
          this.currentFailed = true;
          this.loadFailed = this.itemCount === 0;
          return;
        }
        this.playResolved = true;
        this.updateCoverVisibility();
        this.armCoverFallback();
        logger.info(`${TAG} switch_ready video=${video.videoId} index=${index} `
          + `elapsed=${Date.now() - startedAt}ms`);
      } catch (e) {
        logger.error(`${TAG} switch_error video=${video.videoId} reason=${this.describeError(e)}`);
        if (!this.destroyed && index === this.currentIndex) {
          this.currentFailed = true;
        }
      } finally {
        if (!this.destroyed && index === this.currentIndex) {
          this.switching = false;
        }
      }
    };
    this.switchChain = this.switchChain.then(run).catch(() => undefined);
    return this.switchChain;
  }

  /** 只预取下一条：预取队列不可取消，预取两条会让真实播放排在无用提取之后。 */
  private prefetchUpcoming(index: number): void {
    const items = this.feed.getItems();
    const next = items[index + 1];
    if (next && next.videoId) {
      this.session.prefetchVideo(next);
    }
  }

  /**
   * surface 在页面生命周期内不变；但 playShorts 可能在 controller 被 release 后
   * 重建 controller，重建的 controller 需要重新注入同一个 surfaceId。
   */
  private bindSurface(): void {
    const surfaceId = AppStorage.get<string>('shortsSurfaceId');
    if (surfaceId && surfaceId.length > 0) {
      this.session.controller.setSurfaceID(surfaceId);
    }
  }

  private onSwiperChange(index: number): void {
    if (index === this.currentIndex) {
      return;
    }
    const previousId = this.currentVideoId();
    this.feed.markSeen(previousId);
    this.currentIndex = index;
    this.showCover = true;
    // 换条：先把展示态元数据换成新条目的（可能是空的，等后台补齐）。
    this.currentAuthor = '';
    this.currentAvatar = '';
    this.currentViewCount = '';
    this.refreshCurrentMeta();
    // 作废在飞的那一条：它会在提交前被丢弃，不会把过期源推到控制器上
    // （否则用户已经滑到下一条，屏幕上还在放上一条）。
    this.session.invalidatePendingPlay();
    logger.info(`${TAG} swipe index=${index} from=${previousId}`);
    this.playAt(index);
    this.prefetchUpcoming(index);
    if (this.feed.needsRefill(index)) {
      this.refill().catch(() => undefined);
    }
  }

  // ---- Cover / first frame ----

  /**
   * 首帧判据：源已提交 + 播放位置已经推进（position > 0）。
   *
   * 旧判据（isBuffered）在 MPV 的 playback-restart 事件就发，比首帧早，
   * 封面提前撤掉会露黑帧；而 isBuffered 也可能来自上一条的视频。
   * 这里用控制器 vm 的当前位置——换源时它会被 resetPlaybackState 清零，
   * 所以 position > 0 一定属于新的一条。
   */
  private updateCoverVisibility(): void {
    if (!this.playResolved || !this.showCover) {
      return;
    }
    const vm = this.session.controller.vm;
    if (vm.isPlaying && vm.currentTime > 0) {
      this.showCover = false;
      this.clearCoverFallback();
      logger.info(`${TAG} first_frame video=${this.currentVideoId()} pos=${vm.currentTime.toFixed(2)}s`);
    }
  }

  private armCoverFallback(): void {
    this.clearCoverFallback();
    this.coverFallbackTimer = setTimeout(() => {
      this.coverFallbackTimer = -1;
      if (this.showCover) {
        logger.warn(`${TAG} cover_fallback video=${this.currentVideoId()}`);
        this.showCover = false;
      }
    }, COVER_FALLBACK_MS);
  }

  private clearCoverFallback(): void {
    if (this.coverFallbackTimer !== -1) {
      clearTimeout(this.coverFallbackTimer);
      this.coverFallbackTimer = -1;
    }
  }

  // ---- Gestures ----

  private togglePlayPause(): void {
    if (this.session.controller.vm.isPlaying) {
      this.session.controller.syncPause();
    } else {
      this.session.controller.syncPlay();
    }
  }

  /** 单击画面：长按/页内按钮的保护窗内的抬手不算（否则会顺手暂停）。 */
  private onPageTap(): void {
    const now = Date.now();
    if (now < this.holdReleaseUntilMs) {
      logger.info(`${TAG} tap_ignored_in_hold_guard`);
      return;
    }
    if (now < this.pageButtonTapUntilMs) {
      logger.info(`${TAG} tap_ignored_in_button_guard`);
      return;
    }
    this.togglePlayPause();
  }

  private onHoldSpeedStart(): void {
    this.holdReleaseUntilMs = Date.now() + HOLD_RELEASE_GUARD_MS;
    logger.info(`${TAG} hold_speed_start`);
    this.session.controller.setPlaybackSpeed(2);
  }

  private onHoldSpeedEnd(): void {
    // 松手后仍保留一小段保护窗：抬手与点击手势几乎同时到达，
    // 没有保护窗的话"按住 2x → 松手"会顺手把播放暂停掉。
    this.holdReleaseUntilMs = Date.now() + HOLD_RELEASE_GUARD_MS;
    this.session.controller.setPlaybackSpeed(1);
    logger.info(`${TAG} hold_speed_end`);
  }

  /**
   * 手写长按 2x：Down 起计时，Move 超过阈值（=判定为滑动）就撤销，
   * Up/Cancel 收尾。**不用 LongPressGesture**——它在 400ms 后无条件成立，
   * 会把慢速滑动整条吃掉（Swiper 不滚动）。
   */
  private handlePageTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      const touch = event.touches.length > 0 ? event.touches[0] : undefined;
      if (!touch) {
        return;
      }
      this.touchDownX = touch.x;
      this.touchDownY = touch.y;
      this.holdActive = false;
      this.clearHoldTimer();
      this.holdTimer = setTimeout(() => {
        this.holdTimer = -1;
        this.holdActive = true;
        this.onHoldSpeedStart();
      }, HOLD_SPEED_DELAY_MS);
      return;
    }
    if (event.type === TouchType.Move) {
      const touch = event.touches.length > 0 ? event.touches[0] : undefined;
      if (!touch) {
        return;
      }
      const dx = Math.abs(touch.x - this.touchDownX);
      const dy = Math.abs(touch.y - this.touchDownY);
      if (dx > this.touchMoveSlopPx() || dy > this.touchMoveSlopPx()) {
        // 手指动了 → 是在滑动切条，不是长按：撤掉 2x 计时。
        this.clearHoldTimer();
      }
      return;
    }
    // Up / Cancel
    this.clearHoldTimer();
    if (this.holdActive) {
      this.holdActive = false;
      this.onHoldSpeedEnd();
    }
  }

  private touchMoveSlopPx(): number {
    try {
      return this.getUIContext().vp2px(HOLD_MOVE_SLOP_VP);
    } catch (e) {
      return 30;
    }
  }

  private clearHoldTimer(): void {
    if (this.holdTimer !== -1) {
      clearTimeout(this.holdTimer);
      this.holdTimer = -1;
    }
  }

  private toggleMute(): void {
    this.muted = !this.muted;
    this.session.controller.setMuted(this.muted);
    logger.info(`${TAG} muted=${this.muted}`);
  }

  private exitToLongVideo(): void {
    logger.info(`${TAG} exit_to_long index=${this.currentIndex}`);
    this.actionHub.closePage();
  }

  private progressPercent(): number {
    if (this.durationTime <= 0) {
      return 0;
    }
    const pct = (this.currentTime / this.durationTime) * 100;
    return Math.max(0, Math.min(100, pct));
  }

  private describeError(e: Object): string {
    if (e instanceof Error) {
      return (e as Error).message || 'error';
    }
    return `${e}`;
  }

  // ---- UI ----

  @Builder
  TopBar() {
    Row() {
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(20)
          .fontColor([$r('app.color.yourtube_text_inverse')])
        Text($r('app.string.yt_shorts_switch_long'))
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_inverse'))
      }
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor('#33000000')
      .borderRadius(16)
      .onClick(() => {
        this.exitToLongVideo();
      })

      Text('Shorts')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.yourtube_text_inverse'))
        .padding({ left: 10 })

      Blank()

      SymbolGlyph(this.muted ? $r('sys.symbol.speaker_slash_fill') : $r('sys.symbol.speaker_wave_2'))
        .fontSize(22)
        .fontColor([$r('app.color.yourtube_text_inverse')])
        .padding(8)
        .onClick(() => {
          this.toggleMute();
        })
    }
    .width('100%')
    .padding({
      left: 12,
      right: 12,
      top: this.safeAreaTop + 8
    })
  }

  @Builder
  BottomInfo(video: VideoItem) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        if (this.currentAvatar.length > 0) {
          Image(this.currentAvatar)
            .width(36)
            .height(36)
            .borderRadius(18)
            .objectFit(ImageFit.Cover)
            .backgroundColor('#33FFFFFF')
        } else {
          Column()
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor('#33FFFFFF')
        }
        Column({ space: 2 }) {
          Text(this.currentAuthor.length > 0 ? this.currentAuthor : $r('app.string.yt_label_unknown'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(video.title && video.title.length > 0 ? video.title : 'Shorts')
            .fontSize(13)
            .fontColor('#DDFFFFFF')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph($r('sys.symbol.share'))
          .fontSize(22)
          .fontColor([$r('app.color.yourtube_text_inverse')])
          .padding(6)
          .onClick(() => {
            // 页内按钮的点击与画面单击手势会同时到达（ArkUI 不隔离），
            // 用保护窗把这次点击从"切播放/暂停"里摘出去。
            this.pageButtonTapUntilMs = Date.now() + PAGE_BUTTON_TAP_GUARD_MS;
            this.actionHub.shareVideo(video);
          })
      }
      .width('100%')

      Row({ space: 10 }) {
        Text(this.currentViewCount.length > 0 ? this.currentViewCount : '')
          .fontSize(12)
          .fontColor('#99FFFFFF')
          .maxLines(1)
          .layoutWeight(1)
        Text($r('app.string.yt_action_view_author'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_inverse'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor('#33000000')
          .borderRadius(12)
          .onClick(() => {
            this.pageButtonTapUntilMs = Date.now() + PAGE_BUTTON_TAP_GUARD_MS;
            this.actionHub.openChannelById(video.channelId || '', video.author || '',
              video.channelAvatarUrl || '', video.channelHandle || '');
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 10 })
  }

  @Builder
  ProgressBar() {
    Column() {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(2)
          .backgroundColor('#40FFFFFF')
        Row()
          .width(`${this.progressPercent()}%`)
          .height(2)
          .backgroundColor($r('app.color.yourtube_text_inverse'))
      }
      .width('100%')
      .height(2)
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    // 进度条压在屏幕最底（安全区之上）：安全区内边距由这一层给，
    // 否则进度条会被系统导航栏完全盖住。
    .padding({ bottom: this.safeAreaBottom })
  }

  /** 当前条换源失败：封面 + 重试（不打断整页 feed）。 */
  @Builder
  CurrentFailedState() {
    Column({ space: 12 }) {
      Text($r('app.string.yt_error_load_failed'))
        .fontSize(14)
        .fontColor('#CCFFFFFF')
        .textAlign(TextAlign.Center)
      Button($r('app.string.yt_action_retry'))
        .fontSize(14)
        .backgroundColor('#33FFFFFF')
        .fontColor($r('app.color.yourtube_text_inverse'))
        .onClick(() => {
          this.currentFailed = false;
          this.playAt(this.currentIndex);
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState() {
    Column({ space: 12 }) {
      Text(this.loadFailed ? $r('app.string.yt_error_load_failed') : $r('app.string.yt_empty_no_shorts'))
        .fontSize(14)
        .fontColor('#CCFFFFFF')
        .textAlign(TextAlign.Center)
      Button($r('app.string.yt_action_retry'))
        .fontSize(14)
        .backgroundColor('#33FFFFFF')
        .fontColor($r('app.color.yourtube_text_inverse'))
        .onClick(() => {
          this.feed.invalidate('user_retry');
          this.loadInitial();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.Black)
  }

  @Builder
  ShortsPageContent(video: VideoItem) {
    Column() {
      Blank()
      Column()
        .width('100%')
        .height(260)
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#E6000000', 1.0]]
        })
      this.BottomInfo(video)
      // 进度条压在屏幕最底（安全区之上）：BottomInfo 的安全区内边距只留给
      // 文案，进度条自己再补一段，否则会被系统导航栏完全盖住。
      this.ProgressBar()
    }
    .width('100%')
    .height('100%')
    // 只声明点击手势（parallelGesture：与父级 Swiper 滚动并行识别）。
    // **不声明 LongPressGesture**：ArkUI 的长按识别在 400ms 后就成立，
    // 手指是否已经移动不再影响它——慢速拖动会被长按整条吃掉，Swiper 不滚动
    // （表现为"滑不动"）。长按 2x 改用 onTouch + 计时器自己实现：
    // 手指移动超过阈值就撤销 2x，滑动照常交给 Swiper。
    .parallelGesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 1, fingers: 1 })
          .onAction(() => {
            this.onPageTap();
          })
      )
    )
    .onTouch((event: TouchEvent) => {
      this.handlePageTouch(event);
    })
  }

  @Builder
  CurrentCover(video: VideoItem) {
    Stack({ alignContent: Alignment.Center }) {
      if (video.thumbnailUrl && video.thumbnailUrl.length > 0) {
        Image(video.thumbnailUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(video.thumbnailColor || '#000000')
      }
      if (this.switching || this.isLoading) {
        LoadingProgress()
          .width(42)
          .height(42)
          .color('#CCFFFFFF')
      }
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ShortsSurface({ active: true })
        .width('100%')
        .height('100%')

      // 当前条封面：首帧前挡住 surface，首帧到达后淡出。
      if (this.showCover && this.currentVideo() !== undefined) {
        this.CurrentCover(this.currentVideo() as VideoItem)
      }

      if (this.itemCount > 0) {
        Swiper(this.swiperController) {
          LazyForEach(this.dataSource, (item: VideoItem) => {
            this.ShortsPageContent(item)
          }, (item: VideoItem) => item.videoId)
        }
        .vertical(true)
        .loop(false)
        .indicator(false)
        .cachedCount(1)
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onChange((index: number) => {
          this.onSwiperChange(index);
        })
      }

      if (this.currentFailed && this.itemCount > 0) {
        this.CurrentFailedState()
      }

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(44)
            .height(44)
            .color('#CCFFFFFF')
          Text('Shorts')
            .fontSize(13)
            .fontColor('#99FFFFFF')
            .margin({ top: 10 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#CC000000')
      }

      if (!this.isLoading && this.itemCount === 0) {
        this.EmptyState()
      }

      // 顶栏永远在最上层：加载遮罩/失败态/空态都覆盖全屏，顶栏被压住的话
      // 用户在 feed 还在加载时就点不到「长视频」返回。
      this.TopBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
