#ifndef MDK_NAPI_HWDEC_PROBE_H
#define MDK_NAPI_HWDEC_PROBE_H

#include <napi/native_api.h>

// Query OH_AVCodec hardware decode capability for common video MIME types.
// Results are cached process-wide after the first successful probe.
// Exposes NAPI: probeVideoHwDecoders() -> { avc, hevc, vp9, av1, vp8, probed }
void RegisterHwdecProbeModule(napi_env env, napi_value exports);

#endif
