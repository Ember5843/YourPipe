#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace yourpipe {

struct SidxSegment;

struct HlsStreamCache {
    std::mutex mu;
    bool fetched = false;
    bool valid = false;
    std::vector<int64_t> offsets;
    std::vector<int64_t> sizes;
    std::vector<double> durations;
    int64_t initOffset = 0;
    int64_t initSize = 0;
    double targetDuration = 0;
    std::string cachedPlaylist;
};

struct DashStreamResource {
    std::string representationId;
    std::string url;
    std::string mimeType;
    std::string codecs;
    std::string initRangeStart;
    std::string initRangeEnd;
    std::string indexRangeStart;
    std::string indexRangeEnd;
    std::string userAgent;
    std::string referer;
    int64_t contentLength = 0;
    int64_t bitrate = 0;
    int32_t width = 0;
    int32_t height = 0;
    int32_t fps = 0;
    int64_t approxDurationMs = 0;
    bool isAudio = false;
    bool isYoutubePlayback = false;
    bool isOtf = false;
    std::string sourceClient;
};

enum class LocalMediaSessionType {
    SingleUrl,
    YoutubeDual
};

struct DashSession {
    std::string id;
    LocalMediaSessionType type = LocalMediaSessionType::YoutubeDual;
    int64_t durationMs = 0;
    DashStreamResource single;
    DashStreamResource video;
    DashStreamResource audio;
    std::vector<DashStreamResource> videos;
    std::vector<DashStreamResource> audios;
    bool hasAudio = false;
    std::shared_ptr<HlsStreamCache> videoHls = std::make_shared<HlsStreamCache>();
    std::shared_ptr<HlsStreamCache> audioHls = std::make_shared<HlsStreamCache>();
};

class DashSessionStore {
public:
    static DashSessionStore& instance();

    std::string add(DashSession session);
    std::shared_ptr<DashSession> get(const std::string& id);
    bool remove(const std::string& id);
    void clear();

private:
    DashSessionStore() = default;
    std::string makeSessionId();

    std::mutex mutex_;
    uint64_t nextId_ = 1;
    std::unordered_map<std::string, std::shared_ptr<DashSession>> sessions_;
};

} // namespace yourpipe
