import { AppLog } from '../common/AppLog';
import { AbilityConstant, UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { PreferencesStore } from '../common/PreferencesStore';
import { AppState } from '../common/AppState';
import { UIConfig } from '../common/AppState';
import { PlaybackConfig } from '../common/PlaybackConfig';
import { ColorModeManager } from '../common/ColorModeManager';
import { LanguageManager } from '../common/LanguageManager';
import { BackgroundTaskManager, AvPlayerController } from 'mediaservice';
import { EnhancedLogger, PlaybackPreferences } from 'mediaservice';
import { AuthSessionManager, YTCoreLogger } from 'youtube_core';
import { AuthStateHelper } from '../common/AuthStateHelper';
import { AppLogStore } from '../common/AppLogStore';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaybackContinuationService } from '../features/player/PlaybackContinuationService';
import { PlayerSession } from '../common/PlayerSession';
import { PlayerPresentation } from '../common/PlayerPresentation';
import type { EngineConfig } from 'mediaservice';

const logger = AppLog.getInstance('EntryAbility');


export default class EntryAbility extends UIAbility {
  private curBp: string = '';
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('context', this.context);
    try {
      this.context.setMissionContinueState(AbilityConstant.ContinueState.INACTIVE);
    } catch (err) {
      logger.warn(`setMissionContinueState(INACTIVE) on create failed: ${JSON.stringify(err)}`);
    }
    this.handleContinuationWant(want, launchParam);
    try {
      let systemLanguage: string = i18n.System.getSystemLanguage();
      let systemRegion: string = i18n.System.getSystemRegion();
      logger.info(`System Language: ${systemLanguage}, Region: ${systemRegion}`);

      PreferencesStore.init(this.context);
      AppState.init();
      // 把 UI 偏好读取注入 mediaservice，避免 controller 直接依赖 AppStorage
      PlaybackPreferences.setProvider(() => {
        const ui = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
        const pb = AppStorage.get<PlaybackConfig>('playbackConfig') ?? new PlaybackConfig();
        return {
          searchLanguage: ui.searchLanguage && ui.searchLanguage !== 'default' ? ui.searchLanguage : 'en-GB',
          defaultQuality: pb.defaultQuality,
          mobileQuality: pb.mobileQuality,
        };
      });
      // 注入 MPV 引擎配置提供者
      AvPlayerController.setEngineConfigProvider(() => {
        const pb = AppStorage.get<PlaybackConfig>('playbackConfig') ?? new PlaybackConfig();
        return {
          mpvHwdecEnabled: pb.hwdecEnabled,
          mpvCacheSecs: parseInt(pb.cacheSecs, 10),
          mpvDemuxerReadaheadSecs: parseInt(pb.demuxerReadaheadSecs, 10),
          mpvDemuxerMaxBytes: parseInt(pb.demuxerMaxBytes, 10),
          mpvGpuApi: pb.gpuApi,
        } as EngineConfig;
      });
      // 日志初始化：尽早建立日志列表，根据持久化开关决定是否开始记录
      const logEnabled = PreferencesStore.getString('cfg_enableLogger', 'false') === 'true';
      AppLogStore.init(logEnabled, this.context.filesDir);
      AuthSessionManager.init(this.context);
      AuthStateHelper.refresh();
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

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleContinuationWant(want, launchParam);
  }

  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    try {
      const ok = PlaybackContinuationService.writeWantParam(wantParam);
      if (!ok) {
        return AbilityConstant.OnContinueResult.REJECT;
      }
      PlayerSession.getInstance().controller.syncPause();
      return AbilityConstant.OnContinueResult.AGREE;
    } catch (err) {
      logger.error(`onContinue failed: ${JSON.stringify(err)}`);
      return AbilityConstant.OnContinueResult.REJECT;
    }
  }

  onDestroy(): void {
    logger.info('Ability onDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    logger.info(`onConfigurationUpdate: ${JSON.stringify(newConfig)}`);
    // 配置更新回调：语言、深色模式等系统配置变化时触发。
    // 这里只记录日志，不做任何操作，避免与应用内的语言/主题切换逻辑冲突导致循环触发。
    // 语言切换由 LanguageManager.applyPersistedLanguage() 在 onCreate 时应用，
    // 运行时切换由 Index.ets applyLanguageSelection() 调用 i18n.System.setAppPreferredLanguage() 完成。
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
    logger.info('Ability onForeground');
    // PAGE + force video ON (also restores after share/cast sheets).
    PlayerPresentation.onAbilityForeground();
  }

  onBackground(): void {
    logger.info('Ability onBackground');
    // 后台长时任务由 PlayerStateMachine 统一管理；此处保留兜底注册以应对极端时序
    // （重复注册返回 9800005 会被静默忽略，详见 BackgroundTaskManager）。
    BackgroundTaskManager.startContinuousTask(this.context);
    // BACKGROUND may arm delayed video-off; PiP/OVERLAY keep video ON.
    PlayerPresentation.onAbilityBackground();
  }

  private handleContinuationWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (launchParam.launchReason !== AbilityConstant.LaunchReason.CONTINUATION) {
      return;
    }
    const payload = PlaybackContinuationService.extractFromWantParameters(want.parameters);
    if (!payload) {
      logger.warn('Continuation launch ignored: payload missing or invalid');
      return;
    }
    AppStorage.setOrCreate(PlaybackContinuationService.APP_STORAGE_PENDING_KEY, JSON.stringify(payload));
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
