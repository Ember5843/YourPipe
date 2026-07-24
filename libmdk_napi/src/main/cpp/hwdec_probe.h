#ifndef MDK_NAPI_HWDEC_PROBE_H
#define MDK_NAPI_HWDEC_PROBE_H

#include <napi/native_api.h>

// Query OH_AVCodec hardware decode capability for common video MIME types.
// Results are cached process-wide after the first successful probe.
// Exposes NAPI: probeVideoHwDecoders() -> { avc, hevc, vp9, av1, vp8, probed }
void RegisterHwdecProbeModule(napi_env env, napi_value exports);

struct HwDecVideoCaps {
    bool avc;
    bool hevc;
    bool vp9;
    bool av1;
    bool vp8;
};

// Native-side accessor for the same cached probe results (probes on first
// call). Used by EnsureMpv to restrict hwdec-codecs to codecs with an actual
// hardware decoder on this device.
HwDecVideoCaps GetHwDecVideoCaps();

// hwdec-codecs whitelist derived from the probed caps, in the legacy
// "h264,hevc,vp8,vp9,av1" order. Falls back to the full legacy list when the
// probe reports no hardware at all (probe failure must not disable hwdec).
const char* HwDecCodecsWhitelist();

#endif
