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
import common from '@ohos.app.ability.common';
import { Logger } from 'mediaservice';
import { BusinessError } from '@kit.BasicServicesKit';
import { BreakpointSystem } from './BreakpointSystem';
import { ColorModeManager } from '../ColorModeManager';

const TAG: string = '[WindowUtil]';

export class WindowUtil {
  private static instance: WindowUtil;
  private windowStage?: window.WindowStage;
  private mainWindowClass?: window.Window;
  // 播放页面专属的 windowSizeChange 回调（独立于全局 BreakpointSystem 监听器）
  private playerSizeChangeCallback: ((size: window.Size) => void) | null = null;
  // 全局统一的 windowSizeChange 分发器（唯一注册，内部分发给各子监听器）
  private globalSizeChangeHandler: ((size: window.Size) => void) | null = null;
  private windowStatusChangeHandler: ((status: window.WindowStatusType) => void) | null = null;
  private currentWindowStatus: window.WindowStatusType = window.WindowStatusType.FULL_SCREEN;
  private landscapeMultiWindowEnabled: boolean = false;

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
        let cutoutArea: window.AvoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
        let naviBarArea: window.AvoidArea =
          windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        AppStorage.setOrCreate('deviceWidth', properties.windowRect.width);
        AppStorage.setOrCreate('deviceHeight', properties.windowRect.height);
        // Track system + cutout top separately; UI reads max as statusBarHeight.
        const topSystemVp = uiContext?.px2vp(area.topRect.height) ?? 0;
        const topCutoutVp = uiContext?.px2vp(cutoutArea.topRect.height + cutoutArea.topRect.top) ?? 0;
        const bottomSystemVp = uiContext?.px2vp(area.bottomRect.height) ?? 0;
        const leftSystemVp = uiContext?.px2vp(area.leftRect.width) ?? 0;
        const rightSystemVp = uiContext?.px2vp(area.rightRect.width) ?? 0;
        const bottomCutoutVp = uiContext?.px2vp(cutoutArea.bottomRect.height) ?? 0;
        const leftCutoutVp = uiContext?.px2vp(cutoutArea.leftRect.width) ?? 0;
        const rightCutoutVp = uiContext?.px2vp(cutoutArea.rightRect.width) ?? 0;
        AppStorage.setOrCreate('statusBarSystemHeight', topSystemVp);
        AppStorage.setOrCreate('statusBarCutoutHeight', topCutoutVp);
        AppStorage.setOrCreate('statusBarHeight', Math.max(topSystemVp, topCutoutVp));
        AppStorage.setOrCreate('systemAvoidBottom', bottomSystemVp);
        AppStorage.setOrCreate('systemAvoidLeft', leftSystemVp);
        AppStorage.setOrCreate('systemAvoidRight', rightSystemVp);
        AppStorage.setOrCreate('cutoutAvoidBottom', bottomCutoutVp);
        AppStorage.setOrCreate('cutoutAvoidLeft', leftCutoutVp);
        AppStorage.setOrCreate('cutoutAvoidRight', rightCutoutVp);
        AppStorage.setOrCreate('navBarHeight', uiContext?.px2vp(naviBarArea.bottomRect.height) ?? 0);
        WindowUtil.publishPlayerGestureInsets();
        WindowUtil.publishPlayerControlAvoidInsets();

        // 初始窗口模式（全屏 / 分屏 / 悬浮）
        this.publishWindowStatus(windowClass.getWindowStatus());

        // 注册唯一的全局分发器，内部同时通知 BreakpointSystem、系统栏策略和播放页回调
        this.globalSizeChangeHandler = (size: window.Size) => {
          AppStorage.setOrCreate('deviceWidth', size.width);
          AppStorage.setOrCreate('deviceHeight', size.height);
          BreakpointSystem.getInstance().onWindowSizeChange(windowClass);
          this.updateSystemBar();
          this.playerSizeChangeCallback?.(size);
        };
        windowClass.on('windowSizeChange', this.globalSizeChangeHandler);

        this.windowStatusChangeHandler = (status: window.WindowStatusType) => {
          this.publishWindowStatus(status);
          this.updateSystemBar();
          // 分屏/悬浮尺寸常伴随 size 变化；再推一次当前 rect 给播放页布局
          try {
            const rect = windowClass.getWindowProperties().windowRect;
            this.playerSizeChangeCallback?.({ width: rect.width, height: rect.height });
          } catch (statusErr) {
            Logger.error(TAG, `windowStatusChange size push failed: ${JSON.stringify(statusErr)}`);
          }
        };
        windowClass.on('windowStatusChange', this.windowStatusChangeHandler);

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

  private publishWindowStatus(status: window.WindowStatusType): void {
    this.currentWindowStatus = status;
    const isSplitScreen = status === window.WindowStatusType.SPLIT_SCREEN;
    const isFloating = status === window.WindowStatusType.FLOATING;
    AppStorage.setOrCreate('windowStatus', status);
    AppStorage.setOrCreate('isSplitScreen', isSplitScreen);
    AppStorage.setOrCreate('isFloatingWindow', isFloating);
    // 兼容旧键：仅分屏视为“需强制铺满”的多窗
    AppStorage.setOrCreate('isMultiWindow', isSplitScreen);
    Logger.info(TAG, `windowStatus=${status}, isSplitScreen=${isSplitScreen}, isFloating=${isFloating}`);
  }

  /** 仅分屏：播放页默认铺满窗口（悬浮窗不强制）。 */
  isSplitScreenMode(): boolean {
    return this.currentWindowStatus === window.WindowStatusType.SPLIT_SCREEN
      || (AppStorage.get<boolean>('isSplitScreen') ?? false);
  }

  /** @deprecated 使用 isSplitScreenMode；保留以免外部误用。 */
  isMultiWindowMode(): boolean {
    return this.isSplitScreenMode();
  }

  getWindowStatus(): window.WindowStatusType {
    return this.currentWindowStatus;
  }

  /**
   * 仅用户主动沉浸全屏时调用；默认进播放页 / 悬浮窗不要声明横向多窗，否则系统会强制横屏浮窗。
   */
  enableLandscapeMultiWindow(): void {
    if (this.mainWindowClass === undefined || this.landscapeMultiWindowEnabled) {
      return;
    }
    this.mainWindowClass.enableLandscapeMultiWindow().then(() => {
      this.landscapeMultiWindowEnabled = true;
      Logger.info(TAG, 'enableLandscapeMultiWindow ok');
    }).catch((err: BusinessError) => {
      Logger.error(TAG, `enableLandscapeMultiWindow failed. Code:${err.code}, message:${err.message}`);
    });
  }

  disableLandscapeMultiWindow(): void {
    if (this.mainWindowClass === undefined || !this.landscapeMultiWindowEnabled) {
      return;
    }
    this.mainWindowClass.disableLandscapeMultiWindow().then(() => {
      this.landscapeMultiWindowEnabled = false;
      Logger.info(TAG, 'disableLandscapeMultiWindow ok');
    }).catch((err: BusinessError) => {
      Logger.error(TAG, `disableLandscapeMultiWindow failed. Code:${err.code}, message:${err.message}`);
    });
  }

  // Get status bar height and indicator height.
  // Track TYPE_SYSTEM / TYPE_CUTOUT independently; expose max as statusBarHeight
  // so punch-hole devices still get a non-zero top inset when one type is empty.
  // When system bars hide (TYPE_SYSTEM → 0), keep last positive system value so
  // non-immersive portrait can restore the correct spacer after fullscreen.
  public static setAvoidArea(type: window.AvoidAreaType, area: window.AvoidArea): void {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>('uiContext');
    if (!uiContext) {
      return;
    }
    if (type === window.AvoidAreaType.TYPE_SYSTEM) {
      const topSystemVp = uiContext.px2vp(area.topRect.height);
      WindowUtil.setPositiveInset('statusBarSystemHeight', topSystemVp);
      // Unlike the cached portrait status-bar height, edge avoid values must
      // track zero as well so rotation/folding cannot retain stale side insets.
      AppStorage.setOrCreate('systemAvoidBottom', uiContext.px2vp(area.bottomRect.height));
      AppStorage.setOrCreate('systemAvoidLeft', uiContext.px2vp(area.leftRect.width));
      AppStorage.setOrCreate('systemAvoidRight', uiContext.px2vp(area.rightRect.width));
      // topSystemVp === 0: bars hidden — leave last positive system height cached
      WindowUtil.publishStatusBarHeight();
    } else if (type === window.AvoidAreaType.TYPE_CUTOUT) {
      const topCutoutVp = uiContext.px2vp(area.topRect.height + area.topRect.top);
      AppStorage.setOrCreate('statusBarCutoutHeight', topCutoutVp);
      AppStorage.setOrCreate('cutoutAvoidBottom', uiContext.px2vp(area.bottomRect.height));
      AppStorage.setOrCreate('cutoutAvoidLeft', uiContext.px2vp(area.leftRect.width));
      AppStorage.setOrCreate('cutoutAvoidRight', uiContext.px2vp(area.rightRect.width));
      WindowUtil.publishStatusBarHeight();
    } else if (type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      AppStorage.setOrCreate('navBarHeight', uiContext.px2vp(area.bottomRect.height));
    }
    WindowUtil.publishPlayerGestureInsets();
    WindowUtil.publishPlayerControlAvoidInsets();
  }

  private static setPositiveInset(key: string, value: number): void {
    if (value > 0) {
      AppStorage.setOrCreate(key, value);
    }
  }

  private static publishStatusBarHeight(): void {
    const systemH = AppStorage.get<number>('statusBarSystemHeight') ?? 0;
    const cutoutH = AppStorage.get<number>('statusBarCutoutHeight') ?? 0;
    AppStorage.setOrCreate('statusBarHeight', Math.max(systemH, cutoutH));
  }

  private static publishPlayerGestureInsets(): void {
    const top = Math.max(
      AppStorage.get<number>('statusBarSystemHeight') ?? 0,
      AppStorage.get<number>('statusBarCutoutHeight') ?? 0
    );
    const bottom = Math.max(
      AppStorage.get<number>('systemAvoidBottom') ?? 0,
      AppStorage.get<number>('cutoutAvoidBottom') ?? 0,
      AppStorage.get<number>('navBarHeight') ?? 0
    );
    const left = Math.max(
      AppStorage.get<number>('systemAvoidLeft') ?? 0,
      AppStorage.get<number>('cutoutAvoidLeft') ?? 0
    );
    const right = Math.max(
      AppStorage.get<number>('systemAvoidRight') ?? 0,
      AppStorage.get<number>('cutoutAvoidRight') ?? 0
    );
    AppStorage.setOrCreate('playerGestureSafeTop', Math.min(56, Math.max(24, top)));
    AppStorage.setOrCreate('playerGestureSafeBottom', Math.min(48, Math.max(16, bottom)));
    AppStorage.setOrCreate('playerGestureSafeLeft', Math.min(32, Math.max(16, left)));
    AppStorage.setOrCreate('playerGestureSafeRight', Math.min(32, Math.max(16, right)));
  }

  /**
   * Raw avoid-area values for visible player controls. Keep these separate from
   * playerGestureSafe*: gesture insets are deliberately clamped, while controls
   * must always clear the complete cutout / waterfall / navigation area.
   */
  private static publishPlayerControlAvoidInsets(): void {
    const top = AppStorage.get<number>('statusBarCutoutHeight') ?? 0;
    const bottom = Math.max(
      AppStorage.get<number>('systemAvoidBottom') ?? 0,
      AppStorage.get<number>('cutoutAvoidBottom') ?? 0,
      AppStorage.get<number>('navBarHeight') ?? 0
    );
    const left = Math.max(
      AppStorage.get<number>('systemAvoidLeft') ?? 0,
      AppStorage.get<number>('cutoutAvoidLeft') ?? 0
    );
    const right = Math.max(
      AppStorage.get<number>('systemAvoidRight') ?? 0,
      AppStorage.get<number>('cutoutAvoidRight') ?? 0
    );
    AppStorage.setOrCreate('playerControlAvoidTop', top);
    AppStorage.setOrCreate('playerControlAvoidBottom', bottom);
    AppStorage.setOrCreate('playerControlAvoidLeft', left);
    AppStorage.setOrCreate('playerControlAvoidRight', right);
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
   * Player page sits under a dark video surface: force white status-bar glyphs
   * so clock / icons remain readable. Pass restore=true when leaving player
   * to follow light/dark theme again.
   */
  setPlayerStatusBarStyle(onPlayerPage: boolean): void {
    if (this.mainWindowClass === undefined) {
      Logger.error(`MainWindowClass is undefined`);
      return;
    }
    try {
      if (onPlayerPage) {
        this.mainWindowClass.setWindowSystemBarProperties({
          statusBarContentColor: '#FFFFFF',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#FFFFFF'
        });
      } else {
        const context = AppStorage.get<common.UIAbilityContext>('context');
        const isDarkMode = context !== undefined && ColorModeManager.isEffectiveDarkMode(context);
        const contentColor = isDarkMode ? '#FFFFFF' : '#000000';
        this.mainWindowClass.setWindowSystemBarProperties({
          statusBarContentColor: contentColor,
          navigationBarColor: '#00000000',
          navigationBarContentColor: contentColor
        });
      }
    } catch (err) {
      Logger.error(TAG, `setPlayerStatusBarStyle failed: ${JSON.stringify(err)}`);
    }
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
