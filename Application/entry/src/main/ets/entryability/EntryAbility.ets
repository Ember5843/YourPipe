import { AppLog } from '../common/AppLog';
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { PreferencesStore } from '../common/PreferencesStore';
import { AppState } from '../common/AppState';
import { ColorModeManager } from '../common/ColorModeManager';
import { LanguageManager } from '../common/LanguageManager';
import { BackgroundTaskManager } from 'mediaservice';
import { EnhancedLogger } from 'mediaservice';
import { AuthSessionManager, YTCoreLogger } from 'youtube_core';
import { AppLogStore } from '../common/AppLogStore';
import { hilog } from '@kit.PerformanceAnalysisKit';

const logger = AppLog.getInstance('EntryAbility');


export default class EntryAbility extends UIAbility {
  private curBp: string = '';
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('context', this.context);
    try {
      let systemLanguage: string = i18n.System.getSystemLanguage();
      let systemRegion: string = i18n.System.getSystemRegion();
      logger.info(`System Language: ${systemLanguage}, Region: ${systemRegion}`);

      PreferencesStore.init(this.context);
      AppState.init();
      // 日志初始化：尽早建立日志列表，根据持久化开关决定是否开始记录
      const logEnabled = PreferencesStore.getString('cfg_enableLogger', 'false') === 'true';
      AppLogStore.init(logEnabled, this.context.filesDir);
      AuthSessionManager.init(this.context);
      // 注入 EnhancedLogger sink，覆盖所有 mediaservice 调用
      EnhancedLogger.setSink((level, tag, message) => {
        AppLogStore.push(level, tag, message);
      });
      // 注入 YTCoreLogger sink，覆盖所有 youtube_core 调用
      YTCoreLogger.setSink((level, tag, message) => {
        AppLogStore.push(level, tag, message);
        hilog.info(0xFF00, 'YTC-' + tag, '%{public}s', message);
      });
      LanguageManager.applyPersistedLanguage();
      ColorModeManager.applyPersistedMode(this.context);
    } catch (err) {
      logger.error(`onCreate failed: ${JSON.stringify(err)}`);
    }
    logger.info('Ability onCreate');
  }

  onDestroy(): void {
    logger.info('Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    logger.info('Ability onWindowStageCreate');

    const windowObj = windowStage.getMainWindowSync();
    this.updateBreakpoint(windowObj.getWindowProperties().windowRect.width);
    windowObj.on('windowSizeChange', (windowSize) => {
      this.updateBreakpoint(windowSize.width);
    });

    windowStage.loadContent('product/Index', (err) => {
      if (err.code) {
        logger.error(`Failed to load the content. Cause: ${JSON.stringify(err)}`);
        return;
      }
      logger.info('Succeeded in loading the content.');
      const uiContext: UIContext | undefined = windowStage.getMainWindowSync().getUIContext();
      AppStorage.setOrCreate('uiContext', uiContext);
      // Initialize WindowUtil to set deviceWidth and deviceHeight
      import('../common/utils/WindowUtil').then((WindowUtilModule) => {
        WindowUtilModule.WindowUtil.getInstance().setWindowStage(windowStage);
      });
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    logger.info('Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    logger.info('Ability onForeground');
    AppStorage.setOrCreate('isAppBackground', false);
  }

  onBackground(): void {
    // Ability has back to background
    logger.info('Ability onBackground');
    AppStorage.setOrCreate('isAppBackground', true);
    // 用 UIAbility 自身的 context（最可靠来源）确保后台长时任务生效
    // AVSession.init() 里的首次注册可能因 canIUse 或时序问题失败，这里作为兜底
    BackgroundTaskManager.startContinuousTask(this.context);
  }

  private updateBreakpoint(windowWidth: number): void {
    const windowWidthVp = windowWidth / display.getDefaultDisplaySync().densityPixels;
    let newBp: string = '';
    if (windowWidthVp < 600) {
      newBp = BreakpointConstants.BREAKPOINT_SM;
    } else if (windowWidthVp < 840) {
      newBp = BreakpointConstants.BREAKPOINT_MD;
    } else {
      newBp = BreakpointConstants.BREAKPOINT_LG;
    }
    if (this.curBp !== newBp) {
      this.curBp = newBp;
      AppStorage.setOrCreate('currentBreakpoint', this.curBp);
    }
  }
}
