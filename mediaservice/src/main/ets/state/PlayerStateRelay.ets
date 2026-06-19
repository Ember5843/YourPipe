/*
 * PlayerStateRelay — 播放器状态的单一权威路由层
 *
 * 职责：
 *   1. 接收 MpvPlaybackEngine 推来的 PlaybackState
 *   2. 同步驱动 PlayerStateMachine 状态转换
 *   3. 推送给 AvSessionManager（节流）
 *   4. 向 UI 发布节流后的进度更新
 *
 * 设计原则：
 *   - 不入库 @Track（不直接参与 ArkTS 响应式），由 AvPlayerController 担任 @Track 宿主
 *   - progressSubscribers 仅在 currentTime/durationTime 发生变化时发布，避免高频触发 UI 重渲染
 */

import { PlaybackState } from '../engine/PlaybackEngine';
import { AvSessionManager } from '../common/AvSessionManager';
import { PlayerStateMachine } from './PlayerStateMachine';
import { PlayerState } from './PlayerState';
import Logger from '../utils/Logger';

const TAG: string = '[PlayerStateRelay]';

export type ProgressSubscriber = (currentTime: number, durationTime: number) => void;

export class PlayerStateRelay {
  private stateMachine: PlayerStateMachine | null = null;
  private avSession: AvSessionManager | null = null;

  // Progress throttling
  private progressSubscribers: Set<ProgressSubscriber> = new Set();
  private lastPublishedCurrentTime: number = -1;
  private lastPublishedDuration: number = -1;

  // Ended event subscribers
  private endedSubscribers: Set<() => void> = new Set();

  // AVSession push throttling
  private lastAvSessionState: PlaybackState | null = null;
  private avSessionPushScheduled: boolean = false;

  // Edge-detection cache for state machine
  private prevIsPlaying: boolean = false;
  private prevIsBuffering: boolean = false;
  private prevIsReady: boolean = false;
  private prevIsEnded: boolean = false;
  private prevIsSeeking: boolean = false;
  private prevErrorMsg: string = '';
  private prevDuration: number = 0;

  setStateMachine(sm: PlayerStateMachine): void {
    this.stateMachine = sm;
  }

  setAvSession(am: AvSessionManager): void {
    this.avSession = am;
  }

  /**
   * 引擎每次状态变更时调用（事件驱动，非轮询）
   */
  onStateChange(state: PlaybackState): void {
    // 1. 状态机转换
    this.syncStateMachine(state);

    // 2. 播放结束事件通知
    if (state.isEnded && !this.prevIsEnded) {
      for (const cb of this.endedSubscribers) {
        try { cb(); } catch (e) { Logger.warn(TAG, `endedSubscriber error: ${e}`); }
      }
    }

    // 3. AVSession 推送（有状态变化时才推 + 节流）
    if (this.shouldPushToAvSession(state)) {
      this.scheduleAvSessionPush(state);
    }

    // 4. 进度发布（节流至下一帧）
    this.scheduleProgressPublish(state);

    // 5. 缓存当前值用于下一次 edge detection
    this.cacheForNext(state);
  }

  subscribeProgress(cb: ProgressSubscriber): void {
    this.progressSubscribers.add(cb);
  }

  unsubscribeProgress(cb: ProgressSubscriber): void {
    this.progressSubscribers.delete(cb);
  }

  subscribeEnded(cb: () => void): void {
    this.endedSubscribers.add(cb);
  }

  unsubscribeEnded(cb: () => void): void {
    this.endedSubscribers.delete(cb);
  }

  get currentTime(): number {
    return this.lastPublishedCurrentTime >= 0 ? this.lastPublishedCurrentTime : 0;
  }

  // ── private ──

  private syncStateMachine(state: PlaybackState): void {
    const sm: PlayerStateMachine | null = this.stateMachine;
    if (sm === null) return;

    const readyChanged: boolean = this.prevIsReady !== state.isReady;
    const endedChanged = !this.prevIsEnded && state.isEnded;
    const bufferingChanged = this.prevIsBuffering !== state.isBuffering;
    const playingChanged = this.prevIsPlaying !== state.isPlaying;
    const errorChanged = this.prevErrorMsg !== state.errorMsg && !!state.errorMsg;

    if (readyChanged && state.isReady && sm.isOneOf(PlayerState.LOADING)) {
      sm.transition(PlayerState.READY);
    }
    if (endedChanged && state.isEnded) {
      sm.transition(PlayerState.COMPLETED);
    }
    if (bufferingChanged && state.isBuffering &&
      sm.isOneOf(PlayerState.PLAYING, PlayerState.READY)) {
      sm.forceTransition(PlayerState.BUFFERING);
    }
    if (playingChanged && state.isPlaying && !state.isBuffering &&
      sm.isOneOf(PlayerState.READY, PlayerState.PAUSED, PlayerState.BUFFERING,
        PlayerState.COMPLETED)) {
      sm.transition(PlayerState.PLAYING);
    }
    if (errorChanged && state.errorMsg &&
      sm.isOneOf(PlayerState.LOADING, PlayerState.PLAYING, PlayerState.PAUSED,
        PlayerState.BUFFERING)) {
      sm.transition(PlayerState.ERROR);
    }
  }

  private shouldPushToAvSession(state: PlaybackState): boolean {
    const prev = this.lastAvSessionState;
    if (!prev) return true;

    return prev.isPlaying !== state.isPlaying
      || prev.isBuffering !== state.isBuffering
      || prev.isSeeking !== state.isSeeking
      || prev.isEnded !== state.isEnded
      || prev.errorMsg !== state.errorMsg
      || prev.playbackSpeed !== state.playbackSpeed
      || (this.prevDuration === 0 && state.duration > 0);
  }

  private scheduleAvSessionPush(state: PlaybackState): void {
    if (this.avSessionPushScheduled) return;
    this.avSessionPushScheduled = true;

    const push = () => {
      this.avSessionPushScheduled = false;
      const session: AvSessionManager | null = this.avSession;
      if (session === null) return;
      session.setPlaybackState(
        state.isPlaying,
        state.currentTime,
        state.playbackSpeed,
        state.isBuffering || state.isSeeking,
        state.isEnded
      );
      this.lastAvSessionState = state;
    };

    // 立即推（非节流），状态变化需要第一时间同步到锁屏
    push();
  }

  private scheduleProgressPublish(state: PlaybackState): void {
    // currentTime 和 durationTime 都未变化则跳过
    if (this.lastPublishedCurrentTime === state.currentTime &&
        this.lastPublishedDuration === state.duration) {
      return;
    }

    this.lastPublishedCurrentTime = state.currentTime;
    this.lastPublishedDuration = state.duration;
    for (const cb of this.progressSubscribers) {
      try {
        cb(state.currentTime, state.duration);
      } catch (e) {
        Logger.warn(TAG, `progressSubscriber error: ${e}`);
      }
    }
  }

  private cacheForNext(state: PlaybackState): void {
    this.prevIsPlaying = state.isPlaying;
    this.prevIsBuffering = state.isBuffering;
    this.prevIsReady = state.isReady;
    this.prevIsEnded = state.isEnded;
    this.prevIsSeeking = state.isSeeking;
    this.prevErrorMsg = state.errorMsg;
    this.prevDuration = state.duration;
  }
}
