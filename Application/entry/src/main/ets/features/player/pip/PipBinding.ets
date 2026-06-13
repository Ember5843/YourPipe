/*
 * PipBinding —— PiP 子系统接线层（唯一的副作用集中点）
 *
 * 设计原则：所有"何时调系统 API、何时同步播放器、何时操作导航栈"
 * 的规则都在 PipState 转换监听器里集中表达，外部代码只通过 4 个
 * 公共方法触达：requestEnter / requestExit / setEnabled / dispose。
 *
 * 双轴正交：
 *   PlayerState（播放引擎）—— mediaservice 维护，本类只订阅 isPlaying
 *   PipState（窗口可见性）—— 本类维护
 *
 * 上层关闭语义（按需求规约）：
 *   PiP 系统面板 ✕ / 拖到垃圾桶  → 仅 syncPause()，不 release
 *   PiP 系统面板 ⤢ 恢复按钮       → PipNavigator.restore()，播放器原状继续
 */

import { PiPWindow } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../../../common/AppLog';
import { AvPlayerController, PlayerState, StateChangeListener } from 'mediaservice';
import { PipState } from './PipState';
import { PipStateMachine, PipStateChangeListener } from './PipStateMachine';
import { PipWindowController } from './PipWindowController';
import { PipNavigator } from './PipNavigator';

const TAG = '[PipBinding]';
const logger = AppLog.getInstance('PipBinding');

const NAVIGATION_ID = 'mainNavigation';

export interface PipSurfaceBinding {
  xComponentController: XComponentController;
  /** PlayerPage 的 getUniqueId()，系统据此恢复 NavDestination */
  handleId: number;
}

export type VideoSizeProvider = () => VideoSize;

export interface VideoSize {
  width: number;
  height: number;
}

export class PipBinding implements PipStateChangeListener, StateChangeListener {
  private readonly machine: PipStateMachine = new PipStateMachine();
  private readonly windowController: PipWindowController = new PipWindowController();
  private context: common.UIAbilityContext | null = null;
  private surface: PipSurfaceBinding | null = null;
  private getVideoSize: VideoSizeProvider | null = null;
  private playerController: AvPlayerController | null = null;

  private enabled: boolean = true;
  private lastIsPlaying: boolean = false;

  constructor() {
    this.machine.addListener(this);
  }

  // ─────────────────── 公共接口 ───────────────────

  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
    if (!enabled && this.machine.isVisible()) {
      this.requestExit();
    }
    this.windowController.setAutoStartEnabled(false);
    logger.info(`${TAG} setEnabled=${enabled}`);
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  async bindPlayerSurface(
    context: common.UIAbilityContext,
    surface: PipSurfaceBinding,
    getVideoSize: VideoSizeProvider,
    playerController: AvPlayerController,
  ): Promise<void> {
    this.context = context;
    this.surface = surface;
    this.getVideoSize = getVideoSize;
    if (this.playerController !== playerController) {
      this.playerController?.removeStateListener(this);
      this.playerController = playerController;
      this.playerController.addStateListener(this);
    }
    if (!this.enabled) return;
    if (!PipWindowController.isPiPSupported()) {
      logger.warn(`${TAG} PiP unsupported, staying DISABLED`);
      return;
    }
    await this.ensureCreated();
  }

  async requestEnter(): Promise<boolean> {
    if (!this.enabled) return false;
    if (this.machine.isVisible()) return true;
    if (!await this.ensureCreated()) return false;
    if (!this.machine.transition(PipState.ENTERING)) return false;
    const ok = await this.windowController.startPiP();
    if (!ok) {
      this.machine.transition(PipState.INACTIVE);
      return false;
    }
    return true;
  }

  async requestExit(): Promise<void> {
    if (!this.machine.isOneOf(PipState.ACTIVE, PipState.ENTERING)) return;
    if (!this.machine.transition(PipState.EXITING)) return;
    await this.windowController.stopPiP();
  }

  /** 切视频时由 PlayerSession 调用——PiP 不可见时也无害（被忽略）。 */
  notifyVideoSizeChanged(width: number, height: number): void {
    if (this.machine.state === PipState.ACTIVE) {
      this.windowController.updateContentSize(width, height);
    }
  }

  dispose(): void {
    this.playerController?.removeStateListener(this);
    this.playerController = null;
    this.windowController.dispose();
    this.machine.transition(PipState.DISABLED);
  }

  /** 给 PlayerPage.onVideoChange 早退用——可见时不重新 play。 */
  isVisible(): boolean {
    return this.machine.isVisible();
  }

  getState(): PipState {
    return this.machine.state;
  }

  // ─────────────────── 副作用集中点 ───────────────────

  onPipStateChange(from: PipState, to: PipState): void {
    logger.info(`${TAG} pipState ${from} -> ${to}`);
    if (to === PipState.ACTIVE) {
      this.syncPlayPauseToPanel();
      const size = this.getVideoSize?.();
      if (size && size.width > 0 && size.height > 0) {
        this.windowController.updateContentSize(size.width, size.height);
      }
    } else if (to === PipState.RESTORING) {
      PipNavigator.restore();
    } else if (to === PipState.DISABLED) {
      this.windowController.dispose();
    }
  }

  // ─────────────────── 播放器状态订阅 ───────────────────

  onStateChange(_from: PlayerState, to: PlayerState): void {
    const isPlaying = to === PlayerState.PLAYING;
    if (isPlaying !== this.lastIsPlaying) {
      this.lastIsPlaying = isPlaying;
      if (this.machine.state === PipState.ACTIVE) {
        this.windowController.updatePlayPauseStatus(isPlaying);
      }
    }
    if (to === PlayerState.RELEASED && this.machine.isVisible()) {
      this.requestExit();
    }
  }

  // ─────────────────── 系统事件回调 ───────────────────

  private async ensureCreated(): Promise<boolean> {
    if (this.windowController.hasController()) return true;
    if (!this.context || !this.surface) {
      logger.warn(`${TAG} ensureCreated skipped: surface not bound yet`);
      return false;
    }
    const size = this.getVideoSize?.() ?? { width: 0, height: 0 };
    const ok = await this.windowController.create(
      {
        context: this.context,
        xComponentController: this.surface.xComponentController,
        navigationId: NAVIGATION_ID,
        handleId: this.surface.handleId,
        contentWidth: size.width,
        contentHeight: size.height,
      },
      (s: PiPWindow.PiPState, r: string) => this.handleSysStateChange(s, r),
      (e: PiPWindow.PiPActionEventType, st: number) => this.handleSysControlEvent(e, st),
    );
    if (ok) this.machine.transition(PipState.INACTIVE);
    return ok;
  }

  private handleSysStateChange(state: PiPWindow.PiPState, reason: string): void {
    logger.info(`${TAG} sys state ${state} reason=${reason}`);
    switch (state) {
      case PiPWindow.PiPState.STARTED:
        this.machine.transition(PipState.ACTIVE);
        break;
      case PiPWindow.PiPState.ABOUT_TO_RESTORE:
        this.machine.transition(PipState.RESTORING);
        break;
      case PiPWindow.PiPState.STOPPED:
        this.handleSysStopped(reason);
        break;
      case PiPWindow.PiPState.ERROR:
        logger.warn(`${TAG} PiP ERROR, falling back to INACTIVE`);
        this.machine.transition(PipState.INACTIVE);
        break;
      default:
        break;
    }
  }

  private handleSysStopped(reason: string): void {
    const wasUserClose = reason === 'panelActionDelete' || reason === 'dragDelete';
    const wasRestoring = this.machine.state === PipState.RESTORING;

    this.machine.transition(PipState.INACTIVE);

    if (wasRestoring) return;

    if (wasUserClose) {
      this.playerController?.syncPause();
      if (!PipNavigator.hasPlayerPage()) {
        PipNavigator.removePlayerPages();
      }
    }
  }

  private handleSysControlEvent(event: PiPWindow.PiPActionEventType, status: number): void {
    if (event === 'playbackStateChanged') {
      const wantPlay = status === 1;
      if (wantPlay) {
        this.playerController?.syncPlay();
      } else {
        this.playerController?.syncPause();
      }
      this.windowController.updatePlayPauseStatus(wantPlay);
    }
  }

  private syncPlayPauseToPanel(): void {
    const isPlaying = this.playerController?.vm.isPlaying ?? false;
    this.lastIsPlaying = isPlaying;
    this.windowController.updatePlayPauseStatus(isPlaying);
  }
}
