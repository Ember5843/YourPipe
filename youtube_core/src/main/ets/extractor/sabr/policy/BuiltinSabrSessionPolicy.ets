import { SabrDecodedResponse } from '../SabrDecodedResponse';
import {
  SABR_MAX_ATTESTATION_IDENTITY_ROTATIONS,
  SABR_MAX_CONSECUTIVE_ATTESTATION_PENDING,
  SABR_MAX_PO_TOKEN_REFRESHES,
  SABR_MAX_RELOADS_PER_SESSION,
  SabrControlAction,
  SabrPolicyContext,
  SabrSessionPolicy
} from './SabrSessionPolicy';

const MAX_REDIRECTS = 3;
/** Shared budget for policy-only responses and consecutive empty responses. */
const MAX_POLICY_ONLY_RESPONSES = 3;

/**
 * Default decision set (PipePipe BuiltinSabrSessionPolicy subset).
 * Protection state machine for no-media responses:
 *   status>=3 (required) → FAIL(attestation_required) immediately;
 *   status==2 (pending)  → ROTATE_IDENTITY → APPLY_PO_TOKEN → RELOAD_PLAYER
 *     (only once the PoToken refresh budget is spent) → FAIL(protection),
 *     with a hard FAIL(protection) after 3 consecutive pending responses;
 *   reloadRequested      → RELOAD_PLAYER → FAIL(reload_exhausted).
 * Every fallthrough means the previous action was unavailable or failed.
 */
export class BuiltinSabrSessionPolicy implements SabrSessionPolicy {
  evaluate(decoded: SabrDecodedResponse, ctx: SabrPolicyContext): SabrControlAction[] {
    return ctx.phase === 'pump' ? this.evaluatePump(decoded, ctx) : this.evaluateFetch(decoded, ctx);
  }

  /** Decisions for one POST response inside pumpOnceLocked. */
  private evaluatePump(decoded: SabrDecodedResponse, ctx: SabrPolicyContext): SabrControlAction[] {
    const actions: SabrControlAction[] = [];
    if (decoded.redirectUrl && decoded.redirectUrl.length > 0) {
      if (ctx.redirectCount >= MAX_REDIRECTS) {
        actions.push(SabrControlAction.fail('redirect',
          `SABR too many redirects: ${decoded.redirectUrl}`));
        return actions;
      }
      actions.push(SabrControlAction.applyRedirect(decoded.redirectUrl));
    }
    if (decoded.segments.length > 0) {
      actions.push(SabrControlAction.continue());
      return actions;
    }
    // Empty response without a PoToken usually means "come back with a PoToken"
    // (authenticated sessions hit this on rn=1 with a multi-second backoff).
    // Mint immediately instead of waiting out the backoff empty-handed; if the
    // mint fails the chain falls through to the scheduled backoff.
    if (!ctx.hasPoToken && ctx.hasPoTokenProvider) {
      actions.push(SabrControlAction.applyPoToken());
    }
    actions.push(SabrControlAction.sleepBackoff(decoded.backoffTimeMs));
    return actions;
  }

  /** Decisions for one pumped response while fetching a demanded segment. */
  private evaluateFetch(decoded: SabrDecodedResponse, ctx: SabrPolicyContext): SabrControlAction[] {
    if (decoded.sabrError) {
      return [SabrControlAction.fail('protocol',
        `SABR error while fetching ${ctx.requestKey}: ${decoded.sabrError}`)];
    }
    if (decoded.reloadRequested) {
      const actions: SabrControlAction[] = [];
      if (ctx.hasInfoReloader && ctx.reloads < SABR_MAX_RELOADS_PER_SESSION) {
        actions.push(SabrControlAction.reloadPlayer('reload_requested'));
      }
      actions.push(SabrControlAction.fail('reload_exhausted',
        `SABR reload requested, reload budget exhausted: ${decoded.summarizeNoMediaResponse()}`));
      return actions;
    }
    if (ctx.holeRecoveryAvailable) {
      return [SabrControlAction.recoverHole()];
    }
    if (decoded.isNoMediaResponse() && decoded.isAttestationRequired()) {
      return [SabrControlAction.fail('attestation_required',
        `SABR attestation required: ${decoded.summarizeNoMediaResponse()}`)];
    }
    if (decoded.isNoMediaResponse() && decoded.isAttestationPending()) {
      if (ctx.consecutiveAttestationPending >= SABR_MAX_CONSECUTIVE_ATTESTATION_PENDING) {
        return [SabrControlAction.fail('protection',
          `SABR attestation pending budget exhausted: ${decoded.summarizeNoMediaResponse()}`)];
      }
      const actions: SabrControlAction[] = [];
      if (ctx.canRotateIdentity && ctx.hasInfoReloader
        && ctx.attestationRotations < SABR_MAX_ATTESTATION_IDENTITY_ROTATIONS) {
        actions.push(SabrControlAction.rotateIdentity());
      }
      actions.push(SabrControlAction.applyPoToken());
      if (ctx.hasInfoReloader && ctx.reloads < SABR_MAX_RELOADS_PER_SESSION
        && ctx.poTokenRefreshes >= SABR_MAX_PO_TOKEN_REFRESHES) {
        actions.push(SabrControlAction.reloadPlayer('protected_no_media'));
      }
      actions.push(SabrControlAction.fail('protection',
        `SABR protected no-media: ${decoded.summarizeNoMediaResponse()}`));
      return actions;
    }
    if (decoded.isPolicyOnlyResponse()) {
      if (ctx.policyOnly + 1 >= MAX_POLICY_ONLY_RESPONSES) {
        if (ctx.policyRecoveryAvailable) {
          return [SabrControlAction.recoverPolicy()];
        }
        return [SabrControlAction.fail('no_media',
          `SABR repeated policy-only responses: ${decoded.summarizeNoMediaResponse()}`)];
      }
      return [SabrControlAction.countPolicyOnly()];
    }
    if (ctx.consecutiveNoMedia >= MAX_POLICY_ONLY_RESPONSES && decoded.isNoMediaResponse()) {
      return [SabrControlAction.fail('no_media',
        `SABR repeated no-media: ${decoded.summarizeNoMediaResponse()}`)];
    }
    return [SabrControlAction.continue()];
  }
}
