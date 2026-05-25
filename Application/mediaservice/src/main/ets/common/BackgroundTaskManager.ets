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
          // 9800005: 已有同类任务在运行，重复注册属于正常情况（兜底调用与首次注册重叠）
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
