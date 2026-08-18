#include "global_napi.h"
#include <hilog/log.h>
#include <mutex>
#include <string>
#include <vector>

using namespace std;

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

void RegisterLogHandlerOnce()
{
    static once_flag gLogHandlerOnce;
    call_once(gLogHandlerOnce, [] {
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv", "libmpv backend initialized");
    });
}
