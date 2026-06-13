/*
 * PipNavigator —— 处理 PiP 恢复时的导航栈三种情况
 *
 * 由 Index.ets 在 bindActionHub 时注入 NavPathStack 引用。
 * PipBinding 在 PipState 进入 RESTORING 时调用 restore()。
 *
 * 三种情况：
 *   1) 已 pop（用户从播放页按了返回键）—— 栈中无 PlayerPage   → pushPath
 *   2) 栈中非栈顶（用户点了作者，UserPage 在 PlayerPage 之上）→ moveToTop
 *   3) 已在栈顶（理论不应出现，PiP 时 PlayerPage 不会在栈顶） → no-op
 */

import { AppLog } from '../../../common/AppLog';

const TAG = '[PipNavigator]';
const logger = AppLog.getInstance('PipNavigator');

export const PLAYER_PAGE_NAME = 'PlayerPage';

export class PipNavigator {
  private static _stack: NavPathStack | null = null;

  static bind(stack: NavPathStack): void {
    PipNavigator._stack = stack;
    logger.info(`${TAG} bound to NavPathStack`);
  }

  static unbind(): void {
    PipNavigator._stack = null;
  }

  /**
   * 把 PlayerPage 重新带到前台。返回是否真正推/移动了页面（true）
   * 还是已在栈顶（false）。在 RESTORING 时由 PipBinding 调用。
   */
  static restore(): boolean {
    const stack = PipNavigator._stack;
    if (!stack) {
      logger.warn(`${TAG} restore called but no stack bound`);
      return false;
    }
    const indices = stack.getIndexByName(PLAYER_PAGE_NAME);
    const top = stack.size() - 1;
    if (indices.length === 0) {
      stack.pushPath({ name: PLAYER_PAGE_NAME });
      logger.info(`${TAG} restore: pushPath(PlayerPage)`);
      return true;
    }
    if (indices[0] === top) {
      logger.info(`${TAG} restore: already at top, no-op`);
      return false;
    }
    stack.moveToTop(PLAYER_PAGE_NAME);
    logger.info(`${TAG} restore: moveToTop(PlayerPage)`);
    return true;
  }

  /** 从栈中移除所有 PlayerPage 实例（PiP ✕ 关闭且页面已被 pop 时清理用）。 */
  static removePlayerPages(): void {
    const stack = PipNavigator._stack;
    if (!stack) return;
    const indices = stack.getIndexByName(PLAYER_PAGE_NAME);
    if (indices.length > 0) {
      stack.removeByIndexes(indices);
      logger.info(`${TAG} removed ${indices.length} PlayerPage entries from stack`);
    }
  }

  /** 当前 PlayerPage 是否在栈顶。供 Index.ets 在跳转前判断要不要进 PiP。 */
  static isPlayerPageOnTop(): boolean {
    const stack = PipNavigator._stack;
    if (!stack) return false;
    const indices = stack.getIndexByName(PLAYER_PAGE_NAME);
    const top = stack.size() - 1;
    return indices.length > 0 && indices[0] === top;
  }

  /** 当前 PlayerPage 是否在栈中（任何位置）。 */
  static hasPlayerPage(): boolean {
    const stack = PipNavigator._stack;
    if (!stack) return false;
    return stack.getIndexByName(PLAYER_PAGE_NAME).length > 0;
  }
}
