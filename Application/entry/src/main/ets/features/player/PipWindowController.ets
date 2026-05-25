/*
 * Picture-in-Picture (PiP) Window Controller for YourPipe
 *
 * Features:
 *   - Auto-start PiP on Home button press (respects user settings)
 *   - Play/Pause control synced from PiP panel
 *   - Closing the PiP window (✕) does NOT exit the player page.
 *     The caller supplies an optional onPipStop callback to handle any
 *     post-stop logic (e.g. restoring screen-on).
 */

import { PiPWindow } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Logger } from 'mediaservice';

const TAG = '[PipWindowController]';

export interface PipPlayerDelegate {
  syncPlay(): void;
  syncPause(): void;
  isPlaying: boolean;
}

export class PipWindowController {
  public pipController?: PiPWindow.PiPController;
  private context: common.UIAbilityContext | undefined = AppStorage.get('context');
  private xComponentController?: XComponentController;
  private playerDelegate?: PipPlayerDelegate;
  public curState: string = '';

  public onPipStop: () => void = () => {};
  public onPipRestore: () => void = () => {};

  constructor(xComponentController: XComponentController) {
    this.xComponentController = xComponentController;
  }

  public updateXComponentController(xc: XComponentController): void {
    this.xComponentController = xc;
    Logger.debug(TAG, 'XComponentController updated');
  }

  public getXComponentController(): XComponentController | undefined {
    return this.xComponentController;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  async createPipController(playerDelegate: PipPlayerDelegate, contentWidth?: number, contentHeight?: number): Promise<void> {
    this.playerDelegate = playerDelegate;

    if (!PiPWindow.isPiPEnabled()) {
      Logger.warn(TAG, 'PiP is not enabled on this device');
      return;
    }

    if (!this.pipController) {
      try {
        const config: PiPWindow.PiPConfiguration = {
          context: this.context!,
          componentController: this.xComponentController!,
          templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
          contentWidth: contentWidth || 1280,
          contentHeight: contentHeight || 720,
        };
        this.pipController = await PiPWindow.create(config);
      } catch (e) {
        Logger.error(TAG, `pipController init failed, code=${e.code}, message=${e.message}`);
      }
    }

    this.pipController?.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
      this.onStateChange(state, reason);
    });

    this.pipController?.on('controlPanelActionEvent', (event: PiPWindow.PiPActionEventType, status?: number) => {
      this.onActionEvent(event, status);
    });

    // 初始时禁用 auto-start，等播放器 isReady 后由外部调用 updateAutoStart 启用
    this.pipController?.setAutoStartEnabled(false);
    Logger.info(TAG, `PiP controller created, autoStart initially disabled`);
  }

  destroyPipController(): void {
    if (!this.pipController) {
      return;
    }
    this.pipController.setAutoStartEnabled(false);
    this.pipController.off('stateChange');
    this.pipController.off('controlPanelActionEvent');
    this.pipController = undefined;
    Logger.info(TAG, 'PiP controller destroyed');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Explicit start / stop
  // ─────────────────────────────────────────────────────────────────────────

  async startPiP(): Promise<void> {
    if (!this.pipController) {
      Logger.warn(TAG, 'startPiP called but pipController is null');
      return;
    }
    try {
      await this.pipController.startPiP();
      Logger.info(TAG, 'startPiP succeeded');
    } catch (e) {
      Logger.error(TAG, `startPiP failed, code=${e.code}, message=${e.message}`);
    }
  }

  async stopPiP(): Promise<void> {
    if (!this.pipController) return;
    try {
      await this.pipController.stopPiP();
      Logger.info(TAG, 'stopPiP succeeded');
    } catch (e) {
      Logger.error(TAG, `stopPiP failed, code=${e.code}, message=${e.message}`);
    }
  }

  updateAutoStart(enabled: boolean): void {
    this.pipController?.setAutoStartEnabled(enabled);
    Logger.info(TAG, `AutoStart updated: ${enabled}`);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal helpers
  // ─────────────────────────────────────────────────────────────────────────

  private syncPipPlayState(): void {
    if (!this.pipController) return;
    const status: PiPWindow.PiPControlStatus = this.playerDelegate?.isPlaying
      ? PiPWindow.PiPControlStatus.PLAY
      : PiPWindow.PiPControlStatus.PAUSE;
    this.pipController.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE, status);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Callbacks
  // ─────────────────────────────────────────────────────────────────────────

  /**
   * 更新 PiP 窗口内容尺寸（切换视频时调用）
   */
  updatePipContentSize(width: number, height: number): void {
    if (!this.pipController) return;
    try {
      this.pipController.updateContentSize(width, height);
      Logger.debug(TAG, `PiP content size updated: ${width}x${height}`);
    } catch (e) {
      Logger.warn(TAG, `updateContentSize failed: ${e}`);
    }
  }

  private onStateChange(state: PiPWindow.PiPState, reason: string): void {
    switch (state) {
      case PiPWindow.PiPState.ABOUT_TO_START:
        this.curState = 'ABOUT_TO_START';
        break;

      case PiPWindow.PiPState.STARTED:
        this.curState = 'STARTED';
        this.syncPipPlayState();
        setTimeout(() => { this.syncPipPlayState(); }, 500);
        break;

      case PiPWindow.PiPState.ABOUT_TO_STOP:
        this.curState = 'ABOUT_TO_STOP';
        break;

      case PiPWindow.PiPState.STOPPED:
        this.curState = 'STOPPED';
        if (reason === 'panelActionRestore' || reason === 'requestDelete') {
          Logger.debug(TAG, `PiP stopped via ${reason} — skipping onPipStop()`);
        } else {
          Logger.info(TAG, `PiP stopped via ${reason}`);
          this.onPipStop();
        }
        break;

      case PiPWindow.PiPState.ABOUT_TO_RESTORE:
        this.curState = 'ABOUT_TO_RESTORE';
        this.onPipRestore();
        break;

      case PiPWindow.PiPState.ERROR:
        this.curState = 'ERROR';
        break;

      default:
        break;
    }
    Logger.info(TAG, `onStateChange: ${this.curState}, reason: ${reason}`);
  }

  private onActionEvent(event: PiPWindow.PiPActionEventType, status?: number): void {
    switch (event) {
      case 'playbackStateChanged':
        // status 0 = pause requested, 1 = play requested
        if (status === 0) {
          this.playerDelegate?.syncPause();
          this.pipController?.updatePiPControlStatus(
            PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
            PiPWindow.PiPControlStatus.PAUSE
          );
        } else {
          this.playerDelegate?.syncPlay();
          this.pipController?.updatePiPControlStatus(
            PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
            PiPWindow.PiPControlStatus.PLAY
          );
        }
        break;

      default:
        break;
    }
  }
}
