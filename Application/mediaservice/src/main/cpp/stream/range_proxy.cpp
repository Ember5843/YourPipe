#include "range_proxy.h"
#include "http_client.h"
#include "rcp_session_pool.h"
#include "segment_cache.h"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstring>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unordered_map>
#include <utility>
#include <unistd.h>
#include <vector>

#include <hilog/log.h>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "RangeProxy"
#define LOG_DOMAIN 0x3209

#define RANGE_LOG(level, fmt, ...) \
    OH_LOG_Print(LOG_APP, level, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

namespace yourpipe {

namespace {
constexpr int64_t CHUNK_BYTES = 2 * 1024 * 1024;
std::mutex g_lengthCacheMutex;
std::unordered_map<std::string, int64_t> g_lengthCache;
std::mutex g_upstreamLockMapMutex;
std::unordered_map<std::string, std::shared_ptr<std::mutex>> g_upstreamLocks;

// Per-URL request number (rn) counter for YouTube videoplayback URLs
std::mutex g_rnMutex;
std::unordered_map<std::string, int64_t> g_requestNumberMap;

std::string trim(std::string s) {
    auto notSpace = [](unsigned char c) { return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
    s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
    return s;
}

std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

// Remove a single named query parameter from a URL.
// Handles ?param=value at start, &param=value in middle/end.
std::string stripQueryParam(const std::string& url, const std::string& param) {
    std::string result = url;
    std::string mid = "&" + param + "=";
    size_t pos = result.find(mid);
    if (pos != std::string::npos) {
        size_t valueEnd = result.find('&', pos + mid.size());
        if (valueEnd == std::string::npos) {
            result.erase(pos);
        } else {
            result.erase(pos, valueEnd - pos);
        }
        return result;
    }
    std::string start = "?" + param + "=";
    pos = result.find(start);
    if (pos != std::string::npos) {
        size_t valueEnd = result.find('&', pos + start.size());
        if (valueEnd == std::string::npos) {
            result.erase(pos);
        } else {
            result.erase(pos + 1, valueEnd - pos);
        }
    }
    return result;
}

std::string describeUrlForLog(const std::string& url) {
    return url;
}

std::string upstreamLockKey(const std::string& url) {
    // Per-resource lock: use the URL path (without query params) as key.
    // This allows different itags (audio vs video) to download in parallel
    // while still serializing requests for the same resource.
    size_t scheme = url.find("://");
    size_t start = scheme == std::string::npos ? 0 : scheme + 3;
    size_t queryStart = url.find('?', start);
    return queryStart == std::string::npos ? url.substr(start) : url.substr(start, queryStart - start);
}

std::shared_ptr<std::mutex> upstreamLockFor(const std::string& url) {
    std::string key = upstreamLockKey(url);
    std::lock_guard<std::mutex> lock(g_upstreamLockMapMutex);
    auto it = g_upstreamLocks.find(key);
    if (it != g_upstreamLocks.end()) {
        return it->second;
    }
    auto mtx = std::make_shared<std::mutex>();
    g_upstreamLocks[key] = mtx;
    return mtx;
}

std::string headerValue(const HttpResponse& resp, const std::string& name) {
    std::string target = lower(name);
    for (const auto& h : resp.headers) {
        if (lower(h.first) == target) {
            return h.second;
        }
    }
    return "";
}

int64_t parseTotalFromContentRange(const std::string& value) {
    size_t slash = value.rfind('/');
    if (slash == std::string::npos || slash + 1 >= value.size()) {
        return 0;
    }
    std::string total = trim(value.substr(slash + 1));
    if (total.empty() || total == "*") {
        return 0;
    }
    try {
        return std::stoll(total);
    } catch (...) {
        return 0;
    }
}

int64_t parseContentLength(const std::string& value) {
    try {
        return std::stoll(trim(value));
    } catch (...) {
        return 0;
    }
}

int64_t cachedContentLength(const DashStreamResource& resource) {
    if (resource.contentLength > 0) {
        return resource.contentLength;
    }
    std::lock_guard<std::mutex> lock(g_lengthCacheMutex);
    auto it = g_lengthCache.find(resource.url);
    return it == g_lengthCache.end() ? 0 : it->second;
}

void cacheContentLength(const DashStreamResource& resource, int64_t total) {
    if (total <= 0 || resource.url.empty()) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_lengthCacheMutex);
    g_lengthCache[resource.url] = total;
}

bool isTransientTransportFailure(const HttpResponse& resp) {
    if (resp.status_code != 0) return false;
    if (resp.error.find("1007900992") != std::string::npos ||
        resp.error.find("1007900035") != std::string::npos ||
        resp.error.find("timeout") != std::string::npos ||
        resp.error.find("cancel") != std::string::npos ||
        resp.error.find("Cancel") != std::string::npos) {
        return true;
    }
    return false;
}

bool isRetryableHttpError(const HttpResponse& resp) {
    int code = resp.status_code;
    return code == 403 || code == 429 || code == 500 ||
           code == 502 || code == 503 || code == 504;
}

bool isUrlExpiredError(const HttpResponse& resp) {
    return resp.status_code == 403 || resp.status_code == 410 || resp.status_code == 411;
}

int retryDelayMs(int attempt) {
    if (attempt <= 0) return 300;
    return std::min(attempt * 1000, 5000);
}

// Matching PipePipe: detect client type from URL &c= parameter
bool isAndroidStreamingUrl(const std::string& url) {
    return url.find("&c=ANDROID") != std::string::npos;
}

bool isIosStreamingUrl(const std::string& url) {
    return url.find("&c=IOS") != std::string::npos;
}

bool isWebStreamingUrl(const std::string& url) {
    return url.find("&c=WEB") != std::string::npos;
}

bool isTvHtml5SimplyEmbeddedPlayerStreamingUrl(const std::string& url) {
    return url.find("&c=TVHTML5_SIMPLY_EMBEDDED_PLAYER") != std::string::npos;
}

// YouTube uses URL query parameters instead of HTTP Range header.
std::string buildYoutubeRangeUrl(const std::string& baseUrl, const std::string& rangeSpec) {
    std::string url = baseUrl;
    char sep = (url.find('?') == std::string::npos) ? '?' : '&';
    url += sep;
    url += "range=" + rangeSpec;
    return url;
}

// Append or update the rn (request number) parameter on a YouTube URL.
// Returns the URL with rn set and increments the per-URL counter.
std::string appendYoutubeRn(const std::string& url, const std::string& urlKey) {
    std::string result = url;
    // Remove any existing rn parameter
    size_t rnPos = result.find("&rn=");
    if (rnPos == std::string::npos) {
        rnPos = result.find("?rn=");
    }
    if (rnPos != std::string::npos) {
        size_t endPos = result.find('&', rnPos + 1);
        if (endPos == std::string::npos) {
            result.erase(rnPos);
        } else {
            result.erase(rnPos, endPos - rnPos);
        }
    }
    int64_t rn = 0;
    {
        std::lock_guard<std::mutex> lock(g_rnMutex);
        auto it = g_requestNumberMap.find(urlKey);
        if (it != g_requestNumberMap.end()) {
            rn = it->second;
        }
        g_requestNumberMap[urlKey] = rn + 1;
    }
    char sep = (result.find('?') == std::string::npos) ? '?' : '&';
    result += sep;
    result += "rn=" + std::to_string(rn);
    return result;
}

HttpResponse fetchRangeWithRetry(const DashStreamResource& resource,
                                 const std::string& range,
                                 const std::vector<std::pair<std::string, std::string>>& customHeaders) {
    constexpr int MAX_RETRIES = 4;
    constexpr int TIMEOUT_MS = 30000;
    auto upstreamLock = upstreamLockFor(resource.url);
    std::lock_guard<std::mutex> upstreamGuard(*upstreamLock);

    std::string requestUrl = resource.url;
    // PipePipe: progressive streams also get &rn= on videoplayback URLs
    if (resource.isYoutubePlayback) {
        requestUrl = appendYoutubeRn(requestUrl, resource.url);
    }

    HttpResponse resp;
    int consecutive403 = 0;
    for (int attempt = 0; attempt <= MAX_RETRIES; ++attempt) {
        resp = http_get_range(requestUrl, range,
                              resource.userAgent, resource.referer,
                              customHeaders, nullptr, TIMEOUT_MS);
        if (!isTransientTransportFailure(resp) && !isRetryableHttpError(resp)) {
            return resp;
        }
        if (resp.status_code == 403) {
            ++consecutive403;
            if (consecutive403 >= 2) {
                RANGE_LOG(LOG_WARN, "403 persistent (attempt=%{public}d), giving up resource=%{public}s range=%{public}s",
                          attempt + 1, resource.representationId.c_str(), range.c_str());
                break;
            }
        } else {
            consecutive403 = 0;
        }
        if (attempt == MAX_RETRIES) break;
        RANGE_LOG(LOG_WARN, "upstream failure (status=%{public}d attempt=%{public}d), retrying resource=%{public}s err=%{public}s range=%{public}s",
                  resp.status_code, attempt + 1, resource.representationId.c_str(), resp.error.c_str(), range.c_str());
        RcpSessionPool::instance()->clear();
        std::this_thread::sleep_for(std::chrono::milliseconds(retryDelayMs(attempt)));
    }
    return resp;
}

// Fetch a chunk from a YouTube videoplayback URL.
// Matching PipePipe: Android/iOS use POST with empty body; WEB/TV use GET.
// Range is always specified via &range= query param (YouTube protocol).
HttpResponse fetchYoutubeRangeWithRetry(const DashStreamResource& resource,
                                        const std::string& rangeSpec,
                                        const std::vector<std::pair<std::string, std::string>>& customHeaders) {
    constexpr int MAX_RETRIES = 4;
    constexpr int TIMEOUT_MS = 30000;
    auto upstreamLock = upstreamLockFor(resource.url);
    std::lock_guard<std::mutex> upstreamGuard(*upstreamLock);

    // Build URL with &range= query param and &rn=
    std::string baseUrl = resource.url;
    std::string requestUrl = buildYoutubeRangeUrl(baseUrl, rangeSpec);
    requestUrl = appendYoutubeRn(requestUrl, resource.url);

    // PipePipe: Android/iOS use POST (detected from URL &c= param), WEB/TV use GET
    bool isAndroid = isAndroidStreamingUrl(resource.url);
    bool isIos = isIosStreamingUrl(resource.url);
    bool isWeb = isWebStreamingUrl(resource.url);
    bool isTv = isTvHtml5SimplyEmbeddedPlayerStreamingUrl(resource.url);
    bool usePOST = isAndroid || isIos;
    std::string method = usePOST ? "POST" : "GET";

    // PipePipe sends empty-body POST for Android/iOS (no Content-Length: 0 header)
    std::vector<uint8_t> postBody;

    std::vector<std::pair<std::string, std::string>> hdrs;

    // PipePipe: WEB/TV get Origin + Referer + Sec-Fetch headers
    if (isWeb || isTv) {
        hdrs.push_back({"Origin", "https://www.youtube.com"});
        hdrs.push_back({"Referer", "https://www.youtube.com"});
        hdrs.push_back({"Sec-Fetch-Dest", "empty"});
        hdrs.push_back({"Sec-Fetch-Mode", "cors"});
        hdrs.push_back({"Sec-Fetch-Site", "cross-site"});
    }

    // PipePipe: Android gets Android UA, iOS gets iOS UA, WEB/TV get no custom UA
    if (isAndroid) {
        hdrs.push_back({"User-Agent", "com.google.android.youtube/21.03.36 (Linux; U; Android 16; GB) gzip"});
    } else if (isIos) {
        hdrs.push_back({"User-Agent", "com.google.ios.youtube/20.03.02(iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X; GB)"});
    }

    hdrs.push_back({"Accept-Encoding", "identity"});

    // PipePipe/Java HttpURLConnection does NOT send Content-Length: 0 for empty POST.
    // Adding it manually may confuse YouTube's edge servers when combined with
    // libcurl's internal handling. Leave it out entirely.

    for (const auto& h : customHeaders) {
        hdrs.push_back(h);
    }

    HttpResponse resp;
    int consecutive403 = 0;
    for (int attempt = 0; attempt <= MAX_RETRIES; ++attempt) {
        resp = http_fetch(requestUrl, method, postBody, hdrs, nullptr, TIMEOUT_MS);
        if (!isTransientTransportFailure(resp) && !isRetryableHttpError(resp)) {
            return resp;
        }
        if (resp.status_code == 403) {
            ++consecutive403;
            if (consecutive403 >= 2) {
                RANGE_LOG(LOG_WARN, "YouTube 403 persistent (attempt=%{public}d), giving up resource=%{public}s range=%{public}s",
                          attempt + 1, resource.representationId.c_str(), rangeSpec.c_str());
                break;
            }
        } else {
            consecutive403 = 0;
        }
        if (attempt == MAX_RETRIES) break;
        RANGE_LOG(LOG_WARN, "YouTube upstream failure (status=%{public}d attempt=%{public}d), retrying resource=%{public}s err=%{public}s range=%{public}s",
                  resp.status_code, attempt + 1, resource.representationId.c_str(), resp.error.c_str(), rangeSpec.c_str());
        RcpSessionPool::instance()->clear();
        std::this_thread::sleep_for(std::chrono::milliseconds(retryDelayMs(attempt)));
    }
    return resp;
}
}

bool RangeProxy::parseRangeHeader(const std::string& headerValue, ByteRange& out) {
    out = ByteRange();
    std::string value = trim(headerValue);
    if (value.empty()) {
        return false;
    }
    std::string prefix = "bytes=";
    if (lower(value.substr(0, prefix.size())) != prefix) {
        return false;
    }
    std::string spec = value.substr(prefix.size());
    size_t comma = spec.find(',');
    if (comma != std::string::npos) {
        spec = spec.substr(0, comma);
    }
    size_t dash = spec.find('-');
    if (dash == std::string::npos) {
        return false;
    }
    std::string startText = trim(spec.substr(0, dash));
    std::string endText = trim(spec.substr(dash + 1));
    out.hasRange = true;
    try {
        if (startText.empty()) {
            out.suffix = true;
            out.start = 0;
            out.end = std::stoll(endText);
        } else {
            out.start = std::stoll(startText);
            out.end = endText.empty() ? -1 : std::stoll(endText);
        }
    } catch (...) {
        out = ByteRange();
        return false;
    }
    return true;
}

bool RangeProxy::sendAll(int fd, const void* data, size_t size) {
    const uint8_t* p = static_cast<const uint8_t*>(data);
    size_t sent = 0;
    while (sent < size) {
        ssize_t n = send(fd, p + sent, size - sent, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (n == 0) {
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool RangeProxy::sendString(int fd, const std::string& value) {
    return sendAll(fd, value.data(), value.size());
}

std::string RangeProxy::contentTypeFor(const DashStreamResource& resource) {
    if (!resource.mimeType.empty()) {
        size_t semi = resource.mimeType.find(';');
        return semi == std::string::npos ? resource.mimeType : resource.mimeType.substr(0, semi);
    }
    return resource.isAudio ? "audio/mp4" : "video/mp4";
}

bool RangeProxy::sendUpstreamError(int fd,
                                   const DashStreamResource& resource,
                                   const HttpResponse& resp,
                                   const std::string& range) {
    RANGE_LOG(LOG_ERROR, "upstream failed resource=%{public}s status=%{public}d err=%{public}s range=%{public}s upstream=%{public}s",
              resource.representationId.c_str(), resp.status_code, resp.error.c_str(),
              range.c_str(), describeUrlForLog(resource.url).c_str());
    std::ostringstream body;
    body << "upstream_status=" << resp.status_code
         << "\nupstream_error=" << resp.error
         << "\nrange=" << range << "\n";
    std::string text = body.str();

    // Return 410 Gone for 403 so the player layer can identify URL expiration quickly
    int statusCode = isUrlExpiredError(resp) ? 410 : 502;
    const char* statusText = isUrlExpiredError(resp) ? "Gone" : "Bad Gateway";

    std::ostringstream hdr;
    hdr << "HTTP/1.1 " << statusCode << " " << statusText << "\r\n"
        << "Content-Type: text/plain\r\n"
        << "Content-Length: " << text.size() << "\r\n"
        << "Connection: close\r\n\r\n";
    return sendString(fd, hdr.str()) && sendString(fd, text);
}

bool RangeProxy::serve(int clientFd,
                       const DashStreamResource& resource,
                       const std::string& rangeHeader,
                       bool headOnly) {
    if (resource.url.empty()) {
        sendString(clientFd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return false;
    }

    ByteRange requested;
    parseRangeHeader(rangeHeader, requested);
    RANGE_LOG(LOG_DEBUG, "serve resource=%{public}s isAudio=%{public}d contentLength=%{public}lld clientRange=%{public}s upstream=%{public}s",
              resource.representationId.c_str(), resource.isAudio ? 1 : 0,
              static_cast<long long>(resource.contentLength), rangeHeader.c_str(),
              describeUrlForLog(resource.url).c_str());

    int64_t total = cachedContentLength(resource);
    std::vector<std::pair<std::string, std::string>> customHeaders;

    // Choose the appropriate fetch function based on URL type
    auto fetchChunk = [&](const std::string& rangeSpec) -> HttpResponse {
        std::vector<uint8_t> cachedData;
        if (SegmentMemoryCache::instance().get(resource.url, rangeSpec, cachedData)) {
            HttpResponse resp;
            resp.success = true;
            resp.status_code = 206;
            resp.body = std::move(cachedData);
            return resp;
        }
        HttpResponse resp;
        bool isProgressive = resource.url.find("ratebypass=yes") != std::string::npos;
        if (resource.isYoutubePlayback && !isProgressive) {
            resp = fetchYoutubeRangeWithRetry(resource, rangeSpec, customHeaders);
        } else {
            resp = fetchRangeWithRetry(resource, rangeSpec, customHeaders);
        }
        if (resp.success && !resp.body.empty()) {
            SegmentMemoryCache::instance().put(resource.url, rangeSpec, resp.body);
        }
        return resp;
    };

    if (total <= 0) {
        HttpResponse probe = fetchChunk("0-0");
        if (!probe.success) {
            return sendUpstreamError(clientFd, resource, probe, "0-0");
        }
        int64_t probedTotal = parseTotalFromContentRange(headerValue(probe, "Content-Range"));
        if (probedTotal <= 0 && probe.status_code == 200) {
            probedTotal = parseContentLength(headerValue(probe, "Content-Length"));
        }
        if (probedTotal > 0) {
            total = probedTotal;
            cacheContentLength(resource, total);
            RANGE_LOG(LOG_DEBUG, "probed resource=%{public}s total=%{public}lld",
                      resource.representationId.c_str(), static_cast<long long>(total));
        }
    }

    int64_t start = 0;
    int64_t end = -1;
    if (requested.hasRange) {
        if (requested.suffix && total > 0) {
            int64_t suffixLen = requested.end;
            start = std::max<int64_t>(0, total - suffixLen);
            end = total - 1;
        } else {
            start = std::max<int64_t>(0, requested.start);
            end = requested.end;
        }
    }
    if (total > 0) {
        if (!requested.hasRange) {
            end = std::min<int64_t>(total - 1, CHUNK_BYTES - 1);
        } else if (end < 0 || end >= total) {
            end = total - 1;
        }
        if (start >= total || end < start) {
            std::ostringstream hdr;
            hdr << "HTTP/1.1 416 Range Not Satisfiable\r\n"
                << "Content-Range: bytes */" << total << "\r\n"
                << "Content-Length: 0\r\nConnection: close\r\n\r\n";
            sendString(clientFd, hdr.str());
            return false;
        }
    } else if (end < 0) {
        end = start + CHUNK_BYTES - 1;
    }

    if (headOnly) {
        int64_t declaredLength = end - start + 1;
        std::ostringstream hdr;
        hdr << "HTTP/1.1 206 Partial Content\r\n";
        hdr << "Accept-Ranges: bytes\r\n";
        hdr << "Content-Type: " << contentTypeFor(resource) << "\r\n";
        if (total > 0) {
            hdr << "Content-Range: bytes " << start << "-" << end << "/" << total << "\r\n";
        } else {
            hdr << "Content-Range: bytes " << start << "-" << end << "/*\r\n";
        }
        hdr << "Content-Length: " << declaredLength << "\r\n";
        hdr << "Connection: close\r\n\r\n";
        return sendString(clientFd, hdr.str());
    }

    int64_t firstChunkEnd = std::min<int64_t>(end, start + CHUNK_BYTES - 1);
    std::string firstUpstreamRange = std::to_string(start) + "-" + std::to_string(firstChunkEnd);
    HttpResponse firstResp = fetchChunk(firstUpstreamRange);
    if (firstResp.status_code == 416 && total > 0) {
        std::ostringstream hdr;
        hdr << "HTTP/1.1 416 Range Not Satisfiable\r\n"
            << "Content-Range: bytes */" << total << "\r\n"
            << "Content-Length: 0\r\nConnection: close\r\n\r\n";
        sendString(clientFd, hdr.str());
        return false;
    }
    if (!firstResp.success || firstResp.body.empty()) {
        sendUpstreamError(clientFd, resource, firstResp, firstUpstreamRange);
        return false;
    }

    int64_t upstreamTotal = parseTotalFromContentRange(headerValue(firstResp, "Content-Range"));
    if (upstreamTotal <= 0 && !requested.hasRange && firstResp.status_code == 200) {
        upstreamTotal = parseContentLength(headerValue(firstResp, "Content-Length"));
    }
    if (total <= 0 && upstreamTotal > 0) {
        total = upstreamTotal;
        cacheContentLength(resource, total);
    }

    int64_t firstExpectedBytes = firstChunkEnd - start + 1;
    int64_t firstBytes = std::min<int64_t>(static_cast<int64_t>(firstResp.body.size()), firstExpectedBytes);
    if (total > 0 && end >= total) {
        end = total - 1;
    }
    if (firstBytes > 0 && firstBytes < firstExpectedBytes) {
        end = start + firstBytes - 1;
    }

    int64_t declaredLength = end - start + 1;
    std::ostringstream hdr;
    hdr << "HTTP/1.1 206 Partial Content\r\n";
    hdr << "Accept-Ranges: bytes\r\n";
    hdr << "Content-Type: " << contentTypeFor(resource) << "\r\n";
    if (total > 0) {
        hdr << "Content-Range: bytes " << start << "-" << end << "/" << total << "\r\n";
        hdr << "Content-Length: " << declaredLength << "\r\n";
    } else {
        hdr << "Content-Range: bytes " << start << "-" << end << "/*\r\n";
        hdr << "Content-Length: " << (end - start + 1) << "\r\n";
    }
    hdr << "Connection: close\r\n\r\n";
    RANGE_LOG(LOG_DEBUG, "response resource=%{public}s status=206 range=%{public}lld-%{public}lld declared=%{public}lld headOnly=%{public}d",
              resource.representationId.c_str(), static_cast<long long>(start),
              static_cast<long long>(end), static_cast<long long>(declaredLength), headOnly ? 1 : 0);
    if (!sendString(clientFd, hdr.str()) || headOnly) {
        return true;
    }

    RANGE_LOG(LOG_DEBUG, "upstream ok resource=%{public}s status=%{public}d range=%{public}s bytes=%{public}zu ms=%{public}lld contentRange=%{public}s",
              resource.representationId.c_str(), firstResp.status_code, firstUpstreamRange.c_str(),
              firstResp.body.size(), static_cast<long long>(firstResp.duration_ms),
              headerValue(firstResp, "Content-Range").c_str());
    if (!sendAll(clientFd, firstResp.body.data(), static_cast<size_t>(firstBytes))) {
        RANGE_LOG(LOG_DEBUG, "client closed resource=%{public}s while sending range=%{public}s",
                  resource.representationId.c_str(), firstUpstreamRange.c_str());
        return false;
    }

    int64_t cursor = start;
    cursor += firstBytes;
    while (cursor <= end) {
        int64_t chunkEnd = std::min<int64_t>(end, cursor + CHUNK_BYTES - 1);
        std::string upstreamRange = std::to_string(cursor) + "-" + std::to_string(chunkEnd);
        HttpResponse resp = fetchChunk(upstreamRange);
        if (!resp.success || resp.body.empty()) {
            // Retry once before giving up mid-stream
            RANGE_LOG(LOG_WARN, "mid-stream chunk failed, retrying resource=%{public}s range=%{public}s",
                      resource.representationId.c_str(), upstreamRange.c_str());
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            resp = fetchChunk(upstreamRange);
        }
        if (!resp.success || resp.body.empty()) {
            RANGE_LOG(LOG_ERROR, "upstream failed after headers resource=%{public}s status=%{public}d err=%{public}s range=%{public}s upstream=%{public}s",
                      resource.representationId.c_str(), resp.status_code, resp.error.c_str(),
                      upstreamRange.c_str(), describeUrlForLog(resource.url).c_str());
            return false;
        }
        RANGE_LOG(LOG_DEBUG, "upstream ok resource=%{public}s status=%{public}d range=%{public}s bytes=%{public}zu ms=%{public}lld",
                  resource.representationId.c_str(), resp.status_code, upstreamRange.c_str(),
                  resp.body.size(), static_cast<long long>(resp.duration_ms));
        int64_t expected = chunkEnd - cursor + 1;
        int64_t received = std::min<int64_t>(static_cast<int64_t>(resp.body.size()), expected);
        if (!sendAll(clientFd, resp.body.data(), static_cast<size_t>(received))) {
            RANGE_LOG(LOG_DEBUG, "client closed resource=%{public}s while sending range=%{public}s",
                      resource.representationId.c_str(), upstreamRange.c_str());
            return false;
        }
        cursor += received;
        if (received < expected) {
            break;
        }
    }
    return true;
}

} // namespace yourpipe
