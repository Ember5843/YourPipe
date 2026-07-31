#include "global_napi.h"
#include <hilog/log.h>
#include <rawfile/raw_file_manager.h>
#include <map>
#include <mutex>
#include <string>
#include <variant>
#include <vector>

using namespace std;

namespace {

using GlobalOption = variant<string, int, float, void*>;

mutex gGlobalOptionMutex;
map<string, GlobalOption> gGlobalOptions;

template<typename T>
void SetStoredGlobalOption(const string& key, T value)
{
    const scoped_lock lock(gGlobalOptionMutex);
    gGlobalOptions[key] = value;
}

template<typename T>
bool GetStoredGlobalOption(const string& key, T& value)
{
    const scoped_lock lock(gGlobalOptionMutex);
    auto it = gGlobalOptions.find(key);
    if (it == gGlobalOptions.end())
        return false;
    if (auto stored = get_if<T>(&it->second)) {
        value = *stored;
        return true;
    }
    return false;
}

} // namespace

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

NativeResourceManager* GetResourceManager()
{
    void* value = nullptr;
    if (!GetStoredGlobalOption("resourceManager", value)) {
        return nullptr;
    }
    return static_cast<NativeResourceManager*>(value);
}

void RegisterLogHandlerOnce()
{
    static once_flag gLogHandlerOnce;
    call_once(gLogHandlerOnce, [] {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv", "libmpv backend initialized");
    });
}

napi_value Version(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    napi_create_int32(env, 0, &result);
    return result;
}

napi_value SetGlobalOptionString(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto key = ToString(env, args[0]);
    const auto value = ToString(env, args[1]);
    SetStoredGlobalOption(key, value);
    return Undefined(env);
}

napi_value GetGlobalOptionString(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto key = ToString(env, args[0]);
    string value;
    if (!GetStoredGlobalOption(key, value)) {
        napi_value result = nullptr;
        napi_get_null(env, &result);
        return result;
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

napi_value SetGlobalOptionInt(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto key = ToString(env, args[0]);
    int32_t value = 0;
    napi_get_value_int32(env, args[1], &value);
    SetStoredGlobalOption(key, static_cast<int>(value));
    return Undefined(env);
}

napi_value GetGlobalOptionInt(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto key = ToString(env, args[0]);
    int value = 0;
    if (!GetStoredGlobalOption(key, value)) {
        napi_value result = nullptr;
        napi_get_null(env, &result);
        return result;
    }
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value SetGlobalOptionFloat(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto key = ToString(env, args[0]);
    double value = 0;
    napi_get_value_double(env, args[1], &value);
    SetStoredGlobalOption(key, static_cast<float>(value));
    return Undefined(env);
}

napi_value SetResourceManager(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        return Undefined(env);
    }

    if (auto resMgr = OH_ResourceManager_InitNativeResourceManager(env, args[0])) {
        SetStoredGlobalOption("resourceManager", resMgr);
    } else {
        napi_throw_error(env, nullptr, "Failed to initialize NativeResourceManager");
    }
    return Undefined(env);
}
