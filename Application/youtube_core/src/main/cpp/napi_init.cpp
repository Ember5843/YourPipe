// napi_init.cpp
// 使用 JSVM 动态执行 JavaScript 进行 Cipher 解密

#include "napi/native_api.h"
#include "hilog/log.h"
#include "ark_runtime/jsvm.h"
#include <string>
#include <cstring>
#include <vector>



#define LOG_DOMAIN 0x3200
#define LOG_TAG "CIPHER_JS"

#define CHECK_JSVM_CALL(env, theCall) \
    do { \
        JSVM_Status cond = theCall; \
        if (cond != JSVM_OK) { \
            const JSVM_ExtendedErrorInfo *info; \
            OH_JSVM_GetLastErrorInfo(env, &info); \
            OH_LOG_ERROR(LOG_APP, "JSVM Error: %{public}s at %{public}s:%{public}d", \
                         info ? info->errorMessage : "Unknown", __FILE__, __LINE__); \
            return cond; \
        } \
    } while (0)

// 全局 JSVM 实例（保持持久化以避免重复创建）
static JSVM_VM g_cipherVm = nullptr;
static JSVM_Env g_cipherEnv = nullptr;
static int g_initCount = 0;

// 初始化 Cipher JS 执行环境
static int InitCipherJsEnvironment() {
    if (g_initCount > 0) {
        g_initCount++;
        return 0;
    }

    JSVM_InitOptions initOptions = {0};
    JSVM_Status status = OH_JSVM_Init(&initOptions);
    if (status != JSVM_OK) {
        // JSVM 可能已经初始化过，继续尝试创建 VM
        OH_LOG_INFO(LOG_APP, "JSVM_Init returned: %{public}d, continuing...", status);
    }

    status = OH_JSVM_CreateVM(nullptr, &g_cipherVm);
    if (status != JSVM_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to create VM: %{public}d", status);
        return -1;
    }

    status = OH_JSVM_CreateEnv(g_cipherVm, 0, nullptr, &g_cipherEnv);
    if (status != JSVM_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to create Env: %{public}d", status);
        OH_JSVM_DestroyVM(g_cipherVm);
        g_cipherVm = nullptr;
        return -1;
    }

    g_initCount = 1;
    OH_LOG_INFO(LOG_APP, "Cipher JS Environment initialized");
    return 0;
}

// 销毁 Cipher JS 执行环境
static void DestroyCipherJsEnvironment() {
    g_initCount--;
    if (g_initCount > 0) {
        return;
    }

    if (g_cipherEnv) {
        OH_JSVM_DestroyEnv(g_cipherEnv);
        g_cipherEnv = nullptr;
    }
    if (g_cipherVm) {
        OH_JSVM_DestroyVM(g_cipherVm);
        g_cipherVm = nullptr;
    }
    OH_LOG_INFO(LOG_APP, "Cipher JS Environment destroyed");
}

// 在 JS 环境中执行代码并返回字符串结果
static int ExecuteJsCode(const char* jsCode, const char* functionName, const char* param, std::string& result) {
    if (!g_cipherEnv) {
        OH_LOG_ERROR(LOG_APP, "JS Environment not initialized");
        result = "ERROR:JS Environment not initialized";
        return -1;
    }

    JSVM_EnvScope envScope;
    JSVM_HandleScope handleScope;

    JSVM_Status status = OH_JSVM_OpenEnvScope(g_cipherEnv, &envScope);
    if (status != JSVM_OK) {
        result = "ERROR:Failed to open env scope";
        return -1;
    }

    status = OH_JSVM_OpenHandleScope(g_cipherEnv, &handleScope);
    if (status != JSVM_OK) {
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        result = "ERROR:Failed to open handle scope";
        return -1;
    }

    // 编译并执行 JS 代码
    JSVM_Script script;
    JSVM_Value jsSrc;
    status = OH_JSVM_CreateStringUtf8(g_cipherEnv, jsCode, JSVM_AUTO_LENGTH, &jsSrc);
    if (status != JSVM_OK) {
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        result = "ERROR:Failed to create JS source string";
        return -1;
    }

    status = OH_JSVM_CompileScript(g_cipherEnv, jsSrc, nullptr, 0, true, nullptr, &script);
    if (status != JSVM_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to compile script");
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        result = "ERROR:Failed to compile script";
        return -1;
    }

    JSVM_Value execResult;
    status = OH_JSVM_RunScript(g_cipherEnv, script, &execResult);
    if (status != JSVM_OK) {
        // 尝试获取异常信息
        JSVM_Value exception;
        if (OH_JSVM_GetAndClearLastException(g_cipherEnv, &exception) == JSVM_OK) {
            JSVM_Value exStr;
            if (OH_JSVM_CoerceToString(g_cipherEnv, exception, &exStr) == JSVM_OK) {
                char exMsg[1024] = {0};
                OH_JSVM_GetValueStringUtf8(g_cipherEnv, exStr, exMsg, sizeof(exMsg), nullptr);
                OH_LOG_ERROR(LOG_APP, "JS Runtime Error: %{public}s", exMsg);
                result = std::string("ERROR:Runtime: ") + exMsg;
            } else {
                result = "ERROR:Failed to run script (unknown exception)";
            }
        } else {
            result = "ERROR:Failed to run script";
        }
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        return -1;
    }

    // 调用解密函数
    JSVM_Value global;
    status = OH_JSVM_GetGlobal(g_cipherEnv, &global);
    if (status != JSVM_OK) {
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        result = "ERROR:Failed to get global object";
        return -1;
    }

    JSVM_Value jsFunc;
    status = OH_JSVM_GetNamedProperty(g_cipherEnv, global, functionName, &jsFunc);
    if (status != JSVM_OK) {
        OH_LOG_ERROR(LOG_APP, "Failed to get function: %{public}s", functionName);
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        result = std::string("ERROR:Function not found: ") + functionName;
        return -1;
    }

    // 创建参数
    JSVM_Value jsParam;
    status = OH_JSVM_CreateStringUtf8(g_cipherEnv, param, JSVM_AUTO_LENGTH, &jsParam);
    if (status != JSVM_OK) {
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        result = "ERROR:Failed to create param string";
        return -1;
    }

    // 调用函数
    JSVM_Value callResult;
    JSVM_Value args[] = { jsParam };
    status = OH_JSVM_CallFunction(g_cipherEnv, global, jsFunc, 1, args, &callResult);
    if (status != JSVM_OK) {
        JSVM_Value exception;
        if (OH_JSVM_GetAndClearLastException(g_cipherEnv, &exception) == JSVM_OK) {
            JSVM_Value exStr;
            if (OH_JSVM_CoerceToString(g_cipherEnv, exception, &exStr) == JSVM_OK) {
                char exMsg[1024] = {0};
                OH_JSVM_GetValueStringUtf8(g_cipherEnv, exStr, exMsg, sizeof(exMsg), nullptr);
                OH_LOG_ERROR(LOG_APP, "JS Call Error [%{public}s]: %{public}s", functionName, exMsg);
                result = std::string("ERROR:Call failed: ") + exMsg;
            } else {
                result = std::string("ERROR:Call failed for ") + functionName;
            }
        } else {
            result = std::string("ERROR:Call failed for ") + functionName;
        }
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        return -1;
    }

    // 获取结果字符串
    size_t resultLen = 0;
    OH_JSVM_GetValueStringUtf8(g_cipherEnv, callResult, nullptr, 0, &resultLen);
    if (resultLen > 0) {
        result.resize(resultLen);
        OH_JSVM_GetValueStringUtf8(g_cipherEnv, callResult, &result[0], resultLen + 1, nullptr);
    } else {
        result = "";
    }

    OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
    OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);

    return 0;
}

// NAPI 接口：初始化 Cipher 环境
static napi_value InitCipherEnv(napi_env env, napi_callback_info info) {
    int ret = InitCipherJsEnvironment();
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

// NAPI 接口：销毁 Cipher 环境
static napi_value DestroyCipherEnv(napi_env env, napi_callback_info info) {
    DestroyCipherJsEnvironment();
    return nullptr;
}

// NAPI 接口：执行 Cipher 解密
static napi_value ExecuteCipher(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        OH_LOG_ERROR(LOG_APP, "ExecuteCipher requires 3 arguments: jsCode, functionName, param");
        napi_value errResult;
        napi_create_string_utf8(env, "ERROR:Missing arguments", NAPI_AUTO_LENGTH, &errResult);
        return errResult;
    }

    // 动态获取 jsCode
    size_t jsCodeLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &jsCodeLen);
    std::string jsCode(jsCodeLen + 1, '\0');
    napi_get_value_string_utf8(env, args[0], &jsCode[0], jsCode.size(), &jsCodeLen);

    // functionName 通常很短，栈上分配即可
    char functionName[256] = {0};
    size_t funcNameLen = sizeof(functionName);
    napi_get_value_string_utf8(env, args[1], functionName, funcNameLen, &funcNameLen);

    // 动态获取 param
    size_t paramLen = 0;
    napi_get_value_string_utf8(env, args[2], nullptr, 0, &paramLen);
    std::string param(paramLen + 1, '\0');
    napi_get_value_string_utf8(env, args[2], &param[0], param.size(), &paramLen);

    std::string result;
    ExecuteJsCode(jsCode.c_str(), functionName, param.c_str(), result);

    napi_value napiResult;
    napi_create_string_utf8(env, result.c_str(), result.length(), &napiResult);
    return napiResult;
}

// NAPI 接口：批量执行 Cipher 解密（编译一次 JS，调用多个函数）
// callsJson 格式: [{"func":"funcName","param":"value"},...]
// 返回 JSON 数组: ["result1","result2",...]
static napi_value BatchExecuteCipher(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        OH_LOG_ERROR(LOG_APP, "BatchExecuteCipher requires 2 arguments: jsCode, callsJson");
        napi_value errResult;
        napi_create_string_utf8(env, "ERROR:Missing arguments", NAPI_AUTO_LENGTH, &errResult);
        return errResult;
    }

    // 动态获取 jsCode
    size_t jsCodeLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &jsCodeLen);
    std::string jsCode(jsCodeLen + 1, '\0');
    napi_get_value_string_utf8(env, args[0], &jsCode[0], jsCode.size(), &jsCodeLen);

    // 动态获取 callsJson
    size_t callsLen = 0;
    napi_get_value_string_utf8(env, args[1], nullptr, 0, &callsLen);
    std::string callsJson(callsLen + 1, '\0');
    napi_get_value_string_utf8(env, args[1], &callsJson[0], callsJson.size(), &callsLen);

    if (!g_cipherEnv) {
        OH_LOG_ERROR(LOG_APP, "JS Environment not initialized");
        napi_value errResult;
        napi_create_string_utf8(env, "ERROR:JS Environment not initialized", NAPI_AUTO_LENGTH, &errResult);
        return errResult;
    }

    JSVM_EnvScope envScope;
    JSVM_HandleScope handleScope;
    JSVM_Status status = OH_JSVM_OpenEnvScope(g_cipherEnv, &envScope);
    if (status != JSVM_OK) {
        napi_value errResult;
        napi_create_string_utf8(env, "ERROR:Failed to open env scope", NAPI_AUTO_LENGTH, &errResult);
        return errResult;
    }
    status = OH_JSVM_OpenHandleScope(g_cipherEnv, &handleScope);
    if (status != JSVM_OK) {
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        napi_value errResult;
        napi_create_string_utf8(env, "ERROR:Failed to open handle scope", NAPI_AUTO_LENGTH, &errResult);
        return errResult;
    }

    // 编译并执行 JS 代码（只编译一次）
    JSVM_Script script;
    JSVM_Value jsSrc;
    OH_JSVM_CreateStringUtf8(g_cipherEnv, jsCode.c_str(), JSVM_AUTO_LENGTH, &jsSrc);
    status = OH_JSVM_CompileScript(g_cipherEnv, jsSrc, nullptr, 0, true, nullptr, &script);
    if (status != JSVM_OK) {
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        napi_value errResult;
        napi_create_string_utf8(env, "ERROR:Failed to compile script", NAPI_AUTO_LENGTH, &errResult);
        return errResult;
    }

    JSVM_Value execResult;
    status = OH_JSVM_RunScript(g_cipherEnv, script, &execResult);
    if (status != JSVM_OK) {
        JSVM_Value exception;
        std::string errMsg = "ERROR:Failed to run script";
        if (OH_JSVM_GetAndClearLastException(g_cipherEnv, &exception) == JSVM_OK) {
            JSVM_Value exStr;
            if (OH_JSVM_CoerceToString(g_cipherEnv, exception, &exStr) == JSVM_OK) {
                char exMsg[1024] = {0};
                OH_JSVM_GetValueStringUtf8(g_cipherEnv, exStr, exMsg, sizeof(exMsg), nullptr);
                errMsg = std::string("ERROR:Runtime: ") + exMsg;
            }
        }
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        napi_value errResult;
        napi_create_string_utf8(env, errMsg.c_str(), errMsg.length(), &errResult);
        return errResult;
    }

    // 用 JSVM 解析 callsJson 并批量调用
    // 构造一个 JS wrapper：解析 calls，逐个调用，返回 JSON 结果数组
    std::string batchScript =
        "(" + std::string("function(__calls_json__) {"
        "  var calls = JSON.parse(__calls_json__);"
        "  var results = [];"
        "  for (var i = 0; i < calls.length; i++) {"
        "    try {"
        "      var fn = this[calls[i].func];"
        "      if (typeof fn === 'function') {"
        "        results.push(fn(calls[i].param) || '');"
        "      } else {"
        "        results.push('ERROR:Function not found: ' + calls[i].func);"
        "      }"
        "    } catch(e) {"
        "      results.push('ERROR:' + String(e));"
        "    }"
        "  }"
        "  return JSON.stringify(results);"
        "})");

    JSVM_Value batchSrc;
    OH_JSVM_CreateStringUtf8(g_cipherEnv, batchScript.c_str(), JSVM_AUTO_LENGTH, &batchSrc);
    JSVM_Script batchCompiled;
    status = OH_JSVM_CompileScript(g_cipherEnv, batchSrc, nullptr, 0, true, nullptr, &batchCompiled);
    if (status != JSVM_OK) {
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        napi_value errResult;
        napi_create_string_utf8(env, "ERROR:Failed to compile batch script", NAPI_AUTO_LENGTH, &errResult);
        return errResult;
    }

    JSVM_Value batchFn;
    OH_JSVM_RunScript(g_cipherEnv, batchCompiled, &batchFn);

    // 调用 batch function，传入 callsJson
    JSVM_Value global;
    OH_JSVM_GetGlobal(g_cipherEnv, &global);
    JSVM_Value jsCallsParam;
    OH_JSVM_CreateStringUtf8(g_cipherEnv, callsJson.c_str(), JSVM_AUTO_LENGTH, &jsCallsParam);

    JSVM_Value batchResult;
    JSVM_Value batchArgs[] = { jsCallsParam };
    status = OH_JSVM_CallFunction(g_cipherEnv, global, batchFn, 1, batchArgs, &batchResult);
    if (status != JSVM_OK) {
        JSVM_Value exception;
        std::string errMsg = "ERROR:Batch call failed";
        if (OH_JSVM_GetAndClearLastException(g_cipherEnv, &exception) == JSVM_OK) {
            JSVM_Value exStr;
            if (OH_JSVM_CoerceToString(g_cipherEnv, exception, &exStr) == JSVM_OK) {
                char exMsg[1024] = {0};
                OH_JSVM_GetValueStringUtf8(g_cipherEnv, exStr, exMsg, sizeof(exMsg), nullptr);
                errMsg = std::string("ERROR:Batch: ") + exMsg;
            }
        }
        OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
        OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);
        napi_value errResult;
        napi_create_string_utf8(env, errMsg.c_str(), errMsg.length(), &errResult);
        return errResult;
    }

    // 获取结果字符串
    size_t resultLen = 0;
    OH_JSVM_GetValueStringUtf8(g_cipherEnv, batchResult, nullptr, 0, &resultLen);
    std::string resultStr(resultLen + 1, '\0');
    OH_JSVM_GetValueStringUtf8(g_cipherEnv, batchResult, &resultStr[0], resultStr.size(), &resultLen);
    resultStr.resize(resultLen);

    OH_JSVM_CloseHandleScope(g_cipherEnv, handleScope);
    OH_JSVM_CloseEnvScope(g_cipherEnv, envScope);

    napi_value napiResult;
    napi_create_string_utf8(env, resultStr.c_str(), resultStr.length(), &napiResult);
    return napiResult;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    OH_LOG_INFO(LOG_APP, "Cipher JS Module Init called");
    napi_property_descriptor desc[] = {
        {"initCipherEnv", nullptr, InitCipherEnv, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroyCipherEnv", nullptr, DestroyCipherEnv, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"executeCipher", nullptr, ExecuteCipher, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"batchExecuteCipher", nullptr, BatchExecuteCipher, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "youtubecore",
    .nm_priv = ((void*)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&g_module);
}
