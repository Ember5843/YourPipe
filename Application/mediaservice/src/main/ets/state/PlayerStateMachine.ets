/*
 * 播放器状态机 —— 播放器生命周期的唯一权威
 *
 * 职责：
 *   1. 持有当前 PlayerState
 *   2. 校验并执行状态转换
 *   3. 通知所有订阅者状态变更
 *
 * 各子系统（Surface / PiP / AVSession / BackgroundTask）通过
 * addListener / removeListener 订阅状态变更，并自行决定响应策略，
 * 不再由上层手动编排操作顺序。
 */

import { PlayerState, isValidTransition, describeState } from './PlayerState';

export interface StateChangeListener {
  onStateChange(from: PlayerState, to: PlayerState): void;
}

export class PlayerStateMachine {
  private _currentState: PlayerState = PlayerState.IDLE;
  private listeners: StateChangeListener[] = [];
  private debugTag: string = '[PlayerStateMachine]';

  get currentState(): PlayerState {
    return this._currentState;
  }

  setDebugTag(tag: string): void {
    this.debugTag = tag;
  }

  isAtLeast(state: PlayerState): boolean {
    return this._currentState === state;
  }

  isOneOf(...states: PlayerState[]): boolean {
    return states.includes(this._currentState);
  }

  isPlayingOrPip(): boolean {
    return this._currentState === PlayerState.PLAYING
      || this._currentState === PlayerState.PIP_ACTIVE
      || this._currentState === PlayerState.PIP_ENTERING
      || this._currentState === PlayerState.PAUSED
      || this._currentState === PlayerState.BUFFERING;
  }

  isPipRelated(): boolean {
    return this._currentState === PlayerState.PIP_ENTERING
      || this._currentState === PlayerState.PIP_ACTIVE
      || this._currentState === PlayerState.PIP_RESTORING;
  }

  canPlay(): boolean {
    return this._currentState === PlayerState.READY
      || this._currentState === PlayerState.PAUSED
      || this._currentState === PlayerState.COMPLETED;
  }

  canLoad(): boolean {
    return this._currentState === PlayerState.IDLE
      || this._currentState === PlayerState.READY
      || this._currentState === PlayerState.ERROR;
  }

  /**
   * 尝试状态转换。
   * @returns true 表示转换成功，false 表示非法转换被拒绝
   */
  transition(to: PlayerState): boolean {
    const from = this._currentState;
    if (from === to) {
      return true;
    }
    if (!isValidTransition(from, to)) {
      const allowed = this.getAllowedTransitions(from);
      console.error(
        `${this.debugTag} Illegal transition: ${describeState(from)} → ${describeState(to)}. ` +
        `Allowed: [${allowed.map(s => describeState(s)).join(', ')}]`
      );
      return false;
    }
    this._currentState = to;
    console.info(`${this.debugTag} ${describeState(from)} → ${describeState(to)}`);
    this.notifyListeners(from, to);
    return true;
  }

  /**
   * 强制转换（跳过校验），仅在特殊场景使用（如引擎层同步重置）
   */
  forceTransition(to: PlayerState): void {
    const from = this._currentState;
    if (from === to) return;
    this._currentState = to;
    console.warn(`${this.debugTag} [FORCE] ${describeState(from)} → ${describeState(to)}`);
    this.notifyListeners(from, to);
  }

  addListener(listener: StateChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: StateChangeListener): void {
    this.listeners = this.listeners.filter(l => l !== listener);
  }

  removeAllListeners(): void {
    this.listeners = [];
  }

  private getAllowedTransitions(from: PlayerState): PlayerState[] {
    switch (from) {
      case PlayerState.IDLE:           return [PlayerState.INITIALIZING, PlayerState.RELEASED];
      case PlayerState.INITIALIZING:   return [PlayerState.LOADING, PlayerState.IDLE, PlayerState.ERROR, PlayerState.RELEASED];
      case PlayerState.LOADING:        return [PlayerState.READY, PlayerState.ERROR, PlayerState.IDLE, PlayerState.RELEASED];
      case PlayerState.READY:          return [PlayerState.PLAYING, PlayerState.LOADING, PlayerState.IDLE, PlayerState.RELEASED];
      case PlayerState.PLAYING:        return [PlayerState.PAUSED, PlayerState.BUFFERING, PlayerState.COMPLETED, PlayerState.PIP_ENTERING, PlayerState.ERROR, PlayerState.IDLE, PlayerState.RELEASED];
      case PlayerState.PAUSED:         return [PlayerState.PLAYING, PlayerState.ERROR, PlayerState.IDLE, PlayerState.RELEASED, PlayerState.PIP_ENTERING];
      case PlayerState.BUFFERING:      return [PlayerState.PLAYING, PlayerState.PAUSED, PlayerState.ERROR, PlayerState.RELEASED];
      case PlayerState.COMPLETED:      return [PlayerState.PLAYING, PlayerState.IDLE, PlayerState.RELEASED];
      case PlayerState.PIP_ENTERING:   return [PlayerState.PIP_ACTIVE, PlayerState.PLAYING, PlayerState.ERROR, PlayerState.RELEASED];
      case PlayerState.PIP_ACTIVE:     return [PlayerState.PIP_RESTORING, PlayerState.PAUSED, PlayerState.IDLE, PlayerState.RELEASED, PlayerState.ERROR];
      case PlayerState.PIP_RESTORING:  return [PlayerState.PLAYING, PlayerState.PIP_ACTIVE, PlayerState.ERROR, PlayerState.RELEASED];
      case PlayerState.ERROR:          return [PlayerState.LOADING, PlayerState.IDLE, PlayerState.RELEASED];
      case PlayerState.RELEASED:       return [PlayerState.IDLE];
      default: return [];
    }
  }

  private notifyListeners(from: PlayerState, to: PlayerState): void {
    for (const listener of this.listeners) {
      try {
        listener.onStateChange(from, to);
      } catch (e) {
        console.error(`${this.debugTag} Listener error: ${e}`);
      }
    }
  }
}
