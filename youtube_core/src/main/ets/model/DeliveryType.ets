/**
 * Delivery method enumeration
 * Ported from org.schabi.newpipe.extractor.stream.DeliveryMethod
 */
export enum DeliveryMethod {
  PROGRESSIVE_HTTP = 'PROGRESSIVE_HTTP',
  DASH = 'DASH',
  HLS = 'HLS',
  /** YouTube Server ABR session (PipePipe). Media via SABR POST, not progressive URL. */
  SABR = 'SABR'
}
