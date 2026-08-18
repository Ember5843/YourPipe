#pragma once
#include <napi/native_api.h>
#include <string>

std::string ToString(napi_env env, napi_value value);
napi_value Undefined(napi_env env);

void RegisterLogHandlerOnce();
