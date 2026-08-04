import { SabrDecodedResponse } from '../SabrDecodedResponse';
import { SabrErrorKind } from '../SabrProtocolException';

/** Force-refresh budget for one protected/empty response (execution + policy). */
export const SABR_MAX_PO_TOKEN_REFRESHES = 2;
/** RELOAD_PLAYER budget per session (in-place resume, requestNumber kept). */
export const SABR_MAX_RELOADS_PER_SESSION = 2;
/** ROTATE_IDENTITY budget per session. */
export const SABR_MAX_ATTESTATION_IDENTITY_ROTATIONS = 3;
/** Consecutive attestation-pending no-media responses before FAIL. */
export const SABR_MAX_CONSECUTIVE_ATTESTATION_PENDING = 3;

export type SabrControlActionType = 'apply_redirect' | 'sleep_backoff' | 'apply_po_token'
  | 'recover_hole' | 'recover_policy' | 'count_policy_only' | 'retry' | 'continue' | 'fail'
  | 'reload_player' | 'rotate_identity';

/**
 * One control decision produced by the policy layer and executed by
 * YoutubeSabrSession. The session owns all side effects (URL swap, backoff
 * scheduling, PoToken mint, hole/policy recovery, throws); the policy only
 * decides. Actions are an ordered fallback chain: execute in order until one
 * handles the response (e.g. apply_po_token success stops the chain, failure
 * falls through to the next action).
 */
export class SabrControlAction {
  readonly type: SabrControlActionType;
  readonly url: string;
  readonly ms: number;
  readonly kind: SabrErrorKind;
  readonly message: string;

  private constructor(type: SabrControlActionType, url: string, ms: number,
    kind: SabrErrorKind, message: string) {
    this.type = type;
    this.url = url;
    this.ms = ms;
    this.kind = kind;
    this.message = message;
  }

  static applyRedirect(url: string): SabrControlAction {
    return new SabrControlAction('apply_redirect', url, 0, 'protocol', '');
  }

  static sleepBackoff(ms: number): SabrControlAction {
    return new SabrControlAction('sleep_backoff', '', ms, 'protocol', '');
  }

  static applyPoToken(): SabrControlAction {
    return new SabrControlAction('apply_po_token', '', 0, 'protocol', '');
  }

  static recoverHole(): SabrControlAction {
    return new SabrControlAction('recover_hole', '', 0, 'protocol', '');
  }

  static recoverPolicy(): SabrControlAction {
    return new SabrControlAction('recover_policy', '', 0, 'protocol', '');
  }

  static countPolicyOnly(): SabrControlAction {
    return new SabrControlAction('count_policy_only', '', 0, 'protocol', '');
  }

  static retry(): SabrControlAction {
    return new SabrControlAction('retry', '', 0, 'protocol', '');
  }

  static continue(): SabrControlAction {
    return new SabrControlAction('continue', '', 0, 'protocol', '');
  }

  /** reason is carried in `message` for diagnostics. */
  static reloadPlayer(reason: string): SabrControlAction {
    return new SabrControlAction('reload_player', '', 0, 'protocol', reason);
  }

  static rotateIdentity(): SabrControlAction {
    return new SabrControlAction('rotate_identity', '', 0, 'protocol', '');
  }

  static fail(kind: SabrErrorKind, message: string): SabrControlAction {
    return new SabrControlAction('fail', '', 0, kind, message);
  }
}

export type SabrPolicyPhase = 'pump' | 'fetch';

/**
 * Budget counters and per-request facts the policy may consult. The session
 * snapshots these right before evaluate(); the policy never mutates them.
 */
export interface SabrPolicyContext {
  phase: SabrPolicyPhase;
  redirectCount: number;
  poTokenRefreshes: number;
  consecutiveNoMedia: number;
  policyOnly: number;
  hasPoToken: boolean;
  hasPoTokenProvider: boolean;
  /** fetch phase only: cache key of the demanded segment, for error messages. */
  requestKey: string;
  /** fetch phase only: a hole re-advertise is possible for this request. */
  holeRecoveryAvailable: boolean;
  /** fetch phase only: a policy-only re-advertise is possible for this request. */
  policyRecoveryAvailable: boolean;
  /** RELOAD_PLAYER attempts already spent (epoch counter). */
  reloads: number;
  /** ROTATE_IDENTITY attempts already spent (session counter). */
  attestationRotations: number;
  /** Consecutive attestation-pending no-media responses seen so far. */
  consecutiveAttestationPending: number;
  /** An info reloader is wired (RELOAD_PLAYER / ROTATE_IDENTITY can re-probe). */
  hasInfoReloader: boolean;
  /** The PoToken provider can invalidate the current identity (ROTATE_IDENTITY). */
  canRotateIdentity: boolean;
}

/**
 * Pure decision layer over a decoded UMP response (PipePipe SabrSessionPolicy
 * subset). Implementations must stay side-effect free.
 */
export interface SabrSessionPolicy {
  evaluate(decoded: SabrDecodedResponse, ctx: SabrPolicyContext): SabrControlAction[];
}
