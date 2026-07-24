#include "hwdec_probe.h"

#include <hilog/log.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <mutex>
#include <string>

namespace {

constexpr unsigned int kDomain = 0xFF00;
constexpr const char* kTag = "hwdec";

struct HwCaps {
    bool probed = false;
    bool avc = false;
    bool hevc = false;
    bool vp9 = false;
    bool av1 = false;
    bool vp8 = false;
};

std::mutex gMutex;
HwCaps gCaps;

bool ProbeMimeHardware(const char* mime)
{
    if (!mime || !mime[0]) {
        return false;
    }
    OH_AVCapability* cap = OH_AVCodec_GetCapabilityByCategory(mime, false, HARDWARE);
    const bool ok = cap != nullptr;
    OH_LOG_Print(LOG_APP, LOG_INFO, kDomain, kTag,
                 "hw probe mime=%{public}s hardware=%{public}s",
                 mime, ok ? "yes" : "no");
    return ok;
}

const char* SafeMime(const char* symbol, const char* fallback)
{
    return (symbol && symbol[0]) ? symbol : fallback;
}

void EnsureProbed()
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (gCaps.probed) {
        return;
    }
    gCaps.avc = ProbeMimeHardware(SafeMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC, "video/avc"));
    gCaps.hevc = ProbeMimeHardware(SafeMime(OH_AVCODEC_MIMETYPE_VIDEO_HEVC, "video/hevc"));
    gCaps.vp9 = ProbeMimeHardware(SafeMime(OH_AVCODEC_MIMETYPE_VIDEO_VP9, "video/vp9"));
    gCaps.av1 = ProbeMimeHardware(SafeMime(OH_AVCODEC_MIMETYPE_VIDEO_AV1, "video/av01"));
    gCaps.vp8 = ProbeMimeHardware(SafeMime(OH_AVCODEC_MIMETYPE_VIDEO_VP8, "video/x-vnd.on2.vp8"));
    gCaps.probed = true;
    OH_LOG_Print(LOG_APP, LOG_INFO, kDomain, kTag,
                 "hw caps: avc=%{public}d hevc=%{public}d vp9=%{public}d av1=%{public}d vp8=%{public}d",
                 gCaps.avc ? 1 : 0, gCaps.hevc ? 1 : 0, gCaps.vp9 ? 1 : 0,
                 gCaps.av1 ? 1 : 0, gCaps.vp8 ? 1 : 0);
}

void SetBool(napi_env env, napi_value obj, const char* key, bool value)
{
    napi_value v = nullptr;
    napi_get_boolean(env, value, &v);
    napi_set_named_property(env, obj, key, v);
}

napi_value ProbeVideoHwDecoders(napi_env env, napi_callback_info /*info*/)
{
    EnsureProbed();
    HwCaps caps;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        caps = gCaps;
    }
    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetBool(env, result, "probed", caps.probed);
    SetBool(env, result, "avc", caps.avc);
    SetBool(env, result, "hevc", caps.hevc);
    SetBool(env, result, "vp9", caps.vp9);
    SetBool(env, result, "av1", caps.av1);
    SetBool(env, result, "vp8", caps.vp8);
    return result;
}

} // namespace

HwDecVideoCaps GetHwDecVideoCaps()
{
    EnsureProbed();
    std::lock_guard<std::mutex> lock(gMutex);
    return HwDecVideoCaps{gCaps.avc, gCaps.hevc, gCaps.vp9, gCaps.av1, gCaps.vp8};
}

const char* HwDecCodecsWhitelist()
{
    static const std::string kLegacyList = "h264,hevc,vp8,vp9,av1";
    static const std::string kList = [] {
        const HwDecVideoCaps caps = GetHwDecVideoCaps();
        std::string list;
        const auto add = [&list](bool ok, const char* name) {
            if (!ok) {
                return;
            }
            if (!list.empty()) {
                list += ',';
            }
            list += name;
        };
        add(caps.avc, "h264");
        add(caps.hevc, "hevc");
        add(caps.vp8, "vp8");
        add(caps.vp9, "vp9");
        add(caps.av1, "av1");
        if (list.empty()) {
            // Probe found no hardware at all: treat as probe failure and keep
            // the legacy behavior rather than disabling hwdec entirely.
            OH_LOG_Print(LOG_APP, LOG_WARN, kDomain, kTag,
                         "hw probe empty, keep legacy hwdec-codecs");
            return kLegacyList;
        }
        return list;
    }();
    return kList.c_str();
}

void RegisterHwdecProbeModule(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"probeVideoHwDecoders", nullptr, ProbeVideoHwDecoders, nullptr, nullptr, nullptr,
         napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
}
