#include "http_client.h"
#include <curl/curl.h>
#include <cstring>
#include <chrono>
#include <hilog/log.h>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "HttpClient"
#define LOG_DOMAIN 0x3203

namespace {

size_t writeCallback(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* body = static_cast<std::vector<uint8_t>*>(userdata);
    size_t total = size * nmemb;
    if (total > 0 && ptr) {
        body->insert(body->end(), reinterpret_cast<uint8_t*>(ptr),
                     reinterpret_cast<uint8_t*>(ptr) + total);
    }
    return total;
}

size_t headerCallback(char* buffer, size_t size, size_t nitems, void* userdata) {
    auto* headers = static_cast<std::vector<std::pair<std::string, std::string>>*>(userdata);
    size_t total = size * nitems;
    std::string line(buffer, total);
    // Remove trailing \r\n
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) {
        line.pop_back();
    }
    // Skip HTTP status line (e.g. "HTTP/1.1 200 OK")
    if (line.empty() || line.find("HTTP/") == 0) {
        return total;
    }
    size_t colon = line.find(':');
    if (colon != std::string::npos && colon > 0) {
        std::string key = line.substr(0, colon);
        std::string value = line.substr(colon + 1);
        // trim leading spaces from value
        size_t start = value.find_first_not_of(" \t");
        if (start != std::string::npos) {
            value = value.substr(start);
        }
        headers->push_back({key, value});
    }
    return total;
}

int xferinfoCallback(void *clientp, curl_off_t dltotal, curl_off_t dlnow,
                     curl_off_t ultotal, curl_off_t ulnow) {
    const std::atomic<bool>* cancel = static_cast<const std::atomic<bool>*>(clientp);
    if (cancel && cancel->load()) {
        return 1; // non-zero aborts the transfer
    }
    return 0;
}

} // namespace

HttpResponse http_fetch(const std::string& url,
                        const std::string& method,
                        const std::vector<uint8_t>& body,
                        const std::vector<std::pair<std::string, std::string>>& headers,
                        const std::atomic<bool>* cancel,
                        int timeout_ms) {
    HttpResponse resp;

    CURL* curl = curl_easy_init();
    if (!curl) {
        resp.error = "curl_easy_init failed";
        return resp;
    }

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());

    // Method
    if (method == "POST") {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        if (!body.empty()) {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
            // COPYPOSTFIELDS copies the data so we don't need to keep body alive
            curl_easy_setopt(curl, CURLOPT_COPYPOSTFIELDS, reinterpret_cast<const char*>(body.data()));
        } else {
            // Empty POST body: match PipePipe / Java HttpURLConnection behavior.
            // Do NOT add Content-Length: 0 manually. Setting POSTFIELDSIZE=0 tells
            // libcurl to send an empty POST without a body.
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, 0L);
        }
    } else if (method == "HEAD") {
        curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
    }

    // Headers
    struct curl_slist* hdrs = nullptr;
    for (const auto& h : headers) {
        hdrs = curl_slist_append(hdrs, (h.first + ": " + h.second).c_str());
    }
    if (hdrs) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    }

    // Response body writer
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp.body);

    // Response header parser
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, headerCallback);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &resp.headers);

    // Timeouts
    const auto& cfg = NetTimeoutConfig::getDefault();
    int connectTimeout = (timeout_ms > 0) ? timeout_ms : cfg.connectTimeoutMs;
    int totalTimeout   = (timeout_ms > 0) ? timeout_ms : cfg.readTimeoutMs;
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, static_cast<long>(connectTimeout));
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, static_cast<long>(totalTimeout));

    // Follow redirects automatically (same as Java HttpURLConnection default)
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 10L);

    // SSL verification — use HarmonyOS system CA cert directory
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_CAPATH, "/system/etc/security/cacerts");

    // Progress / cancellation
    if (cancel) {
        curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, xferinfoCallback);
        curl_easy_setopt(curl, CURLOPT_XFERINFODATA, const_cast<std::atomic<bool>*>(cancel));
        curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    }

    // Measure duration
    auto startTime = std::chrono::steady_clock::now();
    CURLcode res = curl_easy_perform(curl);
    auto endTime = std::chrono::steady_clock::now();

    if (res == CURLE_OK) {
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        resp.status_code = static_cast<int>(status);
        resp.success = (resp.status_code >= 200 && resp.status_code < 300);
    } else {
        resp.error = std::string("curl error: ") + curl_easy_strerror(res);
    }

    resp.duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(endTime - startTime).count();

    if (hdrs) curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);
    return resp;
}

HttpResponse http_get(const std::string& url,
                      const std::vector<std::pair<std::string, std::string>>& headers,
                      const std::atomic<bool>* cancel,
                      int timeout_ms) {
    return http_fetch(url, "GET", {}, headers, cancel, timeout_ms);
}
