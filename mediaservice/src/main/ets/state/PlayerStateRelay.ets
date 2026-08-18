/*
 * PlayerStateRelay — 播放器状态的单一权威路由层
 *
 * 职责：
 *   1. 接收 MpvPlaybackEngine 推来的 PlaybackState
 *   2. 同步驱动 PlayerStateMachine 状态转换
 *   3. 推送给 AvSessionManager（状态变化时同步直推，无节流）
 *   4. 向 UI 发布去重后的进度更新（currentTime/duration 变化才发）
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
export type PlaybackStateSubscriber = (state: PlaybackState) => void;

export class PlayerStateRelay {
  private stateMachine: PlayerStateMachine | null = null;
  private avSession: AvSessionManager | null = null;

  // Progress throttling
  private progressSubscribers: Set<ProgressSubscriber> = new Set();
  private playbackStateSubscribers: Set<PlaybackStateSubscriber> = new Set();
  private lastPublishedCurrentTime: number = -1;
  private lastPublishedDuration: number = -1;

  // Ended event subscribers
  private endedSubscribers: Set<() => void> = new Set();

  // AVSession push change detection
  private hasAvSessionState: boolean = false;
  private lastAvSessionIsPlaying: boolean = false;
  private lastAvSessionIsBuffering: boolean = false;
  private lastAvSessionIsSeeking: boolean = false;
  private lastAvSessionIsEnded: boolean = false;
  private lastAvSessionErrorMsg: string = '';
  private lastAvSessionPlaybackSpeed: number = 1;

  // Edge-detection cache for state machine
  private prevIsPlaying: boolean = false;
  private prevIsBuffering: boolean = false;
  private prevIsReady: boolean = false;
  private prevIsEnded: boolean = false;
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
    // Publish the exact MPV snapshot to consumers which must match the page's
    // vm.isPlaying semantics (PiP, external presentation surfaces, etc.).
    for (const cb of this.playbackStateSubscribers) {
      try { cb(state); } catch (e) { Logger.warn(TAG, `playbackStateSubscriber error: ${e}`); }
    }

    // 1. 状态机转换
    this.syncStateMachine(state);

    // 2. 播放结束事件通知
    if (state.isEnded && !this.prevIsEnded) {
      for (const cb of this.endedSubscribers) {
        try { cb(); } catch (e) { Logger.warn(TAG, `endedSubscriber error: ${e}`); }
      }
    }

    // 3. AVSession 推送（有状态变化时才推）
    if (this.shouldPushToAvSession(state)) {
      this.scheduleAvSessionPush(state);
    }

    // 4. 进度发布（值变化时同步发布）
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

  subscribePlaybackState(cb: PlaybackStateSubscriber): void {
    this.playbackStateSubscribers.add(cb);
  }

  unsubscribePlaybackState(cb: PlaybackStateSubscriber): void {
    this.playbackStateSubscribers.delete(cb);
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

  /** Reset per-media edge and throttle state while retaining UI subscribers. */
  resetMediaSession(): void {
    this.lastPublishedCurrentTime = -1;
    this.lastPublishedDuration = -1;
    this.hasAvSessionState = false;
    this.lastAvSessionIsPlaying = false;
    this.lastAvSessionIsBuffering = false;
    this.lastAvSessionIsSeeking = false;
    this.lastAvSessionIsEnded = false;
    this.lastAvSessionErrorMsg = '';
    this.lastAvSessionPlaybackSpeed = 1;
    this.prevIsPlaying = false;
    this.prevIsBuffering = false;
    this.prevIsReady = false;
    this.prevIsEnded = false;
    this.prevErrorMsg = '';
    this.prevDuration = 0;
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

    // Automatic recovery must leave ERROR through LOADING before normal state
    // transitions resume. Otherwise PiP/AVSession keep seeing a stale ERROR
    // even after MPV has cleared the error and is already playing.
    if (sm.isOneOf(PlayerState.ERROR) && !state.errorMsg) {
      sm.transition(PlayerState.LOADING);
      if (state.isReady) {
        sm.transition(PlayerState.READY);
        if (state.isBuffering) {
          sm.forceTransition(PlayerState.BUFFERING);
        } else if (state.isPlaying) {
          sm.transition(PlayerState.PLAYING);
        }
      }
    }

    // ── 进入 BUFFERING ──
    if (bufferingChanged && state.isBuffering &&
      sm.isOneOf(PlayerState.PLAYING, PlayerState.READY, PlayerState.PAUSED)) {
      sm.forceTransition(PlayerState.BUFFERING);
    }

    // ── 退出 BUFFERING ──
    if (bufferingChanged && !state.isBuffering &&
      sm.isOneOf(PlayerState.BUFFERING)) {
      sm.forceTransition(state.isPlaying ? PlayerState.PLAYING : PlayerState.PAUSED);
    }

    // ── 变为暂停（用户暂停 / 系统中断 / 缓冲结束但未播放）──
    if (playingChanged && !state.isPlaying && !state.isEnded &&
      sm.isOneOf(PlayerState.PLAYING, PlayerState.BUFFERING, PlayerState.READY, PlayerState.COMPLETED)) {
      sm.transition(PlayerState.PAUSED);
    }

    // ── 变为播放（暂停后恢复 / 缓冲后恢复 / 完成重播）──
    if (playingChanged && state.isPlaying && !state.isBuffering &&
      sm.isOneOf(PlayerState.READY, PlayerState.PAUSED, PlayerState.BUFFERING,
        PlayerState.COMPLETED)) {
      sm.transition(PlayerState.PLAYING);
    }

    // ── 首次就绪 ──
    if (readyChanged && state.isReady && sm.isOneOf(PlayerState.LOADING)) {
      sm.transition(PlayerState.READY);
    }

    // ── 播放结束 ──
    if (endedChanged && state.isEnded) {
      sm.transition(PlayerState.COMPLETED);
    }

    // ── 进入错误 ──
    if (errorChanged && state.errorMsg &&
      sm.isOneOf(PlayerState.LOADING, PlayerState.PLAYING, PlayerState.PAUSED,
        PlayerState.BUFFERING)) {
      sm.transition(PlayerState.ERROR);
    }
  }

  private shouldPushToAvSession(state: PlaybackState): boolean {
    if (!this.hasAvSessionState) return true;

    return this.lastAvSessionIsPlaying !== state.isPlaying
      || this.lastAvSessionIsBuffering !== state.isBuffering
      || this.lastAvSessionIsSeeking !== state.isSeeking
      || this.lastAvSessionIsEnded !== state.isEnded
      || this.lastAvSessionErrorMsg !== state.errorMsg
      || this.lastAvSessionPlaybackSpeed !== state.playbackSpeed
      || (this.prevDuration === 0 && state.duration > 0);
  }

  private scheduleAvSessionPush(state: PlaybackState): void {
    // 立即推（非节流），状态变化需要第一时间同步到锁屏
    const session: AvSessionManager | null = this.avSession;
    if (session === null) return;
    session.setPlaybackState(
      state.engineState,
      state.isPlaying,
      state.currentTime,
      state.playbackSpeed,
      state.isBuffering || state.isSeeking,
      state.isEnded
    );
    // Cache values instead of retaining an engine-owned state object. This keeps
    // edge detection reliable even if an engine later reuses/mutates snapshots.
    this.hasAvSessionState = true;
    this.lastAvSessionIsPlaying = state.isPlaying;
    this.lastAvSessionIsBuffering = state.isBuffering;
    this.lastAvSessionIsSeeking = state.isSeeking;
    this.lastAvSessionIsEnded = state.isEnded;
    this.lastAvSessionErrorMsg = state.errorMsg;
    this.lastAvSessionPlaybackSpeed = state.playbackSpeed;
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
    this.prevErrorMsg = state.errorMsg;
    this.prevDuration = state.duration;
  }
}
