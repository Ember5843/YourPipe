/*
 * Background Task Manager for YourPipe
 * Handles registration and deregistration of continuous AUDIO_PLAYBACK background tasks
 * to keep the process alive when the app moves to background.
 */

import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import Logger from '../utils/Logger';

const TAG = '[BackgroundTaskManager]';

export class BackgroundTaskManager {
  private static cancelCallback: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | null = null;

  /**
   * 监听系统主动取消长时任务（如后台无有效音频输出被管控、用户划掉通知等），
   * 以便播放器同步重置内部状态，下次起播时可重新申请。
   */
  public static registerCancelListener(onCancel: (reason: number) => void): void {
    BackgroundTaskManager.unregisterCancelListener();
    const cb = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      const reason: number = info?.reason ?? -1;
      Logger.warn(TAG, `continuousTaskCancel received id=${info?.id ?? -1} reason=${reason}`);
      onCancel(reason);
    };
    try {
      backgroundTaskManager.on('continuousTaskCancel', cb);
      BackgroundTaskManager.cancelCallback = cb;
      Logger.info(TAG, 'registered continuousTaskCancel listener');
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `register continuousTaskCancel failed, code=${e?.code}, message=${e?.message}`);
    }
  }

  public static unregisterCancelListener(): void {
    const cb = BackgroundTaskManager.cancelCallback;
    if (!cb) {
      return;
    }
    BackgroundTaskManager.cancelCallback = null;
    try {
      backgroundTaskManager.off('continuousTaskCancel', cb);
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `unregister continuousTaskCancel failed, code=${e?.code}, message=${e?.message}`);
    }
  }

  /**
   * Register a continuous background task of type AUDIO_PLAYBACK.
   * Must be called before the app enters background while playback is active.
   */
  public static startContinuousTask(context?: common.UIAbilityContext): void {
    if (!context) {
      Logger.warn(TAG, 'startContinuousTask: context is undefined, skipping');
      return;
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(wantAgentInfo).then((wantAgentObj) => {
      backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        wantAgentObj
      ).then(() => {
        Logger.info(TAG, 'startBackgroundRunning succeeded');
      }).catch((err: BusinessError) => {
        if (err.code === 9800005) {
          // 9800005: 已有同类任务在运行，重复注册属于正常情况（兜底调用与首次注册重叠）。
          Logger.info(TAG, 'startBackgroundRunning: task already registered, skipping');
        } else {
          Logger.error(TAG, `startBackgroundRunning failed, code=${err.code}, message=${err.message}`);
        }
      });
    }).catch((err: BusinessError) => {
      Logger.error(TAG, `getWantAgent failed, code=${err.code}, message=${err.message}`);
    });
  }

  /**
   * Cancel the continuous background task.
   * Call when playback is stopped/paused for an extended time, or player is destroyed.
   */
  public static stopContinuousTask(context?: common.UIAbilityContext): void {
    if (!context) {
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(context).then(() => {
      Logger.info(TAG, 'stopBackgroundRunning succeeded');
    }).catch((err: BusinessError) => {
      Logger.error(TAG, `stopBackgroundRunning failed, code=${err.code}, message=${err.message}`);
    });
  }
}
