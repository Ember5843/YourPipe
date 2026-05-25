#pragma once

#include "dash_session.h"
#include "sidx_parser.h"

#include <atomic>
#include <mutex>
#include <string>
#include <thread>

namespace yourpipe {

class LocalDashServer {
public:
    static LocalDashServer& instance();

    bool start();
    void stop();
    bool isRunning() const;
    int port() const;

    std::string createSession(const DashStreamResource& video,
                              const DashStreamResource& audio,
                              bool hasAudio,
                              int64_t durationMs);
    std::string createSessionFromInputJson(const std::string& inputJson);
    bool refreshSessionFromInputJson(const std::string& sessionId, const std::string& inputJson);
    bool destroySession(const std::string& sessionId);
    std::string manifestUrl(const std::string& sessionId) const;
    std::string playbackUrl(const std::string& sessionId) const;
    void destroyAllSessions();

private:
    LocalDashServer() = default;
    ~LocalDashServer();
    LocalDashServer(const LocalDashServer&) = delete;
    LocalDashServer& operator=(const LocalDashServer&) = delete;

    void acceptLoop();
    void handleClient(int clientFd);
    bool routeRequest(int clientFd,
                      const std::string& method,
                      const std::string& path,
                      const std::string& rangeHeader);
    static std::string buildManifest(const DashSession& session, int port);
    static std::string buildMasterPlaylist(const DashSession& session);
    std::string buildMediaPlaylist(DashSession& session,
                                   const DashStreamResource& stream,
                                   HlsStreamCache& cache,
                                   const std::string& dataEndpoint);
    bool fetchAndParseSidx(const DashStreamResource& stream, HlsStreamCache& cache);
    static bool sendResponse(int fd,
                             int statusCode,
                             const std::string& statusText,
                             const std::string& contentType,
                             const std::string& body);

    std::atomic<bool> running_{false};
    int listenFd_ = -1;
    int port_ = 0;
    std::thread acceptThread_;
    mutable std::mutex mutex_;
};

} // namespace yourpipe
