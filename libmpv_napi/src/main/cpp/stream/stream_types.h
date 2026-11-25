#pragma once

#include <chrono>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace yp_stream {

enum class StreamErrorCategory : int32_t {
    NONE = 0,
    NETWORK = 1,
    URL_EXPIRED = 2,
    PROXY_AUTH = 3,
    SOURCE = 4,
};

struct StreamProxyConfig {
    std::string kind = "none"; // "none" | "http" | "socks5"
    std::string host;
    int32_t port = 0;
    std::string username;
    std::string password;
    int32_t bridgePort = 0; // Local Socks5Bridge / HTTP auth-bridge loopback port
    std::vector<std::string> exclusions;
    int32_t revision = 0;
};

struct StreamNetworkPolicy {
    int32_t connectTimeoutMs = 5000;
    int32_t firstByteTimeoutMs = 6000;
    int32_t idleReadTimeoutMs = 4000;
    int32_t minChunkBytes = 262144;   // 256 KiB
    int32_t maxChunkBytes = 8388608;  // 8 MiB (covers >40 Mbps 4K60 on high-RTT links)
    int32_t maxRetries = 5;
};

struct StreamLoadControlConfig {
    int32_t earlyBufferMs = 15000;
    int32_t settledAfterMs = 30000;
    int32_t maxBufferMs = 50000;
    int32_t minRebufferMs = 2500;
    int64_t maxBackBufferBytes = 8LL * 1024LL * 1024LL; // 8 MiB
};

struct DirectStreamSpec {
    std::string url;
    std::string userAgent;
    int64_t contentLength = -1;
    int64_t initRangeStart = -1;
    int64_t initRangeEnd = -1;
    int64_t indexRangeStart = -1;
    int64_t indexRangeEnd = -1;
    int32_t bitrate = 0;
    int32_t itag = 0;
    std::map<std::string, std::string> headers;
};

struct HlsStreamSpec {
    std::string url;
    std::string userAgent;
    int32_t bitrate = 0;
    int32_t itag = 0;
    bool isAudio = false;
    std::map<std::string, std::string> headers;
};

struct StreamMetrics {
    int64_t networkSpeedBps = 0;
    int64_t totalBytesRead = 0;
    int32_t retryCount = 0;
    int32_t lastHttpStatus = 0;
};

inline int64_t SteadyNowUs()
{
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

} // namespace yp_stream
