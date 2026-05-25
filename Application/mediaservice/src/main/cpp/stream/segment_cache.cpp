#include "segment_cache.h"

namespace yourpipe {

namespace {

std::string makeKey(const std::string& url, const std::string& rangeSpec) {
    return url + "|" + rangeSpec;
}

} // namespace

SegmentMemoryCache& SegmentMemoryCache::instance() {
    static SegmentMemoryCache inst;
    return inst;
}

bool SegmentMemoryCache::get(const std::string& url, const std::string& rangeSpec, std::vector<uint8_t>& outData) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!enabled_) {
        return false;
    }
    std::string key = makeKey(url, rangeSpec);
    auto it = cache_.find(key);
    if (it == cache_.end()) {
        ++missCount_;
        return false;
    }
    lruList_.splice(lruList_.begin(), lruList_, it->second.lruIt);
    outData = it->second.data;
    ++hitCount_;
    return true;
}

void SegmentMemoryCache::put(const std::string& url, const std::string& rangeSpec, const std::vector<uint8_t>& data) {
    if (data.empty()) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!enabled_) {
        return;
    }
    std::string key = makeKey(url, rangeSpec);
    auto it = cache_.find(key);
    if (it != cache_.end()) {
        currentSizeBytes_ -= it->second.data.size();
        it->second.data = data;
        currentSizeBytes_ += data.size();
        lruList_.splice(lruList_.begin(), lruList_, it->second.lruIt);
    } else {
        evictIfNeeded(data.size());
        lruList_.push_front(key);
        Entry entry;
        entry.data = data;
        entry.lruIt = lruList_.begin();
        cache_[key] = std::move(entry);
        currentSizeBytes_ += data.size();
    }
}

void SegmentMemoryCache::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    cache_.clear();
    lruList_.clear();
    currentSizeBytes_ = 0;
}

void SegmentMemoryCache::setEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(mutex_);
    enabled_ = enabled;
    if (!enabled_) {
        cache_.clear();
        lruList_.clear();
        currentSizeBytes_ = 0;
    }
}

void SegmentMemoryCache::setMaxSize(size_t maxBytes) {
    std::lock_guard<std::mutex> lock(mutex_);
    maxSizeBytes_ = maxBytes;
    evictIfNeeded(0);
}

CacheStats SegmentMemoryCache::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    CacheStats s;
    s.enabled = enabled_;
    s.currentSizeBytes = currentSizeBytes_;
    s.entryCount = cache_.size();
    s.maxSizeBytes = maxSizeBytes_;
    s.hitCount = hitCount_;
    s.missCount = missCount_;
    return s;
}

void SegmentMemoryCache::evictIfNeeded(size_t requiredBytes) {
    while (currentSizeBytes_ + requiredBytes > maxSizeBytes_ && !lruList_.empty()) {
        const std::string& key = lruList_.back();
        auto it = cache_.find(key);
        if (it != cache_.end()) {
            currentSizeBytes_ -= it->second.data.size();
            cache_.erase(it);
        }
        lruList_.pop_back();
    }
}

} // namespace yourpipe
