/**
 * Typed SABR failure category. Replaces string matching on error messages:
 * transient retry / stall decisions must key off `kind`, not the text.
 */
export type SabrErrorKind = 'protection' | 'reload_exhausted' | 'attestation_required'
  | 'no_media' | 'redirect' | 'closed' | 'protocol'
  | 'beyond_end' | 'segment_unavailable';

export class SabrProtocolException extends Error {
  readonly kind: SabrErrorKind;

  constructor(message: string, kind: SabrErrorKind = 'protocol') {
    super(message);
    this.name = 'SabrProtocolException';
    this.kind = kind;
  }
}
