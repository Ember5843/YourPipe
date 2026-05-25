#pragma once

#include <cstdint>
#include <list>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace yourpipe {

struct CacheStats {
    bool enabled = true;
    size_t currentSizeBytes = 0;
    size_t entryCount = 0;
    size_t maxSizeBytes = 64 * 1024 * 1024;
    uint64_t hitCount = 0;
    uint64_t missCount = 0;
};

class SegmentMemoryCache {
public:
    static SegmentMemoryCache& instance();

    bool get(const std::string& url, const std::string& rangeSpec, std::vector<uint8_t>& outData);
    void put(const std::string& url, const std::string& rangeSpec, const std::vector<uint8_t>& data);
    void clear();

    void setEnabled(bool enabled);
    void setMaxSize(size_t maxBytes);
    CacheStats stats() const;

private:
    SegmentMemoryCache() = default;
    void evictIfNeeded(size_t requiredBytes);

    struct Entry {
        std::vector<uint8_t> data;
        std::list<std::string>::iterator lruIt;
    };

    mutable std::mutex mutex_;
    bool enabled_ = true;
    size_t maxSizeBytes_ = 64 * 1024 * 1024;
    size_t currentSizeBytes_ = 0;
    uint64_t hitCount_ = 0;
    uint64_t missCount_ = 0;

    std::unordered_map<std::string, Entry> cache_;
    std::list<std::string> lruList_;
};

} // namespace yourpipe
