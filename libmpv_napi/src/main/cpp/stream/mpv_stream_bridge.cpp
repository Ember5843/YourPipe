#include "mpv_stream_bridge.h"
#include "hls_live_stream.h"
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <hilog/log.h>

namespace yp_stream {

namespace {

constexpr unsigned int kLogDomain = 0xFF00;
constexpr const char* kLogTag = "mpv-stream";
constexpr const char* kDefaultUserAgent = "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36";

// --- Minimal self-contained JSON value & parser (no third-party dependency) ---

struct JsonVal {
    enum class Type { Null, Bool, Number, String, Array, Object };
    Type type = Type::Null;
    bool b = false;
    double n = 0.0;
    std::string s;
    std::vector<JsonVal> arr;
    std::map<std::string, JsonVal> obj;

    const JsonVal* Get(const std::string& key) const
    {
        if (type != Type::Object) return nullptr;
        auto it = obj.find(key);
        return (it != obj.end()) ? &it->second : nullptr;
    }
    std::string Str(const std::string& key, const std::string& def = "") const
    {
        const JsonVal* v = Get(key);
        return (v && v->type == Type::String) ? v->s : def;
    }
    int64_t Int64(const std::string& key, int64_t def = 0) const
    {
        const JsonVal* v = Get(key);
        return (v && v->type == Type::Number) ? static_cast<int64_t>(v->n) : def;
    }
    int32_t Int32(const std::string& key, int32_t def = 0) const
    {
        return static_cast<int32_t>(Int64(key, def));
    }
    bool Bool(const std::string& key, bool def = false) const
    {
        const JsonVal* v = Get(key);
        return (v && v->type == JsonVal::Type::Bool) ? v->b : def;
    }
};

class MiniJsonParser {
public:
    explicit MiniJsonParser(const std::string& src) : s_(src) {}

    bool Parse(JsonVal& out)
    {
        SkipWs();
        if (!ParseValue(out)) return false;
        SkipWs();
        return pos_ == s_.size();
    }

private:
    void SkipWs()
    {
        while (pos_ < s_.size() && std::isspace(static_cast<unsigned char>(s_[pos_]))) {
            ++pos_;
        }
    }

    bool ParseValue(JsonVal& out)
    {
        SkipWs();
        if (pos_ >= s_.size()) return false;
        const char ch = s_[pos_];
        if (ch == '"') {
            out = JsonVal{};
            out.type = JsonVal::Type::String;
            return ParseString(out.s);
        }
        if (ch == '{') return ParseObject(out);
        if (ch == '[') return ParseArray(out);
        if (ch == 't' && s_.compare(pos_, 4, "true") == 0) {
            pos_ += 4;
            out = JsonVal{};
            out.type = JsonVal::Type::Bool;
            out.b = true;
            return true;
        }
        if (ch == 'f' && s_.compare(pos_, 5, "false") == 0) {
            pos_ += 5;
            out = JsonVal{};
            out.type = JsonVal::Type::Bool;
            out.b = false;
            return true;
        }
        if (ch == 'n' && s_.compare(pos_, 4, "null") == 0) {
            pos_ += 4;
            out = JsonVal{};
            out.type = JsonVal::Type::Null;
            return true;
        }
        if (ch == '-' || std::isdigit(static_cast<unsigned char>(ch))) {
            return ParseNumber(out);
        }
        return false;
    }

    bool ParseString(std::string& out)
    {
        if (pos_ >= s_.size() || s_[pos_] != '"') return false;
        ++pos_;
        out.clear();
        while (pos_ < s_.size()) {
            char c = s_[pos_++];
            if (c == '"') return true;
            if (c == '\\') {
                if (pos_ >= s_.size()) return false;
                char esc = s_[pos_++];
                switch (esc) {
                    case '"': out.push_back('"'); break;
                    case '\\': out.push_back('\\'); break;
                    case '/': out.push_back('/'); break;
                    case 'b': out.push_back('\b'); break;
                    case 'f': out.push_back('\f'); break;
                    case 'n': out.push_back('\n'); break;
                    case 'r': out.push_back('\r'); break;
                    case 't': out.push_back('\t'); break;
                    case 'u': {
                        if (pos_ + 4 > s_.size()) return false;
                        unsigned int code = 0;
                        for (int i = 0; i < 4; ++i) {
                            char h = s_[pos_++];
                            code <<= 4;
                            if (h >= '0' && h <= '9') code |= static_cast<unsigned int>(h - '0');
                            else if (h >= 'a' && h <= 'f') code |= static_cast<unsigned int>(h - 'a' + 10);
                            else if (h >= 'A' && h <= 'F') code |= static_cast<unsigned int>(h - 'A' + 10);
                            else return false;
                        }
                        if (code < 0x80) {
                            out.push_back(static_cast<char>(code));
                        } else if (code < 0x800) {
                            out.push_back(static_cast<char>(0xC0 | (code >> 6)));
                            out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                        } else {
                            out.push_back(static_cast<char>(0xE0 | (code >> 12)));
                            out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
                            out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                        }
                        break;
                    }
                    default: out.push_back(esc); break;
                }
            } else {
                out.push_back(c);
            }
        }
        return false;
    }

    bool ParseNumber(JsonVal& out)
    {
        const char* start = s_.c_str() + pos_;
        char* end = nullptr;
        double val = std::strtod(start, &end);
        if (end == start) return false;
        pos_ = static_cast<size_t>(end - s_.c_str());
        out = JsonVal{};
        out.type = JsonVal::Type::Number;
        out.n = val;
        return true;
    }

    bool ParseArray(JsonVal& out)
    {
        ++pos_; // '['
        out = JsonVal{};
        out.type = JsonVal::Type::Array;
        SkipWs();
        if (pos_ < s_.size() && s_[pos_] == ']') {
            ++pos_;
            return true;
        }
        while (pos_ < s_.size()) {
            JsonVal elem;
            if (!ParseValue(elem)) return false;
            out.arr.push_back(std::move(elem));
            SkipWs();
            if (pos_ < s_.size() && s_[pos_] == ',') {
                ++pos_;
                continue;
            }
            if (pos_ < s_.size() && s_[pos_] == ']') {
                ++pos_;
                return true;
            }
            return false;
        }
        return false;
    }

    bool ParseObject(JsonVal& out)
    {
        ++pos_; // '{'
        out = JsonVal{};
        out.type = JsonVal::Type::Object;
        SkipWs();
        if (pos_ < s_.size() && s_[pos_] == '}') {
            ++pos_;
            return true;
        }
        while (pos_ < s_.size()) {
            SkipWs();
            std::string key;
            if (!ParseString(key)) return false;
            SkipWs();
            if (pos_ >= s_.size() || s_[pos_] != ':') return false;
            ++pos_;
            JsonVal val;
            if (!ParseValue(val)) return false;
            out.obj[std::move(key)] = std::move(val);
            SkipWs();
            if (pos_ < s_.size() && s_[pos_] == ',') {
                ++pos_;
                continue;
            }
            if (pos_ < s_.size() && s_[pos_] == '}') {
                ++pos_;
                return true;
            }
            return false;
        }
        return false;
    }

    const std::string& s_;
    size_t pos_ = 0;
};

struct StreamCookie {
    std::string streamId;
    std::shared_ptr<IStreamSource> source;
    int64_t pos = 0;
};

int64_t MpvStreamReadCb(void* cookiePtr, char* buf, uint64_t nbytes)
{
    auto* cookie = static_cast<StreamCookie*>(cookiePtr);
    if (!cookie || !cookie->source || !buf || nbytes == 0) {
        return -1;
    }
    const int64_t n = cookie->source->ReadAt(cookie->pos, reinterpret_cast<uint8_t*>(buf), static_cast<size_t>(nbytes));
    if (n > 0) {
        cookie->pos += n;
        return n;
    }
    if (n == 0) {
        return 0; // EOF
    }
    return -1;
}

int64_t MpvStreamSeekCb(void* cookiePtr, int64_t offset)
{
    auto* cookie = static_cast<StreamCookie*>(cookiePtr);
    if (!cookie || !cookie->source || offset < 0) {
        return MPV_ERROR_GENERIC;
    }
    const int64_t sz = cookie->source->GetSize();
    if (sz >= 0 && offset > sz) {
        return MPV_ERROR_GENERIC;
    }
    cookie->pos = offset;
    return offset;
}

int64_t MpvStreamSizeCb(void* cookiePtr)
{
    auto* cookie = static_cast<StreamCookie*>(cookiePtr);
    if (!cookie || !cookie->source) {
        return MPV_ERROR_UNSUPPORTED;
    }
    const int64_t sz = cookie->source->GetSize();
    return sz >= 0 ? sz : MPV_ERROR_UNSUPPORTED;
}

void MpvStreamCancelCb(void* cookiePtr)
{
    auto* cookie = static_cast<StreamCookie*>(cookiePtr);
    if (cookie && cookie->source) {
        cookie->source->Cancel();
    }
}

void MpvStreamCloseCb(void* cookiePtr)
{
    auto* cookie = static_cast<StreamCookie*>(cookiePtr);
    if (!cookie) return;
    if (cookie->source) {
        cookie->source->Close();
    }
    delete cookie;
}

} // namespace

MpvStreamBridge& MpvStreamBridge::Instance()
{
    static MpvStreamBridge instance;
    return instance;
}

MpvStreamBridge::MpvStreamBridge()
{
    http_ = std::make_shared<NativeHttpTransport>();
    bwEst_ = std::make_shared<BandwidthEstimator>();
    loadCtrl_ = std::make_shared<LoadController>();
    counters_ = std::make_shared<SharedStreamCounters>();
}

std::string MpvStreamBridge::ExtractStreamId(const std::string& urlOrId)
{
    std::string id = urlOrId;
    const std::string prefix = "ypstream://";
    if (id.rfind(prefix, 0) == 0) {
        id = id.substr(prefix.size());
    }
    const size_t cut = id.find_first_of("?#/");
    if (cut != std::string::npos) {
        id = id.substr(0, cut);
    }
    return id;
}

std::string MpvStreamBridge::RegisterDirectStreamJson(const std::string& specJson)
{
    JsonVal root;
    MiniJsonParser parser(specJson);
    if (!parser.Parse(root) || root.type != JsonVal::Type::Object) {
        OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag, "RegisterDirectStreamJson: invalid JSON");
        return "";
    }

    DirectStreamSpec spec;
    spec.url = root.Str("url");
    if (spec.url.empty()) {
        return "";
    }
    spec.userAgent = root.Str("userAgent", kDefaultUserAgent);
    spec.contentLength = root.Int64("contentLength", -1);
    spec.initRangeStart = root.Int64("initRangeStart", -1);
    spec.initRangeEnd = root.Int64("initRangeEnd", -1);
    spec.indexRangeStart = root.Int64("indexRangeStart", -1);
    spec.indexRangeEnd = root.Int64("indexRangeEnd", -1);
    spec.bitrate = root.Int32("bitrate", 0);
    spec.itag = root.Int32("itag", 0);
    if (const JsonVal* hdrs = root.Get("headers"); hdrs && hdrs->type == JsonVal::Type::Object) {
        for (const auto& kv : hdrs->obj) {
            if (kv.second.type == JsonVal::Type::String && !kv.second.s.empty()) {
                spec.headers[kv.first] = kv.second.s;
            }
        }
    }

    const int32_t itagLog = spec.itag;
    const int64_t lenLog = spec.contentLength;
    const uint64_t num = seq_.fetch_add(1);
    const std::string id = "yp_d_" + std::to_string(num);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        specs_[id] = std::move(spec);
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                 "RegisterDirectStream id=%{public}s itag=%{public}d len=%{public}lld",
                 id.c_str(), itagLog, static_cast<long long>(lenLog));
    return "ypstream://" + id;
}

std::string MpvStreamBridge::RegisterHlsStreamJson(const std::string& specJson)
{
    JsonVal root;
    MiniJsonParser parser(specJson);
    if (!parser.Parse(root) || root.type != JsonVal::Type::Object) {
        OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag, "RegisterHlsStreamJson: invalid JSON");
        return "";
    }

    HlsStreamSpec spec;
    spec.url = root.Str("url");
    if (spec.url.empty()) {
        return "";
    }
    spec.userAgent = root.Str("userAgent", kDefaultUserAgent);
    spec.bitrate = root.Int32("bitrate", 0);
    spec.itag = root.Int32("itag", 0);
    spec.isAudio = root.Bool("isAudio", false);
    if (const JsonVal* hdrs = root.Get("headers"); hdrs && hdrs->type == JsonVal::Type::Object) {
        for (const auto& kv : hdrs->obj) {
            if (kv.second.type == JsonVal::Type::String && !kv.second.s.empty()) {
                spec.headers[kv.first] = kv.second.s;
            }
        }
    }

    const int32_t itagLog = spec.itag;
    const bool audioLog = spec.isAudio;
    const uint64_t num = seq_.fetch_add(1);
    const std::string id = "yp_h_" + std::to_string(num);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        hlsSpecs_[id] = std::move(spec);
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                 "RegisterHlsStream id=%{public}s itag=%{public}d audio=%{public}d",
                 id.c_str(), itagLog, audioLog ? 1 : 0);
    return "ypstream://" + id;
}

void MpvStreamBridge::UnregisterStream(const std::string& urlOrId)
{
    const std::string id = ExtractStreamId(urlOrId);
    if (id.empty()) return;

    std::vector<std::shared_ptr<IStreamSource>> toCancel;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        specs_.erase(id);
        hlsSpecs_.erase(id);
        auto it = activeSources_.find(id);
        if (it != activeSources_.end()) {
            for (const auto& wp : it->second) {
                if (auto sp = wp.lock()) {
                    toCancel.push_back(std::move(sp));
                }
            }
            activeSources_.erase(it);
        }
    }
    for (auto& src : toCancel) {
        src->Cancel();
    }
}

void MpvStreamBridge::UpdateProxyJson(const std::string& proxyJson)
{
    JsonVal root;
    MiniJsonParser parser(proxyJson);
    if (!parser.Parse(root) || root.type != JsonVal::Type::Object) {
        return;
    }
    StreamProxyConfig cfg;
    cfg.kind = root.Str("kind", "none");
    cfg.host = root.Str("host", "");
    cfg.port = root.Int32("port", 0);
    cfg.username = root.Str("username", "");
    cfg.password = root.Str("password", "");
    cfg.bridgePort = root.Int32("bridgePort", 0);
    cfg.revision = root.Int32("revision", 0);
    if (const JsonVal* excl = root.Get("exclusions"); excl && excl->type == JsonVal::Type::Array) {
        for (const auto& item : excl->arr) {
            if (item.type == JsonVal::Type::String && !item.s.empty()) {
                cfg.exclusions.push_back(item.s);
            }
        }
    }
    if (http_) {
        http_->UpdateProxy(cfg);
    }
}

void MpvStreamBridge::AbortAllInFlight()
{
    if (http_) {
        http_->CancelAllInFlight(http_->CurrentEpoch() + 1);
    }
}

StreamMetrics MpvStreamBridge::SnapshotMetrics() const
{
    StreamMetrics m{};
    m.networkSpeedBps = http_ ? http_->RecentInboundBytesPerSec() : 0;
    if (http_) {
        m.totalBytesRead = http_->TotalInboundBytes();
    } else if (counters_) {
        m.totalBytesRead = counters_->totalBytesRead.load();
    }
    if (counters_) {
        m.retryCount = counters_->retryCount.load();
        m.lastHttpStatus = counters_->lastHttpStatus.load();
    }
    return m;
}

int MpvStreamBridge::OpenRoCallback(void* /*userData*/, char* uri, mpv_stream_cb_info* info)
{
    if (!uri || !info) {
        return MPV_ERROR_LOADING_FAILED;
    }
    auto& self = MpvStreamBridge::Instance();
    const std::string id = ExtractStreamId(uri);
    std::shared_ptr<IStreamSource> src;
    {
        std::lock_guard<std::mutex> lock(self.mutex_);
        if (auto it = self.specs_.find(id); it != self.specs_.end()) {
            src = std::make_shared<DirectRangeStream>(
                it->second, self.http_, self.bwEst_, self.loadCtrl_, self.counters_);
        } else if (auto hit = self.hlsSpecs_.find(id); hit != self.hlsSpecs_.end()) {
            src = std::make_shared<HlsLiveStream>(
                hit->second, self.http_, self.bwEst_, self.counters_);
        } else {
            OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                         "OpenRoCallback: unknown stream id=%{public}s", id.c_str());
            return MPV_ERROR_LOADING_FAILED;
        }
        auto& vec = self.activeSources_[id];
        vec.erase(std::remove_if(vec.begin(), vec.end(),
                                 [](const std::weak_ptr<IStreamSource>& w) { return w.expired(); }),
                  vec.end());
        vec.push_back(src);
    }

    if (!src->Open()) {
        return MPV_ERROR_LOADING_FAILED;
    }

    const bool seekable = src->IsSeekable();
    auto* cookie = new StreamCookie{id, std::move(src), 0};
    info->cookie = cookie;
    info->read_fn = &MpvStreamReadCb;
    info->seek_fn = seekable ? &MpvStreamSeekCb : nullptr;
    info->size_fn = seekable ? &MpvStreamSizeCb : nullptr;
    info->close_fn = &MpvStreamCloseCb;
    info->cancel_fn = &MpvStreamCancelCb;
    return 0;
}

} // namespace yp_stream
