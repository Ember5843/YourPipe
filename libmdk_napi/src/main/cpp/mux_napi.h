/*
 * Audio/video muxing module for OHOS napi.
 *
 * Remuxes one video file + one audio file into a single output container,
 * copying streams without re-encoding (fast, lossless). Threading/backgrounding
 * is the caller's responsibility (e.g. ArkTS TaskPool).
 */
#pragma once

#include <napi/native_api.h>

// Registers the mux functions onto `exports`. Call from the module Init.
void RegisterMuxModule(napi_env env, napi_value exports);
