#include "media_info_napi.h"

#include <cstdint>
#include <cstdlib>
#include <string>

namespace {

napi_value NewObject(napi_env env)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    return result;
}

void SetNamed(napi_env env, napi_value object, const char* name, napi_value value)
{
    napi_set_named_property(env, object, name, value);
}

void SetNamedInt32(napi_env env, napi_value object, const char* name, int32_t value)
{
    napi_value napiValue = nullptr;
    napi_create_int32(env, value, &napiValue);
    SetNamed(env, object, name, napiValue);
}

void SetNamedInt64(napi_env env, napi_value object, const char* name, int64_t value)
{
    napi_value napiValue = nullptr;
    napi_create_int64(env, value, &napiValue);
    SetNamed(env, object, name, napiValue);
}

void SetNamedDouble(napi_env env, napi_value object, const char* name, double value)
{
    napi_value napiValue = nullptr;
    napi_create_double(env, value, &napiValue);
    SetNamed(env, object, name, napiValue);
}

void SetNamedString(napi_env env, napi_value object, const char* name, const std::string& value)
{
    napi_value napiValue = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &napiValue);
    SetNamed(env, object, name, napiValue);
}

void SetNamedEmptyArray(napi_env env, napi_value object, const char* name)
{
    napi_value array = nullptr;
    napi_create_array_with_length(env, 0, &array);
    SetNamed(env, object, name, array);
}

// Parse helpers: mpv returns properties as strings via get_property_string.
int64_t ToInt(const std::string& s)
{
    if (s.empty()) return 0;
    return strtoll(s.c_str(), nullptr, 10);
}

double ToDouble(const std::string& s)
{
    if (s.empty()) return 0.0;
    return strtod(s.c_str(), nullptr);
}

// Build the single-element video[] array from the current track's properties.
// mpv exposes one "current track" per type via these top-level properties.
napi_value BuildVideoArray(napi_env env, const MpvPropReader& prop)
{
    std::string codec = prop("video-codec");
    int64_t w = ToInt(prop("width"));
    int64_t h = ToInt(prop("height"));
    if (codec.empty() && w == 0 && h == 0) {
        napi_value empty = nullptr;
        napi_create_array_with_length(env, 0, &empty);
        return empty;
    }
    napi_value cp = NewObject(env);
    SetNamedString(env, cp, "codec", codec);
    SetNamedString(env, cp, "formatName", prop("video-format"));
    SetNamedInt64(env, cp, "width", w);
    SetNamedInt64(env, cp, "height", h);
    SetNamedDouble(env, cp, "frameRate", ToDouble(prop("container-fps")));
    SetNamedInt64(env, cp, "bitRate", ToInt(prop("video-bitrate")));
    SetNamedString(env, cp, "pixelFormat", prop("video-params/pixelformat"));
    SetNamedString(env, cp, "colorSpace", prop("video-params/colormatrix"));
    SetNamedString(env, cp, "primaries", prop("video-params/primaries"));
    SetNamedString(env, cp, "gamma", prop("video-params/gamma"));
    SetNamedString(env, cp, "hwdec", prop("hwdec-current"));

    napi_value stream = NewObject(env);
    SetNamedInt32(env, stream, "index", static_cast<int32_t>(ToInt(prop("vid"))));
    SetNamedInt64(env, stream, "width", w);
    SetNamedInt64(env, stream, "height", h);
    SetNamedInt32(env, stream, "rotation", static_cast<int32_t>(ToInt(prop("video-params/rotate"))));
    SetNamed(env, stream, "codec", cp);

    napi_value arr = nullptr;
    napi_create_array_with_length(env, 1, &arr);
    napi_set_element(env, arr, 0, stream);
    return arr;
}

// Build the single-element audio[] array from the current track's properties.
napi_value BuildAudioArray(napi_env env, const MpvPropReader& prop)
{
    std::string codec = prop("audio-codec-name");
    if (codec.empty()) codec = prop("audio-codec");
    int64_t ch = ToInt(prop("audio-params/channel-count"));
    int64_t rate = ToInt(prop("audio-params/samplerate"));
    if (codec.empty() && ch == 0 && rate == 0) {
        napi_value empty = nullptr;
        napi_create_array_with_length(env, 0, &empty);
        return empty;
    }
    napi_value cp = NewObject(env);
    SetNamedString(env, cp, "codec", codec);
    SetNamedInt64(env, cp, "channels", ch);
    SetNamedInt64(env, cp, "sampleRate", rate);
    SetNamedInt64(env, cp, "bitRate", ToInt(prop("audio-bitrate")));
    SetNamedString(env, cp, "format", prop("audio-params/format"));
    SetNamedString(env, cp, "channelLayout", prop("audio-params/hr-channels"));

    napi_value stream = NewObject(env);
    SetNamedInt32(env, stream, "index", static_cast<int32_t>(ToInt(prop("aid"))));
    SetNamed(env, stream, "codec", cp);

    napi_value arr = nullptr;
    napi_create_array_with_length(env, 1, &arr);
    napi_set_element(env, arr, 0, stream);
    return arr;
}

} // namespace

napi_value MediaInfoToNapi(napi_env env, int64_t durationMs, const MpvPropReader& prop)
{
    napi_value result = NewObject(env);
    SetNamedInt64(env, result, "startTime", 0);
    SetNamedInt64(env, result, "duration", durationMs);
    SetNamedInt64(env, result, "bitRate", ToInt(prop("video-bitrate")) + ToInt(prop("audio-bitrate")));
    SetNamedString(env, result, "format", prop("file-format"));
    SetNamedString(env, result, "title", prop("media-title"));
    SetNamedInt32(env, result, "streams", static_cast<int32_t>(ToInt(prop("track-list/count"))));

    // Extra top-level fields beyond the original MediaInfo shape — useful and
    // harmless to consumers that ignore them.
    SetNamedString(env, result, "fileSize", prop("file-size"));
    SetNamedDouble(env, result, "frameRate", ToDouble(prop("container-fps")));

    SetNamed(env, result, "metadata", NewObject(env));
    SetNamed(env, result, "video", BuildVideoArray(env, prop));
    SetNamed(env, result, "audio", BuildAudioArray(env, prop));
    SetNamedEmptyArray(env, result, "subtitle");
    return result;
}