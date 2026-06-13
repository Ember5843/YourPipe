/*
 * PipStateMachine —— 纯逻辑状态机，无系统调用
 *
 * 职责：
 *   1. 持有当前 PipState
 *   2. 校验并执行转换
 *   3. 通知监听器
 *
 * 所有副作用（调用 PiPWindow API、push/pop 导航、同步播放状态）
 * 都由 PipBinding 在监听器里集中处理，本类绝不直接触达。
 */

import { AppLog } from '../../../common/AppLog';
import { PipState, isValidPipTransition } from './PipState';

const TAG = '[PipStateMachine]';
const logger = AppLog.getInstance('PipStateMachine');

export interface PipStateChangeListener {
  onPipStateChange(from: PipState, to: PipState): void;
}

export class PipStateMachine {
  private _state: PipState = PipState.DISABLED;
  private listeners: PipStateChangeListener[] = [];

  get state(): PipState {
    return this._state;
  }

  isOneOf(...states: PipState[]): boolean {
    return states.includes(this._state);
  }

  isVisible(): boolean {
    return this._state === PipState.ACTIVE
      || this._state === PipState.ENTERING
      || this._state === PipState.RESTORING;
  }

  /** 尝试转换。不合法则返回 false 并打印日志。 */
  transition(to: PipState): boolean {
    const from = this._state;
    if (from === to) return true;
    if (!isValidPipTransition(from, to)) {
      logger.warn(`${TAG} illegal transition: ${from} -> ${to}`);
      return false;
    }
    this._state = to;
    logger.info(`${TAG} ${from} -> ${to}`);
    this.notify(from, to);
    return true;
  }

  addListener(l: PipStateChangeListener): void {
    if (!this.listeners.includes(l)) this.listeners.push(l);
  }

  removeListener(l: PipStateChangeListener): void {
    this.listeners = this.listeners.filter(x => x !== l);
  }

  private notify(from: PipState, to: PipState): void {
    for (const l of this.listeners) {
      try {
        l.onPipStateChange(from, to);
      } catch (e) {
        logger.error(`${TAG} listener error: ${e}`);
      }
    }
  }
}
