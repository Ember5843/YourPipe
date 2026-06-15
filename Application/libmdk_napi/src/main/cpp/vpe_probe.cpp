#include "vpe_probe.h"

#include <hilog/log.h>
#include <multimedia/video_processing_engine/video_processing.h>
#include <multimedia/video_processing_engine/video_processing_types.h>
#include <native_buffer/buffer_common.h>

namespace {

constexpr unsigned int kDomain = 0xFF00;
constexpr const char* kTag = "mpv";

#define VPE_LOG(fmt, ...) \
    OH_LOG_Print(LOG_APP, LOG_INFO, kDomain, kTag, "vpe probe: " fmt, ##__VA_ARGS__)

// A color-space descriptor as VPE wants it: (metadataType, colorSpace, pixelFmt).
struct CsDesc {
    const char* name;
    int32_t metadataType;   // OH_NativeBuffer_MetadataType
    int32_t colorSpace;     // OH_NativeBuffer_ColorSpace
    int32_t pixelFormat;    // OH_NativeBuffer_Format
};

VideoProcessing_ColorSpaceInfo MakeInfo(const CsDesc& d)
{
    return VideoProcessing_ColorSpaceInfo{
        .metadataType = d.metadataType,
        .colorSpace = d.colorSpace,
        .pixelFormat = d.pixelFormat,
    };
}

void QueryConversion(const CsDesc& src, const CsDesc& dst)
{
    VideoProcessing_ColorSpaceInfo s = MakeInfo(src);
    VideoProcessing_ColorSpaceInfo d = MakeInfo(dst);
    bool ok = OH_VideoProcessing_IsColorSpaceConversionSupported(&s, &d);
    VPE_LOG("  csc %-18s -> %-18s : %{public}s", src.name, dst.name,
            ok ? "SUPPORTED" : "no");
}

void QueryMetadataGen(const CsDesc& src)
{
    VideoProcessing_ColorSpaceInfo s = MakeInfo(src);
    bool ok = OH_VideoProcessing_IsMetadataGenerationSupported(&s);
    VPE_LOG("  meta-gen %-18s : %{public}s", src.name, ok ? "SUPPORTED" : "no");
}

// Common source/destination descriptors. 10-bit semi-planar (P010) is what a
// HDR HEVC/AV1/VP9 decoder produces; NV12 (8-bit) is the typical SDR target.
const CsDesc kHdr10_PQ_2020{
    "HDR10/PQ-2020", OH_VIDEO_HDR_HDR10, OH_COLORSPACE_BT2020_PQ_LIMIT,
    NATIVEBUFFER_PIXEL_FMT_YCBCR_P010};
const CsDesc kHlg_2020{
    "HLG-2020", OH_VIDEO_HDR_HLG, OH_COLORSPACE_BT2020_HLG_LIMIT,
    NATIVEBUFFER_PIXEL_FMT_YCBCR_P010};
const CsDesc kVivid_PQ{
    "VIVID/PQ-2020", OH_VIDEO_HDR_VIVID, OH_COLORSPACE_BT2020_PQ_LIMIT,
    NATIVEBUFFER_PIXEL_FMT_YCBCR_P010};
const CsDesc kVivid_HLG{
    "VIVID/HLG-2020", OH_VIDEO_HDR_VIVID, OH_COLORSPACE_BT2020_HLG_LIMIT,
    NATIVEBUFFER_PIXEL_FMT_YCBCR_P010};
const CsDesc kSdr_709{
    "SDR/709", OH_VIDEO_NONE, OH_COLORSPACE_BT709_LIMIT,
    NATIVEBUFFER_PIXEL_FMT_YCBCR_420_SP};
const CsDesc kSdr_P3{
    "SDR/P3", OH_VIDEO_NONE, OH_COLORSPACE_P3_FULL,
    NATIVEBUFFER_PIXEL_FMT_YCBCR_420_SP};

} // namespace

void ProbeVpeCapabilities()
{
    // Initializing the global environment is optional for the IsSupported
    // queries, but it forces the VPE shared library to actually load. If the
    // library or its vendor backend is missing, this returns non-success and we
    // can report "VPE unavailable" instead of crashing later.
    VideoProcessing_ErrorCode init = OH_VideoProcessing_InitializeEnvironment();
    if (init != VIDEO_PROCESSING_SUCCESS) {
        VPE_LOG("OH_VideoProcessing_InitializeEnvironment failed (%{public}d) "
                "-> VPE unavailable on this device",
                static_cast<int>(init));
        return;
    }

    VPE_LOG("VPE environment initialized; querying capabilities");

    // HDR -> SDR tone-mapping (what we'd use if the panel/display is SDR).
    QueryConversion(kHdr10_PQ_2020, kSdr_709);
    QueryConversion(kHlg_2020, kSdr_709);
    QueryConversion(kVivid_PQ, kSdr_709);
    QueryConversion(kVivid_PQ, kSdr_P3);

    // HDR -> HDR (passthrough/normalize, what we'd use to present true HDR).
    QueryConversion(kHdr10_PQ_2020, kHdr10_PQ_2020);
    QueryConversion(kVivid_PQ, kHdr10_PQ_2020);
    QueryConversion(kHlg_2020, kHlg_2020);

    // SDR -> HDR inverse tone-mapping (less important, but informative).
    QueryConversion(kSdr_709, kHdr10_PQ_2020);

    // HDR Vivid dynamic metadata generation (vendor feature).
    QueryMetadataGen(kHdr10_PQ_2020);
    QueryMetadataGen(kHlg_2020);
    QueryMetadataGen(kSdr_709);

    OH_VideoProcessing_DeinitializeEnvironment();
    VPE_LOG("done");
}
