#include "native_http_transport.h"
#include <algorithm>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <hilog/log.h>
#include <vector>

namespace yp_stream {

struct NativeHttpTransport::TrafficMeter {
    static constexpr int64_t kBucketMs = 100;
    static constexpr size_t kBucketCount = 50; // 50 * 100ms = 5s sliding window

    struct Bucket {
        int64_t slot = -1;
        int64_t bytes = 0;
    };

    mutable std::mutex mu;
    Bucket buckets[kBucketCount]{};
    std::atomic<int64_t> totalBytes{0};

    void RecordBytes(int64_t n)
    {
        if (n <= 0) return;
        totalBytes.fetch_add(n, std::memory_order_relaxed);
        const int64_t slot = (SteadyNowUs() / 1000LL) / kBucketMs;
        const size_t idx = static_cast<size_t>(slot % static_cast<int64_t>(kBucketCount));
        std::lock_guard<std::mutex> lock(mu);
        if (buckets[idx].slot != slot) {
            buckets[idx].slot = slot;
            buckets[idx].bytes = n;
        } else {
            buckets[idx].bytes += n;
        }
    }

    int64_t RecentBytesPerSec() const
    {
        const int64_t nowSlot = (SteadyNowUs() / 1000LL) / kBucketMs;
        const int64_t minSlot = nowSlot - static_cast<int64_t>(kBucketCount) + 1;
        int64_t sum = 0;
        {
            std::lock_guard<std::mutex> lock(mu);
            for (size_t i = 0; i < kBucketCount; ++i) {
                if (buckets[i].slot >= minSlot && buckets[i].slot <= nowSlot) {
                    sum += buckets[i].bytes;
                }
            }
        }
        // Window duration is 5 seconds (kBucketCount * kBucketMs ms).
        return (sum * 1000LL) / (static_cast<int64_t>(kBucketCount) * kBucketMs);
    }
};

namespace {

constexpr unsigned int kLogDomain = 0xFF00;
constexpr const char* kLogTag = "mpv-stream";

std::string ToLowerAscii(const std::string& s)
{
    std::string out = s;
    for (char& ch : out) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return out;
}

std::string ExtractHostname(const std::string& rawUrl)
{
    size_t schemePos = rawUrl.find("://");
    size_t hostStart = (schemePos == std::string::npos) ? 0 : (schemePos + 3);
    size_t atPos = rawUrl.find('@', hostStart);
    size_t slashPos = rawUrl.find('/', hostStart);
    if (atPos != std::string::npos && (slashPos == std::string::npos || atPos < slashPos)) {
        hostStart = atPos + 1;
    }
    if (hostStart < rawUrl.size() && rawUrl[hostStart] == '[') {
        size_t closeBracket = rawUrl.find(']', hostStart);
        if (closeBracket != std::string::npos) {
            return rawUrl.substr(hostStart, closeBracket - hostStart + 1);
        }
    }
    size_t hostEnd = rawUrl.find_first_of(":/?#", hostStart);
    if (hostEnd == std::string::npos) {
        return rawUrl.substr(hostStart);
    }
    return rawUrl.substr(hostStart, hostEnd - hostStart);
}

int64_t ParseTotalFromContentRange(const std::string& val)
{
    size_t slash = val.rfind('/');
    if (slash == std::string::npos) {
        return -1;
    }
    std::string tail = val.substr(slash + 1);
    while (!tail.empty() && std::isspace(static_cast<unsigned char>(tail.back()))) {
        tail.pop_back();
    }
    if (tail.empty() || tail == "*") {
        return -1;
    }
    char* endPtr = nullptr;
    int64_t total = std::strtoll(tail.c_str(), &endPtr, 10);
    return (endPtr != tail.c_str() && total > 0) ? total : -1;
}

struct StreamCallbackState {
    // Declared FIRST so request/headers are destroyed BEFORE the Rcp_Session closes.
    std::shared_ptr<RcpSessionHolder> sessionHolder;
    std::shared_ptr<NativeHttpTransport::TrafficMeter> trafficMeter;
    std::mutex mu;
    std::condition_variable cv;
    bool statusReceived = false;
    bool responseDone = false;
    bool sinkAborted = false;
    uint32_t httpCode = 0;
    uint32_t rcpErr = 0;
    int64_t bytesReceived = 0;
    int64_t totalContentLength = -1;
    int64_t firstByteSteadyUs = 0;
    int64_t lastProgressSteadyUs = 0;
    HttpChunkSink sink;
    std::string proxyUrl;
    Rcp_Configuration reqCfg{};
    Rcp_Headers* reqHeaders = nullptr;
    Rcp_Request* request = nullptr;

    ~StreamCallbackState()
    {
        if (request) {
            HMS_Rcp_DestroyRequest(request);
            request = nullptr;
        }
        if (reqHeaders) {
            HMS_Rcp_DestroyHeaders(reqHeaders);
            reqHeaders = nullptr;
        }
    }
};

struct CallbackBox {
    std::shared_ptr<StreamCallbackState> state;
};

void OnStatusCodeCallback(void* usrObject, uint32_t statusCode)
{
    auto* box = static_cast<CallbackBox*>(usrObject);
    if (!box || !box->state) return;
    std::shared_ptr<StreamCallbackState> st = box->state;
    {
        std::lock_guard<std::mutex> lock(st->mu);
        st->httpCode = statusCode;
        st->statusReceived = true;
        st->lastProgressSteadyUs = SteadyNowUs();
        if (st->firstByteSteadyUs == 0) {
            st->firstByteSteadyUs = st->lastProgressSteadyUs;
        }
    }
    st->cv.notify_all();
}

size_t OnBinaryRecvCallback(void* usrObject, Rcp_Buffer* buffer)
{
    auto* box = static_cast<CallbackBox*>(usrObject);
    if (!box || !box->state || !buffer) return 0;
    std::shared_ptr<StreamCallbackState> st = box->state;
    const size_t len = static_cast<size_t>(buffer->length);
    if (len == 0 || !buffer->buffer) {
        return len;
    }
    {
        std::lock_guard<std::mutex> lock(st->mu);
        st->statusReceived = true;
        st->lastProgressSteadyUs = SteadyNowUs();
        if (st->firstByteSteadyUs == 0) {
            st->firstByteSteadyUs = st->lastProgressSteadyUs;
        }
        st->bytesReceived += static_cast<int64_t>(len);
    }
    if (st->trafficMeter) {
        st->trafficMeter->RecordBytes(static_cast<int64_t>(len));
    }
    bool keepGoing = true;
    if (st->sink) {
        keepGoing = st->sink(reinterpret_cast<const uint8_t*>(buffer->buffer), len);
    }
    if (!keepGoing) {
        std::lock_guard<std::mutex> lock(st->mu);
        st->sinkAborted = true;
        st->cv.notify_all();
        return 0;
    }
    st->cv.notify_all();
    return len;
}

void OnResponseDoneCallback(void* usrCtx, Rcp_Response* response, uint32_t errCode)
{
    auto* box = static_cast<CallbackBox*>(usrCtx);
    if (!box) return;
    std::shared_ptr<StreamCallbackState> st = box->state;
    if (st) {
        uint32_t finalHttp = 0;
        int64_t parsedTotal = -1;
        if (response) {
            finalHttp = static_cast<uint32_t>(response->statusCode);
            if (response->headers) {
                Rcp_HeaderEntry* entries = HMS_Rcp_GetHeaderEntries(response->headers);
                for (Rcp_HeaderEntry* e = entries; e != nullptr; e = e->next) {
                    if (!e->key || !e->value || !e->value->value) continue;
                    std::string k = ToLowerAscii(e->key);
                    if (k == "content-range") {
                        int64_t crTotal = ParseTotalFromContentRange(e->value->value);
                        if (crTotal > 0) parsedTotal = crTotal;
                    } else if (k == "content-length" && finalHttp == 200 && parsedTotal < 0) {
                        int64_t cl = std::strtoll(e->value->value, nullptr, 10);
                        if (cl > 0) parsedTotal = cl;
                    }
                }
                if (entries) {
                    HMS_Rcp_DestroyHeaderEntries(entries);
                }
            }
            if (response->destroyResponse) {
                response->destroyResponse(response);
            }
        }
        {
            std::lock_guard<std::mutex> lock(st->mu);
            if (finalHttp > 0) {
                st->httpCode = finalHttp;
            }
            if (parsedTotal > 0) {
                st->totalContentLength = parsedTotal;
            }
            st->rcpErr = errCode;
            st->responseDone = true;
        }
        st->cv.notify_all();
    }
    delete box;
}

} // namespace

NativeHttpTransport::NativeHttpTransport()
    : trafficMeter_(std::make_shared<TrafficMeter>())
{
}

NativeHttpTransport::~NativeHttpTransport()
{
    CancelAllInFlight(epoch_.load() + 1);
    std::lock_guard<std::mutex> lock(mutex_);
    ResetSessionLocked();
}

void NativeHttpTransport::UpdateProxy(const StreamProxyConfig& proxy)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (proxy_.kind == proxy.kind && proxy_.host == proxy.host &&
        proxy_.port == proxy.port && proxy_.username == proxy.username &&
        proxy_.bridgePort == proxy.bridgePort && proxy_.exclusions == proxy.exclusions) {
        proxy_ = proxy;
        return;
    }
    proxy_ = proxy;
    ResetSessionLocked();
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                 "HTTP proxy updated kind=%{public}s port=%{public}d bridge=%{public}d",
                 proxy_.kind.c_str(), proxy_.port, proxy_.bridgePort);
}

void NativeHttpTransport::UpdateNetworkPolicy(const StreamNetworkPolicy& policy)
{
    std::lock_guard<std::mutex> lock(mutex_);
    policy_ = policy;
}

StreamNetworkPolicy NativeHttpTransport::GetNetworkPolicy() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return policy_;
}

void NativeHttpTransport::CancelAllInFlight(uint64_t newEpoch)
{
    if (newEpoch <= epoch_.load()) {
        newEpoch = epoch_.load() + 1;
    }
    epoch_.store(newEpoch);
    // Rotate the RCP session so immediate handover retries never hit stale
    // keep-alive sockets left over from the previous network interface.
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ResetSessionLocked();
    }
    std::vector<ActiveReq> snapshot;
    {
        std::lock_guard<std::mutex> lock(activeMutex_);
        snapshot.reserve(activeRequests_.size());
        for (ActiveReq* req : activeRequests_) {
            if (req && req->sessionHolder && req->sessionHolder->session && req->request) {
                snapshot.push_back(*req);
            }
        }
    }
    for (const auto& item : snapshot) {
        HMS_Rcp_CancelRequest(item.sessionHolder->session, item.request);
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                 "CancelAllInFlight epoch=%{public}llu active=%{public}zu (session rotated)",
                 static_cast<unsigned long long>(newEpoch), snapshot.size());
}

uint64_t NativeHttpTransport::CurrentEpoch() const
{
    return epoch_.load();
}

int64_t NativeHttpTransport::RecentInboundBytesPerSec() const
{
    return trafficMeter_ ? trafficMeter_->RecentBytesPerSec() : 0;
}

int64_t NativeHttpTransport::TotalInboundBytes() const
{
    return trafficMeter_ ? trafficMeter_->totalBytes.load(std::memory_order_relaxed) : 0;
}

std::shared_ptr<RcpSessionHolder> NativeHttpTransport::EnsureSession()
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (sessionHolder_ && sessionHolder_->session) {
        return sessionHolder_;
    }
    auto holder = std::make_shared<RcpSessionHolder>();
    std::memset(&holder->cfg, 0, sizeof(holder->cfg));
    holder->cfg.type = RCP_SESSION_TYPE_HTTP;
    holder->cfg.connectionConfiguration.maxConnectionsPerHost = 6;
    holder->cfg.connectionConfiguration.maxTotalConnections = 16;
    holder->cfg.connectionConfiguration.maxCacheConnections = 6;
    uint32_t errCode = 0;
    holder->session = HMS_Rcp_CreateSession(&holder->cfg, &errCode);
    if (!holder->session || errCode != 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, kLogDomain, kLogTag,
                     "HMS_Rcp_CreateSession failed err=%{public}u", errCode);
        return nullptr;
    }
    sessionHolder_ = holder;
    return sessionHolder_;
}

void NativeHttpTransport::ResetSessionLocked()
{
    sessionHolder_.reset();
}

bool NativeHttpTransport::ShouldBypassLocked(const std::string& url) const
{
    const std::string host = ToLowerAscii(ExtractHostname(url));
    if (host.empty()) return false;
    if (host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]") {
        return true;
    }
    for (const auto& ruleRaw : proxy_.exclusions) {
        const std::string rule = ToLowerAscii(ruleRaw);
        if (rule.empty()) continue;
        if (host == rule) return true;
        if (host.size() > rule.size() + 1 &&
            host.compare(host.size() - rule.size(), rule.size(), rule) == 0 &&
            host[host.size() - rule.size() - 1] == '.') {
            return true;
        }
    }
    return false;
}

std::string NativeHttpTransport::BuildProxyUrlLocked() const
{
    if (proxy_.kind == "none" || proxy_.host.empty() || proxy_.port <= 0) {
        return "";
    }
    if (proxy_.kind == "socks5") {
        if (proxy_.bridgePort > 0) {
            return "http://127.0.0.1:" + std::to_string(proxy_.bridgePort);
        }
        return "";
    }
    if (proxy_.kind == "http") {
        if (!proxy_.username.empty() && proxy_.bridgePort > 0) {
            return "http://127.0.0.1:" + std::to_string(proxy_.bridgePort);
        }
        return "http://" + proxy_.host + ":" + std::to_string(proxy_.port);
    }
    return "";
}

HttpFetchResult NativeHttpTransport::FetchRangeStream(
    const std::string& url,
    int64_t rangeStart,
    int64_t rangeEnd,
    const std::map<std::string, std::string>& headers,
    const std::string& userAgent,
    uint64_t expectedEpoch,
    const std::atomic<bool>& localAbort,
    const HttpChunkSink& sink)
{
    HttpFetchResult res{};
    if (localAbort.load() || epoch_.load() != expectedEpoch) {
        res.status = HttpFetchStatus::ABORTED;
        return res;
    }

    std::shared_ptr<RcpSessionHolder> sessionHolder = EnsureSession();
    if (!sessionHolder || !sessionHolder->session) {
        res.status = HttpFetchStatus::NET_ERROR;
        res.errorDetail = "rcp_session_unavailable";
        return res;
    }
    Rcp_Session* session = sessionHolder->session;

    StreamNetworkPolicy pol;
    std::string proxyUrl;
    bool bypass = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        pol = policy_;
        bypass = ShouldBypassLocked(url);
        if (!bypass) {
            proxyUrl = BuildProxyUrlLocked();
        }
    }

    Rcp_Request* request = HMS_Rcp_CreateRequest(url.c_str());
    if (!request) {
        res.status = HttpFetchStatus::NET_ERROR;
        res.errorDetail = "rcp_create_request_failed";
        return res;
    }
    request->method = RCP_METHOD_GET;

    auto cbState = std::make_shared<StreamCallbackState>();
    cbState->sessionHolder = sessionHolder;
    cbState->trafficMeter = trafficMeter_;
    cbState->sink = sink;
    cbState->request = request;
    cbState->proxyUrl = std::move(proxyUrl);

    Rcp_Headers* reqHeaders = HMS_Rcp_CreateHeaders();
    if (reqHeaders) {
        for (const auto& kv : headers) {
            HMS_Rcp_SetHeaderValue(reqHeaders, kv.first.c_str(), kv.second.c_str());
        }
        if (!userAgent.empty() && headers.find("User-Agent") == headers.end()) {
            HMS_Rcp_SetHeaderValue(reqHeaders, "User-Agent", userAgent.c_str());
        }
        if (rangeStart >= 0) {
            std::string rangeStr = "bytes=" + std::to_string(rangeStart) + "-";
            if (rangeEnd >= rangeStart) {
                rangeStr += std::to_string(rangeEnd);
            }
            HMS_Rcp_SetHeaderValue(reqHeaders, "Range", rangeStr.c_str());
        }
        request->headers = reqHeaders;
        cbState->reqHeaders = reqHeaders;
    }

    std::memset(&cbState->reqCfg, 0, sizeof(cbState->reqCfg));
    cbState->reqCfg.transferConfiguration.autoRedirect = true;
    cbState->reqCfg.transferConfiguration.timeout.connectMs = static_cast<uint32_t>(std::max(1000, pol.connectTimeoutMs));
    cbState->reqCfg.transferConfiguration.timeout.transferMs = 600000;
    cbState->reqCfg.transferConfiguration.assumesHTTP3Capable = false;
    cbState->reqCfg.transferConfiguration.pathPreference = RCP_PATH_PREFERENCE_AUTO;
    cbState->reqCfg.securityConfiguration.remoteValidationType = RCP_REMOTE_VALIDATION_SYSTEM;

    if (bypass) {
        cbState->reqCfg.proxyConfiguration.proxyType = RCP_PROXY_NO_PROXY;
    } else if (!cbState->proxyUrl.empty()) {
        cbState->reqCfg.proxyConfiguration.proxyType = RCP_PROXY_CUSTOM;
        cbState->reqCfg.proxyConfiguration.customProxy.url = cbState->proxyUrl.c_str();
        cbState->reqCfg.proxyConfiguration.customProxy.createTunnel = RCP_PROXY_TUNNEL_AUTO;
        cbState->reqCfg.proxyConfiguration.customProxy.securityConfiguration.remoteValidationType = RCP_REMOTE_VALIDATION_SYSTEM;
    } else {
        cbState->reqCfg.proxyConfiguration.proxyType = RCP_PROXY_SYSTEM;
    }
    request->configuration = &cbState->reqCfg;

    const int64_t startSteadyUs = SteadyNowUs();
    cbState->lastProgressSteadyUs = startSteadyUs;

    auto* cbBox = new CallbackBox{cbState};

    Rcp_OnStatusCodeReceiveCallback statusCb{OnStatusCodeCallback, cbBox};
    HMS_Rcp_SetRequestOnStatusCodeReceiveCallback(request, statusCb);

    Rcp_OnBinaryReceiveCallback binaryCb{OnBinaryRecvCallback, cbBox};
    HMS_Rcp_SetRequestOnBinaryDataRecvCallback(request, binaryCb);

    ActiveReq activeEntry{sessionHolder, request, cbState};
    {
        std::lock_guard<std::mutex> lock(activeMutex_);
        activeRequests_.insert(&activeEntry);
    }

    const Rcp_ResponseCallbackObject respCb{OnResponseDoneCallback, cbBox};
    const uint32_t fetchRet = HMS_Rcp_Fetch(session, request, &respCb);

    bool canceledByTimeoutOrAbort = false;
    HttpFetchStatus overrideStatus = HttpFetchStatus::OK;

    if (fetchRet != 0) {
        delete cbBox;
        {
            std::lock_guard<std::mutex> lock(cbState->mu);
            cbState->rcpErr = fetchRet;
            cbState->responseDone = true;
        }
    } else {
        const int64_t firstByteLimitUs = static_cast<int64_t>(std::max(1000, pol.firstByteTimeoutMs)) * 1000LL;
        const int64_t idleLimitUs = static_cast<int64_t>(std::max(1000, pol.idleReadTimeoutMs)) * 1000LL;

        std::unique_lock<std::mutex> lock(cbState->mu);
        while (!cbState->responseDone) {
            cbState->cv.wait_for(lock, std::chrono::milliseconds(50));
            if (cbState->responseDone) {
                break;
            }
            const int64_t nowUs = SteadyNowUs();
            if (localAbort.load() || epoch_.load() != expectedEpoch || cbState->sinkAborted) {
                overrideStatus = HttpFetchStatus::ABORTED;
                canceledByTimeoutOrAbort = true;
                break;
            }
            if (!cbState->statusReceived && (nowUs - startSteadyUs) >= firstByteLimitUs) {
                overrideStatus = HttpFetchStatus::FIRST_BYTE_TIMEOUT;
                canceledByTimeoutOrAbort = true;
                break;
            }
            if (cbState->statusReceived && (nowUs - cbState->lastProgressSteadyUs) >= idleLimitUs) {
                overrideStatus = HttpFetchStatus::IDLE_TIMEOUT;
                canceledByTimeoutOrAbort = true;
                break;
            }
        }
        if (canceledByTimeoutOrAbort && !cbState->responseDone) {
            lock.unlock();
            HMS_Rcp_CancelRequest(session, request);
            lock.lock();
            cbState->cv.wait_for(lock, std::chrono::milliseconds(300), [&cbState]() {
                return cbState->responseDone;
            });
        }
    }

    {
        std::lock_guard<std::mutex> lock(activeMutex_);
        activeRequests_.erase(&activeEntry);
    }

    const int64_t doneSteadyUs = SteadyNowUs();
    res.elapsedUs = std::max<int64_t>(1, doneSteadyUs - startSteadyUs);
    std::lock_guard<std::mutex> lock(cbState->mu);
    if (cbState->firstByteSteadyUs > startSteadyUs) {
        res.firstByteUs = cbState->firstByteSteadyUs - startSteadyUs;
        res.transferUs = std::max<int64_t>(1, doneSteadyUs - cbState->firstByteSteadyUs);
    } else {
        res.firstByteUs = res.elapsedUs;
        res.transferUs = res.elapsedUs;
    }
    res.httpCode = static_cast<int32_t>(cbState->httpCode);
    res.rcpErrCode = cbState->rcpErr;
    res.bytesReceived = cbState->bytesReceived;
    res.totalContentLength = cbState->totalContentLength;

    if (canceledByTimeoutOrAbort) {
        res.status = overrideStatus;
    } else if (localAbort.load() || epoch_.load() != expectedEpoch || cbState->sinkAborted) {
        res.status = HttpFetchStatus::ABORTED;
    } else if (res.httpCode == 403 || res.httpCode == 410) {
        res.status = HttpFetchStatus::HTTP_URL_EXPIRED;
    } else if (res.httpCode == 407) {
        res.status = HttpFetchStatus::HTTP_PROXY_AUTH;
    } else if (res.httpCode == 416) {
        res.eofOnServer = true;
        res.status = HttpFetchStatus::OK;
    } else if (res.httpCode >= 400) {
        res.status = HttpFetchStatus::HTTP_ERROR;
    } else if (res.rcpErrCode != 0) {
        if (res.rcpErrCode == 1007900028) {
            res.status = HttpFetchStatus::CONNECT_TIMEOUT;
        } else if (res.rcpErrCode == 1007900992) {
            res.status = HttpFetchStatus::ABORTED;
        } else {
            res.status = HttpFetchStatus::NET_ERROR;
        }
    } else if (res.httpCode >= 200 && res.httpCode < 300) {
        res.status = HttpFetchStatus::OK;
    } else {
        res.status = HttpFetchStatus::NET_ERROR;
    }

    return res;
}

} // namespace yp_stream
