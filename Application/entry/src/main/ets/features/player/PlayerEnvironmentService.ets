import { settings, commonEventManager } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { window } from '@kit.ArkUI';
import { Logger } from 'mediaservice';
import { AppLogStore } from '../../common/AppLogStore';

const TAG: string = '[PlayerEnvironmentService]';

export interface VolumeInfo {
  volume: number;
  maxVolume: number;
}

/**
 * 播放器环境服务：管理亮度、音量、屏幕事件、KeepScreenOn 等系统交互。
 * 从 VideoPlayer 中提取，避免 UI 组件与系统 API 强耦合。
 */
export class PlayerEnvironmentService {
  private mainWin?: window.Window;
  private screenHeight: number = 0;
  private maxVolume: number = 15;
  private screenEventSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private onScreenOff?: () => void;
  private onScreenOn?: () => void;
  private lastKeepScreenOn?: boolean;

  /** 初始化窗口和音量 */
  async init(context: Context): Promise<void> {
    try {
      this.mainWin = await window.getLastWindow(context);
      this.screenHeight = this.mainWin.getWindowProperties().windowRect.height;
    } catch (e) {
      Logger.warn(TAG, `Failed to get main window: ${(e as Error).message}`);
    }
  }

  /** 获取当前屏幕亮度（0-1） */
  async getBrightness(context: Context): Promise<number> {
    try {
      const value = await settings.getValue(
        context,
        settings.display.SCREEN_BRIGHTNESS_STATUS,
        settings.domainName.DEVICE_SHARED
      );
      const parsed = Number(value);
      return !isNaN(parsed) && parsed >= 0 ? parsed / 255 : 0.5;
    } catch (e) {
      Logger.warn(TAG, `getBrightness failed: ${(e as Error).message}`);
      return 0.5;
    }
  }

  /** 同步获取当前屏幕亮度（0-1），用于手势回调 */
  getBrightnessSync(context: Context): number {
    try {
      const value = settings.getValueSync(
        context,
        settings.display.SCREEN_BRIGHTNESS_STATUS,
        settings.domainName.DEVICE_SHARED
      );
      const parsed = Number(value);
      return !isNaN(parsed) && parsed >= 0 ? parsed / 255 : 0.5;
    } catch (e) {
      Logger.warn(TAG, `getBrightnessSync failed: ${(e as Error).message}`);
      return 0.5;
    }
  }

  /** 设置窗口亮度（0-1） */
  setBrightness(value: number): void {
    if (this.mainWin) {
      this.mainWin.setWindowBrightness(Math.max(0, Math.min(1, value))).catch((e: Error) => {
        Logger.warn(TAG, `setWindowBrightness failed: ${e.message}`);
      });
    }
  }

  /** 检测系统是否锁定了屏幕自动旋转（true=锁定，false=自动旋转） */
  isRotationLocked(context: Context): boolean {
    try {
      const value = settings.getValueSync(
        context,
        settings.display.DEFAULT_SCREEN_ROTATION,
        settings.domainName.DEVICE_SHARED
      );
      return value === '0';
    } catch (e) {
      Logger.warn(TAG, `isRotationLocked failed: ${(e as Error).message}`);
      return false;
    }
  }

  /** 获取当前媒体音量（0-15）和最大值 */
  getVolume(): VolumeInfo {
    try {
      const vol = audio.getAudioManager()
        .getVolumeManager().getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MOVIE);
      return { volume: vol, maxVolume: this.maxVolume };
    } catch (e) {
      Logger.warn(TAG, `getVolume failed: ${(e as Error).message}`);
      return { volume: 8, maxVolume: this.maxVolume };
    }
  }

  /** 设置媒体音量（0-15） */
  setVolume(level: number): void {
    const clamped = Math.max(0, Math.min(this.maxVolume, level));
    try {
      audio.getAudioManager().setVolume(audio.AudioVolumeType.MEDIA, clamped);
    } catch (e) {
      Logger.warn(TAG, `setVolume failed: ${(e as Error).message}`);
    }
  }

  /** 设置 KeepScreenOn */
  setKeepScreenOn(keepOn: boolean): void {
    if (keepOn === this.lastKeepScreenOn) return;
    this.lastKeepScreenOn = keepOn;
    if (this.mainWin) {
      this.mainWin.setWindowKeepScreenOn(keepOn).catch((e: Error) => {
        Logger.warn(TAG, `setWindowKeepScreenOn failed: ${e.message}`);
      });
    }
  }

  /** 订阅屏幕事件 */
  subscribeScreenEvents(onScreenOff?: () => void, onScreenOn?: () => void): void {
    this.onScreenOff = onScreenOff;
    this.onScreenOn = onScreenOn;

    const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
      events: [
        commonEventManager.Support.COMMON_EVENT_SCREEN_OFF,
        commonEventManager.Support.COMMON_EVENT_SCREEN_ON,
      ]
    };
    commonEventManager.createSubscriber(subscribeInfo)
      .then((subscriber: commonEventManager.CommonEventSubscriber) => {
        this.screenEventSubscriber = subscriber;
        commonEventManager.subscribe(subscriber, (err, data) => {
          if (err) {
            Logger.warn(TAG, `Screen event error: ${err.message}`);
            return;
          }
          if (data.event === commonEventManager.Support.COMMON_EVENT_SCREEN_OFF) {
            this.onScreenOff?.();
          } else if (data.event === commonEventManager.Support.COMMON_EVENT_SCREEN_ON) {
            this.onScreenOn?.();
          }
        });
        Logger.info(TAG, 'Screen event subscribed');
      })
      .catch((e: Error) => {
        Logger.warn(TAG, `Failed to subscribe screen events: ${e.message}`);
      });
  }

  /** 取消订阅屏幕事件 */
  unsubscribeScreenEvents(): void {
    if (this.screenEventSubscriber) {
      commonEventManager.unsubscribe(this.screenEventSubscriber, (err) => {
        if (err) {
          Logger.warn(TAG, `Unsubscribe screen events failed: ${err.message}`);
        }
      });
      this.screenEventSubscriber = null;
    }
  }

  /** 释放资源 */
  release(): void {
    this.unsubscribeScreenEvents();
    this.setKeepScreenOn(false);
    this.mainWin = undefined;
  }
}
