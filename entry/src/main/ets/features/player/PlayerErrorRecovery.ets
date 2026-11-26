import { AuthAccountStatus, AuthSessionManager, AuthStage, YoutubePlayerClientConfig } from 'youtube_core';
import { ActionHub } from '../../common/ActionHub';
import { AuthStateHelper } from '../../common/AuthStateHelper';
import { SabrWebViewPoTokenProvider } from './SabrWebViewPoTokenProvider';
import { YoutubeJavaScriptPlayerManager } from 'youtube_core';

export type ErrorRecoveryActionKind =
  'none'
  | 'open_sign_in'
  | 'enable_playback_auth_and_retry'
  | 'open_account_settings'
  | 'open_endpoint_settings'
  | 'open_network_settings';

export interface ErrorRecoveryPlan {
  /** Override hint tailored to the user's exact auth/toggle state, or undefined to use ErrorInfo.actionHint. */
  dynamicHint?: Resource;
  actionKind: ErrorRecoveryActionKind;
  actionLabel?: Resource;
  actionIcon?: Resource;
}

function hasStoredCredential(status: AuthAccountStatus): boolean {
  return status.hasCredential
    || status.hasCookieCredential
    || status.hasRefreshToken
    || status.stage === AuthStage.SIGNED_IN;
}

/**
 * Maps (errorCode × live AuthAccountStatus) to an actionable recovery button and
 * state-aware explanation so users never get stuck on a dead-end error screen.
 */
export function buildErrorRecoveryPlan(
  errorCode: string,
  authStatus: AuthAccountStatus
): ErrorRecoveryPlan {
  const code = (errorCode || '').toUpperCase();
  const hasCred = hasStoredCredential(authStatus);
  const authActive = hasCred && authStatus.authEnabled !== false;
  const playbackAuthOn = authActive && authStatus.useAuthForPlayback !== false;

  if (code === 'BOT_CHECK' || code === 'LOGIN_REQUIRED' || code === 'AGE_RESTRICTED') {
    if (!hasCred) {
      return {
        actionKind: 'open_sign_in',
        actionLabel: $r('app.string.yt_error_action_sign_in'),
        actionIcon: $r('sys.symbol.person_crop_circle_fill')
      };
    }
    if (!authActive) {
      return {
        dynamicHint: $r('app.string.yt_error_hint_incognito_off'),
        actionKind: 'enable_playback_auth_and_retry',
        actionLabel: $r('app.string.yt_error_action_enable_auth_retry'),
        actionIcon: $r('sys.symbol.checkmark_circle')
      };
    }
    if (!playbackAuthOn) {
      return {
        dynamicHint: $r('app.string.yt_error_hint_playback_auth_off'),
        actionKind: 'enable_playback_auth_and_retry',
        actionLabel: $r('app.string.yt_error_action_enable_auth_retry'),
        actionIcon: $r('sys.symbol.checkmark_circle')
      };
    }
    return {
      dynamicHint: $r('app.string.yt_error_hint_auth_already_on'),
      actionKind: 'open_account_settings',
      actionLabel: $r('app.string.yt_error_action_account_settings'),
      actionIcon: $r('sys.symbol.person_crop_circle_fill')
    };
  }

  if (code === 'NETWORK_ERROR' || code === 'TIMEOUT') {
    return {
      actionKind: 'open_network_settings',
      actionLabel: $r('app.string.yt_error_action_network_settings'),
      actionIcon: $r('sys.symbol.wifi')
    };
  }

  if (code === 'NO_STREAMS' || code === 'NO_PLAYABLE_URL' || code === 'EXTRACT_FAILED'
    || code === 'PLAYBACK_FAILED') {
    return {
      actionKind: 'open_endpoint_settings',
      actionLabel: $r('app.string.yt_error_action_endpoint_settings'),
      actionIcon: $r('sys.symbol.slider_horizontal_2')
    };
  }

  return { actionKind: 'none' };
}

/** Captures a lightweight snapshot of auth + active endpoint to detect changes after closing OptionsSheet. */
export function snapshotPlaybackAuthAndEndpoint(): string {
  const session = AuthSessionManager.getInstance();
  const rev = session?.getCredentialRevision() ?? 0;
  const playAuth = session?.isAuthEnabledForPlayback() === true ? '1' : '0';
  const client = YoutubePlayerClientConfig.getYoutubePlayerClient();
  return `${rev}|${playAuth}|${client}`;
}

export function executeErrorRecoveryAction(
  kind: ErrorRecoveryActionKind,
  actionHub: ActionHub,
  onRetryNow: () => void
): void {
  const session = AuthSessionManager.getInstance();
  switch (kind) {
    case 'open_sign_in':
      actionHub.openOptionsTarget('data_account', 'login_entry');
      break;
    case 'enable_playback_auth_and_retry':
      if (session) {
        session.setAuthEnabled(true);
        session.setUseAuthForPlayback(true);
        AuthStateHelper.refresh();
        AuthStateHelper.reconcilePlaybackClient();
        YoutubeJavaScriptPlayerManager.resetSessionVisitorData();
        SabrWebViewPoTokenProvider.getInstance().resetForAuthChange();
      }
      onRetryNow();
      break;
    case 'open_account_settings':
      actionHub.openOptionsTarget('data_account', 'playback_auth');
      break;
    case 'open_endpoint_settings':
      actionHub.openOptionsTarget('playback', 'endpoint_section');
      break;
    case 'open_network_settings':
      actionHub.openOptionsTarget('network');
      break;
    default:
      break;
  }
}
