/*
 * 播放器状态枚举与合法转换定义
 *
 * 设计原则：
 *   1. 状态是播放器的唯一权威来源，替代散落在各处的布尔标志。
 *   2. 每个状态对应一组明确的子系统行为（Surface / PiP / AVSession / BackgroundTask），
 *      各子系统独立订阅状态变更，不再由 PlayerSession 手动编排。
 *   3. 只有 VALID_TRANSITIONS 中声明的转换才被允许，非法转换直接拒绝。
 */

export enum PlayerState {
  IDLE = 'idle',
  INITIALIZING = 'initializing',
  LOADING = 'loading',
  READY = 'ready',
  PLAYING = 'playing',
  PAUSED = 'paused',
  BUFFERING = 'buffering',
  COMPLETED = 'completed',
  RELEASED = 'released',
  ERROR = 'error'
}

const VALID_TRANSITIONS: Map<PlayerState, PlayerState[]> = new Map([
  [PlayerState.IDLE,           [PlayerState.INITIALIZING, PlayerState.RELEASED]],
  [PlayerState.INITIALIZING,   [PlayerState.LOADING, PlayerState.READY, PlayerState.IDLE, PlayerState.ERROR, PlayerState.RELEASED]],
  [PlayerState.LOADING,        [PlayerState.READY, PlayerState.ERROR, PlayerState.IDLE, PlayerState.RELEASED]],
  [PlayerState.READY,          [PlayerState.PLAYING, PlayerState.LOADING, PlayerState.PAUSED, PlayerState.BUFFERING, PlayerState.IDLE, PlayerState.RELEASED]],
  [PlayerState.PLAYING,        [
    PlayerState.PAUSED, PlayerState.BUFFERING, PlayerState.COMPLETED, PlayerState.LOADING,
    PlayerState.ERROR, PlayerState.IDLE, PlayerState.RELEASED
  ]],
  [PlayerState.PAUSED,         [PlayerState.PLAYING, PlayerState.LOADING, PlayerState.BUFFERING,
                                PlayerState.ERROR, PlayerState.IDLE, PlayerState.RELEASED]],
  [PlayerState.BUFFERING,      [PlayerState.PLAYING, PlayerState.PAUSED, PlayerState.LOADING,
                                PlayerState.COMPLETED, PlayerState.ERROR, PlayerState.RELEASED]],
  [PlayerState.COMPLETED,      [PlayerState.PLAYING, PlayerState.LOADING, PlayerState.IDLE, PlayerState.RELEASED]],
  [PlayerState.ERROR,          [PlayerState.LOADING, PlayerState.IDLE, PlayerState.RELEASED]],
  [PlayerState.RELEASED,       [PlayerState.IDLE]],
]);

export function isValidTransition(from: PlayerState, to: PlayerState): boolean {
  const allowed = VALID_TRANSITIONS.get(from);
  return allowed !== undefined && allowed.includes(to);
}

export function describeState(state: PlayerState): string {
  return `PlayerState.${state.toUpperCase()}`;
}
