/*
 * Copyright (c) 2023 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { window } from '@kit.ArkUI';
import { Logger } from 'mediaservice';
import { BusinessError } from '@kit.BasicServicesKit';
import { BreakpointSystem } from './BreakpointSystem';

const TAG: string = '[WindowUtil]';

export class WindowUtil {
  private static instance: WindowUtil;
  private windowStage?: window.WindowStage;
  private mainWindowClass?: window.Window;
  // 播放页面专属的 windowSizeChange 回调（独立于全局 BreakpointSystem 监听器）
  private playerSizeChangeCallback: ((size: window.Size) => void) | null = null;
  // 全局统一的 windowSizeChange 分发器（唯一注册，内部分发给各子监听器）
  private globalSizeChangeHandler: ((size: window.Size) => void) | null = null;

  public static getInstance(): WindowUtil {
    if (!WindowUtil.instance) {
      WindowUtil.instance = new WindowUtil();
    }
    return WindowUtil.instance;
  }

  public setWindowStage(windowStage: window.WindowStage): void {
    const uiContext: UIContext | undefined = AppStorage.get('uiContext');
    this.windowStage = windowStage;
    this.windowStage.getMainWindow((err, windowClass: window.Window) => {
      if (err.code) {
        Logger.error(TAG, `Failed to obtain the main window. Code:${err.code}, message:${err.message}`);
        return;
      }
      this.mainWindowClass = windowClass;
      try {
        const properties: window.WindowProperties = windowClass.getWindowProperties();
        let area: window.AvoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        let naviBarArea: window.AvoidArea =
          windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        AppStorage.setOrCreate('deviceWidth', properties.windowRect.width);
        AppStorage.setOrCreate('deviceHeight', properties.windowRect.height);
        AppStorage.setOrCreate('statusBarHeight', uiContext?.px2vp(area.topRect.height));
        AppStorage.setOrCreate('navBarHeight', uiContext?.px2vp(naviBarArea.bottomRect.height));

        // 注册唯一的全局分发器，内部同时通知 BreakpointSystem、系统栏策略和播放页回调
        this.globalSizeChangeHandler = (size: window.Size) => {
          AppStorage.setOrCreate('deviceWidth', size.width);
          AppStorage.setOrCreate('deviceHeight', size.height);
          BreakpointSystem.getInstance().onWindowSizeChange(windowClass);
          this.updateSystemBar();
          this.playerSizeChangeCallback?.(size);
        };
        windowClass.on('windowSizeChange', this.globalSizeChangeHandler);

        windowClass.on('avoidAreaChange', (avoidAreaOption) => {
          WindowUtil.setAvoidArea(avoidAreaOption.type, avoidAreaOption.area);
        });

        // 窗口就绪：按当前方向设置初始系统栏状态
        this.updateSystemBar();
      } catch (error) {
        Logger.error(TAG, `setWindowStage getWindowProperties failed. Code:${err.code}, message:${err.message}`);
      }
    });
  }

  // Get status bar height and indicator height.
  public static setAvoidArea(type: window.AvoidAreaType, area: window.AvoidArea): void {
    const uiContext: UIContext = AppStorage.get<UIContext>('uiContext')!;
    if (type === window.AvoidAreaType.TYPE_SYSTEM) {
      AppStorage.setOrCreate('statusBarHeight', uiContext?.px2vp(area.topRect.height));
    } else {
      AppStorage.setOrCreate('navBarHeight',  uiContext?.px2vp(area.bottomRect.height));
    }
  }

  setMainWindowOrientation(orientation: window.Orientation, callback?: Function): void {
    if (this.mainWindowClass === undefined) {
      Logger.error(`MainWindowClass is undefined`);
      return;
    }
    this.mainWindowClass.setPreferredOrientation(orientation).then(() => {
      callback?.();
    }).catch((err: BusinessError) => {
      Logger.error(`Failed to set the ${orientation} of main window. Code:${err.code}, message:${err.message}`);
    });
  }

  disableWindowSystemBar(): void {
    if (this.mainWindowClass === undefined) {
      Logger.error(`MainWindowClass is undefined`);
      return;
    }
    this.mainWindowClass.setWindowSystemBarEnable([]).catch((err: BusinessError) => {
      Logger.error(TAG, `disableWindowSystemBar failed, err.code:${err.code}, err.message:${err.message}`);
    });
  }

  enableWindowSystemBar(): void {
    if (this.mainWindowClass === undefined) {
      Logger.error(`MainWindowClass is undefined`);
      return;
    }
    this.mainWindowClass.setWindowSystemBarEnable(['status', 'navigation']).catch((err: BusinessError) => {
      Logger.error(TAG, `enableWindowSystemBar failed, err.code:${err.code}, err.message:${err.message}`);
    });
  }

  // 播放器沉浸全屏标志：true 时强制隐藏系统栏（覆盖方向/尺寸规则）
  private isPlayerFullscreenImmersive: boolean = false;

  /**
   * 设置播放器沉浸全屏标志并立即更新系统栏。
   * 播放器进入沉浸全屏时传 true，退出全屏/离开播放页时传 false。
   */
  setPlayerFullscreenImmersive(value: boolean): void {
    this.isPlayerFullscreenImmersive = value;
    this.updateSystemBar();
  }

  /**
   * 全局系统栏策略（唯一真相源）：
   *   窄屏设备（短边 < 600vp）横屏 → 隐藏系统栏（珍惜竖向空间）
   *   非窄屏设备 / 竖屏 → 显示系统栏
   *   播放器沉浸全屏 → 强制隐藏（覆盖上述规则）
   * 在 windowSizeChange、标志变更、页面进出时调用，保证任意时刻状态正确。
   */
  updateSystemBar(): void {
    if (this.mainWindowClass === undefined) {
      Logger.error(`MainWindowClass is undefined`);
      return;
    }
    try {
      const rect = this.mainWindowClass.getWindowProperties().windowRect;
      const isLandscape = rect.width > rect.height;
      const uiContext = this.mainWindowClass.getUIContext();
      const shortSideVp = uiContext.px2vp(Math.min(rect.width, rect.height));
      const shouldHide = this.isPlayerFullscreenImmersive || (isLandscape && shortSideVp < 600);
      if (shouldHide) {
        this.disableWindowSystemBar();
      } else {
        this.enableWindowSystemBar();
      }
    } catch (err) {
      Logger.error(TAG, `updateSystemBar failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 注册播放页面专属的窗口尺寸变化回调。
   * 通过全局分发器转发，不会影响 BreakpointSystem 等其他监听器。
   */
  registerOnWindowSizeChange(callback?: (size: window.Size) => void): void {
    this.playerSizeChangeCallback = callback ?? null;
  }

  /**
   * 注销播放页面专属的回调，不影响其他全局监听器。
   */
  registerOffWindowSizeChange(): void {
    this.playerSizeChangeCallback = null;
  }
}