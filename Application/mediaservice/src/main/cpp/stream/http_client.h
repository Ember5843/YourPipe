#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include <atomic>

/**
 * HTTP client wrapper using libcurl.
 * Replaces RCP with libcurl for full control over request/response handling.
 */

struct HttpResponse {
    int status_code = 0;
    std::vector<uint8_t> body;
    std::vector<std::pair<std::string, std::string>> headers;
    bool success = false;
    std::string error;
    /** Download duration in milliseconds (measured by caller). */
    int64_t duration_ms = 0;
};

/**
 * Centralized network timeout configuration.
 * Aligned with ExoPlayer DefaultHttpDataSource defaults:
 *   connectTimeout = 15000 ms (mobile-friendly upper bound of 8000-15000 range)
 *   readTimeout    = 15000 ms
 *
 * All HTTP clients (C++ curl, ArkTS HttpDownloader, HLS fetch) should read
 * from the same config source so adjustments propagate without code changes.
 */
struct NetTimeoutConfig {
    /** Connection timeout in milliseconds. 0 = infinite (not recommended). */
    int connectTimeoutMs = 15000;
    /** Read timeout in milliseconds. 0 = infinite (not recommended). */
    int readTimeoutMs = 15000;

    static const NetTimeoutConfig& getDefault() {
        static NetTimeoutConfig instance;
        return instance;
    }
};

/**
 * Synchronous HTTP GET. Blocks until response completes or timeout.
 * @param url     Full URL (https:// supported natively by RCP)
 * @param headers Extra headers, e.g. {{"User-Agent","..."},{"Referer","..."}}
 * @param cancel  Optional atomic flag; if set to true during the call,
 *                the underlying request will be cancelled via HMS_Rcp_CancelRequest.
 * @param timeout_ms Optional timeout in milliseconds. 0 = no timeout (wait indefinitely).
 *                   Defaults to NetTimeoutConfig::readTimeoutMs for consistency.
 * @return        HttpResponse
 */
HttpResponse http_get(const std::string& url,
                      const std::vector<std::pair<std::string, std::string>>& headers = {},
                      const std::atomic<bool>* cancel = nullptr,
                      int timeout_ms = 0);

/**
 * Generic HTTP fetch supporting custom method and body.
 * @param method  HTTP method string: "GET" or "POST"
 * @param body    Request body bytes (empty for GET)
 */
HttpResponse http_fetch(const std::string& url,
                        const std::string& method,
                        const std::vector<uint8_t>& body,
                        const std::vector<std::pair<std::string, std::string>>& headers = {},
                        const std::atomic<bool>* cancel = nullptr,
                        int timeout_ms = 0);

/**
 * Convenience wrapper for Range request.
 * @param custom_headers Extra headers to inject (e.g. Authorization, X-Custom-Header).
 *                       These are applied AFTER user_agent/referer so they can override.
 * @param timeout_ms Optional timeout. 0 = use NetTimeoutConfig::readTimeoutMs.
 */
inline HttpResponse http_get_range(const std::string& url,
                                   const std::string& range,
                                   const std::string& user_agent = "",
                                   const std::string& referer = "",
                                   const std::vector<std::pair<std::string, std::string>>& custom_headers = {},
                                   const std::atomic<bool>* cancel = nullptr,
                                   int timeout_ms = 0) {
    std::vector<std::pair<std::string, std::string>> hdrs;
    if (!range.empty())      hdrs.push_back({"Range", "bytes=" + range});
    if (!user_agent.empty()) hdrs.push_back({"User-Agent", user_agent});
    if (!referer.empty())    hdrs.push_back({"Referer", referer});
    // Force uncompressed so we can parse raw MP4/WebM boxes.
    hdrs.push_back({"Accept-Encoding", "identity"});
    // Inject custom headers (highest priority, can override defaults)
    for (const auto& h : custom_headers) {
        hdrs.push_back(h);
    }
    return http_get(url, hdrs, cancel, timeout_ms);
}
