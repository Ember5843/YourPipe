#include "local_dash_server.h"
#include "range_proxy.h"
#include "http_client.h"
#include "sidx_parser.h"

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <cctype>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <netinet/in.h>
#include <sstream>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#include <hilog/log.h>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "LocalDashServer"
#define LOG_DOMAIN 0x3208

#define LDS_LOG(level, fmt, ...) \
    OH_LOG_Print(LOG_APP, level, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

namespace yourpipe {

namespace {
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

std::vector<std::string> splitPath(const std::string& path) {
    std::vector<std::string> parts;
    size_t pos = 0;
    while (pos < path.size()) {
        while (pos < path.size() && path[pos] == '/') {
            pos++;
        }
        size_t next = path.find('/', pos);
        if (next == std::string::npos) {
            next = path.size();
        }
        if (next > pos) {
            parts.push_back(path.substr(pos, next - pos));
        }
        pos = next;
    }
    return parts;
}

bool sendAll(int fd, const std::string& value) {
    size_t sent = 0;
    while (sent < value.size()) {
        ssize_t n = send(fd, value.data() + sent, value.size() - sent, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

std::string rangeOrEmpty(const std::string& start, const std::string& end) {
    if (start.empty() || end.empty()) {
        return "";
    }
    return start + "-" + end;
}

std::string adaptationMime(const DashStreamResource& stream) {
    if (stream.mimeType.empty()) {
        return stream.isAudio ? "audio/mp4" : "video/mp4";
    }
    size_t semi = stream.mimeType.find(';');
    return semi == std::string::npos ? stream.mimeType : stream.mimeType.substr(0, semi);
}

const char* sessionTypeName(LocalMediaSessionType type) {
    switch (type) {
        case LocalMediaSessionType::SingleUrl: return "single";
        case LocalMediaSessionType::YoutubeDual: return "youtube-dual";
        default: return "unknown";
    }
}

std::string describeUrlForLog(const std::string& url) {
    return url;
}

std::string escapeXml(const std::string& input) {
    std::string output;
    output.reserve(input.size());
    for (char ch : input) {
        switch (ch) {
            case '&': output += "&amp;"; break;
            case '<': output += "&lt;"; break;
            case '>': output += "&gt;"; break;
            case '"': output += "&quot;"; break;
            case '\'': output += "&apos;"; break;
            default: output.push_back(ch); break;
        }
    }
    return output;
}

std::string jsonExtractString(const std::string& json, const std::string& key) {
    std::string qkey = "\"" + key + "\"";
    size_t pos = json.find(qkey);
    if (pos == std::string::npos) return "";
    pos = json.find(':', pos + qkey.size());
    if (pos == std::string::npos) return "";
    pos++;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) pos++;
    if (pos >= json.size() || json[pos] != '"') return "";
    pos++;
    std::string out;
    while (pos < json.size()) {
        char c = json[pos++];
        if (c == '"') break;
        if (c == '\\' && pos < json.size()) {
            char e = json[pos++];
            switch (e) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                default: out.push_back(e); break;
            }
        } else {
            out.push_back(c);
        }
    }
    return out;
}

int64_t jsonExtractInt64(const std::string& json, const std::string& key, int64_t fallback = 0) {
    std::string qkey = "\"" + key + "\"";
    size_t pos = json.find(qkey);
    if (pos == std::string::npos) return fallback;
    pos = json.find(':', pos + qkey.size());
    if (pos == std::string::npos) return fallback;
    pos++;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) pos++;
    try {
        return std::stoll(json.substr(pos));
    } catch (...) {
        return fallback;
    }
}

std::string jsonExtractStringOrNumber(const std::string& json, const std::string& key) {
    std::string value = jsonExtractString(json, key);
    if (!value.empty()) return value;
    int64_t n = jsonExtractInt64(json, key, -1);
    return n >= 0 ? std::to_string(n) : "";
}

std::string jsonExtractRawValue(const std::string& json, const std::string& key) {
    std::string qkey = "\"" + key + "\"";
    size_t pos = json.find(qkey);
    if (pos == std::string::npos) return "";
    pos = json.find(':', pos + qkey.size());
    if (pos == std::string::npos) return "";
    pos++;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) pos++;
    if (pos >= json.size()) return "";

    char open = json[pos];
    char close = open == '[' ? ']' : (open == '{' ? '}' : '\0');
    if (close == '\0') return "";

    size_t start = pos;
    int depth = 0;
    bool inString = false;
    bool escape = false;
    for (; pos < json.size(); ++pos) {
        char c = json[pos];
        if (inString) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                inString = false;
            }
            continue;
        }
        if (c == '"') {
            inString = true;
        } else if (c == open) {
            depth++;
        } else if (c == close) {
            depth--;
            if (depth == 0) {
                return json.substr(start, pos - start + 1);
            }
        }
    }
    return "";
}

std::vector<std::string> splitJsonObjects(const std::string& arrayJson) {
    std::vector<std::string> out;
    size_t pos = 0;
    while (pos < arrayJson.size()) {
        size_t start = arrayJson.find('{', pos);
        if (start == std::string::npos) break;
        int depth = 0;
        bool inString = false;
        bool escape = false;
        for (size_t i = start; i < arrayJson.size(); ++i) {
            char c = arrayJson[i];
            if (inString) {
                if (escape) {
                    escape = false;
                } else if (c == '\\') {
                    escape = true;
                } else if (c == '"') {
                    inString = false;
                }
                continue;
            }
            if (c == '"') {
                inString = true;
            } else if (c == '{') {
                depth++;
            } else if (c == '}') {
                depth--;
                if (depth == 0) {
                    out.push_back(arrayJson.substr(start, i - start + 1));
                    pos = i + 1;
                    break;
                }
            }
        }
        if (pos <= start) break;
    }
    return out;
}

DashStreamResource parseResourceObject(const std::string& json, bool isAudio, const std::string& defaultUserAgent) {
    DashStreamResource resource;
    int64_t itag = jsonExtractInt64(json, "itag", 0);
    resource.representationId = jsonExtractString(json, "id");
    if (resource.representationId.empty()) {
        resource.representationId = itag > 0 ? std::to_string(itag) : (isAudio ? "audio" : "video");
    }
    resource.url = jsonExtractString(json, "url");
    resource.mimeType = jsonExtractString(json, "mimeType");
    resource.codecs = jsonExtractString(json, "codecs");
    resource.initRangeStart = jsonExtractStringOrNumber(json, "initRangeStart");
    resource.initRangeEnd = jsonExtractStringOrNumber(json, "initRangeEnd");
    resource.indexRangeStart = jsonExtractStringOrNumber(json, "indexRangeStart");
    resource.indexRangeEnd = jsonExtractStringOrNumber(json, "indexRangeEnd");
    resource.userAgent = jsonExtractString(json, "userAgent");
    if (resource.userAgent.empty()) resource.userAgent = defaultUserAgent;
    resource.referer = jsonExtractString(json, "referer");
    if (resource.referer.empty()) resource.referer = "https://www.youtube.com";
    resource.contentLength = jsonExtractInt64(json, "contentLength", 0);
    resource.bitrate = jsonExtractInt64(json, "bitrate", 0);
    resource.width = static_cast<int32_t>(jsonExtractInt64(json, "width", 0));
    resource.height = static_cast<int32_t>(jsonExtractInt64(json, "height", 0));
    resource.fps = static_cast<int32_t>(jsonExtractInt64(json, "fps", 0));
    resource.approxDurationMs = jsonExtractInt64(json, "approxDurationMs", 0);
    resource.isAudio = isAudio;
    resource.sourceClient = jsonExtractString(json, "sourceClient");
    // Detect YouTube videoplayback URLs
    if (resource.url.find("googlevideo.com") != std::string::npos &&
        resource.url.find("videoplayback") != std::string::npos) {
        resource.isYoutubePlayback = true;
    }
    // Detect OTF streams by delivery method or URL parameter
    if (resource.url.find("otf") != std::string::npos ||
        resource.url.find("sq=") != std::string::npos) {
        resource.isOtf = true;
    }
    // Also check explicit flags from JSON if present
    std::string deliveryMethod = jsonExtractString(json, "deliveryMethod");
    if (deliveryMethod == "DASH" || deliveryMethod == "dash") {
        // keep default; youtube-dual sessions are typically DASH
    }
    std::string otfFlag = jsonExtractString(json, "isOtf");
    if (otfFlag == "true" || otfFlag == "1") {
        resource.isOtf = true;
    }
    return resource;
}

DashSession parseInputJson(const std::string& inputJson) {
    const std::string defaultUa = jsonExtractString(inputJson, "userAgent").empty()
        ? "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36"
        : jsonExtractString(inputJson, "userAgent");
    DashSession session;
    session.durationMs = jsonExtractInt64(inputJson, "durationMs", 0);

    std::string type = jsonExtractString(inputJson, "type");
    if (type == "single" || type == "single_url" || type == "url") {
        std::string resourceJson = jsonExtractRawValue(inputJson, "resource");
        session.type = LocalMediaSessionType::SingleUrl;
        session.single = parseResourceObject(resourceJson.empty() ? inputJson : resourceJson, false, defaultUa);
        if (session.single.mimeType.empty()) {
            session.single.mimeType = "application/octet-stream";
        }
        return session;
    }

    session.type = LocalMediaSessionType::YoutubeDual;
    for (const auto& raw : splitJsonObjects(jsonExtractRawValue(inputJson, "videos"))) {
        auto resource = parseResourceObject(raw, false, defaultUa);
        if (!resource.url.empty()) session.videos.push_back(resource);
    }
    for (const auto& raw : splitJsonObjects(jsonExtractRawValue(inputJson, "audios"))) {
        auto resource = parseResourceObject(raw, true, defaultUa);
        if (!resource.url.empty()) session.audios.push_back(resource);
    }

    std::string videoJson = jsonExtractRawValue(inputJson, "video");
    if (!videoJson.empty()) {
        auto resource = parseResourceObject(videoJson, false, defaultUa);
        if (!resource.url.empty()) session.videos.push_back(resource);
    }
    std::string audioJson = jsonExtractRawValue(inputJson, "audio");
    if (!audioJson.empty()) {
        auto resource = parseResourceObject(audioJson, true, defaultUa);
        if (!resource.url.empty()) session.audios.push_back(resource);
    }

    if (!session.videos.empty()) session.video = session.videos[0];
    if (!session.audios.empty()) {
        session.audio = session.audios[0];
        session.hasAudio = true;
    }
    return session;
}
}

LocalDashServer& LocalDashServer::instance() {
    static LocalDashServer server;
    return server;
}

LocalDashServer::~LocalDashServer() {
    stop();
}

bool LocalDashServer::start() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (running_.load()) {
        return true;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        LDS_LOG(LOG_ERROR, "socket failed errno=%{public}d", errno);
        return false;
    }

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(0);
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        LDS_LOG(LOG_ERROR, "bind failed errno=%{public}d", errno);
        close(fd);
        return false;
    }

    socklen_t len = sizeof(addr);
    if (getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
        LDS_LOG(LOG_ERROR, "getsockname failed errno=%{public}d", errno);
        close(fd);
        return false;
    }
    if (listen(fd, 16) != 0) {
        LDS_LOG(LOG_ERROR, "listen failed errno=%{public}d", errno);
        close(fd);
        return false;
    }

    listenFd_ = fd;
    port_ = ntohs(addr.sin_port);
    running_.store(true);
    acceptThread_ = std::thread(&LocalDashServer::acceptLoop, this);
    LDS_LOG(LOG_INFO, "started on 127.0.0.1:%{public}d", port_);
    return true;
}

void LocalDashServer::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_.exchange(false)) {
            return;
        }
        if (listenFd_ >= 0) {
            shutdown(listenFd_, SHUT_RDWR);
            close(listenFd_);
            listenFd_ = -1;
        }
        port_ = 0;
    }
    if (acceptThread_.joinable()) {
        acceptThread_.join();
    }
    DashSessionStore::instance().clear();
    LDS_LOG(LOG_INFO, "stopped");
}

bool LocalDashServer::isRunning() const {
    return running_.load();
}

int LocalDashServer::port() const {
    return port_;
}

std::string LocalDashServer::createSession(const DashStreamResource& video,
                                           const DashStreamResource& audio,
                                           bool hasAudio,
                                           int64_t durationMs) {
    if (!start()) {
        return "";
    }
    DashSession session;
    session.type = LocalMediaSessionType::YoutubeDual;
    session.durationMs = durationMs;
    session.video = video;
    session.audio = audio;
    session.videos.push_back(video);
    session.hasAudio = hasAudio;
    if (hasAudio) {
        session.audios.push_back(audio);
    }
    std::string id = DashSessionStore::instance().add(std::move(session));
    LDS_LOG(LOG_INFO, "created session %{public}s v=%{public}s a=%{public}s",
            id.c_str(), video.representationId.c_str(), hasAudio ? audio.representationId.c_str() : "");
    LDS_LOG(LOG_INFO, "session %{public}s upstream video=%{public}s audio=%{public}s",
            id.c_str(), describeUrlForLog(video.url).c_str(),
            hasAudio ? describeUrlForLog(audio.url).c_str() : "");
    return id;
}

std::string LocalDashServer::createSessionFromInputJson(const std::string& inputJson) {
    if (!start()) {
        return "";
    }
    DashSession session = parseInputJson(inputJson);
    bool valid = session.type == LocalMediaSessionType::SingleUrl
        ? !session.single.url.empty()
        : (!session.videos.empty() && !session.audios.empty());
    if (!valid) {
        LDS_LOG(LOG_ERROR, "createSessionFromInputJson: invalid input");
        return "";
    }
    std::string id = DashSessionStore::instance().add(std::move(session));
    auto created = DashSessionStore::instance().get(id);
    if (created) {
        LDS_LOG(LOG_INFO, "created local media session %{public}s type=%{public}s videos=%{public}zu audios=%{public}zu single=%{public}s",
                id.c_str(), sessionTypeName(created->type), created->videos.size(), created->audios.size(),
                describeUrlForLog(created->single.url).c_str());
        if (!created->videos.empty()) {
            LDS_LOG(LOG_INFO, "session %{public}s video[0] itag=%{public}s mime=%{public}s range=%{public}s-%{public}s upstream=%{public}s",
                    id.c_str(), created->videos[0].representationId.c_str(), created->videos[0].mimeType.c_str(),
                    created->videos[0].initRangeStart.c_str(), created->videos[0].indexRangeEnd.c_str(),
                    describeUrlForLog(created->videos[0].url).c_str());
        }
        if (!created->audios.empty()) {
            LDS_LOG(LOG_INFO, "session %{public}s audio[0] itag=%{public}s mime=%{public}s range=%{public}s-%{public}s upstream=%{public}s",
                    id.c_str(), created->audios[0].representationId.c_str(), created->audios[0].mimeType.c_str(),
                    created->audios[0].initRangeStart.c_str(), created->audios[0].indexRangeEnd.c_str(),
                    describeUrlForLog(created->audios[0].url).c_str());
        }
    }
    return id;
}

bool LocalDashServer::refreshSessionFromInputJson(const std::string& sessionId, const std::string& inputJson) {
    if (sessionId.empty()) return false;
    DashSession session = parseInputJson(inputJson);
    bool valid = session.type == LocalMediaSessionType::SingleUrl
        ? !session.single.url.empty()
        : (!session.videos.empty() && !session.audios.empty());
    if (!valid) return false;
    session.id = sessionId;
    DashSessionStore::instance().add(std::move(session));
    auto refreshed = DashSessionStore::instance().get(sessionId);
    LDS_LOG(LOG_INFO, "refreshed local media session %{public}s type=%{public}s videos=%{public}zu audios=%{public}zu",
            sessionId.c_str(), refreshed ? sessionTypeName(refreshed->type) : "unknown",
            refreshed ? refreshed->videos.size() : 0, refreshed ? refreshed->audios.size() : 0);
    return true;
}

bool LocalDashServer::destroySession(const std::string& sessionId) {
    return DashSessionStore::instance().remove(sessionId);
}

std::string LocalDashServer::manifestUrl(const std::string& sessionId) const {
    if (!running_.load() || port_ <= 0 || sessionId.empty()) {
        return "";
    }
    return "http://127.0.0.1:" + std::to_string(port_) + "/session/" + sessionId + "/manifest.mpd";
}

std::string LocalDashServer::playbackUrl(const std::string& sessionId) const {
    if (!running_.load() || port_ <= 0 || sessionId.empty()) {
        return "";
    }
    auto session = DashSessionStore::instance().get(sessionId);
    if (!session) {
        return "";
    }
    std::string base = "http://127.0.0.1:" + std::to_string(port_) + "/session/" + sessionId;
    if (session->type == LocalMediaSessionType::SingleUrl) {
        std::string url = base + "/resource/main";
        LDS_LOG(LOG_INFO, "playbackUrl session=%{public}s type=single url=%{public}s", sessionId.c_str(), url.c_str());
        return url;
    }
    std::string url = base + "/master.m3u8";
    LDS_LOG(LOG_INFO, "playbackUrl session=%{public}s type=%{public}s url=%{public}s",
            sessionId.c_str(), sessionTypeName(session->type), url.c_str());
    return url;
}

void LocalDashServer::destroyAllSessions() {
    DashSessionStore::instance().clear();
}

void LocalDashServer::acceptLoop() {
    while (running_.load()) {
        sockaddr_in peer{};
        socklen_t len = sizeof(peer);
        int client = accept(listenFd_, reinterpret_cast<sockaddr*>(&peer), &len);
        if (client < 0) {
            if (running_.load()) {
                LDS_LOG(LOG_WARN, "accept failed errno=%{public}d", errno);
            }
            continue;
        }
        if (peer.sin_addr.s_addr != htonl(INADDR_LOOPBACK)) {
            close(client);
            continue;
        }
        std::thread(&LocalDashServer::handleClient, this, client).detach();
    }
}

void LocalDashServer::handleClient(int clientFd) {
    std::string request;
    char buf[4096];
    while (request.find("\r\n\r\n") == std::string::npos && request.size() < 32768) {
        ssize_t n = recv(clientFd, buf, sizeof(buf), 0);
        if (n <= 0) {
            close(clientFd);
            return;
        }
        request.append(buf, static_cast<size_t>(n));
    }

    std::istringstream input(request);
    std::string requestLine;
    std::getline(input, requestLine);
    if (!requestLine.empty() && requestLine.back() == '\r') {
        requestLine.pop_back();
    }

    std::istringstream rl(requestLine);
    std::string method;
    std::string path;
    rl >> method >> path;
    std::string rangeHeader;
    std::string line;
    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line.empty()) {
            break;
        }
        size_t colon = line.find(':');
        if (colon == std::string::npos) {
            continue;
        }
        std::string key = lower(trim(line.substr(0, colon)));
        std::string value = trim(line.substr(colon + 1));
        if (key == "range") {
            rangeHeader = value;
        }
    }

    routeRequest(clientFd, method, path, rangeHeader);
    close(clientFd);
}

bool LocalDashServer::routeRequest(int clientFd,
                                   const std::string& method,
                                   const std::string& path,
                                   const std::string& rangeHeader) {
    if (method != "GET" && method != "HEAD") {
        return sendResponse(clientFd, 405, "Method Not Allowed", "text/plain", "");
    }

    std::string pathOnly = path;
    size_t q = pathOnly.find('?');
    if (q != std::string::npos) {
        pathOnly = pathOnly.substr(0, q);
    }
    auto parts = splitPath(pathOnly);
    if (parts.size() < 3 || parts[0] != "session") {
        LDS_LOG(LOG_WARN, "route miss method=%{public}s path=%{public}s", method.c_str(), pathOnly.c_str());
        return sendResponse(clientFd, 404, "Not Found", "text/plain", "");
    }

    auto session = DashSessionStore::instance().get(parts[1]);
    if (!session) {
        LDS_LOG(LOG_WARN, "route no-session method=%{public}s path=%{public}s range=%{public}s",
                method.c_str(), pathOnly.c_str(), rangeHeader.c_str());
        return sendResponse(clientFd, 404, "Not Found", "text/plain", "");
    }
    LDS_LOG(LOG_DEBUG, "route method=%{public}s path=%{public}s range=%{public}s session=%{public}s type=%{public}s",
            method.c_str(), pathOnly.c_str(), rangeHeader.c_str(), session->id.c_str(), sessionTypeName(session->type));

    if (parts.size() == 3 && parts[2] == "manifest.mpd") {
        if (session->type == LocalMediaSessionType::SingleUrl) {
            return sendResponse(clientFd, 404, "Not Found", "text/plain", "");
        }
        std::string manifest = method == "HEAD" ? "" : buildManifest(*session, port_);
        LDS_LOG(LOG_DEBUG, "local DASH manifest session=%{public}s bytes=%{public}zu videos=%{public}zu audios=%{public}zu",
                session->id.c_str(), manifest.size(), session->videos.size(), session->audios.size());
        return sendResponse(clientFd, 200, "OK", "application/dash+xml", manifest);
    }

    if (parts.size() == 3 && parts[2] == "master.m3u8") {
        if (session->type == LocalMediaSessionType::SingleUrl) {
            return sendResponse(clientFd, 404, "Not Found", "text/plain", "");
        }
        std::string playlist = method == "HEAD" ? "" : buildMasterPlaylist(*session);
        return sendResponse(clientFd, 200, "OK", "application/vnd.apple.mpegurl", playlist);
    }

    if (parts.size() == 3 && parts[2] == "video.m3u8") {
        if (session->videos.empty()) {
            return sendResponse(clientFd, 404, "Not Found", "text/plain", "");
        }
        std::string playlist = method == "HEAD" ? "" : buildMediaPlaylist(*session, session->video, *session->videoHls, "video/0");
        return sendResponse(clientFd, 200, "OK", "application/vnd.apple.mpegurl", playlist);
    }

    if (parts.size() == 3 && parts[2] == "audio.m3u8") {
        if (!session->hasAudio || session->audios.empty()) {
            return sendResponse(clientFd, 404, "Not Found", "text/plain", "");
        }
        std::string playlist = method == "HEAD" ? "" : buildMediaPlaylist(*session, session->audio, *session->audioHls, "audio/0");
        return sendResponse(clientFd, 200, "OK", "application/vnd.apple.mpegurl", playlist);
    }

    if (parts.size() >= 4) {
        if (parts[2] == "resource" && parts[3] == "main") {
            return RangeProxy::serve(clientFd, session->single, rangeHeader, method == "HEAD");
        }
        if (parts[2] == "video") {
            size_t idx = 0;
            try {
                idx = static_cast<size_t>(std::stoul(parts[3]));
            } catch (...) {
                idx = 0;
            }
            if (idx < session->videos.size()) {
                return RangeProxy::serve(clientFd, session->videos[idx], rangeHeader, method == "HEAD");
            }
            return sendResponse(clientFd, 404, "Not Found", "text/plain", "");
        }
        if (parts[2] == "audio" && session->hasAudio) {
            size_t idx = 0;
            try {
                idx = static_cast<size_t>(std::stoul(parts[3]));
            } catch (...) {
                idx = 0;
            }
            if (idx < session->audios.size()) {
                return RangeProxy::serve(clientFd, session->audios[idx], rangeHeader, method == "HEAD");
            }
            return sendResponse(clientFd, 404, "Not Found", "text/plain", "");
        }
    }

    return sendResponse(clientFd, 404, "Not Found", "text/plain", "");
}

std::string LocalDashServer::buildManifest(const DashSession& session, int port) {
    auto appendRep = [&](std::ostringstream& mpd,
                         const DashStreamResource& stream,
                         const std::string& localUrl) {
        mpd << "      <Representation id=\"" << escapeXml(stream.representationId)
            << "\" codecs=\"" << escapeXml(stream.codecs)
            << "\" bandwidth=\"" << stream.bitrate << "\"";
        if (!stream.isAudio) {
            if (stream.width > 0) mpd << " width=\"" << stream.width << "\"";
            if (stream.height > 0) mpd << " height=\"" << stream.height << "\"";
            if (stream.fps > 0) mpd << " frameRate=\"" << stream.fps << "\"";
        }
        mpd << ">\n";
        mpd << "        <BaseURL>" << escapeXml(localUrl) << "</BaseURL>\n";
        std::string indexRange = rangeOrEmpty(stream.indexRangeStart, stream.indexRangeEnd);
        std::string initRange = rangeOrEmpty(stream.initRangeStart, stream.initRangeEnd);
        if (!indexRange.empty() && !initRange.empty()) {
            mpd << "        <SegmentBase indexRangeExact=\"true\" indexRange=\"" << indexRange << "\">\n";
            mpd << "          <Initialization range=\"" << initRange << "\"/>\n";
            mpd << "        </SegmentBase>\n";
        } else if (stream.isOtf) {
            // OTF streams use segment sequence numbers (sq=) instead of byte ranges
            mpd << "        <SegmentTemplate timescale=\"1000\" media=\"&amp;sq=$Number$\" startNumber=\"0\"/>\n";
        }
        mpd << "      </Representation>\n";
    };

    int64_t durationMs = session.durationMs > 0 ? session.durationMs : session.video.approxDurationMs;
    if (durationMs <= 0 && session.hasAudio) {
        durationMs = session.audio.approxDurationMs;
    }
    if (durationMs <= 0) {
        // 尝试从 bitrate + contentLength 估算 duration（毫秒）
        auto estimateDurationMs = [](const DashStreamResource& s) -> int64_t {
            if (s.bitrate > 0 && s.contentLength > 0) {
                return static_cast<int64_t>((s.contentLength * 8.0 / s.bitrate) * 1000.0);
            }
            return 0;
        };
        durationMs = estimateDurationMs(session.video);
        if (durationMs <= 0 && session.hasAudio) {
            durationMs = estimateDurationMs(session.audio);
        }
    }
    if (durationMs <= 0) {
        // Fallback：使用一个较大的默认值（24小时），避免生成 PT0.001S 的无效 MPD
        durationMs = 86400000;
        LDS_LOG(LOG_WARN, "buildManifest: duration unknown, fallback to 24h for session=%{public}s", session.id.c_str());
    }

    std::ostringstream mpd;
    mpd << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    mpd << "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" "
        << "profiles=\"urn:mpeg:dash:profile:isoff-on-demand:2011\" "
        << "type=\"static\" mediaPresentationDuration=\"PT"
        << (durationMs / 1000.0) << "S\" minBufferTime=\"PT5S\">\n";
    mpd << "  <Period>\n";

    std::string base = "http://127.0.0.1:" + std::to_string(port) + "/session/" + session.id;
    const DashStreamResource& video = session.videos.empty() ? session.video : session.videos[0];
    const DashStreamResource& audio = session.audios.empty() ? session.audio : session.audios[0];

    mpd << "    <AdaptationSet mimeType=\"" << escapeXml(adaptationMime(video))
        << "\" contentType=\"video\" subsegmentAlignment=\"true\" subsegmentStartsWithSAP=\"1\">\n";
    appendRep(mpd, video, base + "/video/0");
    mpd << "    </AdaptationSet>\n";

    if (session.hasAudio) {
        mpd << "    <AdaptationSet mimeType=\"" << escapeXml(adaptationMime(audio))
            << "\" contentType=\"audio\" subsegmentAlignment=\"true\" subsegmentStartsWithSAP=\"1\">\n";
        appendRep(mpd, audio, base + "/audio/0");
        mpd << "    </AdaptationSet>\n";
    }

    mpd << "  </Period>\n";
    mpd << "</MPD>\n";
    return mpd.str();
}

std::string LocalDashServer::buildMasterPlaylist(const DashSession& session) {
    std::ostringstream m3u;
    m3u << "#EXTM3U\n";
    m3u << "#EXT-X-VERSION:7\n";
    m3u << "#EXT-X-INDEPENDENT-SEGMENTS\n\n";

    if (session.hasAudio && !session.audios.empty()) {
        m3u << "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\","
            << "NAME=\"default\",DEFAULT=YES,URI=\"audio.m3u8\"\n\n";
    }

    const auto& v = session.video;
    m3u << "#EXT-X-STREAM-INF:BANDWIDTH=" << v.bitrate;
    std::string codecs = v.codecs;
    if (session.hasAudio && !session.audio.codecs.empty()) {
        codecs += "," + session.audio.codecs;
    }
    if (!codecs.empty()) m3u << ",CODECS=\"" << codecs << "\"";
    if (v.width > 0 && v.height > 0) {
        m3u << ",RESOLUTION=" << v.width << "x" << v.height;
    }
    if (v.fps > 0) m3u << ",FRAME-RATE=" << v.fps;
    if (session.hasAudio) m3u << ",AUDIO=\"audio\"";
    m3u << "\nvideo.m3u8\n";

    return m3u.str();
}

bool LocalDashServer::fetchAndParseSidx(const DashStreamResource& stream, HlsStreamCache& cache) {
    std::lock_guard<std::mutex> lock(cache.mu);
    if (cache.fetched) return cache.valid;
    cache.fetched = true;

    if (stream.indexRangeStart.empty() || stream.indexRangeEnd.empty()) {
        return false;
    }

    int64_t initStart = 0, initEnd = 0;
    try {
        initStart = std::stoll(stream.initRangeStart);
        initEnd = std::stoll(stream.initRangeEnd);
    } catch (...) {}
    cache.initOffset = initStart;
    cache.initSize = initEnd - initStart + 1;

    std::string rangeSpec = stream.indexRangeStart + "-" + stream.indexRangeEnd;

    HttpResponse resp;
    if (stream.isYoutubePlayback) {
        // YouTube Android streams require POST with range= query param
        std::string fetchUrl = stream.url;
        fetchUrl += (fetchUrl.find('?') != std::string::npos ? "&" : "?");
        fetchUrl += "range=" + rangeSpec;
        std::vector<std::pair<std::string, std::string>> hdrs;
        if (!stream.userAgent.empty()) hdrs.push_back({"User-Agent", stream.userAgent});
        if (!stream.referer.empty()) hdrs.push_back({"Referer", stream.referer});
        hdrs.push_back({"Accept-Encoding", "identity"});
        // Match PipePipe: Android/iOS POST with empty body
        resp = http_fetch(fetchUrl, "POST", {}, hdrs);
    } else {
        resp = http_get_range(stream.url, rangeSpec, stream.userAgent, stream.referer);
    }
    if (!resp.success || resp.body.empty()) {
        LDS_LOG(LOG_WARN, "fetchAndParseSidx failed for %{public}s", stream.representationId.c_str());
        return false;
    }

    int64_t sidxEnd = 0;
    try { sidxEnd = std::stoll(stream.indexRangeEnd) + 1; } catch (...) {}

    SidxInfo info = parseSidxBox(resp.body.data(), resp.body.size(), sidxEnd);
    if (!info.valid || info.segments.empty()) {
        LDS_LOG(LOG_WARN, "sidx parse failed for %{public}s", stream.representationId.c_str());
        return false;
    }

    cache.offsets.reserve(info.segments.size());
    cache.sizes.reserve(info.segments.size());
    cache.durations.reserve(info.segments.size());
    double maxDur = 0;
    for (const auto& seg : info.segments) {
        cache.offsets.push_back(seg.offset);
        cache.sizes.push_back(seg.size);
        cache.durations.push_back(seg.duration);
        if (seg.duration > maxDur) maxDur = seg.duration;
    }
    cache.targetDuration = std::ceil(maxDur);
    if (cache.targetDuration < 1) cache.targetDuration = 10;
    cache.valid = true;
    return true;
}

std::string LocalDashServer::buildMediaPlaylist(
    DashSession& session,
    const DashStreamResource& stream,
    HlsStreamCache& cache,
    const std::string& dataEndpoint)
{
    {
        std::lock_guard<std::mutex> lock(cache.mu);
        if (!cache.cachedPlaylist.empty()) return cache.cachedPlaylist;
    }

    // fetchAndParseSidx acquires its own lock internally
    fetchAndParseSidx(stream, cache);

    std::lock_guard<std::mutex> lock(cache.mu);
    if (!cache.cachedPlaylist.empty()) return cache.cachedPlaylist;

    std::ostringstream m3u;
    m3u << "#EXTM3U\n";
    m3u << "#EXT-X-VERSION:7\n";

    if (cache.valid && !cache.offsets.empty()) {
        m3u << "#EXT-X-TARGETDURATION:" << (int)cache.targetDuration << "\n";
        m3u << "#EXT-X-PLAYLIST-TYPE:VOD\n";
        m3u << "#EXT-X-MAP:URI=\"" << dataEndpoint << "\",BYTERANGE=\""
            << cache.initSize << "@" << cache.initOffset << "\"\n\n";

        for (size_t i = 0; i < cache.offsets.size(); i++) {
            m3u << "#EXTINF:" << std::fixed;
            m3u.precision(3);
            m3u << cache.durations[i] << ",\n";
            m3u << "#EXT-X-BYTERANGE:" << cache.sizes[i] << "@" << cache.offsets[i] << "\n";
            m3u << dataEndpoint << "\n";
        }
    } else {
        // Fallback: single segment covering entire file
        double dur = stream.approxDurationMs > 0 ? stream.approxDurationMs / 1000.0 : 3600.0;
        m3u << "#EXT-X-TARGETDURATION:" << (int)std::ceil(dur) << "\n";
        m3u << "#EXT-X-PLAYLIST-TYPE:VOD\n";
        if (cache.initSize > 0) {
            m3u << "#EXT-X-MAP:URI=\"" << dataEndpoint << "\",BYTERANGE=\""
                << cache.initSize << "@" << cache.initOffset << "\"\n\n";
        }
        m3u << "#EXTINF:" << std::fixed;
        m3u.precision(3);
        m3u << dur << ",\n";
        if (stream.contentLength > 0) {
            int64_t dataStart = cache.initSize > 0 ? cache.initOffset + cache.initSize : 0;
            m3u << "#EXT-X-BYTERANGE:" << (stream.contentLength - dataStart) << "@" << dataStart << "\n";
        }
        m3u << dataEndpoint << "\n";
    }
    m3u << "#EXT-X-ENDLIST\n";

    cache.cachedPlaylist = m3u.str();
    return cache.cachedPlaylist;
}

bool LocalDashServer::sendResponse(int fd,
                                   int statusCode,
                                   const std::string& statusText,
                                   const std::string& contentType,
                                   const std::string& body) {
    std::ostringstream hdr;
    hdr << "HTTP/1.1 " << statusCode << " " << statusText << "\r\n";
    hdr << "Content-Type: " << contentType << "\r\n";
    hdr << "Content-Length: " << body.size() << "\r\n";
    hdr << "Connection: close\r\n\r\n";
    return sendAll(fd, hdr.str()) && (body.empty() || sendAll(fd, body));
}

} // namespace yourpipe
