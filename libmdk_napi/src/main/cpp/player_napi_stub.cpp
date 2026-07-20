// x86_64 emulator stub: same NAPI surface as player_napi, no libmpv/FFmpeg.
// UI/debug on emulator only — real playback stays on arm64-v8a devices.

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <napi/native_api.h>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace {

using namespace std;

constexpr int kStatusNoMedia = 0;
constexpr int kStatusInvalid = 1 << 31;

mutex gMutex;
map<string, int> gPlayers;

string ToString(napi_env env, napi_value value)
{
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    vector<char> buffer(length + 1);
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return {buffer.data(), length};
}

napi_value Undefined(napi_env env)
{
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

napi_value MakeInt(napi_env env, int32_t v)
{
    napi_value result = nullptr;
    napi_create_int32(env, v, &result);
    return result;
}

napi_value MakeDouble(napi_env env, double v)
{
    napi_value result = nullptr;
    napi_create_double(env, v, &result);
    return result;
}

napi_value MakeString(napi_env env, const char* s)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, s ? s : "", NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value MakeEmptyArray(napi_env env)
{
    napi_value arr = nullptr;
    napi_create_array_with_length(env, 0, &arr);
    return arr;
}

napi_value MakeEmptyObject(napi_env env)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    return obj;
}

void SetNamedInt(napi_env env, napi_value obj, const char* name, int32_t v)
{
    napi_value val = MakeInt(env, v);
    napi_set_named_property(env, obj, name, val);
}

void SetNamedDouble(napi_env env, napi_value obj, const char* name, double v)
{
    napi_value val = MakeDouble(env, v);
    napi_set_named_property(env, obj, name, val);
}

void SetNamedString(napi_env env, napi_value obj, const char* name, const char* s)
{
    napi_value val = MakeString(env, s);
    napi_set_named_property(env, obj, name, val);
}

void SetNamedBool(napi_env env, napi_value obj, const char* name, bool v)
{
    napi_value val = nullptr;
    napi_get_boolean(env, v, &val);
    napi_set_named_property(env, obj, name, val);
}

void EnsurePlayerId(const string& id)
{
    if (id.empty()) {
        return;
    }
    const scoped_lock lock(gMutex);
    gPlayers[id] = 1;
}

// ---- NAPI stubs ----

napi_value EnsurePlayer(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    EnsurePlayerId(ToString(env, args[0]));
    return Undefined(env);
}

napi_value ReleasePlayer(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const string id = ToString(env, args[0]);
    const scoped_lock lock(gMutex);
    gPlayers.erase(id);
    return Undefined(env);
}

napi_value NoopPlayer(napi_env env, napi_callback_info /*info*/)
{
    return Undefined(env);
}

napi_value GetPosition(napi_env env, napi_callback_info /*info*/)
{
    return MakeDouble(env, 0);
}

napi_value Buffered(napi_env env, napi_callback_info /*info*/)
{
    return MakeDouble(env, 0);
}

napi_value GetSeekableRangesJson(napi_env env, napi_callback_info /*info*/)
{
    return MakeString(env, "[]");
}

napi_value GetState(napi_env env, napi_callback_info /*info*/)
{
    return MakeInt(env, 0); // Stopped
}

napi_value GetMediaStatus(napi_env env, napi_callback_info /*info*/)
{
    return MakeInt(env, kStatusNoMedia | kStatusInvalid);
}

napi_value GetDuration(napi_env env, napi_callback_info /*info*/)
{
    return MakeDouble(env, 0);
}

napi_value IsPlaying(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_get_boolean(env, false, &result);
    return result;
}

napi_value GetProperty(napi_env env, napi_callback_info /*info*/)
{
    return MakeString(env, "");
}

napi_value GetMediaInfo(napi_env env, napi_callback_info /*info*/)
{
    napi_value info = MakeEmptyObject(env);
    SetNamedDouble(env, info, "startTime", 0);
    SetNamedDouble(env, info, "duration", 0);
    SetNamedDouble(env, info, "bitRate", 0);
    SetNamedString(env, info, "format", "stub");
    SetNamedInt(env, info, "streams", 0);
    napi_set_named_property(env, info, "metadata", MakeEmptyObject(env));
    napi_set_named_property(env, info, "audio", MakeEmptyArray(env));
    napi_set_named_property(env, info, "video", MakeEmptyArray(env));
    napi_set_named_property(env, info, "subtitle", MakeEmptyArray(env));
    return info;
}

napi_value Version(napi_env env, napi_callback_info /*info*/)
{
    return MakeInt(env, 0);
}

napi_value FfmpegVersion(napi_env env, napi_callback_info /*info*/)
{
    return MakeString(env, "stub-x86_64");
}

napi_value GetGlobalOptionString(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_get_null(env, &result);
    return result;
}

napi_value GetGlobalOptionInt(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_get_null(env, &result);
    return result;
}

napi_value MuxAudioVideo(napi_env env, napi_callback_info /*info*/)
{
    napi_throw_error(env, nullptr, "muxAudioVideo is unavailable on x86_64 stub (emulator UI only)");
    return Undefined(env);
}

napi_value ProbeVideoHwDecoders(napi_env env, napi_callback_info /*info*/)
{
    napi_value obj = MakeEmptyObject(env);
    SetNamedBool(env, obj, "probed", true);
    SetNamedBool(env, obj, "avc", false);
    SetNamedBool(env, obj, "hevc", false);
    SetNamedBool(env, obj, "vp9", false);
    SetNamedBool(env, obj, "av1", false);
    SetNamedBool(env, obj, "vp8", false);
    return obj;
}

napi_value Init(napi_env env, napi_value exports)
{
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "mpv",
                 "libmdk_napi x86_64 STUB loaded — UI/debug only, no real playback");

    bool hasXComponent = false;
    if (napi_has_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &hasXComponent) == napi_ok && hasXComponent) {
        // No surface callbacks needed for stub.
    }

    napi_property_descriptor descriptors[] = {
        {"ensurePlayer", nullptr, EnsurePlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releasePlayer", nullptr, ReleasePlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMedia", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMediaSource", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"play", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pause", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"prepare", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"seek", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"seekWithFlags", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPlaybackRate", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVolume", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setLoop", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setProperty", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getProperty", nullptr, GetProperty, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setColorSpace", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVideoEffect", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setDecoders", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setActiveTracks", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setAudioBackends", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPosition", nullptr, GetPosition, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buffered", nullptr, Buffered, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSeekableRangesJson", nullptr, GetSeekableRangesJson, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getState", nullptr, GetState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMediaStatus", nullptr, GetMediaStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMediaInfo", nullptr, GetMediaInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isPlaying", nullptr, IsPlaying, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVideoSurfaceSize", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVideoSurfaceId", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"ffmpegVersion", nullptr, FfmpegVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setGlobalOptionString", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getGlobalOptionString", nullptr, GetGlobalOptionString, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setGlobalOptionInt", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getGlobalOptionInt", nullptr, GetGlobalOptionInt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setGlobalOptionFloat", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setResourceManager", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDuration", nullptr, GetDuration, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEventCallback", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"command", nullptr, NoopPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"muxAudioVideo", nullptr, MuxAudioVideo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeVideoHwDecoders", nullptr, ProbeVideoHwDecoders, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

NAPI_MODULE(mdk_napi, Init)

} // namespace
