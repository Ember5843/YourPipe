/*
 * Reusable player N-API bridge for OHOS.
 *
 * The public ArkTS API and native module name stay compatible with the
 * original MDK package while playback is delegated to libmpv.
 */
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <filemanagement/file_uri/oh_file_uri.h>
#include <hilog/log.h>
#include <mpv/client.h>
#include <mpv/stream_cb.h>
#include <napi/native_api.h>
#include <rawfile/raw_file_manager.h>

#include "global_napi.h"
#include "hwdec_probe.h"
#include "media_info_napi.h"
#include "mux_napi.h"
#include "vpe_probe.h"

// FFmpeg (n8.0) for direct libav* use — e.g. muxing an audio + video file into
// one output. These are C headers, so they need C linkage from C++.
extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
}

#include <cmath>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <dlfcn.h>
#include <climits>
#include <cstring>
#include <iterator>
#include <condition_variable>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

using namespace std;

namespace {

constexpr int32_t kStateStopped = 0;
constexpr int32_t kStatePlaying = 1;
constexpr int32_t kStatePaused = 2;

constexpr int32_t kStatusNoMedia = 0;
constexpr int32_t kStatusUnloaded = 1;
constexpr int32_t kStatusLoading = 1 << 1;
constexpr int32_t kStatusLoaded = 1 << 2;
constexpr int32_t kStatusStalled = 1 << 3;
constexpr int32_t kStatusBuffering = 1 << 4;
constexpr int32_t kStatusBuffered = 1 << 5;
constexpr int32_t kStatusEnd = 1 << 6;
constexpr int32_t kStatusSeeking = 1 << 7;
constexpr int32_t kStatusPrepared = 1 << 8;
constexpr int32_t kStatusInvalid = 1 << 31;

constexpr int32_t kMediaTypeVideo = 0;
constexpr int32_t kMediaTypeAudio = 1;
constexpr int32_t kMediaTypeSubtitle = 3;

struct MpvApi {
    void* library = nullptr;
    bool attempted = false;
    bool available = false;
    mpv_handle* (*create)() = nullptr;
    int (*set_option_string)(mpv_handle*, const char*, const char*) = nullptr;
    int (*set_option)(mpv_handle*, const char*, mpv_format, void*) = nullptr;
    int (*initialize)(mpv_handle*) = nullptr;
    void (*destroy)(mpv_handle*) = nullptr;
    void (*terminate_destroy)(mpv_handle*) = nullptr;
    int (*command)(mpv_handle*, const char**) = nullptr;
    int (*command_async)(mpv_handle*, uint64_t, const char**) = nullptr;
    const char* (*error_string)(int) = nullptr;
    int (*set_property)(mpv_handle*, const char*, mpv_format, void*) = nullptr;
    char* (*get_property_string)(mpv_handle*, const char*) = nullptr;
    void (*free)(void*) = nullptr;
    int (*set_property_async)(mpv_handle*, uint64_t, const char*, mpv_format, void*) = nullptr;
    int (*set_property_string)(mpv_handle*, const char*, const char*) = nullptr;
    int (*request_log_messages)(mpv_handle*, const char*) = nullptr;
    int (*observe_property)(mpv_handle*, uint64_t, const char*, mpv_format) = nullptr;
    mpv_event* (*wait_event)(mpv_handle*, double) = nullptr;
    void (*wakeup)(mpv_handle*) = nullptr;
    int (*stream_cb_add_ro)(mpv_handle*, const char*, void*, mpv_stream_cb_open_ro_fn) = nullptr;
};

MpvApi& Mpv()
{
    static MpvApi api;
    return api;
}

template<typename T>
bool LoadSymbol(void* library, T& target, const char* name)
{
    target = reinterpret_cast<T>(dlsym(library, name));
    if (!target) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "mpv", "dlsym %{public}s failed: %{public}s", name, dlerror());
        return false;
    }
    return true;
}

bool LoadMpv()
{
    auto& api = Mpv();
    if (api.attempted) {
        return api.available;
    }
    api.attempted = true;

    if (!dlopen("libmpv_ohcodec_shim.so", RTLD_NOW | RTLD_GLOBAL)) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "mpv", "dlopen libmpv_ohcodec_shim.so failed: %{public}s", dlerror());
    }

    api.library = dlopen("libmpv.so.2", RTLD_NOW | RTLD_GLOBAL);
    if (!api.library) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "mpv", "dlopen libmpv.so.2 failed: %{public}s", dlerror());
        return false;
    }

    bool ok = true;
    ok = LoadSymbol(api.library, api.create, "mpv_create") && ok;
    ok = LoadSymbol(api.library, api.set_option_string, "mpv_set_option_string") && ok;
    ok = LoadSymbol(api.library, api.set_option, "mpv_set_option") && ok;
    ok = LoadSymbol(api.library, api.initialize, "mpv_initialize") && ok;
    ok = LoadSymbol(api.library, api.destroy, "mpv_destroy") && ok;
    ok = LoadSymbol(api.library, api.terminate_destroy, "mpv_terminate_destroy") && ok;
    ok = LoadSymbol(api.library, api.command, "mpv_command") && ok;
    ok = LoadSymbol(api.library, api.command_async, "mpv_command_async") && ok;
    ok = LoadSymbol(api.library, api.error_string, "mpv_error_string") && ok;
    ok = LoadSymbol(api.library, api.set_property, "mpv_set_property") && ok;
    ok = LoadSymbol(api.library, api.get_property_string, "mpv_get_property_string") && ok;
    ok = LoadSymbol(api.library, api.free, "mpv_free") && ok;
    ok = LoadSymbol(api.library, api.set_property_async, "mpv_set_property_async") && ok;
    ok = LoadSymbol(api.library, api.set_property_string, "mpv_set_property_string") && ok;
    ok = LoadSymbol(api.library, api.request_log_messages, "mpv_request_log_messages") && ok;
    ok = LoadSymbol(api.library, api.observe_property, "mpv_observe_property") && ok;
    ok = LoadSymbol(api.library, api.wait_event, "mpv_wait_event") && ok;
    ok = LoadSymbol(api.library, api.wakeup, "mpv_wakeup") && ok;
    ok = LoadSymbol(api.library, api.stream_cb_add_ro, "mpv_stream_cb_add_ro") && ok;

    api.available = ok;
    if (!ok) {
        dlclose(api.library);
        api.library = nullptr;
    }
    return api.available;
}

struct PlayerContext {
    mpv_handle* mpv = nullptr;
    void* window = nullptr;
    string surfaceId;
    string mediaUrl;
    int64_t mediaStartPositionMs = 0;
    bool pendingLoad = false;
    atomic_int32_t state {kStateStopped};
    atomic_int32_t mediaStatus {kStatusNoMedia};
    atomic_int64_t lastPositionMs {0};
    atomic_int64_t lastDurationMs {0};
    atomic_int64_t lastBufferedMs {0};
    mutex cacheRangesMutex;
    string seekableRangesJson = "[]";
    int32_t loopCount = 0;
    bool initialized = false;
    atomic_bool eventLoopRunning {false};
    thread eventThread;
    atomic_bool commandLoopRunning {false};
    mutex commandMutex;
    condition_variable commandCv;
    deque<function<void(PlayerContext&)>> commandQueue;
    thread commandThread;
    atomic_int64_t cacheBufferingState {-1};
    atomic_bool idleActive {false};
    atomic_bool pausedForCache {false};
    atomic_bool seeking {false};
    atomic_bool eofReached {false};
    atomic_bool paused {true};
    int32_t surfaceWidth = 0;
    int32_t surfaceHeight = 0;
    napi_threadsafe_function tsfn = nullptr;
};

mutex gMutex;
map<string, unique_ptr<PlayerContext>> gPlayers;
atomic_uint64_t gAsyncReplyId {1};

void LogMpvError(const char* action, int error)
{
    if (error < 0) {
        const char* message = Mpv().error_string ? Mpv().error_string(error) : "unknown mpv error";
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "mpv", "%{public}s failed: %{public}s", action, message);
    }
}

void SetMediaStatus(PlayerContext& ctx, int32_t status, const char* reason)
{
    ctx.mediaStatus.store(status);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv-status", "%{public}s status=0x%{public}x", reason, status);
}

void SetTransientBuffering(PlayerContext& ctx, bool seeking, const char* reason)
{
    int32_t status = ctx.mediaStatus.load();
    status |= kStatusBuffering | kStatusStalled;
    if (seeking) {
        status |= kStatusSeeking;
        // A user seek moves off the last frame, so we are no longer at EOF.
        // mpv does not clear eof-reached on a seek-from-end by itself (it only
        // clears on unpause), so clear our cached copy here to avoid the status
        // snapping back to End on the next time-pos update.
        ctx.eofReached.store(false);
    }
    status &= ~(kStatusBuffered | kStatusEnd | kStatusInvalid | kStatusUnloaded);
    ctx.mediaStatus.store(status);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv-status", "%{public}s status=0x%{public}x", reason, status);
}

void StartCommandLoop(PlayerContext& ctx)
{
    if (ctx.commandLoopRunning.load()) {
        return;
    }
    if (ctx.commandThread.joinable()) {
        ctx.commandThread.join();
    }

    ctx.commandLoopRunning = true;
    ctx.commandThread = thread([&ctx]() {
        while (ctx.commandLoopRunning.load()) {
            function<void(PlayerContext&)> task;
            {
                unique_lock<mutex> lock(ctx.commandMutex);
                ctx.commandCv.wait(lock, [&ctx]() {
                    return !ctx.commandLoopRunning.load() || !ctx.commandQueue.empty();
                });
                if (!ctx.commandLoopRunning.load() && ctx.commandQueue.empty()) {
                    break;
                }
                task = move(ctx.commandQueue.front());
                ctx.commandQueue.pop_front();
            }
            if (task) {
                task(ctx);
            }
        }
        ctx.commandLoopRunning = false;
    });
}

void StopCommandLoop(PlayerContext& ctx)
{
    ctx.commandLoopRunning = false;
    {
        const scoped_lock lock(ctx.commandMutex);
        ctx.commandQueue.clear();
    }
    ctx.commandCv.notify_all();
    if (ctx.commandThread.joinable()) {
        ctx.commandThread.join();
    }
}

void PostCommand(PlayerContext& ctx, function<void(PlayerContext&)> task)
{
    StartCommandLoop(ctx);
    {
        const scoped_lock lock(ctx.commandMutex);
        ctx.commandQueue.push_back(move(task));
    }
    ctx.commandCv.notify_one();
}

struct RawFileCookie {
    RawFile* file = nullptr;
};

string StripRawFileScheme(const char* uri)
{
    string path = uri ? uri : "";
    constexpr const char* scheme = "rawfile://";
    if (path.rfind(scheme, 0) == 0) {
        path.erase(0, strlen(scheme));
    }
    while (!path.empty() && path.front() == '/') {
        path.erase(path.begin());
    }
    return path;
}

int64_t RawFileRead(void* cookie, char* buffer, uint64_t bytes)
{
    auto* raw = static_cast<RawFileCookie*>(cookie);
    if (!raw || !raw->file) {
        return -1;
    }
    return OH_ResourceManager_ReadRawFile(raw->file, buffer, static_cast<size_t>(bytes));
}

int64_t RawFileSeek(void* cookie, int64_t offset)
{
    auto* raw = static_cast<RawFileCookie*>(cookie);
    if (!raw || !raw->file || offset < 0 || offset > LONG_MAX) {
        return MPV_ERROR_GENERIC;
    }
    if (OH_ResourceManager_SeekRawFile(raw->file, static_cast<long>(offset), 0) != 0) {
        return MPV_ERROR_GENERIC;
    }
    return OH_ResourceManager_GetRawFileOffset(raw->file);
}

int64_t RawFileSize(void* cookie)
{
    auto* raw = static_cast<RawFileCookie*>(cookie);
    if (!raw || !raw->file) {
        return MPV_ERROR_GENERIC;
    }
    return OH_ResourceManager_GetRawFileSize(raw->file);
}

void RawFileClose(void* cookie)
{
    auto* raw = static_cast<RawFileCookie*>(cookie);
    if (!raw) {
        return;
    }
    if (raw->file) {
        OH_ResourceManager_CloseRawFile(raw->file);
    }
    delete raw;
}

int RawFileOpen(void* userData, char* uri, mpv_stream_cb_info* info)
{
    auto* resourceManager = static_cast<NativeResourceManager*>(userData);
    const auto path = StripRawFileScheme(uri);
    if (!resourceManager || path.empty()) {
        return MPV_ERROR_LOADING_FAILED;
    }

    RawFile* file = OH_ResourceManager_OpenRawFile(resourceManager, path.c_str());
    if (!file) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "mpv", "rawfile open failed: %{public}s", path.c_str());
        return MPV_ERROR_LOADING_FAILED;
    }

    auto* cookie = new RawFileCookie { file };
    info->cookie = cookie;
    info->read_fn = RawFileRead;
    info->seek_fn = RawFileSeek;
    info->size_fn = RawFileSize;
    info->close_fn = RawFileClose;
    info->cancel_fn = nullptr;
    return 0;
}

void RegisterRawFileProtocol(mpv_handle* mpv)
{
    if (!mpv || !Mpv().stream_cb_add_ro) {
        return;
    }
    auto* resourceManager = GetResourceManager();
    if (!resourceManager) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "mpv", "rawfile protocol skipped: no resource manager");
        return;
    }
    LogMpvError("register rawfile protocol", Mpv().stream_cb_add_ro(mpv, "rawfile", resourceManager, RawFileOpen));
}

void SetOptionString(mpv_handle* mpv, const char* name, const char* value)
{
    LogMpvError(name, Mpv().set_option_string(mpv, name, value));
}

int64_t SecondsToMilliseconds(double seconds)
{
    if (!isfinite(seconds) || seconds <= 0.0) {
        return 0;
    }
    return static_cast<int64_t>(llround(seconds * 1000.0));
}

void ResetObservedPlaybackState(PlayerContext& ctx)
{
    ctx.lastPositionMs.store(0);
    ctx.lastBufferedMs.store(0);
    ctx.cacheBufferingState.store(-1);
    ctx.idleActive.store(false);
    ctx.pausedForCache.store(false);
    ctx.seeking.store(false);
    ctx.eofReached.store(false);
    {
        const scoped_lock lock(ctx.cacheRangesMutex);
        ctx.seekableRangesJson = "[]";
    }
    // Do not reset ctx.paused here. "pause" is an observed MPV property and
    // START_FILE does not necessarily change it, so MPV may emit no follow-up
    // property event. Retaining the last observed value keeps MPV authoritative.
}

string SerializeSeekableRanges(const mpv_node* node)
{
    if (!node || node->format != MPV_FORMAT_NODE_MAP || !node->u.list) {
        return "[]";
    }
    const mpv_node_list* map = node->u.list;
    const mpv_node* rangesNode = nullptr;
    for (int i = 0; i < map->num; i++) {
        if (map->keys && map->keys[i] && string(map->keys[i]) == "seekable-ranges") {
            rangesNode = &map->values[i];
            break;
        }
    }
    if (!rangesNode || rangesNode->format != MPV_FORMAT_NODE_ARRAY || !rangesNode->u.list) {
        return "[]";
    }

    const mpv_node_list* ranges = rangesNode->u.list;
    string result = "[";
    bool first = true;
    for (int i = 0; i < ranges->num; i++) {
        const mpv_node* range = &ranges->values[i];
        if (range->format != MPV_FORMAT_NODE_MAP || !range->u.list) continue;
        const mpv_node_list* rangeMap = range->u.list;
        double start = -1.0;
        double end = -1.0;
        for (int j = 0; j < rangeMap->num; j++) {
            if (!rangeMap->keys || !rangeMap->keys[j]) continue;
            const mpv_node* value = &rangeMap->values[j];
            const double number = value->format == MPV_FORMAT_DOUBLE ? value->u.double_ : -1.0;
            const string key = rangeMap->keys[j];
            if (key == "start") start = number;
            else if (key == "end") end = number;
        }
        if (!isfinite(start) || !isfinite(end) || start < 0.0 || end <= start) continue;
        char buffer[80];
        snprintf(buffer, sizeof(buffer), first ? "[%.3f,%.3f]" : ",[%.3f,%.3f]", start, end);
        result += buffer;
        first = false;
    }
    result += "]";
    return result;
}

void UpdateStatusFromObservedProperties(PlayerContext& ctx)
{
    if (ctx.mediaUrl.empty()) {
        ctx.state.store(kStateStopped);
        ctx.mediaStatus.store(kStatusNoMedia);
        return;
    }

    int32_t status = ctx.mediaStatus.load();
    if (status & kStatusInvalid) {
        return;
    }

    // End must strictly follow the live eof-reached property. The old code also
    // treated the kStatusEnd bit as a trigger, which made End self-sustaining:
    // once set it could never be cleared by observed-property updates, so a
    // seek-back could not recover. Derive End from eof-reached only.
    if (ctx.eofReached.load()) {
        status |= kStatusEnd;
        status &= ~(kStatusLoading | kStatusBuffering | kStatusStalled | kStatusSeeking);
        ctx.state.store(kStateStopped);
        ctx.mediaStatus.store(status);
        return;
    }
    status &= ~kStatusEnd;

    if (ctx.idleActive.load() && !(status & kStatusLoading)) {
        ctx.state.store(kStateStopped);
        ctx.mediaStatus.store(kStatusUnloaded);
        return;
    }

    const int64_t durationMs = ctx.lastDurationMs.load();
    const int64_t positionMs = ctx.lastPositionMs.load();
    const int64_t bufferedMs = ctx.lastBufferedMs.load();
    const int64_t cacheState = ctx.cacheBufferingState.load();
    ctx.state.store(ctx.paused.load() ? kStatePaused : kStatePlaying);

    if (durationMs > 0) {
        status &= ~kStatusLoading;
        status |= kStatusLoaded | kStatusPrepared;
    } else if (!(status & (kStatusLoaded | kStatusPrepared | kStatusEnd))) {
        status |= kStatusLoading;
    }

    if (ctx.seeking.load()) {
        status |= kStatusSeeking | kStatusBuffering | kStatusStalled;
        status &= ~kStatusBuffered;
    } else {
        status &= ~kStatusSeeking;
        if (ctx.pausedForCache.load() || (cacheState >= 0 && cacheState < 100)) {
            status |= kStatusBuffering | kStatusStalled;
            status &= ~kStatusBuffered;
        } else if ((durationMs > 0 || positionMs > 0) && !(status & kStatusLoading)) {
            status |= kStatusBuffered;
            status &= ~(kStatusBuffering | kStatusStalled);
        }
    }

    if (bufferedMs > 500 && !(status & kStatusBuffering)) {
        status |= kStatusBuffered;
    }

    ctx.mediaStatus.store(status);
}

void HandleObservedProperty(PlayerContext& ctx, mpv_event_property* property)
{
    if (!property || !property->name || !property->data) {
        return;
    }

    const string name = property->name;
    if (property->format == MPV_FORMAT_DOUBLE) {
        const double value = *static_cast<double*>(property->data);
        if (!isfinite(value)) {
            return;
        }
        if (name == "duration") {
            const int64_t durationMs = SecondsToMilliseconds(value);
            if (durationMs > 0) {
                ctx.lastDurationMs.store(durationMs);
            }
        } else if (name == "time-pos") {
            ctx.lastPositionMs.store(SecondsToMilliseconds(value));
        } else if (name == "demuxer-cache-duration") {
            ctx.lastBufferedMs.store(SecondsToMilliseconds(value));
        }
    } else if (property->format == MPV_FORMAT_INT64) {
        const int64_t value = *static_cast<int64_t*>(property->data);
        if (name == "cache-buffering-state") {
            ctx.cacheBufferingState.store(value);
        }
    } else if (property->format == MPV_FORMAT_FLAG) {
        const bool value = *static_cast<int*>(property->data) != 0;
        if (name == "idle-active") {
            ctx.idleActive.store(value);
        } else if (name == "paused-for-cache") {
            ctx.pausedForCache.store(value);
        } else if (name == "seeking") {
            ctx.seeking.store(value);
        } else if (name == "eof-reached") {
            ctx.eofReached.store(value);
        } else if (name == "pause") {
            ctx.paused.store(value);
        }
    } else if (property->format == MPV_FORMAT_NODE && name == "demuxer-cache-state") {
        const string rangesJson = SerializeSeekableRanges(static_cast<mpv_node*>(property->data));
        const scoped_lock lock(ctx.cacheRangesMutex);
        ctx.seekableRangesJson = rangesJson;
    }

    UpdateStatusFromObservedProperties(ctx);
}

void ObservePlaybackProperties(PlayerContext& ctx)
{
    if (!ctx.mpv || !Mpv().observe_property) {
        return;
    }

    struct ObservedProperty {
        const char* name;
        mpv_format format;
    };
    constexpr ObservedProperty properties[] = {
        {"duration", MPV_FORMAT_DOUBLE},
        {"time-pos", MPV_FORMAT_DOUBLE},
        {"demuxer-cache-duration", MPV_FORMAT_DOUBLE},
        {"cache-buffering-state", MPV_FORMAT_INT64},
        {"idle-active", MPV_FORMAT_FLAG},
        {"paused-for-cache", MPV_FORMAT_FLAG},
        {"seeking", MPV_FORMAT_FLAG},
        {"eof-reached", MPV_FORMAT_FLAG},
        {"pause", MPV_FORMAT_FLAG},
        {"demuxer-cache-state", MPV_FORMAT_NODE},
    };

    uint64_t replyId = 1;
    for (const auto& property : properties) {
        LogMpvError(property.name, Mpv().observe_property(ctx.mpv, replyId++, property.name, property.format));
    }
}

struct TsfnEvent { int type; int64_t value; };

void PushEvent(PlayerContext& ctx, int type, int64_t value)
{
    if (!ctx.tsfn) return;
    auto* evt = new TsfnEvent{type, value};
    napi_call_threadsafe_function(ctx.tsfn, evt, napi_tsfn_nonblocking);
}

void StartEventLoop(PlayerContext& ctx)
{
    if (!ctx.mpv || ctx.eventLoopRunning.load()) {
        return;
    }

    ctx.eventLoopRunning = true;
    mpv_handle* handle = ctx.mpv;
    ctx.eventThread = thread([handle, &ctx]() {
        while (ctx.eventLoopRunning.load()) {
            mpv_event* event = Mpv().wait_event(handle, -1);
            if (!event || event->event_id == MPV_EVENT_NONE) {
                continue;
            }
            if (event->event_id == MPV_EVENT_SHUTDOWN) {
                break;
            }
            if (event->event_id == MPV_EVENT_START_FILE) {
                ResetObservedPlaybackState(ctx);
                SetMediaStatus(ctx, kStatusLoading, "start-file");
                PushEvent(ctx, 2, ctx.mediaStatus.load());
            } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
                SetMediaStatus(ctx, kStatusLoaded | kStatusPrepared, "file-loaded");
                PushEvent(ctx, 2, ctx.mediaStatus.load());
            } else if (event->event_id == MPV_EVENT_SEEK) {
                int32_t status = ctx.mediaStatus.load();
                status |= kStatusSeeking | kStatusBuffering | kStatusStalled;
                status &= ~kStatusBuffered;
                ctx.mediaStatus.store(status);
                OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv-status", "seek status=0x%{public}x",
                             ctx.mediaStatus.load());
                PushEvent(ctx, 2, ctx.mediaStatus.load());
            } else if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
                SetMediaStatus(ctx, kStatusLoaded | kStatusPrepared | kStatusBuffered, "playback-restart");
                PushEvent(ctx, 2, ctx.mediaStatus.load());
            } else if (event->event_id == MPV_EVENT_PROPERTY_CHANGE && event->data) {
                auto* prop = static_cast<mpv_event_property*>(event->data);
                if (prop->format == MPV_FORMAT_NONE) { continue; }
                HandleObservedProperty(ctx, prop);
                if (prop->name == string("time-pos")) {
                    PushEvent(ctx, 1, ctx.lastPositionMs.load());
                } else if (prop->name == string("duration")) {
                    PushEvent(ctx, 3, ctx.lastDurationMs.load());
                } else if (prop->name == string("demuxer-cache-state")) {
                    PushEvent(ctx, 4, 0);
                } else {
                    PushEvent(ctx, 2, ctx.mediaStatus.load());
                }
            } else if (event->event_id == MPV_EVENT_END_FILE && event->data) {
                auto* end = static_cast<mpv_event_end_file*>(event->data);
                if (end->reason == MPV_END_FILE_REASON_EOF) {
                    SetMediaStatus(ctx, kStatusLoaded | kStatusBuffered | kStatusEnd, "end-file-eof");
                    ctx.state.store(kStateStopped);
                } else if (end->reason == MPV_END_FILE_REASON_ERROR) {
                    SetMediaStatus(ctx, kStatusInvalid, "end-file-error");
                    ctx.state.store(kStateStopped);
                } else if (end->reason == MPV_END_FILE_REASON_STOP || end->reason == MPV_END_FILE_REASON_QUIT) {
                    SetMediaStatus(ctx, ctx.mediaUrl.empty() ? kStatusNoMedia : kStatusUnloaded, "end-file-stop");
                    ctx.state.store(kStateStopped);
                }
                PushEvent(ctx, 2, ctx.mediaStatus.load());
            }
            if (event->event_id == MPV_EVENT_LOG_MESSAGE && event->data) {
                auto* message = static_cast<mpv_event_log_message*>(event->data);
                LogLevel level = LOG_INFO;
                if (message->log_level <= MPV_LOG_LEVEL_ERROR) {
                    level = LOG_ERROR;
                } else if (message->log_level <= MPV_LOG_LEVEL_WARN) {
                    level = LOG_WARN;
                }
                OH_LOG_Print(LOG_APP, level, 0xFF00, "mpv-core", "[%{public}s] %{public}s",
                             message->prefix ? message->prefix : "mpv",
                             message->text ? message->text : "");
            }
        }
        ctx.eventLoopRunning = false;
    });
}

void StopEventLoop(PlayerContext& ctx)
{
    ctx.eventLoopRunning = false;
    if (ctx.mpv && Mpv().wakeup) {
        Mpv().wakeup(ctx.mpv);
    }
    if (ctx.eventThread.joinable()) {
        ctx.eventThread.join();
    }
}

uint64_t NextAsyncReplyId()
{
    return gAsyncReplyId.fetch_add(1);
}

void RunMpvCommand(PlayerContext& ctx, const vector<string>& args, const char* action)
{
    if (!ctx.mpv) {
        return;
    }

    vector<const char*> rawArgs;
    rawArgs.reserve(args.size() + 1);
    for (const auto& arg : args) {
        rawArgs.push_back(arg.c_str());
    }
    rawArgs.push_back(nullptr);

    if (ctx.initialized && Mpv().command_async) {
        LogMpvError(action, Mpv().command_async(ctx.mpv, NextAsyncReplyId(), rawArgs.data()));
        return;
    }
    LogMpvError(action, Mpv().command(ctx.mpv, rawArgs.data()));
}

}  // namespace
namespace {

void SetMpvFlagProperty(PlayerContext& ctx, const char* property, int value, const char* action)
{
    if (!ctx.mpv) {
        return;
    }
    if (ctx.initialized && Mpv().set_property_async) {
        LogMpvError(action, Mpv().set_property_async(ctx.mpv, NextAsyncReplyId(), property, MPV_FORMAT_FLAG, &value));
        return;
    }
    LogMpvError(action, Mpv().set_property(ctx.mpv, property, MPV_FORMAT_FLAG, &value));
}

void SetMpvDoubleProperty(PlayerContext& ctx, const char* property, double value, const char* action)
{
    if (!ctx.mpv) {
        return;
    }
    if (ctx.initialized && Mpv().set_property_async) {
        LogMpvError(action, Mpv().set_property_async(ctx.mpv, NextAsyncReplyId(), property, MPV_FORMAT_DOUBLE, &value));
        return;
    }
    LogMpvError(action, Mpv().set_property(ctx.mpv, property, MPV_FORMAT_DOUBLE, &value));
}

void SetMpvStringProperty(PlayerContext& ctx, const char* property, const string& value, const char* action)
{
    if (!ctx.mpv) {
        return;
    }
    if (ctx.initialized && Mpv().set_property_async) {
        char* rawValue = const_cast<char*>(value.c_str());
        LogMpvError(action, Mpv().set_property_async(ctx.mpv, NextAsyncReplyId(), property, MPV_FORMAT_STRING, &rawValue));
        return;
    }
    LogMpvError(action, Mpv().set_property_string(ctx.mpv, property, value.c_str()));
}

// Runtime VO output color space override (see body for the full contract).
// Values mirror the ColorSpace enum in enums.ets.
void ApplyColorSpace(PlayerContext& ctx, int32_t colorSpace)
{
    if (!ctx.mpv) {
        return;
    }
    // Runtime colorspace override via setColorSpace().
    //
    // By default (no call) target-trc/target-prim stay UNSET so the
    // native-window HDR path in vo_ohos_set_color drives output (see EnsureMpv).
    // Calling this pins an explicit target:
    //  - mode 2 (BT2100_PQ) / 7 (BT2100_HLG): force an HDR target.
    //  - any other value: force SDR (gamma2.2 / bt.709), e.g. to tone-map HDR
    //    down to SDR on demand.
    // Note: pinning target-trc here overrides the colorspace hint in
    // vo_gpu-next, so forcing SDR will disengage the true-HDR native-window
    // path until the player is recreated.
    const char* trc = "gamma2.2";
    const char* prim = "bt.709";
    if (colorSpace == 2) {            // BT2100_PQ -> force HDR10 output
        trc = "pq"; prim = "bt.2020";
    } else if (colorSpace == 7) {     // BT2100_HLG -> force HLG output
        trc = "hlg"; prim = "bt.2020";
    }
    SetOptionString(ctx.mpv, "target-trc", trc);
    SetOptionString(ctx.mpv, "target-prim", prim);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv",
                 "colorspace mode=%{public}d trc=%{public}s prim=%{public}s",
                 colorSpace, trc, prim);
}

// Push the current XComponent surface size to mpv's OHOS VO.
//
// The project's AVPlayer uses an inline XComponent (no libraryname, no
// setXComponentSurfaceRect pinning) sized by .aspectRatio(); when it grows
// (e.g. entering fullscreen) the surface buffer geometry does NOT change in
// lock-step, and the rebuilt libmpv.so (GPU-only render path) no longer
// auto-detects the growth via VOCTRL_CHECK_EVENTS — its ohos_control returns
// VO_NOTIMPL for everything. So without explicitly pushing the new WxH here,
// the VO keeps rendering at the initial (small) geometry and the video lands
// pinned to the top-left corner of the now-larger surface.
//
// We set the run-time property "ohos-surface-size" (the property twin of the
// ohos_surface_size m_geometry option, parallel to android_surface_size).
// vo_ohos_surface_size() gives this option priority over GET_BUFFER_GEOMETRY,
// so the VO picks it up on the next reconfig/resize tick and reconfigures the
// Vulkan swapchain to the new dimensions. This mirrors how the official
// Android embedding keeps mpv in sync with SurfaceView layout changes.
void ApplySurfaceSize(PlayerContext& ctx)
{
    if (!ctx.mpv || ctx.surfaceWidth <= 0 || ctx.surfaceHeight <= 0) {
        return;
    }
    char buf[32];
    snprintf(buf, sizeof(buf), "%dx%d", ctx.surfaceWidth, ctx.surfaceHeight);
    if (ctx.initialized) {
        LogMpvError("ApplySurfaceSize set ohos-surface-size",
                    Mpv().set_property_string(ctx.mpv, "ohos-surface-size", buf));
    } else {
        LogMpvError("ApplySurfaceSize set ohos-surface-size option",
                    Mpv().set_option_string(ctx.mpv, "ohos-surface-size", buf));
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv",
                 "ApplySurfaceSize: %{public}dx%{public}d -> %{public}s",
                 ctx.surfaceWidth, ctx.surfaceHeight, buf);
}

void ApplyWindowOption(PlayerContext& ctx)
{
    if (!ctx.mpv) {
        return;
    }
    // mpv's OHOS VO expects "wid" to carry the XComponent *surfaceId* (a uint64
    // id), which it passes to OH_NativeWindow_CreateNativeWindowFromSurfaceId().
    // It must NOT be the native window pointer: feeding the pointer value as a
    // surfaceId makes that call fail (native_window ptr: 0 -> audio but no
    // video). So always use surfaceId here and never ctx.window.
    if (ctx.surfaceId.empty() || ctx.surfaceId == "0") {
        return;
    }
    if (ctx.initialized) {
        SetMpvStringProperty(ctx, "wid", ctx.surfaceId, "set surface id wid property");
    } else {
        LogMpvError("set surface id wid option", Mpv().set_option_string(ctx.mpv, "wid", ctx.surfaceId.c_str()));
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv", "wid=surfaceId=%{public}s", ctx.surfaceId.c_str());
}

bool EnsureMpv(PlayerContext& ctx)
{
    if (ctx.surfaceId.empty() || ctx.surfaceId == "0") {
        SetMediaStatus(ctx, ctx.mediaUrl.empty() ? kStatusNoMedia : kStatusLoading, "waiting-surface");
        return false;
    }

    if (!LoadMpv()) {
        SetMediaStatus(ctx, kStatusInvalid, "load-mpv-failed");
        return false;
    }

    if (!ctx.mpv) {
        ctx.mpv = Mpv().create();
        if (!ctx.mpv) {
            SetMediaStatus(ctx, kStatusInvalid, "mpv-create-failed");
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0xFF00, "mpv", "mpv_create failed");
            return false;
        }

        RegisterRawFileProtocol(ctx.mpv);
        SetOptionString(ctx.mpv, "terminal", "no");
        SetOptionString(ctx.mpv, "config", "no");
        SetOptionString(ctx.mpv, "idle", "yes");
        SetOptionString(ctx.mpv, "vo", "gpu-next");
        SetOptionString(ctx.mpv, "gpu-api", "vulkan");
        SetOptionString(ctx.mpv, "gpu-context", "ohosvk");
        SetOptionString(ctx.mpv, "ao", "ohaudio");
        SetOptionString(ctx.mpv, "hwdec", "ohcodec-copy");
        // Prefer OHCodec; lavc falls back to software when HW is missing.
        SetOptionString(ctx.mpv, "vd-lavc-software-fallback", "yes");
        SetOptionString(ctx.mpv, "hwdec-codecs", "h264,hevc,vp8,vp9,av1");
        // Cheap libplacebo path: rotate/fullscreen reconfig stays light.
        // video-sync=audio avoids display-resample GPU work; framedrop=vo
        // drops late frames under brief spikes instead of backlog stutter.
        SetOptionString(ctx.mpv, "scale", "bilinear");
        SetOptionString(ctx.mpv, "cscale", "bilinear");
        SetOptionString(ctx.mpv, "dscale", "bilinear");
        SetOptionString(ctx.mpv, "dither", "no");
        SetOptionString(ctx.mpv, "deband", "no");
        SetOptionString(ctx.mpv, "correct-downscaling", "no");
        SetOptionString(ctx.mpv, "linear-downscaling", "no");
        SetOptionString(ctx.mpv, "sigmoid-upscaling", "no");
        SetOptionString(ctx.mpv, "hdr-compute-peak", "no");
        SetOptionString(ctx.mpv, "video-sync", "audio");
        SetOptionString(ctx.mpv, "framedrop", "vo");
        // Soft VP9/AV1: skip loopfilter on non-keyframes (no quality hit on HW).
        SetOptionString(ctx.mpv, "vd-lavc-skiploopfilter", "nonkey");
        // Product path: vo=gpu-next + hwdec=ohcodec-copy.
        // Background audio-only uses vid=no at app layer, not a VO switch.
        SetOptionString(ctx.mpv, "keep-open", "yes");
        SetOptionString(ctx.mpv, "keep-open-pause", "yes");
        SetOptionString(ctx.mpv, "ytdl", "no");
        SetOptionString(ctx.mpv, "msg-level", "all=warn");
        SetOptionString(ctx.mpv, "osc", "no");
        SetOptionString(ctx.mpv, "input-default-bindings", "no");
        SetOptionString(ctx.mpv, "input-vo-keyboard", "no");
        // target-colorspace-hint=yes drives the native-window HDR path.
        //
        // The OHOS Vulkan WSI (Maleoon 920C) only offers SDR swapchain
        // colorspaces, but the swapchain image is still 10-bit
        // (A2B10G10R10) AND is backed by the same OHNativeWindow we tag for
        // HDR. The trick: vo_ohos_set_color() returns true for PQ/HLG sources,
        // which makes vo_gpu-next treat the hint as "external params" and set
        // the render target straight to PQ — bypassing the swapchain's SDR
        // colorspace and NOT tone-mapping (see set_colorspace_hint /
        // external_params in vo_gpu_next.c). libplacebo then writes true PQ into
        // the 10-bit buffer, while vo_ohos_set_color tags that native window
        // BT2020_PQ + HDR10 metadata + SOURCE_TYPE=VIDEO, so the compositor
        // displays it as real HDR.
        //
        // (The earlier "very dark" result came from the hint being on but the
        // surface NOT being routed to the HDR pipeline — the missing piece was
        // SET_SOURCE_TYPE=VIDEO, now set in vo_ohos_init.)
        SetOptionString(ctx.mpv, "target-colorspace-hint", "yes");
        // target-colorspace-hint-mode=source: tag the surface after the
        // *content's* colorspace, NOT the display capability.
        //
        // The default mode ("target") sets the render-target hint to the
        // display's preferred csp (vo_ohos_preferred_csp), which on an
        // HDR-capable panel is ALWAYS PQ/HDR10 regardless of what is playing.
        // That makes vo_ohos_set_color() tag SDR clips as BT2020_PQ too, so
        // libplacebo renders bt.709 content into a PQ target and the compositor
        // shows it inverse-tone-mapped — too bright, and visibly ramping as the
        // HDR peak-detect adapts ("dark -> bright on re-entry").
        //
        // "source" makes the hint follow the decoded frame:
        //  - SDR (bt.709/bt.1886) source -> hint is SDR -> set_color sees a
        //    non-HDR transfer, returns false -> normal SDR brightness.
        //  - HDR (PQ/HLG) source -> hint is PQ/HLG -> set_color tags the native
        //    window HDR and returns true -> real HDR output (unchanged).
        SetOptionString(ctx.mpv, "target-colorspace-hint-mode", "source");
        // IMPORTANT: do NOT set target-trc / target-prim here.
        //
        // vo_gpu-next applies opts->target_trc as a hard override of the
        // colorspace hint (vo_gpu_next.c: "if (opts->target_trc)
        // hint.transfer = opts->target_trc"). If we pinned target-trc=gamma2.2
        // at init, it would rewrite the PQ/HLG hint back to SDR gamma22, so
        // vo_ohos_set_color() would see a non-HDR transfer, return false, and
        // the true-HDR native-window path would never engage.
        //
        // Leaving them unset (UNKNOWN) lets the hint flow through as-is:
        //  - HDR source: hint = preferred_csp() = PQ/HLG -> set_color tags the
        //    native window HDR and returns true -> real HDR output.
        //  - SDR source / SDR display: libplacebo presents SDR normally.
        // A runtime override is still available via setColorSpace()
        // (ApplyColorSpace), e.g. to force SDR on HDR-broken hardware.
    }

    if (!ctx.initialized) {
        ApplyWindowOption(ctx);
        const int error = Mpv().initialize(ctx.mpv);
        if (error < 0) {
            LogMpvError("mpv_initialize", error);
            Mpv().destroy(ctx.mpv);
            ctx.mpv = nullptr;
            SetMediaStatus(ctx, kStatusInvalid, "mpv-initialize-failed");
            return false;
        }
        ctx.initialized = true;
        LogMpvError("request log messages", Mpv().request_log_messages(ctx.mpv, "v"));
        ObservePlaybackProperties(ctx);
        StartEventLoop(ctx);
        SetMediaStatus(ctx, ctx.mediaUrl.empty() ? kStatusNoMedia : kStatusLoading, "mpv-initialized");
    }

    return true;
}

void DestroyMpv(PlayerContext& ctx)
{
    ctx.pendingLoad = false;
    ctx.commandLoopRunning = false;
    {
        const scoped_lock lock(ctx.commandMutex);
        ctx.commandQueue.clear();
    }
    ctx.commandCv.notify_all();
    StopCommandLoop(ctx);
    StopEventLoop(ctx);
    if (ctx.mpv) {
        Mpv().terminate_destroy(ctx.mpv);
    }

    ctx.mpv = nullptr;
    ctx.initialized = false;
    ctx.window = nullptr;
    ctx.state.store(kStateStopped);
    SetMediaStatus(ctx, kStatusNoMedia, "destroy");
}

void SetPause(PlayerContext& ctx, bool pause)
{
    // MPV is the single source of truth. Do not publish the requested state here:
    // the command is asynchronous and may not have taken effect yet. The observed
    // "pause" property updates ctx.paused/ctx.state and emits the callback only
    // after MPV confirms the actual value.
    PostCommand(ctx, [pause](PlayerContext& workerCtx) {
        if (!EnsureMpv(workerCtx)) {
            return;
        }
        SetMpvFlagProperty(workerCtx, "pause", pause ? 1 : 0, "set pause");
    });
}

int32_t BuildMediaStatus(PlayerContext& ctx)
{
    return ctx.mediaUrl.empty() ? kStatusNoMedia : ctx.mediaStatus.load();
}

// OHOS DocumentPicker / "open from other apps" hand back a "file://docs/..."
// URI, not a real filesystem path. mpv's loadfile can't open that authority,
// so resolve it to a real path first (libmdk did the same via this API before
// the mpv migration). Non file:// inputs (http/https/rawfile/fd/...) pass
// through unchanged so mpv's own protocol handlers still apply.
string ResolveMediaUri(const string& url)
{
    if (url.rfind("file://", 0) != 0) {
        return url;
    }
    char* realPath = nullptr;
    FileManagement_ErrCode err =
        OH_FileUri_GetPathFromUri(url.c_str(), static_cast<unsigned int>(url.size()), &realPath);
    if (err == ERR_OK && realPath != nullptr) {
        string resolved(realPath);
        free(realPath);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv", "file uri %{public}s => %{public}s",
                     url.c_str(), resolved.c_str());
        return resolved;
    }
    OH_LOG_Print(LOG_APP, LOG_WARN, 0xFF00, "mpv", "OH_FileUri_GetPathFromUri failed for %{public}s", url.c_str());
    return url;
}

vector<string> BuildLoadFileCommand(const string& url, int64_t startPositionMs)
{
    vector<string> command {"loadfile", url, "replace"};
    if (startPositionMs > 0) {
        const string seconds = to_string(static_cast<double>(startPositionMs) / 1000.0);
        // mpv >= 0.38 reserves the third loadfile argument for a playlist index. The fourth
        // argument is a per-file option list. A leading '+' makes start relative to media start.
        command.push_back("-1");
        command.push_back("start=+" + seconds);
    }
    return command;
}

void LoadMedia(PlayerContext& ctx, const string& rawUrl, int64_t startPositionMs = 0)
{
    const string url = ResolveMediaUri(rawUrl);
    ctx.mediaUrl = url;
    ctx.mediaStartPositionMs = max<int64_t>(0, startPositionMs);
    ctx.pendingLoad = false;
    ctx.lastPositionMs.store(0);
    ctx.lastDurationMs.store(0);
    ctx.lastBufferedMs.store(0);
    if (url.empty()) {
        ctx.state.store(kStateStopped);
        SetMediaStatus(ctx, kStatusNoMedia, "load-empty");
        PostCommand(ctx, [](PlayerContext& workerCtx) {
            if (!EnsureMpv(workerCtx)) {
                return;
            }
            RunMpvCommand(workerCtx, {"stop"}, "stop");
        });
        return;
    }

    if (ctx.surfaceId.empty() || ctx.surfaceId == "0") {
        ctx.pendingLoad = true;
        SetMediaStatus(ctx, kStatusLoading | kStatusBuffering | kStatusStalled, "load-pending-surface");
        return;
    }

    SetMediaStatus(ctx, kStatusLoading | kStatusBuffering | kStatusStalled, "loadfile-start");
    const int64_t requestedStartMs = ctx.mediaStartPositionMs;
    PostCommand(ctx, [url, requestedStartMs](PlayerContext& workerCtx) {
        if (!EnsureMpv(workerCtx)) {
            return;
        }
        RunMpvCommand(workerCtx, BuildLoadFileCommand(url, requestedStartMs), "loadfile");
    });
}

void SetStringProperty(PlayerContext& ctx, const char* key, const string& value)
{
    const string property = key ? key : "";
    PostCommand(ctx, [property, value](PlayerContext& workerCtx) {
        if (!EnsureMpv(workerCtx)) {
            return;
        }
        SetMpvStringProperty(workerCtx, property.c_str(), value, property.c_str());
    });
}

// Lock gMutex, ensure player context exists, then call f(ctx).
auto lockFor(const string& id, auto&& f)
{
    const scoped_lock lock(gMutex);
    auto& player = gPlayers[id];
    if (!player) {
        player = make_unique<PlayerContext>();
    }
    auto& ctx = *player;
    if constexpr (is_invocable_v<decltype(f), PlayerContext&>) {
        return f(ctx);
    }
}

// Lock gMutex and call f(ctx) only if the context already exists.
void lockFind(const string& id, auto&& f)
{
    const scoped_lock lock(gMutex);
    if (auto it = gPlayers.find(id); it != gPlayers.end() && it->second) {
        f(*it->second);
    }
}

template<class Container>
Container FromArray(napi_env env, napi_value value)
{
    Container result;
    bool isArray = false;
    napi_is_array(env, value, &isArray);
    if (!isArray) {
        return result;
    }

    uint32_t length = 0;
    napi_get_array_length(env, value, &length);
    for (uint32_t index = 0; index < length; ++index) {
        napi_value item = nullptr;
        napi_get_element(env, value, index, &item);
        if constexpr (is_same_v<typename Container::value_type, int>) {
            int32_t v = 0;
            napi_get_value_int32(env, item, &v);
            result.insert(result.end(), v);
        }
        if constexpr (is_same_v<typename Container::value_type, string>) {
            result.insert(result.end(), ToString(env, item));
        }
    }
    return result;
}

string IdOf(OH_NativeXComponent* component)
{
    char id[OH_XCOMPONENT_ID_LEN_MAX + 1] = {};
    uint64_t idLength = OH_XCOMPONENT_ID_LEN_MAX + 1;
    OH_NativeXComponent_GetXComponentId(component, id, &idLength);
    return id;
}

void OnSurfaceCreated(OH_NativeXComponent* component, void* window)
{
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    const auto id = IdOf(component);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv", "surface created id=%{public}s window=%{public}p size=%{public}llu x %{public}llu",
                 id.c_str(), window, static_cast<unsigned long long>(width), static_cast<unsigned long long>(height));
    lockFor(id, [=](PlayerContext& ctx) {
        ctx.window = window;
        ctx.surfaceWidth = static_cast<int32_t>(width);
        ctx.surfaceHeight = static_cast<int32_t>(height);
    });
}

void OnSurfaceChanged(OH_NativeXComponent* component, void* window)
{
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    const auto id = IdOf(component);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv", "surface changed id=%{public}s window=%{public}p size=%{public}llu x %{public}llu",
                 id.c_str(), window, static_cast<unsigned long long>(width), static_cast<unsigned long long>(height));
    lockFind(id, [=](PlayerContext& ctx) {
        ctx.window = window;
        ctx.surfaceWidth = static_cast<int32_t>(width);
        ctx.surfaceHeight = static_cast<int32_t>(height);
        // Propagate the new size to mpv so the VO reconfigures (and re-tags HDR)
        // instead of leaving the video at its old geometry.
        ApplySurfaceSize(ctx);
    });
}

void OnSurfaceDestroyed(OH_NativeXComponent* component, void* /*window*/)
{
    lockFind(IdOf(component), [](PlayerContext& ctx) {
        ctx.window = nullptr;
    });
}

napi_value SetVideoSurfaceSize(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t width = 0;
    int32_t height = 0;
    napi_get_value_int32(env, args[1], &width);
    napi_get_value_int32(env, args[2], &height);
    const auto id = ToString(env, args[0]);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv", "surface size id=%{public}s size=%{public}d x %{public}d",
                 id.c_str(), width, height);
    lockFor(id, [=](PlayerContext& ctx) {
        if (width > 0 && height > 0) {
            ctx.surfaceWidth = width;
            ctx.surfaceHeight = height;
            ApplySurfaceSize(ctx);
        }
    });
    return Undefined(env);
}

napi_value SetVideoSurfaceId(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const string surfaceId = argc > 1 ? ToString(env, args[1]) : "";
    const auto id = ToString(env, args[0]);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv", "surface id id=%{public}s surface=%{public}s",
                 id.c_str(), surfaceId.c_str());
    lockFor(id, [&](PlayerContext& ctx) {
        const string previousSurfaceId = ctx.surfaceId;
        const bool surfaceChanged = !surfaceId.empty() && surfaceId != "0" && surfaceId != previousSurfaceId;
        if (!surfaceId.empty() && surfaceId != "0") {
            ctx.surfaceId = surfaceId;
        }
        if (!ctx.pendingLoad || ctx.mediaUrl.empty()) {
            // Runtime surface redirect (e.g. PiP restore: a brand-new XComponent
            // hands us a fresh surfaceId while mpv is already initialized and
            // playing). The first-load path below never runs here because
            // pendingLoad is false once playback has started, so without this
            // branch mpv keeps rendering to the old (gone) surface -> black.
            //
            // Re-push the new surfaceId into mpv's "wid" option. This fork tags
            // "wid" with UPDATE_VO (mpv commit 8b0b186 "options: handle runtime
            // wid change"), so changing it makes mpv tear down the whole VO
            // (uninit_video_out) and rebuild it (reinit_video_chain) against the
            // new surface, then auto queue_seek to the current position to
            // present a frame — see player/command.c UPDATE_VO handler. That
            // built-in seek is why we do NOT issue our own here. Cost: the
            // decoder is also recreated, so expect a brief stall (acceptable,
            // usually hidden by the PiP restore animation).
            if (surfaceChanged && ctx.initialized && ctx.mpv) {
                OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv",
                             "surface redirect old=%{public}s new=%{public}s (UPDATE_VO)",
                             previousSurfaceId.c_str(), surfaceId.c_str());
                PostCommand(ctx, [](PlayerContext& workerCtx) {
                    ApplyWindowOption(workerCtx);
                });
            }
            return;
        }
        const string url = ctx.mediaUrl;
        const int64_t requestedStartMs = ctx.mediaStartPositionMs;
        SetMediaStatus(ctx, kStatusLoading | kStatusBuffering | kStatusStalled, "load-pending-start");
        ctx.pendingLoad = false;
        PostCommand(ctx, [url, requestedStartMs](PlayerContext& workerCtx) {
            if (EnsureMpv(workerCtx)) {
                ApplyWindowOption(workerCtx);
                RunMpvCommand(workerCtx, BuildLoadFileCommand(url, requestedStartMs), "loadfile");
            }
        });
    });
    return Undefined(env);
}

napi_value EnsurePlayer(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    lockFor(ToString(env, args[0]), [](PlayerContext& ctx) {
        PostCommand(ctx, [](PlayerContext& workerCtx) { EnsureMpv(workerCtx); });
    });
    return Undefined(env);
}

napi_value ReleasePlayer(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto id = ToString(env, args[0]);
    unique_ptr<PlayerContext> player;
    {
        const scoped_lock lock(gMutex);
        auto it = gPlayers.find(id);
        if (it != gPlayers.end()) {
            player = move(it->second);
            gPlayers.erase(it);
        }
    }
    if (player) {
        if (player->tsfn) {
            napi_release_threadsafe_function(player->tsfn, napi_tsfn_release);
            player->tsfn = nullptr;
        }
        DestroyMpv(*player);
    }
    return Undefined(env);
}

napi_value SetMedia(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const string url = ToString(env, args[1]);
    int64_t startPositionMs = 0;
    if (argc > 2) {
        napi_get_value_int64(env, args[2], &startPositionMs);
    }
    lockFor(ToString(env, args[0]), [&](PlayerContext& ctx) {
        LoadMedia(ctx, url, startPositionMs);
    });
    return Undefined(env);
}

napi_value SetMediaSource(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const string url = ToString(env, args[1]);
    lockFor(ToString(env, args[0]), [&](PlayerContext& ctx) { LoadMedia(ctx, url); });
    return Undefined(env);
}

napi_value Play(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    lockFor(ToString(env, args[0]), [](PlayerContext& ctx) { SetPause(ctx, false); });
    return Undefined(env);
}

napi_value Pause(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    lockFor(ToString(env, args[0]), [](PlayerContext& ctx) { SetPause(ctx, true); });
    return Undefined(env);
}

napi_value Stop(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    lockFor(ToString(env, args[0]), [](PlayerContext& ctx) {
        PostCommand(ctx, [](PlayerContext& workerCtx) {
            if (!EnsureMpv(workerCtx)) {
                return;
            }
            RunMpvCommand(workerCtx, {"stop"}, "stop");
        });
    });
    return Undefined(env);
}

napi_value Prepare(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t startPosition = 0;
    if (argc > 1) {
        napi_get_value_int64(env, args[1], &startPosition);
    }
    lockFor(ToString(env, args[0]), [=](PlayerContext& ctx) {
        if (startPosition > 0) {
            const string seconds = to_string(static_cast<double>(startPosition) / 1000.0);
            SetTransientBuffering(ctx, true, "prepare-seek-start");
            PostCommand(ctx, [seconds](PlayerContext& workerCtx) {
                if (!EnsureMpv(workerCtx)) {
                    return;
                }
                RunMpvCommand(workerCtx, {"seek", seconds, "absolute+exact"}, "seek");
            });
        }
        ctx.mediaStatus.fetch_or(kStatusPrepared);
    });
    return Undefined(env);
}

napi_value Seek(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t ms = 0;
    napi_get_value_int64(env, args[1], &ms);
    lockFor(ToString(env, args[0]), [=](PlayerContext& ctx) {
        const string seconds = to_string(static_cast<double>(ms) / 1000.0);
        SetTransientBuffering(ctx, true, "seek-command-start");
        PostCommand(ctx, [seconds](PlayerContext& workerCtx) {
            if (!EnsureMpv(workerCtx)) {
                return;
            }
            RunMpvCommand(workerCtx, {"seek", seconds, "absolute+exact"}, "seek");
        });
    });
    return Undefined(env);
}

napi_value SeekWithFlags(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t ms = 0;
    napi_get_value_int64(env, args[1], &ms);
    lockFor(ToString(env, args[0]), [=](PlayerContext& ctx) {
        const string seconds = to_string(static_cast<double>(ms) / 1000.0);
        SetTransientBuffering(ctx, true, "seek-flags-command-start");
        PostCommand(ctx, [seconds](PlayerContext& workerCtx) {
            if (!EnsureMpv(workerCtx)) {
                return;
            }
            RunMpvCommand(workerCtx, {"seek", seconds, "absolute+exact"}, "seek");
        });
    });
    return Undefined(env);
}

napi_value SetPlaybackRate(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double rate = 1.0;
    napi_get_value_double(env, args[1], &rate);
    lockFor(ToString(env, args[0]), [=](PlayerContext& ctx) {
        PostCommand(ctx, [rate](PlayerContext& workerCtx) {
            if (!EnsureMpv(workerCtx)) {
                return;
            }
            SetMpvDoubleProperty(workerCtx, "speed", rate, "set speed");
        });
    });
    return Undefined(env);
}

napi_value SetVolume(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double volume = 1.0;
    napi_get_value_double(env, args[1], &volume);
    lockFor(ToString(env, args[0]), [=](PlayerContext& ctx) {
        double mpvVolume = volume <= 1.0 ? volume * 100.0 : volume;
        PostCommand(ctx, [mpvVolume](PlayerContext& workerCtx) {
            if (!EnsureMpv(workerCtx)) {
                return;
            }
            SetMpvDoubleProperty(workerCtx, "volume", mpvVolume, "set volume");
        });
    });
    return Undefined(env);
}

napi_value SetLoop(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t count = 0;
    napi_get_value_int32(env, args[1], &count);
    lockFor(ToString(env, args[0]), [=](PlayerContext& ctx) {
        ctx.loopCount = count;
        if (count < 0) {
            SetStringProperty(ctx, "loop-file", "inf");
        } else if (count == 0) {
            SetStringProperty(ctx, "loop-file", "no");
        } else {
            SetStringProperty(ctx, "loop-file", to_string(count));
        }
    });
    return Undefined(env);
}

napi_value SetProperty(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto key = ToString(env, args[1]);
    const auto value = ToString(env, args[2]);
    lockFor(ToString(env, args[0]), [&](PlayerContext& ctx) { SetStringProperty(ctx, key.c_str(), value); });
    return Undefined(env);
}

napi_value GetProperty(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value result = nullptr;
    napi_create_string_utf8(env, "", 0, &result);
    return result;
}

napi_value MpvCommand(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t cmdArgc = 0;
    napi_get_array_length(env, args[1], &cmdArgc);
    vector<string> cmdArgs;
    cmdArgs.reserve(cmdArgc);
    for (uint32_t i = 0; i < cmdArgc; ++i) {
        napi_value element = nullptr;
        napi_get_element(env, args[1], i, &element);
        cmdArgs.push_back(ToString(env, element));
    }
    lockFor(ToString(env, args[0]), [cmdArgs = move(cmdArgs)](PlayerContext& ctx) {
        PostCommand(ctx, [cmdArgs](PlayerContext& workerCtx) {
            if (!EnsureMpv(workerCtx)) return;
            RunMpvCommand(workerCtx, cmdArgs, cmdArgs.empty() ? "command" : cmdArgs[0].c_str());
        });
    });
    return Undefined(env);
}

napi_value SetColorSpace(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t colorSpace = 0;
    napi_get_value_int32(env, args[1], &colorSpace);
    lockFor(ToString(env, args[0]), [=](PlayerContext& ctx) {
        PostCommand(ctx, [colorSpace](PlayerContext& workerCtx) {
            if (!EnsureMpv(workerCtx)) {
                return;
            }
            ApplyColorSpace(workerCtx, colorSpace);
        });
    });
    return Undefined(env);
}

napi_value SetVideoEffect(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t effect = 0;
    double value = 0;
    napi_get_value_int32(env, args[1], &effect);
    napi_get_value_double(env, args[2], &value);

    const char* property = nullptr;
    switch (effect) {
    case 0: property = "brightness"; break;
    case 1: property = "contrast"; break;
    case 2: property = "hue"; break;
    case 3: property = "saturation"; break;
    default: break;
    }

    if (property) {
        lockFor(ToString(env, args[0]), [=](PlayerContext& ctx) {
            const string prop = property;
            PostCommand(ctx, [prop, value](PlayerContext& workerCtx) {
                if (!EnsureMpv(workerCtx)) {
                    return;
                }
                SetMpvDoubleProperty(workerCtx, prop.c_str(), value, prop.c_str());
            });
        });
    }
    return Undefined(env);
}

napi_value SetDecoders(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t mediaType = 0;
    napi_get_value_int32(env, args[1], &mediaType);
    const auto decoders = FromArray<vector<string>>(env, args[2]);
    if (mediaType == kMediaTypeVideo && !decoders.empty()) {
        lockFor(ToString(env, args[0]), [&](PlayerContext& ctx) { SetStringProperty(ctx, "vd-lavc-software-fallback", "yes"); });
    }
    return Undefined(env);
}

napi_value SetActiveTracks(napi_env env, napi_callback_info info)
{
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t mediaType = 0;
    napi_get_value_int32(env, args[1], &mediaType);
    const auto tracks = FromArray<set<int>>(env, args[2]);

    const char* property = nullptr;
    if (mediaType == kMediaTypeVideo) {
        property = "vid";
    } else if (mediaType == kMediaTypeAudio) {
        property = "aid";
    } else if (mediaType == kMediaTypeSubtitle) {
        property = "sid";
    }

    if (property) {
        const string value = tracks.empty() ? "no" : to_string(*tracks.begin() + 1);
        lockFor(ToString(env, args[0]), [&](PlayerContext& ctx) { SetStringProperty(ctx, property, value); });
    }
    return Undefined(env);
}

napi_value SetAudioBackends(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto backends = FromArray<vector<string>>(env, args[1]);
    if (!backends.empty()) {
        lockFor(ToString(env, args[0]), [&](PlayerContext& ctx) { SetStringProperty(ctx, "ao", backends.front()); });
    }
    return Undefined(env);
}

napi_value GetPosition(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto pos = lockFor(ToString(env, args[0]), [](PlayerContext& ctx) {
        return ctx.lastPositionMs.load();
    });
    napi_value result = nullptr;
    napi_create_int64(env, pos, &result);
    return result;
}

napi_value Buffered(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto buf = lockFor(ToString(env, args[0]), [](PlayerContext& ctx) {
        return ctx.lastBufferedMs.load();
    });
    napi_value result = nullptr;
    napi_create_int64(env, buf, &result);
    return result;
}

napi_value GetSeekableRangesJson(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto json = lockFor(ToString(env, args[0]), [](PlayerContext& ctx) {
        const scoped_lock lock(ctx.cacheRangesMutex);
        return ctx.seekableRangesJson;
    });
    napi_value result = nullptr;
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value GetState(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto state = lockFor(ToString(env, args[0]), [](PlayerContext& ctx) {
        return ctx.mediaUrl.empty() ? kStateStopped : ctx.state.load();
    });
    napi_value result = nullptr;
    napi_create_int32(env, state, &result);
    return result;
}

napi_value GetMediaStatus(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto status = lockFor(ToString(env, args[0]), [](PlayerContext& ctx) {
        return BuildMediaStatus(ctx);
    });
    napi_value result = nullptr;
    napi_create_int32(env, status, &result);
    return result;
}

napi_value GetMediaInfo(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t duration = 0;
    MpvPropReader reader;
    lockFor(ToString(env, args[0]), [&](PlayerContext& ctx) {
        duration = ctx.lastDurationMs.load();
        mpv_handle* handle = ctx.mpv;
        // Capture by value: the reader is used synchronously below, still under
        // the player lock, so the handle stays valid.
        reader = [handle](const char* name) -> std::string {
            if (!handle || !Mpv().get_property_string) return {};
            char* val = Mpv().get_property_string(handle, name);
            if (!val) return {};
            std::string out(val);
            Mpv().free(val);
            return out;
        };
        // Build the info object while still holding the lock and the handle.
        // (MediaInfoToNapi only reads; no mpv state is mutated.)
    });
    if (!reader) {
        reader = [](const char*) -> std::string { return {}; };
    }
    return MediaInfoToNapi(env, duration, reader);
}

napi_value GetDuration(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto dur = lockFor(ToString(env, args[0]), [](PlayerContext& ctx) {
        return ctx.lastDurationMs.load();
    });
    napi_value result = nullptr;
    napi_create_int64(env, dur, &result);
    return result;
}

napi_value SetEventCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value resourceName;
    napi_create_string_utf8(env, "mpvEvent", NAPI_AUTO_LENGTH, &resourceName);
    lockFor(ToString(env, args[0]), [&](PlayerContext& ctx) {
        if (ctx.tsfn) {
            napi_release_threadsafe_function(ctx.tsfn, napi_tsfn_release);
            ctx.tsfn = nullptr;
        }
        napi_create_threadsafe_function(env, args[1], nullptr, resourceName, 0, 1,
            nullptr, nullptr, nullptr,
            [](napi_env tEnv, napi_value jsCb, void*, void* data) {
                auto* evt = static_cast<TsfnEvent*>(data);
                napi_value argv[2];
                napi_create_int32(tEnv, evt->type, &argv[0]);
                napi_create_int64(tEnv, evt->value, &argv[1]);
                napi_value global;
                napi_get_global(tEnv, &global);
                napi_call_function(tEnv, global, jsCb, 2, argv, nullptr);
                delete evt;
            }, &ctx.tsfn);
    });
    return Undefined(env);
}

napi_value IsPlaying(napi_env env, napi_callback_info info)
{
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto playing = lockFor(ToString(env, args[0]), [](PlayerContext& ctx) {
        return !ctx.mediaUrl.empty() && ctx.state.load() == kStatePlaying;
    });
    napi_value result = nullptr;
    napi_get_boolean(env, playing, &result);
    return result;
}

// Link probe: returns the FFmpeg build/version string. Confirms the libav*
// static libs link and call correctly before we build the real mux feature.
napi_value FfmpegVersion(napi_env env, napi_callback_info /*info*/)
{
    const char* info = av_version_info();
    unsigned int v = avformat_version();
    char buf[256];
    snprintf(buf, sizeof(buf), "ffmpeg %s (avformat %u.%u.%u)",
             info ? info : "?", v >> 16, (v >> 8) & 0xff, v & 0xff);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv", "ffmpeg probe: %{public}s", buf);
    napi_value result = nullptr;
    napi_create_string_utf8(env, buf, NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    RegisterLogHandlerOnce();
    // Auto-probe on module load: proves the ffmpeg static libs linked and are
    // callable. Look for "ffmpeg probe:" in the log right after app start —
    // no frontend call needed.
    {
        const char* ver = av_version_info();
        unsigned int v = avformat_version();
        OH_LOG_Print(LOG_APP, LOG_INFO, 0xFF00, "mpv",
                     "ffmpeg probe: %{public}s (avformat %u.%u.%u)",
                     ver ? ver : "?", v >> 16, (v >> 8) & 0xff, v & 0xff);
    }
    // One-shot VPE capability probe: logs whether this device's Video
    // Processing Engine supports HDR color-space conversion / metadata
    // generation, deciding whether true-HDR output via VPE is achievable.
    // Look for "vpe probe:" in the log right after app start.
    ProbeVpeCapabilities();
    bool hasXComponent = false;
    if (napi_has_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &hasXComponent) == napi_ok && hasXComponent) {
        napi_value xcompInstance = nullptr;
        if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xcompInstance) == napi_ok) {
            napi_valuetype valueType = napi_undefined;
            napi_typeof(env, xcompInstance, &valueType);
            if (valueType != napi_undefined && valueType != napi_null) {
                OH_NativeXComponent* nativeXComponent = nullptr;
                napi_unwrap(env, xcompInstance, (void**)&nativeXComponent);
                if (nativeXComponent) {
                    lockFor(IdOf(nativeXComponent), nullptr);

                    static OH_NativeXComponent_Callback callbacks {};
                    callbacks.OnSurfaceCreated = OnSurfaceCreated;
                    callbacks.OnSurfaceChanged = OnSurfaceChanged;
                    callbacks.OnSurfaceDestroyed = OnSurfaceDestroyed;
                    callbacks.DispatchTouchEvent = nullptr;
                    OH_NativeXComponent_RegisterCallback(nativeXComponent, &callbacks);
                }
            }
        }
    }

    napi_property_descriptor descriptors[] = {
        {"ensurePlayer", nullptr, EnsurePlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releasePlayer", nullptr, ReleasePlayer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMedia", nullptr, SetMedia, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMediaSource", nullptr, SetMediaSource, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"play", nullptr, Play, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pause", nullptr, Pause, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"prepare", nullptr, Prepare, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"seek", nullptr, Seek, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"seekWithFlags", nullptr, SeekWithFlags, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPlaybackRate", nullptr, SetPlaybackRate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVolume", nullptr, SetVolume, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setLoop", nullptr, SetLoop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setProperty", nullptr, SetProperty, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getProperty", nullptr, GetProperty, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setColorSpace", nullptr, SetColorSpace, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVideoEffect", nullptr, SetVideoEffect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setDecoders", nullptr, SetDecoders, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setActiveTracks", nullptr, SetActiveTracks, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setAudioBackends", nullptr, SetAudioBackends, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPosition", nullptr, GetPosition, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buffered", nullptr, Buffered, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSeekableRangesJson", nullptr, GetSeekableRangesJson, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getState", nullptr, GetState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMediaStatus", nullptr, GetMediaStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMediaInfo", nullptr, GetMediaInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isPlaying", nullptr, IsPlaying, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVideoSurfaceSize", nullptr, SetVideoSurfaceSize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setVideoSurfaceId", nullptr, SetVideoSurfaceId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"ffmpegVersion", nullptr, FfmpegVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setGlobalOptionString", nullptr, SetGlobalOptionString, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getGlobalOptionString", nullptr, GetGlobalOptionString, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setGlobalOptionInt", nullptr, SetGlobalOptionInt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getGlobalOptionInt", nullptr, GetGlobalOptionInt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setGlobalOptionFloat", nullptr, SetGlobalOptionFloat, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setResourceManager", nullptr, SetResourceManager, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDuration", nullptr, GetDuration, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEventCallback", nullptr, SetEventCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"command", nullptr, MpvCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, std::size(descriptors), descriptors);
    RegisterMuxModule(env, exports);
    RegisterHwdecProbeModule(env, exports);
    return exports;
}

NAPI_MODULE(mdk_napi, Init)

} // namespace
