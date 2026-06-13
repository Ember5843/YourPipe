/*
 * PipState —— 画中画窗口的独立状态轴
 *
 * 与 PlayerState（播放器引擎状态）正交。播放器是否暂停、是否就绪和
 * "PiP 窗口是否显示"是两个维度，分开维护避免组合爆炸。
 *
 * 状态转换：
 *   DISABLED ──init()──▶ INACTIVE
 *                          │
 *                          ├─enter()──▶ ENTERING ──onSTARTED──▶ ACTIVE
 *                          │                                     │
 *                          │                                     ├─onABOUT_TO_RESTORE──▶ RESTORING ──onSTOPPED──▶ INACTIVE
 *                          │                                     │
 *                          │                                     └─exit()/系统STOPPED──▶ EXITING ──onSTOPPED──▶ INACTIVE
 *                          │
 *                          └─dispose()──▶ DISABLED
 */

export enum PipState {
  /** 未初始化，或被 dispose */
  DISABLED = 'DISABLED',
  /** 已 create PiP controller，但窗口未显示 */
  INACTIVE = 'INACTIVE',
  /** 调用了 startPiP()，等待系统回 STARTED */
  ENTERING = 'ENTERING',
  /** 窗口正在前台显示 */
  ACTIVE = 'ACTIVE',
  /** 用户点了恢复按钮，正在导航回 PlayerPage */
  RESTORING = 'RESTORING',
  /** 应用主动 stopPiP() 或用户关闭，等待系统回 STOPPED */
  EXITING = 'EXITING',
}

const VALID: Map<PipState, PipState[]> = new Map([
  [PipState.DISABLED,  [PipState.INACTIVE]],
  [PipState.INACTIVE,  [PipState.ENTERING, PipState.DISABLED]],
  [PipState.ENTERING,  [PipState.ACTIVE, PipState.INACTIVE, PipState.DISABLED]],
  [PipState.ACTIVE,    [PipState.RESTORING, PipState.EXITING, PipState.INACTIVE, PipState.DISABLED]],
  [PipState.RESTORING, [PipState.INACTIVE, PipState.ACTIVE, PipState.DISABLED]],
  [PipState.EXITING,   [PipState.INACTIVE, PipState.DISABLED]],
]);

export function isValidPipTransition(from: PipState, to: PipState): boolean {
  if (from === to) return true;
  return VALID.get(from)?.includes(to) ?? false;
}
