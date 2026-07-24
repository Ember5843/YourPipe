import { AppLog } from '../../../common/AppLog';
import { PiPWindow } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PlayerSession } from '../../../common/PlayerSession';
import { PlayerPresentation } from '../../../common/PlayerPresentation';
import { AvPlayerController, PlaybackState } from 'mediaservice';

const logger = AppLog.getInstance('PiPManager');
const TAG: string = '[PiP][PiPManager]';

/**
 * PiP 生命周期回调接口。注册后由 PiPManager 在状态变化时回调。
 */
export interface PiPLifecycleCallback {
  onPiPStateChanged(state: PiPWindow.PiPState): void;
}

/**
 * 画中画管理器（单例）—— XComponent 方式。
 *
 * 与 typeNode 方式不同：本方式不创建/迁移节点，PiPWindow.create(config) 不传 contentNode。
 * 系统在启动 PiP 时把播放页 XComponent 当前的 surface 画面直接投射到悬浮窗，
 * surfaceId 自始至终不变，MPV 引擎无需 detach/re-attach surface，无黑帧、无几何丢失。
 *
 * 还原（点击 PiP 恢复）由系统通过 navigationId 自动回到原页面，应用无需手动管理页面节点。
 *
 * 职责：
 * 1. 持有播放页注入的 XComponentController（componentController）。
 * 2. 创建 PiPWindow.PiPController，注册 stateChange / controlEvent 回调。
 * 3. 提供 startPiP / stopPiP / setAutoStart / updateContentSize。
 * 4. 把 controlEvent（PLAY_PAUSE / NEXT / PREVIOUS）路由到 controller / PlayQueueManager。
 * 5. 把 stateChange 同步到 PlayerSession.isPiPActive，并通知注册的生命周期回调。
 */
export class PiPManager {
  private static instance: PiPManager | null = null;

  /** 由播放页 AVPlayer 通过 onSurfaceReady 注入的渲染用 XComponentController */
  private componentController: XComponentController | null = null;
  /** Controller captured by the currently-created system PiPController. */
  private boundComponentController: XComponentController | null = null;
  private pipController: PiPWindow.PiPController | null = null;
  private isInitialized: boolean = false;
  private isCreatingController: boolean = false;
  /** 与 Index.ets 的 HdsNavigation id 一致，用于 PiP 还原时恢复原页面 */
  private navigationId: string = 'mainNavigation';
  private lifecycleCallbacks: PiPLifecycleCallback[] = [];
  private playbackStateController: AvPlayerController | null = null;
  private hasPlaybackState: boolean = false;
  private lastIsPlaying: boolean = false;
  private desiredAutoStart: boolean = false;
  private suppressNextStopAction: boolean = false;
  private pendingRestoreComponentController: XComponentController | null = null;
  private restoreWatchdogTimerId: number = -1;
  private restoreStopped: boolean = false;
  private playbackStateListener = (state: PlaybackState): void => {
    this.hasPlaybackState = true;
    this.lastIsPlaying = state.isPlaying;
    this.applyPlaybackStateToPiP();
  };

  /** PiP 恢复时回调（移植 0.4.0）：由 Index 注入，确保 PlayerPage 在栈顶以重建 */
  onPipRestore: (() => void) | null = null;
  /** 正在从 PiP 恢复，避免 STOPPED 误触发 onPipStop 的释放 */
  isRestoring: boolean = false;

  /** 待初始化：init 时若 componentController 未就绪，缓存参数，待 setComponentController 后自动补 init。
   *  消除"流提取完成调 init"与"新页 XComponent.onLoad 注入 controller"的到达顺序竞争。 */
  private pendingInitCtx: common.UIAbilityContext | null = null;
  private pendingInitW: number = 0;
  private pendingInitH: number = 0;

  private constructor() {
    PlayerSession.getInstance().onStopPiP = () => this.stopPiP();
  }

  static getInstance(): PiPManager {
    if (!PiPManager.instance) {
      PiPManager.instance = new PiPManager();
    }
    return PiPManager.instance;
  }

  /**
   * 是否支持画中画（设备能力检测）。
   */
  isPiPSupported(): boolean {
    try {
      return PiPWindow.isPiPEnabled();
    } catch (e) {
      logger.warn(`${TAG} isPiPEnabled failed: ${e}`);
      return false;
    }
  }

  /**
   * 播放页 AVPlayer 在 XComponent.onLoad（onSurfaceReady）时注入渲染 controller。
   * 这是 XComponent 方式 PiP 的 componentController 来源。
   */
  setComponentController(controller: XComponentController): void {
    const session = PlayerSession.getInstance();
    if (this.isRestoring || session.isPipRestoring) {
      // The restored page can expose its new XComponent before the old PiP
      // controller reports STOPPED. Keep the new surface pending until the
      // old system-owned surface is fully released.
      this.componentController = controller;
      this.pendingRestoreComponentController = controller;
      if (this.restoreStopped) {
        this.finishRestoreRebind();
      } else {
        logger.info(`${TAG} setComponentController: defer PiP recreation until restore STOPPED`);
      }
      return;
    }
    // PiPWindow.create captures componentController; changing our field does
    // not update an existing PiPController. A newly-created PlayerPage must
    // therefore invalidate a controller bound to the previous page surface.
    if (this.pipController && this.boundComponentController !== controller) {
      logger.info(`${TAG} setComponentController: page controller changed, recreate PiPController`);
      this.destroy();
    }
    this.componentController = controller;
    // 若此前 init 因 controller 未就绪而挂起，现在补做（消除冷启动后的到达顺序竞争）。
    if (!this.isInitialized && this.pendingInitCtx) {
      const ctx = this.pendingInitCtx;
      const w = this.pendingInitW;
      const h = this.pendingInitH;
      this.pendingInitCtx = null;
      logger.info(`${TAG} setComponentController: running pending init`);
      this.init(ctx, w, h).catch((e: Error) => {
        logger.warn(`${TAG} pending init failed: ${e.message}`);
      });
    }
  }

  /**
   * 创建 PiPController（首次或重置后）。
   * videoWidth/videoHeight 用于计算 PiP 窗口比例（必须大于 0）。
   */
  async init(ctx: common.UIAbilityContext, videoWidth: number, videoHeight: number): Promise<boolean> {
    this.attachPlaybackStateSource();
    if (this.isInitialized && this.pipController) {
      this.updateContentSize(videoWidth, videoHeight);
      this.applyPlaybackStateToPiP();
      return true;
    }
    if (this.isCreatingController) {
      logger.info(`${TAG} init skipped: controller creation in progress`);
      return false;
    }
    if (!this.componentController) {
      // componentController 尚未注入（新页 XComponent.onLoad 还没触发）：缓存参数，
      // 待 setComponentController 注入后自动补 init，避免冷启动后竞争失败导致 PiP 不可用。
      logger.info(`${TAG} init deferred: componentController not set yet, pending`);
      this.pendingInitCtx = ctx;
      this.pendingInitW = videoWidth;
      this.pendingInitH = videoHeight;
      return false;
    }

    this.isCreatingController = true;
    try {
      const safeW = videoWidth > 0 ? videoWidth : 16;
      const safeH = videoHeight > 0 ? videoHeight : 9;
      const config: PiPWindow.PiPConfiguration = {
        context: ctx,
        componentController: this.componentController,
        navigationId: this.navigationId,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: safeW,
        contentHeight: safeH,
      };
      this.pipController = await PiPWindow.create(config);
      this.boundComponentController = this.componentController;
      this.registerCallbacks();
      this.pipController.setAutoStartEnabled(this.desiredAutoStart);
      this.isInitialized = true;
      this.applyPlaybackStateToPiP();
      logger.info(`${TAG} init success, pipController created`);
      return true;
    } catch (e) {
      logger.error(`${TAG} init failed: ${e}`);
      return false;
    } finally {
      this.isCreatingController = false;
    }
  }

  private registerCallbacks(): void {
    if (!this.pipController) {
      return;
    }
    this.pipController.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
      this.onStateChange(state, reason);
    });
    this.pipController.on('controlEvent', (param: PiPWindow.ControlEventParam) => {
      this.onControlEvent(param);
    });
  }

  private unregisterCallbacks(): void {
    if (!this.pipController) {
      return;
    }
    try {
      this.pipController.off('stateChange');
    } catch (e) {
      logger.warn(`${TAG} off stateChange failed: ${e}`);
    }
    try {
      this.pipController.off('controlEvent');
    } catch (e) {
      logger.warn(`${TAG} off controlEvent failed: ${e}`);
    }
  }

  private onStateChange(state: PiPWindow.PiPState, reason: string): void {
    logger.info(`${TAG} onStateChange state=${state} reason=${reason}`);
    const session = PlayerSession.getInstance();
    switch (state) {
      case PiPWindow.PiPState.ABOUT_TO_START:
        // 即将进入 PiP：系统正在把主页 XComponent 的 surface 接管到悬浮窗，
        // 此时主页 XComponent 依然在正常渲染最后一帧。若现在就 mount 占位层
        // 会突然覆盖在画面上，与系统的缩放动画并行造成"闪一下"。延迟到 STARTED
        // （悬浮窗已就位、主页 surface 已腾空）再 mount，视觉过渡平滑。
        break;
      case PiPWindow.PiPState.STARTED:
        // 已进入 PiP：surface 已被悬浮窗接管。
        // Back→PiP keeps handoff pending until page disappears so the full page
        // never flashes "画中画运行中" before navPathStack.pop().
        // Home auto-start has no handoff → placeholder can cover the empty surface.
        session.setPiPActive(true);
        if (!session.isPipHandoffPending) {
          session.completePipHandoff();
        }
        // Keep video decode ON for PiP surface (cancel any background off timer).
        PlayerPresentation.onPipStarted();
        this.applyPlaybackStateToPiP();
        break;
      case PiPWindow.PiPState.ABOUT_TO_STOP:
        // 即将退出 PiP（关闭、要释放或要恢复都会先走这一步）：系统准备把 surface
        // 还回主页。提前 unmount 占位层让主页 XComponent 露出，与系统缩放动画
        // 同步过渡；否则要等到 STOPPED 才 unmount，悬浮窗已消失而占位层还在，
        // 会出现"先黑屏闪一下再露画面"。
        // Closing the PiP panel is equivalent to destroying the playback page.
        // Stop MPV before WMS destroys the PiP surface; waiting until STOPPED
        // leaves gpu-next rendering into a dead swapchain and produces
        // VK_ERROR_SURFACE_LOST_KHR. Restore keeps rendering for hand-back.
        // Restore hand-back must never release media/queue even if reason text
        // is ambiguous on some devices (ABOUT_TO_RESTORE may already be set).
        if (this.isRestoreInProgress(session) || this.isRestoreReason(reason)) {
          logger.info(`${TAG} ABOUT_TO_STOP restore path reason=${reason}; retain media`);
          session.setPiPActive(false);
          break;
        }
        if (this.isDeleteReason(reason)) {
          logger.info(`${TAG} ABOUT_TO_STOP via ${reason}, release session before surface teardown`);
          // This controller belongs to the playback page that is being closed.
          // Invalidate it immediately: a subsequent page can call init() before
          // STOPPED arrives, and must wait for its own XComponent.onLoad rather
          // than create a PiPController with this dead surface controller.
          this.componentController = null;
          // Closing the PiP window means closing playback altogether.  Release
          // MPV while the PiP surface is still valid so its Vulkan swapchain is
          // destroyed before WindowManager removes the surface.
          this.isRestoring = false;
          this.restoreStopped = false;
          this.clearRestoreWatchdog();
          session.setPipRestoring(false);
          session.setPiPActive(false);
          session.release();
          PlayerPresentation.onPipStopped(false);
        }
        session.setPiPActive(false);
        break;
      case PiPWindow.PiPState.ABOUT_TO_RESTORE:
        // 点 PiP 恢复按钮：立刻清占位层，避免系统还原出的播放页先闪「画中画运行中」。
        this.isRestoring = true;
        this.restoreStopped = false;
        session.setPiPActive(false);
        session.setPipRestoring(true);
        this.startRestoreWatchdog();
        if (this.onPipRestore) {
          this.onPipRestore();
        }
        break;
      case PiPWindow.PiPState.STOPPED:
        // 兜底：极端情况下没收到 ABOUT_TO_STOP（系统直接 STOPPED），这里再保险
        // 一次。正常时机已经在 ABOUT_TO_STOP 处理过，这里 setPiPActive(false)
        // 是幂等的，不会再触发 UI 抖动。
        session.setPiPActive(false);
        // panelActionRestore / restore flags：恢复到播放页，跳过清理。
        // requestDelete：用户主动关闭 PiP → release。
        // 其它原因：仅在非 restore 时关闭媒体；误判会清空 ADHOC 队列并杀死引擎。
        if (this.suppressNextStopAction) {
          this.suppressNextStopAction = false;
          PlayerPresentation.onPipStopped(false);
          logger.info(`${TAG} STOPPED ignored: old PiP was intentionally replaced`);
        } else if (this.isRestoreInProgress(session) || this.isRestoreReason(reason)) {
          logger.info(`${TAG} STOPPED restore path reason=${reason}; retain media/queue`);
          this.isRestoring = true;
          session.setPipRestoring(true);
          PlayerPresentation.onPipStopped(true);
          this.restoreStopped = true;
          this.finishRestoreRebind();
        } else if (this.isDeleteReason(reason)) {
          logger.info(`${TAG} STOPPED via ${reason}, release session + destroy pipController`);
          PlayerPresentation.onPipStopped(false);
          this.isRestoring = false;
          this.restoreStopped = false;
          this.clearRestoreWatchdog();
          session.setPipRestoring(false);
          session.release();
          // 销毁 PiPController 本身：它持有已销毁播放页的旧 XComponentController，
          // 若残留，下次播新视频 init() 会复用它，导致系统重绑 surface 失败
          // (SetXComponentController: swap xComponent failed / OnInitXComponentController failed)。
          // destroy 后 isInitialized=false，下次 init 重建绑定新 XComponentController 的干净控制器。
          this.destroy();
        } else {
          PlayerPresentation.onPipStopped(false);
          this.handleDefaultPipStop();
        }
        // Media retain (session.isPipRestoring) stays true until PlayerPage
        // finishes attach; only clear when this STOPPED was not a restore.
        if (!this.isRestoreInProgress(session)) {
          this.clearRestoreWatchdog();
        }
        break;
      case PiPWindow.PiPState.ERROR:
        logger.error(`${TAG} PiP error: ${reason}`);
        const failedDuringRestore = this.isRestoreInProgress(session);
        session.cancelPipHandoff();
        session.setPiPActive(false);
        PlayerPresentation.onPipStopped(false);
        if (failedDuringRestore) {
          // Keep media alive: restore UI may still rebind the existing session.
          // Only drop PiP controller bookkeeping; do not release()/clear queue.
          logger.error(`${TAG} PiP restore failed; keep media session for page rebind`);
          this.isRestoring = false;
          this.restoreStopped = false;
          this.clearRestoreWatchdog();
          this.destroy(false);
        } else {
          this.isRestoring = false;
          this.restoreStopped = false;
          session.setPipRestoring(false);
          this.clearRestoreWatchdog();
        }
        break;
      default:
        break;
    }
    for (const cb of this.lifecycleCallbacks) {
      try {
        cb.onPiPStateChanged(state);
      } catch (e) {
        logger.warn(`${TAG} lifecycle callback error: ${e}`);
      }
    }
  }

  private onControlEvent(param: PiPWindow.ControlEventParam): void {
    logger.info(`${TAG} onControlEvent controlType=${param.controlType} status=${param.status}`);
    const session = PlayerSession.getInstance();
    const controller = session.controller;
    switch (param.controlType) {
      case PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE: {
        if (param.status === PiPWindow.PiPControlStatus.PLAY) {
          controller.syncPlay();
        } else {
          controller.syncPause();
        }
        break;
      }
      case PiPWindow.PiPControlType.VIDEO_NEXT: {
        session.playNextFromQueue().catch((e: Error) => {
          logger.warn(`${TAG} playNext from PiP failed: ${e.message}`);
        });
        break;
      }
      case PiPWindow.PiPControlType.VIDEO_PREVIOUS: {
        session.playPreviousFromQueue().catch((e: Error) => {
          logger.warn(`${TAG} playPrev from PiP failed: ${e.message}`);
        });
        break;
      }
      default:
        break;
    }
  }

  /**
   * 启动画中画。返回是否成功（内部捕获异常）。
   */
  async startPiP(): Promise<boolean> {
    if (!this.pipController) {
      logger.warn(`${TAG} startPiP failed: controller not created`);
      return false;
    }
    try {
      await this.pipController.startPiP();
      logger.info(`${TAG} startPiP success`);
      return true;
    } catch (e) {
      logger.error(`${TAG} startPiP failed: ${e}`);
      return false;
    }
  }

  /**
   * 停止画中画。
   */
  async stopPiP(): Promise<void> {
    if (!this.pipController) {
      return;
    }
    try {
      await this.pipController.stopPiP();
      logger.info(`${TAG} stopPiP success`);
    } catch (e) {
      logger.warn(`${TAG} stopPiP failed: ${e}`);
    }
  }

  /**
   * 设置是否在应用返回桌面时自动启动画中画（home 键场景）。
   */
  setAutoStart(enabled: boolean): void {
    this.desiredAutoStart = enabled;
    if (!this.pipController) {
      logger.info(`${TAG} setAutoStart deferred=${enabled}`);
      return;
    }
    try {
      this.pipController.setAutoStartEnabled(enabled);
      logger.info(`${TAG} setAutoStart=${enabled}`);
    } catch (e) {
      logger.warn(`${TAG} setAutoStart failed: ${e}`);
    }
  }

  /**
   * 把 MPV 引擎的实际播放/暂停状态同步给画中画控件，使 PiP 面板的
   * 播放/暂停按钮显示与真实播放状态一致（PLAY=正在播放→显示暂停按钮）。
   * 仅在 PiP 控制器已创建时生效；缓冲中不切换，避免按钮抖动。
   */
  updatePlayPauseStatus(isPlaying: boolean): void {
    // Compatibility entry for callers without a full PlaybackState. Cache the
    // value so controller creation / STARTED can replay it instead of dropping it.
    this.hasPlaybackState = true;
    this.lastIsPlaying = isPlaying;
    this.applyPlayPauseStatus(isPlaying);
  }

  private attachPlaybackStateSource(): void {
    const controller: AvPlayerController = PlayerSession.getInstance().controller;
    if (this.playbackStateController === controller) return;
    if (this.playbackStateController) {
      this.playbackStateController.unsubscribePlaybackState(this.playbackStateListener);
    }
    this.playbackStateController = controller;
    controller.subscribePlaybackState(this.playbackStateListener);
    const state: PlaybackState = controller.getPlaybackState();
    this.hasPlaybackState = true;
    this.lastIsPlaying = state.isPlaying;
  }

  private applyPlaybackStateToPiP(): void {
    if (!this.hasPlaybackState) return;
    this.applyPlayPauseStatus(this.lastIsPlaying);
  }

  private applyPlayPauseStatus(isPlaying: boolean): void {
    // PiPController can exist while the app is still on the player page, but
    // the system pipWindow is created only after STARTED. Updating controls
    // before that point produces WMSPiP "pipWindow not exist" and can race
    // with back-to-PiP startup. The cached state is replayed in STARTED.
    if (!this.pipController || !PlayerSession.getInstance().isPiPActive) return;
    try {
      const status: PiPWindow.PiPControlStatus =
        isPlaying ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE;
      this.pipController.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE, status);
    } catch (e) {
      logger.warn(`${TAG} updatePlayPauseStatus failed: ${e}`);
    }
  }

  /**
   * 更新媒体源尺寸（切视频后调用，调整 PiP 窗口比例）。
   */
  updateContentSize(width: number, height: number): void {
    if (!this.pipController || width <= 0 || height <= 0) {
      return;
    }
    try {
      this.pipController.updateContentSize(width, height);
      logger.info(`${TAG} updateContentSize ${width}x${height}`);
    } catch (e) {
      logger.warn(`${TAG} updateContentSize failed: ${e}`);
    }
  }

  /**
   * PiPController 是否已创建。
   */
  get isReady(): boolean {
    return this.isInitialized && this.pipController !== null;
  }

  registerLifecycleCallback(cb: PiPLifecycleCallback): void {
    this.lifecycleCallbacks.push(cb);
  }

  unregisterLifecycleCallback(cb: PiPLifecycleCallback): void {
    const idx = this.lifecycleCallbacks.indexOf(cb);
    if (idx >= 0) {
      this.lifecycleCallbacks.splice(idx, 1);
    }
  }

  /**
   * 注销所有生命周期监听（PlayerPage aboutToDisappear 时调用）。
   */
  unregisterPipStateChangeListener(): void {
    this.lifecycleCallbacks = [];
  }

  /**
   * 销毁 PiPController（应用退出 / 全局释放时）。
   * @param clearSessionRestore when false, keep session.pipRestoring so PlayerPage
   *   aboutToDisappear still retains media (restore-error soft cleanup).
   */
  destroy(clearSessionRestore: boolean = true): void {
    // 先关闭系统 PiP 窗口再置空控制器：否则 PiP 激活时点新视频走 destroy，
    // app 侧控制器没了但系统悬浮窗还在，成为孤儿窗口导致状态错乱。
    const ctrl = this.pipController;
    if (ctrl) {
      this.suppressNextStopAction = PlayerSession.getInstance().isPiPActive;
      ctrl.stopPiP().catch((e: Error) => {
        this.suppressNextStopAction = false;
        logger.warn(`${TAG} stopPiP during destroy failed: ${e.message}`);
      });
    }
    this.unregisterCallbacks();
    this.pipController = null;
    this.boundComponentController = null;
    this.isInitialized = false;
    this.isRestoring = false;
    this.restoreStopped = false;
    if (clearSessionRestore) {
      PlayerSession.getInstance().setPipRestoring(false);
    }
    // requestDelete 在 ABOUT_TO_STOP 中已经清除了旧页面 controller。其他 destroy
    // 场景可能仍会复用同一个页面，因此这里不做无条件清理。
    // 同步清 PiP 激活标志，避免占位层/返回键误判残留。
    PlayerSession.getInstance().setPiPActive(false);
    // 清待初始化缓存，避免冷重置后残留旧参数误触发 init。
    this.pendingInitCtx = null;
    this.pendingRestoreComponentController = null;
    this.clearRestoreWatchdog();
  }

  /**
   * Called by restored PlayerPage after surface rebind. Ends media-retain window
   * so a later real navigation can closeForNavigation normally.
   */
  completePageRestore(): void {
    this.isRestoring = false;
    this.restoreStopped = false;
    this.clearRestoreWatchdog();
    PlayerSession.getInstance().setPipRestoring(false);
    logger.info(`${TAG} page restore complete; media retain released`);
  }

  private finishRestoreRebind(): void {
    const restoredController = this.pendingRestoreComponentController;
    if (!restoredController || !this.restoreStopped) {
      return;
    }
    // Rebind PiP controller to the new page surface, but keep session.pipRestoring
    // true until PlayerPage.aboutToAppear finishes attach. Clearing it here races
    // old-page aboutToDisappear → closeForNavigation → empty queue / dead engine.
    this.unregisterCallbacks();
    this.pipController = null;
    this.boundComponentController = null;
    this.isInitialized = false;
    this.componentController = restoredController;
    this.pendingRestoreComponentController = null;
    this.isRestoring = true;
    this.restoreStopped = false;
    PlayerSession.getInstance().setPipRestoring(true);
    this.clearRestoreWatchdog();
    const ctx = AppStorage.get<common.UIAbilityContext>('context');
    if (!ctx) {
      logger.warn(`${TAG} restore rebind skipped: context unavailable`);
      return;
    }
    const vm = PlayerSession.getInstance().controller.vm;
    this.init(ctx, vm.videoWidth || 16, vm.videoHeight || 9).catch((e: Error) => {
      logger.warn(`${TAG} restore PiP recreation failed: ${e.message}`);
    });
  }

  private startRestoreWatchdog(): void {
    this.clearRestoreWatchdog();
    this.restoreStopped = false;
    this.restoreWatchdogTimerId = setTimeout(() => {
      this.restoreWatchdogTimerId = -1;
      if (!this.isRestoring && !PlayerSession.getInstance().isPipRestoring) {
        return;
      }
      // Do not release media on timeout: user already restored into the player.
      // Only drop stuck restore flags so later navigation can clean up normally.
      logger.warn(`${TAG} restore timed out; keep media session, clear restore flags`);
      this.completePageRestore();
    }, 8000);
  }

  private clearRestoreWatchdog(): void {
    if (this.restoreWatchdogTimerId >= 0) {
      clearTimeout(this.restoreWatchdogTimerId);
      this.restoreWatchdogTimerId = -1;
    }
  }

  private handleDefaultPipStop(): void {
    const session = PlayerSession.getInstance();
    if (this.isRestoreInProgress(session)) {
      logger.info(`${TAG} default PiP stop skipped: restore in progress`);
      return;
    }
    logger.info(`${TAG} default PiP stop -> close media session`);
    session.release();
  }

  private isRestoreInProgress(session: PlayerSession): boolean {
    return this.isRestoring || session.isPipRestoring;
  }

  /** HarmonyOS / OEM variants for restore stop reason. */
  private isRestoreReason(reason: string): boolean {
    if (!reason) {
      return false;
    }
    if (reason === 'panelActionRestore') {
      return true;
    }
    const lower = reason.toLowerCase();
    return lower.indexOf('restore') >= 0;
  }

  /** HarmonyOS versions report panel close as either value. */
  private isDeleteReason(reason: string): boolean {
    return reason === 'requestDelete' || reason === 'panelActionDelete';
  }
}
