import { AvPlayerController } from 'mediaservice';
import { VideoItem } from 'youtube_core';
import { AppLog } from '../AppLog';
import {
  ExperimentalConfig,
  EXP_SB_BEHAVIOR_MANUAL,
  EXP_SB_BEHAVIOR_TOAST
} from './ExperimentalConfig';
import { SponsorBlockClient, SponsorSegment } from './SponsorBlockClient';

const logger = AppLog.getInstance('SponsorBlockSkipper');

const SKIP_DEBOUNCE_MS: number = 800;
const SEGMENT_EDGE_MARGIN_SEC: number = 0.05;
const REWIND_REARM_SEC: number = 2;

export interface SponsorSkipNotice {
  category: string;
  startSec: number;
  endSec: number;
}

/**
 * SponsorBlock 跳过策略：订阅当前控制器的播放进度，命中片段后 seek 到片段末尾。
 * 只依赖 mediaservice 的控制器与 VideoItem，不依赖播放页组件 —— 后台音频 / PiP
 * 也能继续跳过。
 */
export class SponsorBlockSkipper {
  private static instance: SponsorBlockSkipper | null = null;

  private controller: AvPlayerController | null = null;
  private videoId: string = '';
  private segments: SponsorSegment[] = [];
  private lastSegment: SponsorSegment | null = null;
  /** 提示条「撤销」的目标：只在新视频/新跳过/撤销时更新，不被进度事件清空。 */
  private undoSegment: SponsorSegment | null = null;
  /** 用户点「撤销」后暂时放行的片段；离开片段范围后自动解除。 */
  private suppressedSegment: SponsorSegment | null = null;
  private lastSkipAtMs: number = 0;
  private generation: number = 0;
  private noticeListener: ((notice: SponsorSkipNotice | null) => void) | null = null;

  private progressListener = (currentTime: number, durationTime: number): void => {
    this.onProgress(currentTime, durationTime);
  };

  static getInstance(): SponsorBlockSkipper {
    if (!SponsorBlockSkipper.instance) {
      SponsorBlockSkipper.instance = new SponsorBlockSkipper();
    }
    return SponsorBlockSkipper.instance;
  }

  /** 播放页注册提示层；页面销毁时传 null。 */
  setNoticeListener(listener: ((notice: SponsorSkipNotice | null) => void) | null): void {
    this.noticeListener = listener;
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
      + `privacy=${config.sponsorPrivacyMode}`);
    SponsorBlockClient.getInstance()
      .getSegments(videoId, categories, config.sponsorServer, config.sponsorPrivacyMode)
      .then((segments: SponsorSegment[]) => {
        if (generation !== this.generation) {
          return;
        }
        this.segments = segments;
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

  /** 用户在提示条上点「撤销」：回到片段起点，并放行该片段。 */
  undo(): boolean {
    const segment = this.undoSegment;
    const controller = this.controller;
    if (!segment || !controller) {
      logger.warn(`undo ignored video=${this.videoId} segment=${segment ? 'set' : 'none'} controller=${controller ? 'set' : 'none'}`);
      return false;
    }
    this.suppressedSegment = segment;
    this.lastSegment = null;
    this.undoSegment = null;
    if (this.noticeListener) {
      this.noticeListener(null);
    }
    controller.syncSeek(Math.max(0, (segment.startSec + SEGMENT_EDGE_MARGIN_SEC) * 1000));
    logger.info(`undo skip video=${this.videoId} category=${segment.category} `
      + `start=${segment.startSec.toFixed(2)}`);
    return true;
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
    this.undoSegment = null;
    this.suppressedSegment = null;
    this.lastSkipAtMs = 0;
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
    if (config.sponsorBehavior === EXP_SB_BEHAVIOR_MANUAL) {
      return;
    }
    if (this.segments.length === 0 || durationTime <= 0) {
      return;
    }

    const state = controller.getPlaybackState();
    // seek 过程中 MPV 的 time-pos 可能短暂回落（甚至 0）。若此时先做
    // 「拖回片段之前」判断，会把 lastSegment 清掉，提示条的撤销随即失效。
    // 因此所有状态判断必须先于 rearm。
    if (!state.isPlaying || state.isSeeking) {
      return;
    }
    const position = currentTime;
    if (position <= 0 || Date.now() - this.lastSkipAtMs < SKIP_DEBOUNCE_MS) {
      return;
    }
    // 用户真正拖回片段之前 → 重新武装，允许再次跳过。
    if (this.lastSegment && position < this.lastSegment.startSec - REWIND_REARM_SEC) {
      this.lastSegment = null;
    }
    if (this.suppressedSegment) {
      const suppressed = this.suppressedSegment;
      if (position < suppressed.startSec - REWIND_REARM_SEC
        || position > suppressed.endSec + SEGMENT_EDGE_MARGIN_SEC) {
        this.suppressedSegment = null;
      } else {
        return;
      }
    }

    const segment = this.findSegment(position);
    if (!segment || segment === this.lastSegment) {
      return;
    }

    const targetSec = Math.min(
      segment.endSec + SEGMENT_EDGE_MARGIN_SEC,
      Math.max(0, durationTime - 0.2)
    );
    if (targetSec <= position) {
      return;
    }

    this.lastSegment = segment;
    this.undoSegment = segment;
    this.lastSkipAtMs = Date.now();
    controller.syncSeek(targetSec * 1000);
    logger.info(`skip video=${this.videoId} category=${segment.category} `
      + `from=${position.toFixed(2)} to=${targetSec.toFixed(2)}`);
    if (config.sponsorBehavior === EXP_SB_BEHAVIOR_TOAST && this.noticeListener) {
      this.noticeListener({
        category: segment.category,
        startSec: segment.startSec,
        endSec: segment.endSec
      });
    }
  }

  private findSegment(position: number): SponsorSegment | null {
    for (const segment of this.segments) {
      if (segment.actionType !== 'skip' && segment.actionType !== 'poi') {
        continue;
      }
      if (position >= segment.startSec && position < segment.endSec) {
        return segment;
      }
    }
    return null;
  }

  private static config(): ExperimentalConfig | null {
    return AppStorage.get<ExperimentalConfig>('experimentalConfig') ?? null;
  }
}

