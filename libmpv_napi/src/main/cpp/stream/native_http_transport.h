#pragma once

#include "stream_types.h"
#include <RemoteCommunicationKit/rcp.h>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>

namespace yp_stream {

enum class HttpFetchStatus : int32_t {
    OK = 0,
    ABORTED = 1,
    CONNECT_TIMEOUT = 2,
    FIRST_BYTE_TIMEOUT = 3,
    IDLE_TIMEOUT = 4,
    HTTP_URL_EXPIRED = 5,
    HTTP_PROXY_AUTH = 6,
    HTTP_ERROR = 7,
    NET_ERROR = 8,
};

struct HttpFetchResult {
    HttpFetchStatus status = HttpFetchStatus::NET_ERROR;
    int32_t httpCode = 0;
    uint32_t rcpErrCode = 0;
    int64_t bytesReceived = 0;
    int64_t totalContentLength = -1;
    int64_t elapsedUs = 0;
    int64_t firstByteUs = 0;
    int64_t transferUs = 0;
    bool eofOnServer = false;
    std::string errorDetail;
};

using HttpChunkSink = std::function<bool(const uint8_t* data, size_t len)>;

/**
 * Ref-counted holder for Rcp_Session + its configuration struct.
 * Allows instant session rotation on proxy change or network handover
 * without closing an old session while cancelled requests are still draining.
 */
struct RcpSessionHolder {
    Rcp_SessionConfiguration cfg{};
    Rcp_Session* session = nullptr;

    ~RcpSessionHolder()
    {
        if (session) {
            Rcp_Session* s = session;
            session = nullptr;
            HMS_Rcp_CloseSession(&s);
        }
    }
};

/**
 * Streaming HTTP/HTTPS range transport built on HarmonyOS RemoteCommunicationKit (librcp_c).
 * Features:
 * - Three isolated timeouts: connect, first-byte TTFB, and idle-read stall.
 * - Millisecond cancellation + session pool rotation on network handover / seek / stop.
 * - Full app proxy alignment (unauth HTTP, HTTP auth bridge, SOCKS5 bridge, exclusions).
 */
class NativeHttpTransport {
public:
    NativeHttpTransport();
    ~NativeHttpTransport();

    void UpdateProxy(const StreamProxyConfig& proxy);
    void UpdateNetworkPolicy(const StreamNetworkPolicy& policy);
    StreamNetworkPolicy GetNetworkPolicy() const;

    void CancelAllInFlight(uint64_t newEpoch);
    uint64_t CurrentEpoch() const;

    // Unified 5-second sliding-window inbound throughput (bytes/sec) and total wire bytes
    // across all ypstream:// sources (DirectRangeStream, HlsLiveStream, etc.).
    struct TrafficMeter;
    int64_t RecentInboundBytesPerSec() const;
    int64_t TotalInboundBytes() const;

    HttpFetchResult FetchRangeStream(
        const std::string& url,
        int64_t rangeStart,
        int64_t rangeEnd,
        const std::map<std::string, std::string>& headers,
        const std::string& userAgent,
        uint64_t expectedEpoch,
        const std::atomic<bool>& localAbort,
        const HttpChunkSink& sink);

private:
    struct ActiveReq {
        std::shared_ptr<RcpSessionHolder> sessionHolder;
        Rcp_Request* request = nullptr;
        std::shared_ptr<void> keepAlive;
    };

    std::shared_ptr<RcpSessionHolder> EnsureSession();
    void ResetSessionLocked();
    bool ShouldBypassLocked(const std::string& url) const;
    std::string BuildProxyUrlLocked() const;

    mutable std::mutex mutex_;
    StreamProxyConfig proxy_{};
    StreamNetworkPolicy policy_{};
    std::shared_ptr<RcpSessionHolder> sessionHolder_;

    std::atomic<uint64_t> epoch_{1};
    std::mutex activeMutex_;
    std::set<ActiveReq*> activeRequests_;

    std::shared_ptr<TrafficMeter> trafficMeter_;
};

} // namespace yp_stream
