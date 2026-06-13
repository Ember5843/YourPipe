/*
 * PipWindowController —— 包装 HarmonyOS PiPWindow 系统 API
 *
 * 职责（薄包装层）：
 *   - PiPWindow.create / startPiP / stopPiP
 *   - 订阅 on('stateChange') / on('controlEvent')，通过回调暴露给 PipBinding
 *   - updateContentSize / updatePiPControlStatus 透传
 *
 * 不做任何业务决策（什么时候 enter、谁来 release、栈如何恢复）——
 * 全部由 PipBinding 在 PipStateMachine 监听器里集中决策。
 */

import { PiPWindow } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../../../common/AppLog';

const TAG = '[PipWindowController]';
const logger = AppLog.getInstance('PipWindowController');

export type PipSysStateCallback = (state: PiPWindow.PiPState, reason: string) => void;
export type PipSysControlCallback = (event: PiPWindow.PiPActionEventType, status: number) => void;

export interface PipCreateConfig {
  context: common.UIAbilityContext;
  xComponentController: XComponentController;
  navigationId: string;
  handleId: number;
  contentWidth: number;
  contentHeight: number;
}

interface BusinessError {
  code: number;
  message: string;
}

export class PipWindowController {
  private pipController: PiPWindow.PiPController | null = null;
  private onSysState: PipSysStateCallback | null = null;
  private onSysControl: PipSysControlCallback | null = null;

  static isPiPSupported(): boolean {
    try {
      return PiPWindow.isPiPEnabled();
    } catch (_e) {
      return false;
    }
  }

  hasController(): boolean {
    return this.pipController !== null;
  }

  async create(cfg: PipCreateConfig,
    onSysState: PipSysStateCallback,
    onSysControl: PipSysControlCallback): Promise<boolean> {
    if (this.pipController) return true;

    if (!PipWindowController.isPiPSupported()) {
      logger.warn(`${TAG} create skipped: PiP not supported on device`);
      return false;
    }

    try {
      const config: PiPWindow.PiPConfiguration = {
        context: cfg.context,
        componentController: cfg.xComponentController,
        navigationId: cfg.navigationId,
        handleId: cfg.handleId,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: cfg.contentWidth || 1920,
        contentHeight: cfg.contentHeight || 1080,
      };
      this.pipController = await PiPWindow.create(config);
      this.onSysState = onSysState;
      this.onSysControl = onSysControl;
      this.pipController.on('stateChange', (s: PiPWindow.PiPState, reason: string) => {
        this.onSysState?.(s, reason);
      });
      this.pipController.on('controlEvent', (e: PiPWindow.ControlEventParam) => {
        this.onSysControl?.(this.controlTypeToEvent(e.controlType), Number(e.status));
      });
      this.pipController.setAutoStartEnabled(false);
      logger.info(`${TAG} controller created`);
      return true;
    } catch (e) {
      const be = e as BusinessError;
      logger.error(`${TAG} create failed: code=${be.code} msg=${be.message}`);
      return false;
    }
  }

  async startPiP(): Promise<boolean> {
    if (!this.pipController) return false;
    try {
      await this.pipController.startPiP();
      return true;
    } catch (e) {
      const be = e as BusinessError;
      logger.error(`${TAG} startPiP failed: ${be.code} ${be.message}`);
      return false;
    }
  }

  async stopPiP(): Promise<void> {
    if (!this.pipController) return;
    try {
      await this.pipController.stopPiP();
    } catch (e) {
      const be = e as BusinessError;
      logger.warn(`${TAG} stopPiP failed: ${be.code} ${be.message}`);
    }
  }

  updateContentSize(w: number, h: number): void {
    if (!this.pipController || w <= 0 || h <= 0) return;
    try {
      this.pipController.updateContentSize(w, h);
    } catch (e) {
      logger.warn(`${TAG} updateContentSize failed: ${e}`);
    }
  }

  updatePlayPauseStatus(isPlaying: boolean): void {
    if (!this.pipController) return;
    try {
      this.pipController.updatePiPControlStatus(
        PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        isPlaying ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE,
      );
    } catch (e) {
      logger.warn(`${TAG} updatePlayPauseStatus failed: ${e}`);
    }
  }

  setAutoStartEnabled(enabled: boolean): void {
    this.pipController?.setAutoStartEnabled(enabled);
  }

  dispose(): void {
    if (!this.pipController) return;
    try {
      this.pipController.setAutoStartEnabled(false);
      this.pipController.off('stateChange');
      this.pipController.off('controlEvent');
    } catch (_e) {}
    this.pipController = null;
    this.onSysState = null;
    this.onSysControl = null;
    logger.info(`${TAG} disposed`);
  }

  private controlTypeToEvent(t: PiPWindow.PiPControlType): PiPWindow.PiPActionEventType {
    if (t === PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE) return 'playbackStateChanged';
    if (t === PiPWindow.PiPControlType.VIDEO_NEXT) return 'nextVideo';
    if (t === PiPWindow.PiPControlType.VIDEO_PREVIOUS) return 'previousVideo';
    if (t === PiPWindow.PiPControlType.FAST_FORWARD) return 'fastForward';
    if (t === PiPWindow.PiPControlType.FAST_BACKWARD) return 'fastBackward';
    return 'playbackStateChanged';
  }
}
