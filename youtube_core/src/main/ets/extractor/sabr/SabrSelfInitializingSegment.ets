/**
 * Post-live SABR has no separate initialization segment: every media segment
 * starts with its own `ftyp` + `moov` box pair followed by the `emsg`/`moof`/`mdat`
 * media fragment (PipePipe SabrSelfInitializingSegment parity).
 */
export interface SelfInitSegmentSplit {
  initBytes: Uint8Array;
  mediaBytes: Uint8Array;
}

/**
 * Return the byte end offset of a leading `ftyp` + `moov` pair, or -1 if the
 * buffer does not start with a valid self-initializing MP4 prefix.
 */
export function findSelfInitSegmentEnd(data: Uint8Array): number {
  let offset = 0;
  while (offset + 8 <= data.length) {
    const size = ((data[offset] * 0x1000000)
      + ((data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3]));
    const type = String.fromCharCode(
      data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7]);
    if (size < 8 || size > data.length - offset || (offset === 0 && type !== 'ftyp')) {
      return -1;
    }
    offset += size;
    if (type === 'moov') {
      return offset;
    }
  }
  return -1;
}

/**
 * Split a self-initializing post-live segment into `{ initBytes, mediaBytes }`,
 * or return undefined when the payload has no separate media tail after `moov`.
 */
export function splitSelfInitializingSegment(data: Uint8Array): SelfInitSegmentSplit | undefined {
  const end = findSelfInitSegmentEnd(data);
  if (end <= 0 || end >= data.length) {
    return undefined;
  }
  return {
    initBytes: data.subarray(0, end),
    mediaBytes: data.subarray(end)
  };
}
