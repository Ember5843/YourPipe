#include <ark_runtime/jsvm.h>
#include <napi/native_api.h>
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0xD004902
#define LOG_TAG "YourPipeCipher"
#include <hilog/log.h>

#ifndef YOURPIPE_NO_DEVICE_SECURITY_MODE
#include <DeviceSecurityKit/device_security_mode.h>
#endif

#include <map>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include "ejs_bundle.generated.h"

namespace {
constexpr size_t MAX_PLAYER_JS = 8 * 1024 * 1024;
constexpr size_t MAX_CHALLENGES = 128;

struct PreparedPlayer {
    std::string id;
    std::string preprocessed;
};

std::mutex gMutex;
std::map<std::string, PreparedPlayer> gPlayers;
std::once_flag gInitFlag;
JSVM_VMInfo gVmInfo{};

std::string NapiString(napi_env env, napi_value value)
{
    size_t size = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &size);
    std::string result(size + 1, '\0');
    napi_get_value_string_utf8(env, value, result.data(), result.size(), &size);
    result.resize(size);
    return result;
}

napi_value String(napi_env env, const std::string& value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

void Set(napi_env env, napi_value object, const char* name, napi_value value)
{
    napi_set_named_property(env, object, name, value);
}

std::string JsonEscape(const std::string& input)
{
    std::ostringstream out;
    out << '"';
    for (unsigned char c : input) {
        switch (c) {
            case '"': out << "\\\""; break;
            case '\\': out << "\\\\"; break;
            case '\b': out << "\\b"; break;
            case '\f': out << "\\f"; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default:
                if (c < 0x20) {
                    const char* hex = "0123456789abcdef";
                    out << "\\u00" << hex[c >> 4] << hex[c & 15];
                } else {
                    out << static_cast<char>(c);
                }
        }
    }
    out << '"';
    return out.str();
}

std::vector<std::string> NapiStringArray(napi_env env, napi_value value)
{
    uint32_t length = 0;
    napi_get_array_length(env, value, &length);
    if (length > MAX_CHALLENGES) throw std::runtime_error("too many cipher challenges");
    std::vector<std::string> result;
    result.reserve(length);
    for (uint32_t i = 0; i < length; ++i) {
        napi_value item = nullptr;
        napi_get_element(env, value, i, &item);
        result.push_back(NapiString(env, item));
    }
    return result;
}

void InitJsvm()
{
    std::call_once(gInitFlag, [] {
        JSVM_InitOptions init{};
        JSVM_Status status = OH_JSVM_Init(&init);
        if (status != JSVM_OK && status != JSVM_GENERIC_FAILURE) {
            OH_LOG_ERROR(LOG_APP, "JSVM init failed: %{public}d", status);
        }
        OH_JSVM_GetVMInfo(&gVmInfo);
        OH_LOG_INFO(LOG_APP, "JSVM engine=%{public}s api=%{public}u",
            gVmInfo.engine ? gVmInfo.engine : "unknown", gVmInfo.apiVersion);
    });
}

std::string JsvmString(JSVM_Env env, JSVM_Value value)
{
    size_t size = 0;
    if (OH_JSVM_GetValueStringUtf8(env, value, nullptr, 0, &size) != JSVM_OK) {
        throw std::runtime_error("JSVM result is not a string");
    }
    std::string result(size + 1, '\0');
    if (OH_JSVM_GetValueStringUtf8(env, value, result.data(), result.size(), &size) != JSVM_OK) {
        throw std::runtime_error("failed to read JSVM string");
    }
    result.resize(size);
    return result;
}

class CipherRuntime {
public:
    static CipherRuntime& Instance() { static CipherRuntime runtime; return runtime; }

    std::string Run(std::string source)
    {
        EnsureStarted();
        auto job = std::make_shared<Job>();
        job->source = std::move(source);
        {
            std::lock_guard lock(mutex_);
            if (!startupError_.empty()) throw std::runtime_error(startupError_);
            queue_.push_back(job);
        }
        cv_.notify_one();
        std::unique_lock lock(job->mutex);
        job->cv.wait(lock, [&] { return job->done; });
        if (!job->error.empty()) throw std::runtime_error(job->error);
        return job->result;
    }

    void Shutdown()
    {
        std::thread worker;
        {
            std::lock_guard lock(mutex_);
            if (!thread_.joinable()) return;
            stopping_ = true;
            worker = std::move(thread_);
        }
        cv_.notify_one();
        worker.join();
    }

private:
    struct Job {
        std::mutex mutex;
        std::condition_variable cv;
        std::string source;
        std::string result;
        std::string error;
        bool done = false;
    };

    std::mutex mutex_;
    std::condition_variable cv_;
    std::condition_variable readyCv_;
    std::deque<std::shared_ptr<Job>> queue_;
    std::thread thread_;
    std::string startupError_;
    bool ready_ = false;
    bool stopping_ = false;

    static void Check(JSVM_Status status, const char* stage)
    {
        if (status != JSVM_OK) throw std::runtime_error(std::string(stage) + " failed: " + std::to_string(status));
    }

    void EnsureStarted()
    {
        std::unique_lock lock(mutex_);
        if (!thread_.joinable()) {
            stopping_ = false;
            ready_ = false;
            startupError_.clear();
            thread_ = std::thread([this] { Worker(); });
        }
        readyCv_.wait(lock, [&] { return ready_; });
        if (!startupError_.empty()) throw std::runtime_error(startupError_);
    }

    std::string Execute(JSVM_Env env, const std::string& source, bool stringResult)
    {
        JSVM_HandleScope scope = nullptr;
        Check(OH_JSVM_OpenHandleScope(env, &scope), "open handle scope");
        try {
            JSVM_Value sourceValue = nullptr;
            Check(OH_JSVM_CreateStringUtf8(env, source.c_str(), source.size(), &sourceValue), "create source");
            JSVM_Script script = nullptr;
            bool rejected = false;
            Check(OH_JSVM_CompileScript(env, sourceValue, nullptr, 0, true, &rejected, &script), "compile");
            JSVM_Value value = nullptr;
            Check(OH_JSVM_RunScript(env, script, &value), "run");
            std::string result = stringResult ? JsvmString(env, value) : std::string();
            OH_JSVM_CloseHandleScope(env, scope);
            return result;
        } catch (...) {
            OH_JSVM_CloseHandleScope(env, scope);
            throw;
        }
    }

    void Worker()
    {
        JSVM_VM vm = nullptr;
        JSVM_VMScope vmScope = nullptr;
        JSVM_Env env = nullptr;
        JSVM_EnvScope envScope = nullptr;
        try {
            InitJsvm();
            JSVM_CreateVMOptions options{};
            options.maxOldGenerationSize = 96 * 1024 * 1024;
            options.maxYoungGenerationSize = 24 * 1024 * 1024;
            Check(OH_JSVM_CreateVM(&options, &vm), "create VM");
            Check(OH_JSVM_OpenVMScope(vm, &vmScope), "open VM scope");
            Check(OH_JSVM_CreateEnv(vm, 0, nullptr, &env), "create env");
            Check(OH_JSVM_OpenEnvScope(env, &envScope), "open env scope");
            Execute(env, std::string(YOURPIPE_EJS_BUNDLE), false);
            OH_LOG_INFO(LOG_APP, "persistent JSVM runtime ready");
        } catch (const std::exception& e) {
            std::lock_guard lock(mutex_);
            startupError_ = e.what();
        }
        {
            std::lock_guard lock(mutex_);
            ready_ = true;
        }
        readyCv_.notify_all();

        while (env) {
            std::shared_ptr<Job> job;
            {
                std::unique_lock lock(mutex_);
                cv_.wait(lock, [&] { return stopping_ || !queue_.empty(); });
                if (stopping_ && queue_.empty()) break;
                job = queue_.front();
                queue_.pop_front();
            }
            try { job->result = Execute(env, job->source, true); }
            catch (const std::exception& e) { job->error = e.what(); }
            {
                std::lock_guard lock(job->mutex);
                job->done = true;
            }
            job->cv.notify_one();
        }
        if (envScope) OH_JSVM_CloseEnvScope(env, envScope);
        if (env) OH_JSVM_DestroyEnv(env);
        if (vmScope) OH_JSVM_CloseVMScope(vm, vmScope);
        if (vm) OH_JSVM_DestroyVM(vm);
    }

    ~CipherRuntime() { Shutdown(); }
};

std::string RunScript(const std::string& source) { return CipherRuntime::Instance().Run(source); }

std::string BuildDecodeScript(const PreparedPlayer& player,
    const std::vector<std::string>& sigs, const std::vector<std::string>& ns)
{
    std::ostringstream input;
    input << "{\"type\":\"preprocessed\",\"player_id\":" << JsonEscape(player.id)
        << ",\"requests\":[";
    bool needsComma = false;
    if (!ns.empty()) {
        input << "{\"type\":\"n\",\"challenges\":[";
        for (size_t i = 0; i < ns.size(); ++i) { if (i) input << ','; input << JsonEscape(ns[i]); }
        input << "]}"; needsComma = true;
    }
    if (!sigs.empty()) {
        if (needsComma) input << ',';
        input << "{\"type\":\"sig\",\"challenges\":[";
        for (size_t i = 0; i < sigs.size(); ++i) { if (i) input << ','; input << JsonEscape(sigs[i]); }
        input << "]}";
    }
    input << "]}";
    return "__yourpipeEjs(" + JsonEscape(input.str()) + ")";
}

std::string BuildWarmScript(const PreparedPlayer& player)
{
    std::string input = "{\"type\":\"preprocessed\",\"player_id\":" + JsonEscape(player.id)
        + ",\"replace_prepared\":true,\"preprocessed_player\":" + JsonEscape(player.preprocessed)
        + ",\"requests\":[]}";
    return "__yourpipeEjs(" + JsonEscape(input) + ")";
}

std::string BuildPreprocessScript(const std::string& playerJs)
{
    std::string input = "{\"type\":\"player\",\"player\":" + JsonEscape(playerJs)
        + ",\"requests\":[],\"output_preprocessed\":true}";
    return "__yourpipeEjs(" + JsonEscape(input) + ")";
}

struct DecodeWork {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string playerId;
    std::vector<std::string> sigs;
    std::vector<std::string> ns;
    std::string result;
    std::string error;
};

struct PreprocessWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string playerJs;
    std::string result;
    std::string error;
};

struct PrepareWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    PreparedPlayer player;
    std::string error;
};

void ExecutePrepare(napi_env, void* data)
{
    auto* work = static_cast<PrepareWork*>(data);
    try {
        RunScript(BuildWarmScript(work->player));
        std::lock_guard lock(gMutex);
        gPlayers[work->player.id] = work->player;
    } catch (const std::exception& e) { work->error = e.what(); }
}

void CompletePrepare(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<PrepareWork*>(data);
    if (status != napi_ok && work->error.empty()) work->error = "native prepare work failed";
    if (work->error.empty()) {
        napi_value result = nullptr; napi_create_object(env, &result);
        Set(env, result, "playerId", String(env, work->player.id));
        napi_value truth = nullptr; napi_get_boolean(env, true, &truth);
        Set(env, result, "prepared", truth); Set(env, result, "hasN", truth); Set(env, result, "hasSig", truth);
        napi_resolve_deferred(env, work->deferred, result);
    } else {
        napi_value error = nullptr;
        napi_create_error(env, nullptr, String(env, work->error), &error);
        napi_reject_deferred(env, work->deferred, error);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecutePreprocess(napi_env, void* data)
{
    auto* work = static_cast<PreprocessWork*>(data);
    try { work->result = RunScript(BuildPreprocessScript(work->playerJs)); }
    catch (const std::exception& e) { work->error = e.what(); }
}

void CompletePreprocess(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<PreprocessWork*>(data);
    if (status != napi_ok && work->error.empty()) work->error = "native preprocess work failed";
    if (work->error.empty()) napi_resolve_deferred(env, work->deferred, String(env, work->result));
    else {
        napi_value error = nullptr;
        napi_create_error(env, nullptr, String(env, work->error), &error);
        napi_reject_deferred(env, work->deferred, error);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value PreprocessPlayer(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value argv[1]{};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 1) { napi_throw_type_error(env, nullptr, "preprocessPlayer expects playerJs"); return nullptr; }
    auto* work = new PreprocessWork();
    work->playerJs = NapiString(env, argv[0]);
    if (work->playerJs.empty() || work->playerJs.size() > MAX_PLAYER_JS) {
        delete work; napi_throw_range_error(env, nullptr, "invalid Player JS size"); return nullptr;
    }
    napi_value promise = nullptr; napi_create_promise(env, &work->deferred, &promise);
    napi_value name = String(env, "YourPipeCipherPreprocess");
    napi_create_async_work(env, nullptr, name, ExecutePreprocess, CompletePreprocess, work, &work->work);
    napi_queue_async_work(env, work->work);
    return promise;
}

void ExecuteDecode(napi_env, void* data)
{
    auto* work = static_cast<DecodeWork*>(data);
    try {
        PreparedPlayer player;
        {
            std::lock_guard lock(gMutex);
            auto it = gPlayers.find(work->playerId);
            if (it == gPlayers.end()) throw std::runtime_error("player is not prepared");
            player = it->second;
        }
        work->result = RunScript(BuildDecodeScript(player, work->sigs, work->ns));
    } catch (const std::exception& e) {
        work->error = e.what();
    }
}

void CompleteDecode(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<DecodeWork*>(data);
    if (status != napi_ok && work->error.empty()) work->error = "native async work failed";
    if (work->error.empty()) {
        napi_resolve_deferred(env, work->deferred, String(env, work->result));
    } else {
        napi_value error = nullptr;
        napi_create_error(env, nullptr, String(env, work->error), &error);
        napi_reject_deferred(env, work->deferred, error);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value PreparePlayer(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2]{};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 2) { napi_throw_type_error(env, nullptr, "preparePlayer expects playerId, preprocessedPlayer"); return nullptr; }
    std::string id = NapiString(env, argv[0]);
    auto* work = new PrepareWork();
    work->player = PreparedPlayer{id, NapiString(env, argv[1])};
    if (id.empty() || work->player.preprocessed.empty() || work->player.preprocessed.size() > MAX_PLAYER_JS) {
        delete work;
        napi_throw_range_error(env, nullptr, "invalid player or solver size"); return nullptr;
    }
    napi_value promise = nullptr; napi_create_promise(env, &work->deferred, &promise);
    napi_value name = String(env, "YourPipeCipherPrepare");
    napi_create_async_work(env, nullptr, name, ExecutePrepare, CompletePrepare, work, &work->work);
    napi_queue_async_work(env, work->work);
    return promise;
}

napi_value DecodeBatch(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value argv[3]{};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 3) { napi_throw_type_error(env, nullptr, "decodeBatch expects playerId, sigs, nParams"); return nullptr; }
    auto* work = new DecodeWork();
    work->env = env; work->playerId = NapiString(env, argv[0]);
    try { work->sigs = NapiStringArray(env, argv[1]); work->ns = NapiStringArray(env, argv[2]); }
    catch (const std::exception& e) { delete work; napi_throw_range_error(env, nullptr, e.what()); return nullptr; }
    napi_value promise = nullptr; napi_create_promise(env, &work->deferred, &promise);
    napi_value name = String(env, "YourPipeCipherDecode");
    napi_create_async_work(env, nullptr, name, ExecuteDecode, CompleteDecode, work, &work->work);
    napi_queue_async_work(env, work->work);
    return promise;
}

napi_value EvictPlayer(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value argv[1]{}; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc) { std::lock_guard lock(gMutex); gPlayers.erase(NapiString(env, argv[0])); }
    napi_value undefined = nullptr; napi_get_undefined(env, &undefined);
    napi_value promise = nullptr; napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise); napi_resolve_deferred(env, deferred, undefined); return promise;
}

napi_value RuntimeInfo(napi_env env, napi_callback_info)
{
    InitJsvm();
    napi_value result = nullptr; napi_create_object(env, &result);
    Set(env, result, "engine", String(env, gVmInfo.engine ? gVmInfo.engine : "unknown"));
    napi_value api = nullptr; napi_create_uint32(env, gVmInfo.apiVersion, &api); Set(env, result, "apiVersion", api);
    napi_value jit = nullptr; napi_get_boolean(env, true, &jit); Set(env, result, "jitRequested", jit);
    size_t count = 0; { std::lock_guard lock(gMutex); count = gPlayers.size(); }
    napi_value prepared = nullptr; napi_create_uint32(env, static_cast<uint32_t>(count), &prepared); Set(env, result, "preparedPlayers", prepared);
    return result;
}

/**
 * Device Security Kit: Secure Shield (坚盾守护) disables JIT globally.
 * Docs: HMS_DSM_GetDeviceSecurityMode / DSM_SECURE_SHIELD_MODE (API 5.0.1+).
 */
napi_value IsSecureShieldMode(napi_env env, napi_callback_info)
{
    bool shieldOn = false;
#ifndef YOURPIPE_NO_DEVICE_SECURITY_MODE
    const DSM_DeviceSecurityMode mode = HMS_DSM_GetDeviceSecurityMode();
    shieldOn = (static_cast<int32_t>(mode) & static_cast<int32_t>(DSM_SECURE_SHIELD_MODE)) != 0;
    OH_LOG_INFO(LOG_APP, "DeviceSecurityMode=%{public}d shield=%{public}d",
        static_cast<int>(mode), shieldOn ? 1 : 0);
#else
    OH_LOG_WARN(LOG_APP, "Device Security Mode library not linked");
#endif
    napi_value result = nullptr;
    napi_get_boolean(env, shieldOn, &result);
    return result;
}

napi_value Shutdown(napi_env env, napi_callback_info)
{
    { std::lock_guard lock(gMutex); gPlayers.clear(); }
    CipherRuntime::Instance().Shutdown();
    napi_value undefined = nullptr; napi_get_undefined(env, &undefined);
    napi_value promise = nullptr; napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise); napi_resolve_deferred(env, deferred, undefined); return promise;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor props[] = {
        {"preprocessPlayer", nullptr, PreprocessPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"preparePlayer", nullptr, PreparePlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"decodeBatch", nullptr, DecodeBatch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"evictPlayer", nullptr, EvictPlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRuntimeInfo", nullptr, RuntimeInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isSecureShieldMode", nullptr, IsSecureShieldMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shutdown", nullptr, Shutdown, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
    return exports;
}
}

NAPI_MODULE(yourpipe_cipher, Init)
