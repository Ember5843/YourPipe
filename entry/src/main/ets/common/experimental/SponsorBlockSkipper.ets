import { AvPlayerController } from 'mediaservice';
import { VideoItem } from 'youtube_core';
import { AppLog } from '../AppLog';
import {
  ExperimentalConfig,
  EXP_CATEGORY_HIGHLIGHT,
  EXP_SB_BEHAVIOR_MANUAL,
  EXP_SB_BEHAVIOR_SILENT,
  EXP_SB_BEHAVIOR_TOAST
} from './ExperimentalConfig';
import { SponsorBlockClient, SponsorSegment } from './SponsorBlockClient';

const logger = AppLog.getInstance('SponsorBlockSkipper');

const SKIP_DEBOUNCE_MS: number = 800;
const SEGMENT_EDGE_MARGIN_SEC: number = 0.05;
const PROMPT_MIN_LEAD_SEC: number = 3;
const PROMPT_MAX_LEAD_SEC: number = 10;
/** 用户把进度拖到提示点之前这么远，视为放弃本次提示。 */
const PROMPT_REARM_SEC: number = 3;
/** poi_highlight 仅在时间点 > 1s 且播放尚在其前 > 2s 时提示一次。 */
const POI_MIN_START_SEC: number = 1;
const POI_LEAD_THRESHOLD_SEC: number = 2;

export type SponsorSkipNoticeMode = 'undo' | 'manual' | 'poi';

export interface SponsorSkipNotice {
  mode: SponsorSkipNoticeMode;
  category: string;
  startSec: number;
  endSec: number;
}

/**
 * SponsorBlock 跳过策略：片段开始**前**提前弹出提示，用户不点撤销才在片段
 * 起点 seek 到片段末尾。这样「撤销」就是取消本次跳过，不需要回跳，也不会
 * 受 seek 期间 time-pos 抖动影响。
 *
 * 只依赖 mediaservice 控制器与 VideoItem，不依赖播放页组件 —— 后台音频 /
 * PiP 也会继续按同样策略跳过（没有 UI 时提示不可见，等同于静默）。
 */
export class SponsorBlockSkipper {
  private static instance: SponsorBlockSkipper | null = null;

  private controller: AvPlayerController | null = null;
  private videoId: string = '';
  private segments: SponsorSegment[] = [];
  /** 已处理过的片段（提示过或跳过过），防止同一片段反复触发。 */
  private lastSegment: SponsorSegment | null = null;
  /** 正在等待用户确认的片段；到起点仍未撤销才真正跳过。 */
  private pendingSegment: SponsorSegment | null = null;
  /** 用户点「撤销」后放行的片段；离开片段范围后自动解除。 */
  private suppressedSegment: SponsorSegment | null = null;
  /** manual 模式下当前命中的可跳过片段。 */
  private manualSegment: SponsorSegment | null = null;
  /** manual 模式下用户主动关闭提示的片段；离开该片段后解除。 */
  private dismissedManualSegment: SponsorSegment | null = null;
  /** 当前展示的精彩片段（poi_highlight）跳转提示。 */
  private poiSegment: SponsorSegment | null = null;
  /** 当前视频的精彩片段提示是否已处理（已跳转、已关闭或播放已到达其附近）。 */
  private poiHandled: boolean = false;
  /** 当前激活的提示，供页面重新挂载监听时同步。 */
  private currentNotice: SponsorSkipNotice | null = null;
  private lastSkipAtMs: number = 0;
  private generation: number = 0;
  private noticeListener: ((notice: SponsorSkipNotice | null) => void) | null = null;
  private segmentsListeners: Set<(segments: SponsorSegment[]) => void> = new Set();

  private progressListener = (currentTime: number, durationTime: number): void => {
    this.onProgress(currentTime, durationTime);
  };

  static getInstance(): SponsorBlockSkipper {
    if (!SponsorBlockSkipper.instance) {
      SponsorBlockSkipper.instance = new SponsorBlockSkipper();
    }
    return SponsorBlockSkipper.instance;
  }

  /** 返回当前视频已加载的 SponsorBlock 片段副本（无片段或停用时为空数组）。 */
  getSegments(): SponsorSegment[] {
    return this.segments.slice();
  }

  /** 订阅当前视频的 SponsorBlock 片段变化；注册时立即同步当前快照。 */
  subscribeSegments(listener: (segments: SponsorSegment[]) => void): void {
    this.segmentsListeners.add(listener);
    try {
      listener(this.segments.slice());
    } catch (e) {
      logger.warn(`segments listener initial sync failed: ${(e as Error).message}`);
    }
  }

  unsubscribeSegments(listener: (segments: SponsorSegment[]) => void): void {
    this.segmentsListeners.delete(listener);
  }

  /** 播放页注册提示层；页面销毁时传 null。 */
  setNoticeListener(listener: ((notice: SponsorSkipNotice | null) => void) | null): void {
    this.noticeListener = listener;
    if (listener && this.currentNotice) {
      listener(this.currentNotice);
    }
  }

  onVideoStarted(controller: AvPlayerController, video: VideoItem): void {
    this.detach();
    const videoId = (video.videoId || '').trim();
    const config = SponsorBlockSkipper.config();
    if (videoId.length === 0 || video.localMediaPath || video.isLive || !config
      || !config.sponsorBlockEnabled || config.isChannelWhitelisted(video.channelId)) {
      return;
    }

    this.controller = controller;
    this.videoId = videoId;
    controller.subscribeProgress(this.progressListener);
    const generation = ++this.generation;
    const categories = config.enabledSponsorCategories();
    logger.info(`attach video=${videoId} categories=${categories.length} `
      + `privacy=${config.sponsorPrivacyMode} behavior=${config.sponsorBehavior}`);
    SponsorBlockClient.getInstance()
      .getSegments(videoId, categories, config.sponsorServer, config.sponsorPrivacyMode)
      .then((segments: SponsorSegment[]) => {
        if (generation !== this.generation) {
          return;
        }
        this.segments = segments;
        this.emitSegments();
        logger.info(`segments ready video=${videoId} count=${segments.length}`);
        // 片段回来时可能已经播进片段内（从历史进度续播），立刻评估一次。
        const state = this.controller ? this.controller.getPlaybackState() : null;
        if (state) {
          this.trySkip(state.currentTime, state.duration);
        }
      })
      .catch((e: Error) => {
        if (generation === this.generation) {
          logger.warn(`segments unavailable video=${videoId} error=${e.message}`);
        }
      });
  }

  onPlaybackStopped(): void {
    this.detach();
  }

  /**
   * 用户点「撤销」：取消正在等待的跳过，并放行该片段。
   * 返回 false 表示当前没有可撤销的提示（例如已经跳过或提示已消失）。
   */
  undo(): boolean {
    const segment = this.pendingSegment;
    if (!segment) {
      logger.warn(`undo ignored video=${this.videoId} no pending prompt`);
      return false;
    }
    this.pendingSegment = null;
    this.suppressedSegment = segment;
    this.lastSegment = segment;
    this.emitNotice(null);
    logger.info(`undo pending skip video=${this.videoId} category=${segment.category} `
      + `start=${segment.startSec.toFixed(2)}`);
    return true;
  }

  /** manual 模式下用户点击「跳过」按钮：跳转到当前片段末尾。 */
  skipManual(): boolean {
    const segment = this.manualSegment;
    const controller = this.controller;
    if (!segment || !controller) {
      logger.warn(`skipManual ignored video=${this.videoId} no active manual segment`);
      return false;
    }
    const state = controller.getPlaybackState();
    this.manualSegment = null;
    this.dismissedManualSegment = segment;
    this.commitSkip(segment, state.duration);
    return true;
  }

  /** poi_highlight 模式下用户点击「跳至精彩处」：跳转到 poi.startSec 并标记已处理。 */
  jumpToPoi(): boolean {
    const segment = this.poiSegment;
    const controller = this.controller;
    if (!segment || !controller) {
      logger.warn(`jumpToPoi ignored video=${this.videoId} no active poi segment`);
      return false;
    }
    const state = controller.getPlaybackState();
    const targetSec = state.duration > 0
      ? Math.min(segment.startSec, Math.max(0, state.duration - 0.2))
      : segment.startSec;
    this.poiSegment = null;
    this.poiHandled = true;
    this.lastSkipAtMs = Date.now();
    this.emitNotice(null);
    controller.syncSeek(targetSec * 1000);
    logger.info(`jump poi video=${this.videoId} from=${state.currentTime.toFixed(2)} `
      + `to=${targetSec.toFixed(2)}`);
    return true;
  }

  /** 关闭当前提示（manual 放行当前片段、poi 标记本视频已处理、undo 等同撤销）。 */
  dismissNotice(): void {
    if (this.pendingSegment) {
      this.undo();
      return;
    }
    if (this.manualSegment) {
      const segment = this.manualSegment;
      this.dismissedManualSegment = segment;
      this.manualSegment = null;
      this.emitNotice(null);
      logger.info(`manual prompt dismissed video=${this.videoId} category=${segment.category} `
        + `start=${segment.startSec.toFixed(2)}`);
      return;
    }
    if (this.poiSegment) {
      const segment = this.poiSegment;
      this.poiSegment = null;
      this.poiHandled = true;
      this.emitNotice(null);
      logger.info(`poi prompt dismissed video=${this.videoId} start=${segment.startSec.toFixed(2)}`);
      return;
    }
    if (this.currentNotice) {
      this.emitNotice(null);
    }
  }

  /** 配置变更后按当前视频重新取片段（开关/类别/隐私模式改了要立即生效）。 */
  reconnect(controller: AvPlayerController | null, video: VideoItem | null): void {
    if (!controller || !video) {
      this.onPlaybackStopped();
      return;
    }
    this.onVideoStarted(controller, video);
  }

  private detach(): void {
    this.generation += 1;
    if (this.controller) {
      this.controller.unsubscribeProgress(this.progressListener);
    }
    this.controller = null;
    this.videoId = '';
    this.segments = [];
    this.lastSegment = null;
    this.pendingSegment = null;
    this.suppressedSegment = null;
    this.manualSegment = null;
    this.dismissedManualSegment = null;
    this.poiSegment = null;
    this.poiHandled = false;
    this.lastSkipAtMs = 0;
    this.emitSegments();
    this.emitNotice(null);
  }

  private emitSegments(): void {
    const snapshot = this.segments.slice();
    for (const listener of this.segmentsListeners) {
      try {
        listener(snapshot);
      } catch (e) {
        logger.warn(`segments listener failed: ${(e as Error).message}`);
      }
    }
  }

  private emitNotice(notice: SponsorSkipNotice | null): void {
    this.currentNotice = notice;
    if (this.noticeListener) {
      this.noticeListener(notice);
    }
  }

  private onProgress(currentTime: number, durationTime: number): void {
    this.trySkip(currentTime, durationTime);
  }

  private trySkip(currentTime: number, durationTime: number): void {
    const controller = this.controller;
    const config = SponsorBlockSkipper.config();
    if (!controller || !config || !config.sponsorBlockEnabled) {
      return;
    }
    if (this.segments.length === 0 || durationTime <= 0) {
      return;
    }

    const state = controller.getPlaybackState();
    if (!state.isPlaying || state.isSeeking) {
      return;
    }
    const position = currentTime;
    if (position <= 0) {
      return;
    }

    if (config.sponsorBehavior === EXP_SB_BEHAVIOR_MANUAL) {
      this.cancelPending();
      this.tryManualSkip(position, durationTime, config);
      return;
    }
    if (this.manualSegment) {
      this.clearManualNotice();
    }
    this.dismissedManualSegment = null;

    const leadSec = SponsorBlockSkipper.leadSeconds(config);

    // 1. 已有待确认的提示：到片段起点就执行，用户拖远则取消。
    if (this.pendingSegment) {
      const pending = this.pendingSegment;
      if (position >= pending.startSec) {
        this.commitSkip(pending, durationTime);
        return;
      }
      if (position < pending.startSec - leadSec - PROMPT_REARM_SEC) {
        this.cancelPending();
      }
      return;
    }

    if (Date.now() - this.lastSkipAtMs < SKIP_DEBOUNCE_MS) {
      return;
    }

    // 2. 用户拖回片段之前 → 允许再次提示/跳过。
    if (this.lastSegment && position < this.lastSegment.startSec - PROMPT_REARM_SEC) {
      this.lastSegment = null;
    }

    // 3. 已选择放行的片段：本次播放内一直放行，**只在离开片段之后**才解除。
    // 不能在片段开始前用「回退阈值」清掉：提示出现在片段起点前 lead 秒，
    // 撤销时位置通常仍在 start-3 之前，若按回退阈值清除，下一帧就会再次
    // 弹提示，表现为「要点好几次才停」。
    if (this.suppressedSegment) {
      const suppressed = this.suppressedSegment;
      if (position > suppressed.endSec + SEGMENT_EDGE_MARGIN_SEC) {
        logger.info(`suppression cleared video=${this.videoId} `
          + `start=${suppressed.startSec.toFixed(2)} position=${position.toFixed(2)}`);
        this.suppressedSegment = null;
      } else {
        return;
      }
    }

    // 4. 已经处在片段内（续播/拖动进入）：没有提前提示的余地，直接跳。
    const current = this.findSegment(position);
    if (current && current !== this.lastSegment) {
      this.poiSegment = null;
      this.commitSkip(current, durationTime);
      return;
    }

    if (config.sponsorBehavior === EXP_SB_BEHAVIOR_SILENT) {
      this.evaluatePoiHighlight(position, durationTime, config);
      return;
    }

    // 5. 片段开始前 leadSec 秒内：弹出可撤销提示，起点时才真正跳。
    const upcoming = this.findUpcomingSegment(position, leadSec);
    if (upcoming && upcoming !== this.lastSegment) {
      this.poiSegment = null;
      this.pendingSegment = upcoming;
      this.lastSegment = upcoming;
      logger.info(`prompt video=${this.videoId} category=${upcoming.category} `
        + `start=${upcoming.startSec.toFixed(2)} position=${position.toFixed(2)} lead=${leadSec}s`);
      if (config.sponsorBehavior === EXP_SB_BEHAVIOR_TOAST) {
        this.emitNotice({
          mode: 'undo',
          category: upcoming.category,
          startSec: upcoming.startSec,
          endSec: upcoming.endSec
        });
      }
      return;
    }

    // 6. 无待处理跳过片段时，评估精彩片段（poi_highlight）一次性跳转提示。
    this.evaluatePoiHighlight(position, durationTime, config);
  }

  private tryManualSkip(position: number, durationTime: number, config: ExperimentalConfig): void {
    if (this.dismissedManualSegment) {
      const dismissed = this.dismissedManualSegment;
      if (position < dismissed.startSec - SEGMENT_EDGE_MARGIN_SEC
        || position > dismissed.endSec + SEGMENT_EDGE_MARGIN_SEC) {
        this.dismissedManualSegment = null;
      }
    }
    const current = this.findSegment(position);
    if (current && current !== this.dismissedManualSegment) {
      if (this.poiSegment) {
        this.poiSegment = null;
      }
      if (this.manualSegment !== current) {
        this.manualSegment = current;
        logger.info(`manual prompt video=${this.videoId} category=${current.category} `
          + `start=${current.startSec.toFixed(2)} end=${current.endSec.toFixed(2)} `
          + `position=${position.toFixed(2)}`);
        this.emitNotice({
          mode: 'manual',
          category: current.category,
          startSec: current.startSec,
          endSec: current.endSec
        });
      }
      return;
    }
    if (this.manualSegment) {
      this.clearManualNotice();
    }
    this.evaluatePoiHighlight(position, durationTime, config);
  }

  private clearManualNotice(): void {
    if (!this.manualSegment) {
      return;
    }
    logger.info(`manual prompt cleared video=${this.videoId} `
      + `start=${this.manualSegment.startSec.toFixed(2)}`);
    this.manualSegment = null;
    if (this.currentNotice && this.currentNotice.mode === 'manual') {
      this.emitNotice(null);
    }
  }

  private evaluatePoiHighlight(position: number, durationTime: number, config: ExperimentalConfig): void {
    if (!config.isSponsorCategoryEnabled(EXP_CATEGORY_HIGHLIGHT)) {
      if (this.poiSegment) {
        this.poiSegment = null;
        if (this.currentNotice && this.currentNotice.mode === 'poi') {
          this.emitNotice(null);
        }
      }
      return;
    }
    const poi = this.findPoiHighlight();
    if (!poi || poi.startSec >= durationTime - 0.5) {
      return;
    }
    if (this.poiSegment) {
      if (position >= poi.startSec - POI_LEAD_THRESHOLD_SEC) {
        this.poiSegment = null;
        this.poiHandled = true;
        if (this.currentNotice && this.currentNotice.mode === 'poi') {
          this.emitNotice(null);
        }
      }
      return;
    }
    if (this.poiHandled) {
      return;
    }
    if (position < poi.startSec - POI_LEAD_THRESHOLD_SEC) {
      this.poiSegment = poi;
      logger.info(`poi prompt video=${this.videoId} start=${poi.startSec.toFixed(2)} `
        + `position=${position.toFixed(2)}`);
      this.emitNotice({
        mode: 'poi',
        category: poi.category,
        startSec: poi.startSec,
        endSec: poi.endSec
      });
    } else {
      // 视频从精彩处附近或之后续播：不再弹提示。
      this.poiHandled = true;
    }
  }

  private commitSkip(segment: SponsorSegment, durationTime: number): void {
    const controller = this.controller;
    if (!controller) {
      return;
    }
    const targetSec = Math.min(
      segment.endSec + SEGMENT_EDGE_MARGIN_SEC,
      Math.max(0, durationTime - 0.2)
    );
    const state = controller.getPlaybackState();
    if (targetSec <= state.currentTime) {
      this.cancelPending();
      this.manualSegment = null;
      this.emitNotice(null);
      return;
    }
    this.pendingSegment = null;
    this.manualSegment = null;
    this.lastSegment = segment;
    this.lastSkipAtMs = Date.now();
    this.emitNotice(null);
    controller.syncSeek(targetSec * 1000);
    logger.info(`skip video=${this.videoId} category=${segment.category} `
      + `from=${state.currentTime.toFixed(2)} to=${targetSec.toFixed(2)}`);
  }

  private cancelPending(): void {
    if (!this.pendingSegment) {
      return;
    }
    logger.info(`prompt cancelled video=${this.videoId} `
      + `start=${this.pendingSegment.startSec.toFixed(2)}`);
    this.pendingSegment = null;
    if (this.currentNotice && this.currentNotice.mode === 'undo') {
      this.emitNotice(null);
    }
  }

  private findPoiHighlight(): SponsorSegment | null {
    for (const segment of this.segments) {
      if (segment.actionType === 'poi' && segment.category === EXP_CATEGORY_HIGHLIGHT
        && segment.startSec > POI_MIN_START_SEC) {
        return segment;
      }
    }
    return null;
  }

  private findSegment(position: number): SponsorSegment | null {
    for (const segment of this.segments) {
      if (segment.actionType !== 'skip') {
        continue;
      }
      if (position >= segment.startSec && position < segment.endSec) {
        return segment;
      }
    }
    return null;
  }

  /** 位置在片段起点前 lead 秒内、且尚未到起点。 */
  private findUpcomingSegment(position: number, leadSec: number): SponsorSegment | null {
    for (const segment of this.segments) {
      if (segment.actionType !== 'skip') {
        continue;
      }
      if (position < segment.startSec && position >= segment.startSec - leadSec) {
        return segment;
      }
    }
    return null;
  }

  private static leadSeconds(config: ExperimentalConfig): number {
    const value = config.sponsorUnskipSeconds;
    if (!Number.isFinite(value)) {
      return PROMPT_MIN_LEAD_SEC;
    }
    return Math.min(PROMPT_MAX_LEAD_SEC, Math.max(1, value));
  }

  private static config(): ExperimentalConfig | null {
    return AppStorage.get<ExperimentalConfig>('experimentalConfig') ?? null;
  }
}
