import { Logger } from 'mediaservice';
import { PlaybackConfig } from './PlaybackConfig';
import { PlayerSession } from './PlayerSession';

const TAG = '[PlayerPresentation]';

/**
 * Presentation mode for video on/off (separate from PlayerState).
 *
 * PAGE / OVERLAY / PIP → video always ON
 * BACKGROUND → may turn video OFF after delay (backgroundAudioOnly)
 *
 * Never arms video-off from page hide alone. Never touches load/seek.
 */
export enum PresentationMode {
  PAGE = 'page',
  OVERLAY = 'overlay',
  PIP = 'pip',
  BACKGROUND = 'background',
}

export class PlayerPresentation {
  private static mode: PresentationMode = PresentationMode.PAGE;
  private static overlayHold: number = 0;
  private static offTimerId: number = -1;

  static getMode(): PresentationMode {
    return PlayerPresentation.mode;
  }

  static onAbilityForeground(): void {
    AppStorage.setOrCreate('isAppBackground', false);
    PlayerPresentation.overlayHold = 0;
    PlayerPresentation.enter(PresentationMode.PAGE, 'ability-fg');
  }

  static onAbilityBackground(): void {
    AppStorage.setOrCreate('isAppBackground', true);
    if (AppStorage.get<boolean>('isPiPActive') === true) {
      PlayerPresentation.enter(PresentationMode.PIP, 'ability-bg-pip');
      return;
    }
    if (PlayerPresentation.overlayHold > 0) {
      PlayerPresentation.enter(PresentationMode.OVERLAY, 'ability-bg-overlay');
      return;
    }
    PlayerPresentation.enter(PresentationMode.BACKGROUND, 'ability-bg');
  }

  static onPipStarted(): void {
    PlayerPresentation.overlayHold = 0;
    PlayerPresentation.enter(PresentationMode.PIP, 'pip-started');
  }

  static onPipStopped(restoredToPage: boolean): void {
    if (restoredToPage || AppStorage.get<boolean>('isAppBackground') !== true) {
      PlayerPresentation.enter(PresentationMode.PAGE, 'pip-stop-page');
    } else {
      PlayerPresentation.enter(PresentationMode.BACKGROUND, 'pip-stop-bg');
    }
  }

  /** Before share / cast sheet (may fire ability onBackground). */
  static beginOverlay(reason: string): void {
    PlayerPresentation.overlayHold++;
    Logger.info(TAG, `beginOverlay hold=${PlayerPresentation.overlayHold} (${reason})`);
    PlayerPresentation.cancelOffTimer();
    PlayerPresentation.mode = PresentationMode.OVERLAY;
    PlayerPresentation.ensureVideoOn(`overlay:${reason}`);
  }

  static endOverlay(reason: string): void {
    if (PlayerPresentation.overlayHold > 0) {
      PlayerPresentation.overlayHold--;
    }
    Logger.info(TAG, `endOverlay hold=${PlayerPresentation.overlayHold} (${reason})`);
    if (PlayerPresentation.overlayHold > 0) return;
    if (AppStorage.get<boolean>('isPiPActive') === true) {
      PlayerPresentation.enter(PresentationMode.PIP, 'end-overlay-pip');
    } else if (AppStorage.get<boolean>('isAppBackground') === true) {
      PlayerPresentation.enter(PresentationMode.BACKGROUND, 'end-overlay-bg');
    } else {
      PlayerPresentation.enter(PresentationMode.PAGE, 'end-overlay-page');
    }
  }

  /** Page show/hide: never schedule off; only re-sync video ON when foreground. */
  static onPlayerPageVisibility(visible: boolean): void {
    if (!visible) return;
    if (AppStorage.get<boolean>('isAppBackground') === true) return;
    if (AppStorage.get<boolean>('isPiPActive') === true) return;
    PlayerPresentation.cancelOffTimer();
    if (PlayerPresentation.mode !== PresentationMode.OVERLAY) {
      PlayerPresentation.mode = PresentationMode.PAGE;
    }
    PlayerPresentation.ensureVideoOn('page-visible-fg');
  }

  private static enter(next: PresentationMode, reason: string): void {
    const prev = PlayerPresentation.mode;
    PlayerPresentation.mode = next;
    Logger.info(TAG, `mode ${prev} → ${next} (${reason})`);
    switch (next) {
      case PresentationMode.PAGE:
      case PresentationMode.OVERLAY:
      case PresentationMode.PIP:
        PlayerPresentation.cancelOffTimer();
        PlayerPresentation.ensureVideoOn(reason);
        break;
      case PresentationMode.BACKGROUND:
        PlayerPresentation.armBackgroundVideoOff();
        break;
    }
  }

  private static armBackgroundVideoOff(): void {
    const pb = AppStorage.get<PlaybackConfig>('playbackConfig') ?? new PlaybackConfig();
    if (!pb.backgroundAudioOnly) {
      Logger.info(TAG, 'background: audio-only disabled');
      return;
    }
    if (AppStorage.get<boolean>('isPiPActive') === true || PlayerPresentation.overlayHold > 0) {
      return;
    }
    PlayerPresentation.cancelOffTimer();
    const delaySec = parseInt(pb.backgroundVideoOffDelaySec, 10);
    const ms = Math.max(0, Math.floor((isNaN(delaySec) ? 15 : delaySec) * 1000));
    if (ms <= 0) {
      PlayerPresentation.applyBackgroundVideoOff();
      return;
    }
    Logger.info(TAG, `background: schedule video-off in ${ms}ms`);
    PlayerPresentation.offTimerId = setTimeout(() => {
      PlayerPresentation.offTimerId = -1;
      PlayerPresentation.applyBackgroundVideoOff();
    }, ms) as number;
  }

  private static applyBackgroundVideoOff(): void {
    if (PlayerPresentation.mode !== PresentationMode.BACKGROUND) return;
    if (AppStorage.get<boolean>('isAppBackground') !== true) return;
    if (AppStorage.get<boolean>('isPiPActive') === true || PlayerPresentation.overlayHold > 0) return;
    try {
      PlayerSession.getInstance().controller.setVideoOutputEnabled(false);
      Logger.info(TAG, 'video OFF (BACKGROUND audio-only)');
    } catch (_e) {
      // no session
    }
  }

  private static cancelOffTimer(): void {
    if (PlayerPresentation.offTimerId >= 0) {
      clearTimeout(PlayerPresentation.offTimerId);
      PlayerPresentation.offTimerId = -1;
    }
  }

  private static ensureVideoOn(reason: string): void {
    try {
      PlayerSession.getInstance().controller.setVideoOutputEnabled(true);
      Logger.info(TAG, `video ON (${reason})`);
    } catch (_e) {
      // no session
    }
  }
}
