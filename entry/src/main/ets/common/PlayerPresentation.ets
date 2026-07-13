import { Logger } from 'mediaservice';
import { PlaybackConfig } from './PlaybackConfig';
import { PlayerSession } from './PlayerSession';

const TAG = '[PlayerPresentation]';

/**
 * Presentation mode for video on/off (separate from PlayerState).
 *
 * PAGE / OVERLAY / PIP → video ON unless session audio-only
 * BACKGROUND → may turn video OFF after delay (backgroundAudioOnly)
 * Session audio-only → video always OFF (even on PAGE / ability FG)
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
    PlayerPresentation.syncVideoForMode(`overlay:${reason}`);
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

  /** Page show/hide: never schedule off; only re-sync video when foreground. */
  static onPlayerPageVisibility(visible: boolean): void {
    if (!visible) return;
    if (AppStorage.get<boolean>('isAppBackground') === true) return;
    if (AppStorage.get<boolean>('isPiPActive') === true) return;
    PlayerPresentation.cancelOffTimer();
    if (PlayerPresentation.mode !== PresentationMode.OVERLAY) {
      PlayerPresentation.mode = PresentationMode.PAGE;
    }
    PlayerPresentation.syncVideoForMode('page-visible-fg');
  }

  /** Session audio-only toggled while staying in current presentation mode. */
  static onAudioOnlyModeChanged(enabled: boolean): void {
    Logger.info(TAG, `onAudioOnlyModeChanged=${enabled} mode=${PlayerPresentation.mode}`);
    if (enabled) {
      PlayerPresentation.cancelOffTimer();
      PlayerPresentation.applyVideoOff('session-audio-only');
      return;
    }
    // Leaving audio-only: re-apply mode policy (PAGE/PIP/OVERLAY → on; BACKGROUND → arm delay).
    PlayerPresentation.syncVideoForMode('session-audio-only-off');
    if (PlayerPresentation.mode === PresentationMode.BACKGROUND) {
      PlayerPresentation.armBackgroundVideoOff();
    }
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
        PlayerPresentation.syncVideoForMode(reason);
        break;
      case PresentationMode.BACKGROUND:
        PlayerPresentation.armBackgroundVideoOff();
        break;
    }
  }

  private static armBackgroundVideoOff(): void {
    // Session audio-only already keeps video off; no need to schedule.
    if (PlayerSession.getInstance().isAudioOnlyMode) {
      PlayerPresentation.applyVideoOff('background-session-audio-only');
      return;
    }
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
    PlayerPresentation.applyVideoOff('BACKGROUND audio-only');
  }

  private static cancelOffTimer(): void {
    if (PlayerPresentation.offTimerId >= 0) {
      clearTimeout(PlayerPresentation.offTimerId);
      PlayerPresentation.offTimerId = -1;
    }
  }

  /** PAGE / OVERLAY / PIP want video ON unless session audio-only. */
  private static syncVideoForMode(reason: string): void {
    if (PlayerSession.getInstance().isAudioOnlyMode) {
      PlayerPresentation.applyVideoOff(`audio-only:${reason}`);
      return;
    }
    PlayerPresentation.ensureVideoOn(reason);
  }

  private static applyVideoOff(reason: string): void {
    try {
      PlayerSession.getInstance().controller.setVideoOutputEnabled(false);
      Logger.info(TAG, `video OFF (${reason})`);
    } catch (_e) {
      // no session
    }
  }

  private static ensureVideoOn(reason: string): void {
    if (PlayerSession.getInstance().isAudioOnlyMode) {
      Logger.info(TAG, `skip video ON (audio-only) (${reason})`);
      return;
    }
    try {
      PlayerSession.getInstance().controller.setVideoOutputEnabled(true);
      Logger.info(TAG, `video ON (${reason})`);
    } catch (_e) {
      // no session
    }
  }
}
