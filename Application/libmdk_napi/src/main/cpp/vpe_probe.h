#ifndef MDK_NAPI_VPE_PROBE_H
#define MDK_NAPI_VPE_PROBE_H

// One-shot capability probe for the HarmonyOS Video Processing Engine (VPE).
//
// Background: this device's Vulkan WSI (Maleoon 920C, ARM proprietary driver)
// exposes only SDR swapchain colorspaces, so true HDR cannot be presented via
// the libplacebo/Vulkan render path. The official HarmonyOS route for HDR Vivid
// / HDR10 / Dolby-Vision-mapped output is the Video Processing Engine, which
// does hardware color-space conversion and HDR metadata generation straight to
// a display native window.
//
// Before committing to a VPE integration we must confirm the vendor actually
// implements it on THIS chip. ProbeVpeCapabilities() queries
// OH_VideoProcessing_IsColorSpaceConversionSupported /
// OH_VideoProcessing_IsMetadataGenerationSupported for the conversions a player
// needs and logs the result (tag "mpv", grep "vpe probe:"). It allocates no
// processing instance and has no side effects, so it is safe to call on module
// load alongside the existing ffmpeg probe.
void ProbeVpeCapabilities();

#endif // MDK_NAPI_VPE_PROBE_H
