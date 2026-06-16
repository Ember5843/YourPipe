import { AppLog } from '../../../common/AppLog';
import { PiPWindow } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PlayerSession } from '../../../common/PlayerSession';

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
  private pipController: PiPWindow.PiPController | null = null;
  private isInitialized: boolean = false;
  private isCreatingController: boolean = false;
  /** 与 Index.ets 的 HdsNavigation id 一致，用于 PiP 还原时恢复原页面 */
  private navigationId: string = 'mainNavigation';
  private lifecycleCallbacks: PiPLifecycleCallback[] = [];

  private constructor() {}

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
    this.componentController = controller;
  }

  /**
   * 创建 PiPController（首次或重置后）。
   * videoWidth/videoHeight 用于计算 PiP 窗口比例（必须大于 0）。
   */
  async init(ctx: common.UIAbilityContext, videoWidth: number, videoHeight: number): Promise<boolean> {
    if (this.isInitialized && this.pipController) {
      this.updateContentSize(videoWidth, videoHeight);
      return true;
    }
    if (this.isCreatingController) {
      logger.info(`${TAG} init skipped: controller creation in progress`);
      return false;
    }
    if (!this.componentController) {
      logger.warn(`${TAG} init failed: componentController not set yet (XComponent not loaded)`);
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
        controlGroups: [PiPWindow.VideoPlayControlGroup.VIDEO_PREVIOUS_NEXT],
      };
      this.pipController = await PiPWindow.create(config);
      this.registerCallbacks();
      this.pipController.setAutoStartEnabled(false);
      this.isInitialized = true;
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
      case PiPWindow.PiPState.STARTED:
        // XComponent 方式：系统把播放页 surface 投到悬浮窗，无需迁移节点。
        session.setPiPActive(true);
        break;
      case PiPWindow.PiPState.STOPPED:
        session.setPiPActive(false);
        break;
      case PiPWindow.PiPState.ERROR:
        logger.error(`${TAG} PiP error: ${reason}`);
        session.setPiPActive(false);
        break;
      default:
        // ABOUT_TO_STOP / ABOUT_TO_RESTORE：还原由系统经 navigationId 处理，无需操作。
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
          controller.syncPause();
        } else {
          controller.syncPlay();
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
    if (!this.pipController) {
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
   */
  destroy(): void {
    this.unregisterCallbacks();
    this.pipController = null;
    this.isInitialized = false;
  }
}
