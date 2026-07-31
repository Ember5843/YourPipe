#pragma once

#include <cstdint>
#include <functional>
#include <string>

#include <napi/native_api.h>

// Reads a string-valued mpv property by name; returns "" if unset/error.
// Lets the media-info builder pull live data without depending on the mpv API
// struct (which lives in player_napi.cpp).
using MpvPropReader = std::function<std::string(const char*)>;

napi_value MediaInfoToNapi(napi_env env, int64_t durationMs, const MpvPropReader& prop);
