#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstdio>
#include <string>
#include <curl/curl.h>
#include "stream/local_dash_server.h"
#include "stream/segment_cache.h"

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "NativeInit"
#define LOG_DOMAIN 0x3201

namespace {
    static std::string napi_get_string(napi_env env, napi_value val) {
        size_t len = 0;
        napi_get_value_string_utf8(env, val, nullptr, 0, &len);
        if (len == 0) return "";
        std::string s(len, '\0');
        napi_get_value_string_utf8(env, val, &s[0], len + 1, &len);
        return s;
    }

    napi_value LocalMediaCreateSession(napi_env env, napi_callback_info info) {
        size_t argc = 1;
        napi_value args[1];
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        std::string inputJson;
        if (argc > 0) {
            inputJson = napi_get_string(env, args[0]);
        }
        std::string sessionId = yourpipe::LocalDashServer::instance().createSessionFromInputJson(inputJson);
        napi_value result;
        napi_create_string_utf8(env, sessionId.c_str(), sessionId.size(), &result);
        return result;
    }

    napi_value LocalMediaDestroySession(napi_env env, napi_callback_info info) {
        size_t argc = 1;
        napi_value args[1];
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc > 0) {
            yourpipe::LocalDashServer::instance().destroySession(napi_get_string(env, args[0]));
        }
        return nullptr;
    }

    napi_value LocalMediaGetPlaybackUrl(napi_env env, napi_callback_info info) {
        size_t argc = 1;
        napi_value args[1];
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        std::string url;
        if (argc > 0) {
            url = yourpipe::LocalDashServer::instance().playbackUrl(napi_get_string(env, args[0]));
        }
        napi_value result;
        napi_create_string_utf8(env, url.c_str(), url.size(), &result);
        return result;
    }

    napi_value LocalMediaRefreshSession(napi_env env, napi_callback_info info) {
        size_t argc = 2;
        napi_value args[2];
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        std::string playbackUrl;
        if (argc > 1) {
            std::string sessionId = napi_get_string(env, args[0]);
            bool ok = yourpipe::LocalDashServer::instance()
                .refreshSessionFromInputJson(sessionId, napi_get_string(env, args[1]));
            if (ok) {
                playbackUrl = yourpipe::LocalDashServer::instance().playbackUrl(sessionId);
            }
        }
        napi_value result;
        napi_create_string_utf8(env, playbackUrl.c_str(), playbackUrl.size(), &result);
        return result;
    }

    napi_value LocalMediaStopAll(napi_env env, napi_callback_info info) {
        (void)env;
        (void)info;
        yourpipe::LocalDashServer::instance().destroyAllSessions();
        return nullptr;
    }

    napi_value LocalMediaSetCacheConfig(napi_env env, napi_callback_info info) {
        size_t argc = 1;
        napi_value args[1];
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc > 0) {
            std::string json = napi_get_string(env, args[0]);
            bool enabled = true;
            size_t maxSizeBytes = 64 * 1024 * 1024;
            size_t pos = json.find("\"enabled\"");
            if (pos != std::string::npos) {
                size_t colon = json.find(':', pos);
                if (colon != std::string::npos) {
                    size_t valPos = json.find_first_not_of(" \t", colon + 1);
                    if (valPos != std::string::npos) {
                        if (json.substr(valPos, 5) == "false") enabled = false;
                        else if (json.substr(valPos, 4) == "true") enabled = true;
                    }
                }
            }
            pos = json.find("\"maxSizeBytes\"");
            if (pos != std::string::npos) {
                size_t colon = json.find(':', pos);
                if (colon != std::string::npos) {
                    try {
                        maxSizeBytes = static_cast<size_t>(std::stoull(json.substr(colon + 1)));
                    } catch (...) {}
                }
            }
            yourpipe::SegmentMemoryCache::instance().setEnabled(enabled);
            yourpipe::SegmentMemoryCache::instance().setMaxSize(maxSizeBytes);
        }
        return nullptr;
    }

    napi_value LocalMediaGetCacheStats(napi_env env, napi_callback_info info) {
        (void)info;
        auto stats = yourpipe::SegmentMemoryCache::instance().stats();
        std::string json = "{"
            "\"enabled\":" + std::string(stats.enabled ? "true" : "false") + ","
            "\"currentSizeBytes\":" + std::to_string(stats.currentSizeBytes) + ","
            "\"entryCount\":" + std::to_string(stats.entryCount) + ","
            "\"maxSizeBytes\":" + std::to_string(stats.maxSizeBytes) + ","
            "\"hitCount\":" + std::to_string(stats.hitCount) + ","
            "\"missCount\":" + std::to_string(stats.missCount) +
        "}";
        napi_value result;
        napi_create_string_utf8(env, json.c_str(), json.size(), &result);
        return result;
    }

    napi_value LocalMediaClearCache(napi_env env, napi_callback_info info) {
        (void)env;
        (void)info;
        yourpipe::SegmentMemoryCache::instance().clear();
        return nullptr;
    }

    static void CleanupHook(void* arg) {
        (void)arg;
        curl_global_cleanup();
    }

    napi_value Init(napi_env env, napi_value exports) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "NAPI Init started");
        curl_global_init(CURL_GLOBAL_DEFAULT);
        napi_add_env_cleanup_hook(env, CleanupHook, nullptr);

        napi_property_descriptor desc[] = {
            {"localMediaCreateSession", nullptr, LocalMediaCreateSession, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"localMediaDestroySession", nullptr, LocalMediaDestroySession, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"localMediaGetPlaybackUrl", nullptr, LocalMediaGetPlaybackUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"localMediaRefreshSession", nullptr, LocalMediaRefreshSession, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"localMediaStopAll", nullptr, LocalMediaStopAll, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"localMediaSetCacheConfig", nullptr, LocalMediaSetCacheConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"localMediaGetCacheStats", nullptr, LocalMediaGetCacheStats, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"localMediaClearCache", nullptr, LocalMediaClearCache, nullptr, nullptr, nullptr, napi_default, nullptr},
        };
        napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

        return exports;
    }

    __attribute__((constructor)) void RegisterModule() {
        static napi_module module = {
            .nm_version = 1,
            .nm_flags = 0,
            .nm_filename = nullptr,
            .nm_register_func = Init,
            .nm_modname = "player",
            .nm_priv = nullptr,
            .reserved = {0}
        };
        napi_module_register(&module);
    }
}
