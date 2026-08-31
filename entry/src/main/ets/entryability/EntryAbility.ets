import { AppLog } from '../common/AppLog';
import { AbilityConstant, UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';
import { PreferencesStore } from '../common/PreferencesStore';
import { AppState, UIConfig, YourtubeDarkMode } from '../common/AppState';
import { PlaybackConfig } from '../common/PlaybackConfig';
import { ColorModeManager } from '../common/ColorModeManager';
import { LanguageManager } from '../common/LanguageManager';
import { BackgroundTaskManager, AvPlayerController, LocalMediaProxy, PlayerState } from 'mediaservice';
import { EnhancedLogger, PlaybackPreferences, ContextProvider } from 'mediaservice';
import { AuthSessionManager, YTCoreLogger, YoutubeJavaScriptPlayerManager,
  YoutubePlayerClientConfig } from 'youtube_core';
import { AuthStateHelper } from '../common/AuthStateHelper';
import { AppLogStore } from '../common/AppLogStore';
import { PlaybackContinuationService } from '../features/player/PlaybackContinuationService';
import { PlayerSession } from '../common/PlayerSession';
import { WatchHistoryStore } from '../common/WatchHistoryStore';
import { PlayerPresentation } from '../common/PlayerPresentation';
import { YouTubePlayService } from '../features/player/YouTubePlayService';
import { SabrWebViewPoTokenProvider } from '../features/player/SabrWebViewPoTokenProvider';
import type { EngineConfig, PlaybackPreferencesSnapshot } from 'mediaservice';

const logger = AppLog.getInstance('EntryAbility');


export default class EntryAbility extends UIAbility {
  private curBp: string = '';
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('context', this.context);
    AppStorage.setOrCreate('playerLoading', false);
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
      // 把 UIAbilityContext 读取注入 mediaservice（惰性 getter），
      // 避免 AvSessionManager / 后台长时任务直接 AppStorage.get('context')。
      ContextProvider.setProvider(() => this.context);
      // 把 UI 偏好读取注入 mediaservice，避免 controller 直接依赖 AppStorage
      PlaybackPreferences.setProvider(() => {
        const ui = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
        const pb = AppStorage.get<PlaybackConfig>('playbackConfig') ?? new PlaybackConfig();
        // Audio track ranking (PipePipe preferred_audio_language default "original").
        // Only use content language when user explicitly set it — never force en-GB.
        const contentLang = (ui.searchLanguage || '').trim();
        const preferredAudio = contentLang.length > 0 && contentLang !== 'default'
          ? contentLang
          : 'original';
        const snapshot: PlaybackPreferencesSnapshot = {
          searchLanguage: preferredAudio,
          defaultQuality: pb.defaultQuality,
          mobileQuality: pb.mobileQuality,
          subtitleOffsetMs: pb.subtitleOffsetMs,
        };
        return snapshot;
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
      // 凭据内部失效路径（invalid_grant / 服务端清除 SID 等）也触发状态刷新。
      AuthSessionManager.setAuthStateChangeListener(() => AuthStateHelper.refresh());
      AuthStateHelper.refresh();
      // Stream client per-state settings (Options → 播放端点): guest default
      // visionos, signed-in default mweb; reconcile picks the
      // configured client for the current auth state.
      const pbConfig = AppStorage.get<PlaybackConfig>('playbackConfig') ?? new PlaybackConfig();
      YoutubePlayerClientConfig.setConfiguredClients(pbConfig.guestPlayerClient, pbConfig.authPlayerClient);
      AuthStateHelper.reconcilePlaybackClient();
      // 注入 EnhancedLogger sink，覆盖所有 mediaservice 调用
      EnhancedLogger.setSink((level, tag, message) => {
        AppLogStore.push(level, tag, message);
      });
      // 注入 YTCoreLogger sink，覆盖所有 youtube_core 调用
      YTCoreLogger.setSink((level, tag, message) => {
        AppLogStore.push(level, tag, message);
      });
      YoutubeJavaScriptPlayerManager.startAppPrewarm(this.context)
        .then(() => {
          // Layer 1: BotGuard init belongs to app startup, not mid-playback.
          // The WebView may still be attaching; the provider queues the warm-up
          // until setMinter fires.
          const visitorData = YoutubeJavaScriptPlayerManager.getPrewarmedVisitorData();
          if (visitorData) {
            SabrWebViewPoTokenProvider.getInstance().warmRuntime(visitorData);
          }
        })
        .catch((e: Error) => logger.warn(`Cipher prewarm failed: ${e.message || e}`));
      this.startPlaybackPrewarm();
      LanguageManager.applyPersistedLanguage();
      ColorModeManager.applyPersistedMode(this.context);
    } catch (err) {
      logger.error(`onCreate failed: ${JSON.stringify(err)}`);
    }
    logger.info('Ability onCreate');
  }

  private startPlaybackPrewarm(): void {
    const startedAt = Date.now();
    PlayerSession.getInstance().prewarmPlaybackEngine().then(() => {
      logger.info(`Playback prewarm MPV ready elapsed=${Date.now() - startedAt}ms`);
    }).catch((e: Error) => {
      logger.warn(`Playback prewarm MPV failed: ${e.message || e}`);
    });
    LocalMediaProxy.warmup().then((ok: boolean) => {
      logger.info(`Playback prewarm proxy ready=${ok} elapsed=${Date.now() - startedAt}ms`);
    }).catch((e: Error) => {
      logger.warn(`Playback prewarm proxy failed: ${e.message || e}`);
    });
    const service = YouTubePlayService.getInstance(this.context);
    // P0-2 (TTFF): proxy-side startup gate — demand-side SIDX/segment fetches
    // wait for the pending pot injection without blocking play() submission.
    LocalMediaProxy.setStartupUrlGate(() => service.awaitPendingDashPoToken());
    service.initialize().then(() => service.prewarmClientVersion()).then(() => {
      logger.info(`Playback prewarm extractor ready elapsed=${Date.now() - startedAt}ms`);
    }).catch((e: Error) => {
      logger.warn(`Playback prewarm extractor failed: ${e.message || e}`);
    });
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
    PlayerSession.getInstance().controller.releaseVideo(0);
    logger.info('Ability onDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    logger.info(`onConfigurationUpdate: ${JSON.stringify(newConfig)}`);
    // 配置更新回调：语言、深色模式等系统配置变化时触发。
    // 当用户选择跟随系统时，系统深色模式变化需要同步到 effectiveColorMode，
    // 否则退出播放页等场景的状态栏内容颜色会沿用旧值。
    const uiConfig: UIConfig = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
    if (uiConfig.darkMode === YourtubeDarkMode.SYSTEM) {
      ColorModeManager.publishEffectiveColorMode(this.context, YourtubeDarkMode.SYSTEM);
    }
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
    // 观看历史进度 tick 是延迟落盘的，退后台先把脏数据刷掉，防止被杀后丢进度。
    WatchHistoryStore.flushIfDirty();
    // 后台长时任务由 PlayerStateMachine 统一管理；此处保留兜底注册以应对极端时序
    // （重复注册返回 9800005 会被静默忽略，详见 BackgroundTaskManager）。
    // 仅播放活跃时才兜底注册（与 BackgroundTaskStateListener 同一活跃集合）：
    // 从未播放就退后台时，注册注定失败，只会产生一条无意义的 ERROR 日志。
    const playerState = PlayerSession.getInstance().playerState;
    const isPlaybackActive = playerState === PlayerState.PLAYING || playerState === PlayerState.PAUSED
      || playerState === PlayerState.BUFFERING || playerState === PlayerState.READY
      || playerState === PlayerState.LOADING;
    if (isPlaybackActive) {
      BackgroundTaskManager.startContinuousTask(this.context);
    } else {
      logger.debug(`onBackground: skip safety-net continuous task, playerState=${playerState}`);
    }
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
