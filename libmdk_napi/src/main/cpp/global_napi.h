#pragma once
#include <napi/native_api.h>
#include <string>

struct NativeResourceManager;

std::string ToString(napi_env env, napi_value value);
napi_value Undefined(napi_env env);
NativeResourceManager* GetResourceManager();

void RegisterLogHandlerOnce();

napi_value Version(napi_env env, napi_callback_info info);
napi_value SetGlobalOptionString(napi_env env, napi_callback_info info);
napi_value GetGlobalOptionString(napi_env env, napi_callback_info info);
napi_value SetGlobalOptionInt(napi_env env, napi_callback_info info);
napi_value GetGlobalOptionInt(napi_env env, napi_callback_info info);
napi_value SetGlobalOptionFloat(napi_env env, napi_callback_info info);

napi_value SetResourceManager(napi_env env, napi_callback_info info);
