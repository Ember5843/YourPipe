#include "direct_range_stream.h"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <hilog/log.h>

namespace yp_stream {

namespace {
constexpr unsigned int kLogDomain = 0xFF00;
constexpr const char* kLogTag = "mpv-stream";
constexpr int64_t kMaxCacheBytes = 24LL * 1024LL * 1024LL; // 24 MiB cap per stream (holds ~6x 4MiB chunks)
constexpr int32_t kBackoffMs[] = {200, 500, 1000, 2000, 4000};
} // namespace

DirectRangeStream::DirectRangeStream(DirectStreamSpec spec,
                                     std::shared_ptr<NativeHttpTransport> http,
                                     std::shared_ptr<BandwidthEstimator> bwEst,
                                     std::shared_ptr<LoadController> loadCtrl,
                                     std::shared_ptr<SharedStreamCounters> counters)
    : spec_(std::move(spec)),
      http_(std::move(http)),
      bwEst_(std::move(bwEst)),
      loadCtrl_(std::move(loadCtrl)),
      counters_(std::move(counters))
{
    if (spec_.contentLength > 0) {
        knownSize_.store(spec_.contentLength);
    }
}

DirectRangeStream::~DirectRangeStream()
{
    Close();
}

int32_t DirectRangeStream::SelectChunkSize() const
{
    const StreamNetworkPolicy pol = http_ ? http_->GetNetworkPolicy() : StreamNetworkPolicy{};
    int32_t chunkSize = bwEst_
        ? bwEst_->SelectAdaptiveChunkSize(pol.minChunkBytes, pol.maxChunkBytes, spec_.bitrate)
        : 1048576;
    return std::max<int32_t>(65536, chunkSize);
}

bool DirectRangeStream::Open()
{
    if (spec_.url.empty() || !http_) {
        return false;
    }
    closed_.store(false);
    canceled_.store(false);
    fatalErrorCategory_.store(static_cast<int32_t>(StreamErrorCategory::NONE));

    int64_t primeEnd = -1;
    if (spec_.initRangeEnd > 0) {
        primeEnd = std::max(primeEnd, spec_.initRangeEnd);
    }
    if (spec_.indexRangeEnd > 0 && spec_.indexRangeEnd < 512 * 1024) {
        primeEnd = std::max(primeEnd, spec_.indexRangeEnd);
    }
    if (primeEnd <= 0) {
        primeEnd = 262143; // Initial 256 KiB header/index probe
    }
    const int64_t sz = knownSize_.load();
    if (sz > 0) {
        primeEnd = std::min(primeEnd, sz - 1);
    }
    if (primeEnd < 0) {
        return true;
    }

    auto af = LaunchFetch(0, primeEnd);
    if (!af) {
        return false;
    }
    {
        std::unique_lock<std::mutex> lock(af->mu);
        af->cv.wait(lock, [&]() {
            return af->done || af->abort.load() || canceled_.load() || closed_.load();
        });
    }
    if (!af->ok) {
        OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                     "DirectRangeStream Open prime failed itag=%{public}d http=%{public}d",
                     spec_.itag, lastHttpStatus_.load());
        return false;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                 "DirectRangeStream opened itag=%{public}d size=%{public}lld primed=%{public}lld",
                 spec_.itag, static_cast<long long>(knownSize_.load()), static_cast<long long>(primeEnd + 1));
    return true;
}

int64_t DirectRangeStream::ReadFromCacheLocked(int64_t offset, uint8_t* dst, size_t size,
                                               int64_t* outChunkStart, int64_t* outChunkEnd)
{
    for (auto it = chunks_.begin(); it != chunks_.end(); ++it) {
        const int64_t cStart = it->start;
        const int64_t cEnd = cStart + static_cast<int64_t>(it->data.size());
        if (offset >= cStart && offset < cEnd) {
            const size_t inOff = static_cast<size_t>(offset - cStart);
            const size_t avail = it->data.size() - inOff;
            const size_t copyLen = std::min(size, avail);
            std::memcpy(dst, it->data.data() + inOff, copyLen);
            if (outChunkStart) *outChunkStart = cStart;
            if (outChunkEnd) *outChunkEnd = cEnd;
            chunks_.splice(chunks_.begin(), chunks_, it);
            return static_cast<int64_t>(copyLen);
        }
    }
    return 0;
}

bool DirectRangeStream::IsOffsetCachedLocked(int64_t offset) const
{
    for (const auto& c : chunks_) {
        const int64_t cEnd = c.start + static_cast<int64_t>(c.data.size());
        if (offset >= c.start && offset < cEnd) {
            return true;
        }
    }
    return false;
}

void DirectRangeStream::InsertChunkLocked(int64_t start, std::vector<uint8_t>&& bytes)
{
    if (bytes.empty()) return;
    const size_t addSize = bytes.size();
    chunks_.push_front(CachedChunk{start, std::move(bytes)});
    cachedBytes_ += static_cast<int64_t>(addSize);
    const int64_t backCap = loadCtrl_
        ? std::max<int64_t>(1048576, loadCtrl_->GetConfig().maxBackBufferBytes)
        : (8LL * 1024LL * 1024LL);
    const int64_t totalCap = (spec_.bitrate > 16000000)
        ? (40LL * 1024LL * 1024LL)
        : kMaxCacheBytes;
    EvictCacheLocked(backCap, totalCap);
}

void DirectRangeStream::EvictCacheLocked(int64_t maxBackBytes, int64_t maxTotalBytes)
{
    const int64_t cursor = lastReadOffset_.load();
    auto isProtectedHeader = [](const CachedChunk& c) {
        return c.start == 0 && c.data.size() <= 512 * 1024;
    };
    int64_t backBytes = 0;
    for (auto it = chunks_.begin(); it != chunks_.end();) {
        if (isProtectedHeader(*it)) {
            ++it;
            continue;
        }
        const int64_t cEnd = it->start + static_cast<int64_t>(it->data.size());
        if (cEnd < cursor) {
            backBytes += static_cast<int64_t>(it->data.size());
            if (backBytes > maxBackBytes) {
                cachedBytes_ -= static_cast<int64_t>(it->data.size());
                it = chunks_.erase(it);
                continue;
            }
        }
        ++it;
    }
    while (cachedBytes_ > maxTotalBytes && !chunks_.empty()) {
        auto victim = chunks_.end();
        for (auto it = chunks_.end(); it != chunks_.begin();) {
            --it;
            if (!isProtectedHeader(*it)) {
                victim = it;
                break;
            }
        }
        if (victim == chunks_.end()) {
            break;
        }
        cachedBytes_ -= static_cast<int64_t>(victim->data.size());
        chunks_.erase(victim);
    }
}

void DirectRangeStream::AbortActiveFetch()
{
    std::shared_ptr<ActiveFetch> af;
    {
        std::lock_guard<std::mutex> lock(activePtrMutex_);
        af = activeFetch_;
    }
    if (af) {
        af->abort.store(true);
        std::lock_guard<std::mutex> alock(af->mu);
        af->cv.notify_all();
    }
}

std::shared_ptr<DirectRangeStream::ActiveFetch> DirectRangeStream::LaunchFetch(int64_t reqStart, int64_t reqEnd)
{
    if (!http_ || canceled_.load() || closed_.load() || reqEnd < reqStart) {
        return nullptr;
    }
    std::lock_guard<std::mutex> mgmtLock(threadMgmtMutex_);
    AbortActiveFetch();
    if (workerThread_.joinable()) {
        workerThread_.join();
    }
    if (canceled_.load() || closed_.load()) {
        return nullptr;
    }

    auto af = std::make_shared<ActiveFetch>();
    af->reqStart = reqStart;
    af->reqEnd = reqEnd;
    af->buf.reserve(static_cast<size_t>(std::min<int64_t>(8388608, std::max<int64_t>(65536, reqEnd - reqStart + 1))));
    {
        std::lock_guard<std::mutex> ptrLock(activePtrMutex_);
        activeFetch_ = af;
    }
    workerThread_ = std::thread(&DirectRangeStream::RunFetchWorker, this, af);
    return af;
}

void DirectRangeStream::MaybeStartPrefetch(int64_t nextOffset)
{
    if (canceled_.load() || closed_.load() || nextOffset < 0) {
        return;
    }
    const int64_t totalSz = knownSize_.load();
    if (totalSz > 0 && nextOffset >= totalSz) {
        return;
    }
    {
        std::lock_guard<std::mutex> cacheLock(cacheMutex_);
        if (IsOffsetCachedLocked(nextOffset)) {
            return;
        }
    }
    {
        std::lock_guard<std::mutex> ptrLock(activePtrMutex_);
        if (activeFetch_) {
            std::lock_guard<std::mutex> alock(activeFetch_->mu);
            if (!activeFetch_->done) {
                // Worker already busy fetching a chunk (either current or prefetched); do not interrupt it.
                return;
            }
        }
    }

    const int32_t chunkSize = SelectChunkSize();
    int64_t prefEnd = nextOffset + static_cast<int64_t>(chunkSize) - 1;
    if (totalSz > 0) {
        prefEnd = std::min(prefEnd, totalSz - 1);
    }
    if (prefEnd < nextOffset) {
        return;
    }
    LaunchFetch(nextOffset, prefEnd);
}

void DirectRangeStream::RunFetchWorker(std::shared_ptr<ActiveFetch> af)
{
    const StreamNetworkPolicy pol = http_->GetNetworkPolicy();
    const int32_t maxRetries = std::max(1, pol.maxRetries);

    int64_t cursor = af->reqStart;

    for (int32_t attempt = 0; attempt <= maxRetries && !af->abort.load() && !canceled_.load() && !closed_.load(); ++attempt) {
        const uint64_t currentEpoch = http_->CurrentEpoch();
        int64_t attemptBytes = 0;

        const HttpFetchResult hr = http_->FetchRangeStream(
            spec_.url,
            cursor,
            af->reqEnd,
            spec_.headers,
            spec_.userAgent,
            currentEpoch,
            af->abort,
            [&af, &attemptBytes, this](const uint8_t* data, size_t len) -> bool {
                if (af->abort.load() || canceled_.load() || closed_.load()) return false;
                if (len > 0) {
                    {
                        std::lock_guard<std::mutex> alock(af->mu);
                        af->buf.insert(af->buf.end(), data, data + len);
                    }
                    attemptBytes += static_cast<int64_t>(len);
                    af->cv.notify_all();
                }
                return true;
            });

        if (hr.httpCode > 0) {
            lastHttpStatus_.store(hr.httpCode);
            if (counters_) counters_->lastHttpStatus.store(hr.httpCode);
        }
        if (hr.totalContentLength > 0 && knownSize_.load() <= 0) {
            knownSize_.store(hr.totalContentLength);
        }
        if (attemptBytes > 0) {
            // Only feed completed video chunks (>= 256 KiB) into the shared
            // BandwidthEstimator so Seek-aborted fragments and small audio
            // chunks never drag down video chunk sizing.
            const bool isVideoTrack = (spec_.bitrate == 0 || spec_.bitrate >= 300000);
            if (bwEst_ && hr.status == HttpFetchStatus::OK && isVideoTrack && attemptBytes >= 262144) {
                bwEst_->OnBytesTransferred(attemptBytes, hr.elapsedUs, hr.firstByteUs);
            }
            cursor += attemptBytes;
        }

        if (hr.status == HttpFetchStatus::OK) {
            if (hr.eofOnServer && knownSize_.load() <= 0) {
                knownSize_.store(cursor);
            }
            std::vector<uint8_t> cacheCopy;
            {
                std::lock_guard<std::mutex> alock(af->mu);
                cacheCopy = af->buf;
            }
            if (!cacheCopy.empty()) {
                std::lock_guard<std::mutex> cacheLock(cacheMutex_);
                InsertChunkLocked(af->reqStart, std::move(cacheCopy));
            }
            {
                std::lock_guard<std::mutex> alock(af->mu);
                af->eofOnServer = hr.eofOnServer;
                af->ok = true;
                af->done = true;
            }
            af->cv.notify_all();
            return;
        }

        if (hr.status == HttpFetchStatus::HTTP_URL_EXPIRED) {
            fatalErrorCategory_.store(static_cast<int32_t>(StreamErrorCategory::URL_EXPIRED));
            break;
        }
        if (hr.status == HttpFetchStatus::HTTP_PROXY_AUTH) {
            fatalErrorCategory_.store(static_cast<int32_t>(StreamErrorCategory::PROXY_AUTH));
            break;
        }
        if (af->abort.load() || canceled_.load() || closed_.load()) {
            break;
        }

        // Network handover epoch bump: retry immediately on the new network without consuming retry budget.
        if (hr.status == HttpFetchStatus::ABORTED && http_->CurrentEpoch() != currentEpoch) {
            if (cursor > af->reqEnd) {
                std::vector<uint8_t> cacheCopy;
                {
                    std::lock_guard<std::mutex> alock(af->mu);
                    cacheCopy = af->buf;
                }
                if (!cacheCopy.empty()) {
                    std::lock_guard<std::mutex> cacheLock(cacheMutex_);
                    InsertChunkLocked(af->reqStart, std::move(cacheCopy));
                }
                {
                    std::lock_guard<std::mutex> alock(af->mu);
                    af->ok = true;
                    af->done = true;
                }
                af->cv.notify_all();
                return;
            }
            attempt = std::max(0, attempt - 1);
            continue;
        }

        if (attempt >= maxRetries) {
            fatalErrorCategory_.store(static_cast<int32_t>(StreamErrorCategory::NETWORK));
            break;
        }

        retryCount_.fetch_add(1);
        if (counters_) counters_->retryCount.fetch_add(1);
        const int idx = std::min(attempt, static_cast<int32_t>(sizeof(kBackoffMs) / sizeof(kBackoffMs[0]) - 1));
        const int backoffMs = kBackoffMs[idx];
        OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                     "DirectRangeStream retry=%{public}d itag=%{public}d cursor=%{public}lld http=%{public}d status=%{public}d backoff=%{public}dms",
                     attempt + 1, spec_.itag, static_cast<long long>(cursor), hr.httpCode,
                     static_cast<int32_t>(hr.status), backoffMs);
        for (int elapsed = 0; elapsed < backoffMs && !af->abort.load() && !canceled_.load() && !closed_.load(); elapsed += 50) {
            const int slice = std::min(50, backoffMs - elapsed);
            std::this_thread::sleep_for(std::chrono::milliseconds(slice));
        }
    }

    {
        std::lock_guard<std::mutex> alock(af->mu);
        af->ok = false;
        af->done = true;
    }
    af->cv.notify_all();
}

int64_t DirectRangeStream::ReadAt(int64_t offset, uint8_t* dst, size_t size)
{
    if (canceled_.load() || closed_.load() || !dst || size == 0 || offset < 0) {
        return -1;
    }
    const int64_t totalSz = knownSize_.load();
    if (totalSz >= 0 && offset >= totalSz) {
        return 0; // EOF
    }

    lastReadOffset_.store(offset);

    // 1. Fast cache hit (0ms wait) + trigger 1-slot background prefetch once past chunk midpoint.
    {
        int64_t hitStart = 0;
        int64_t hitEnd = 0;
        int64_t hit = 0;
        {
            std::lock_guard<std::mutex> cacheLock(cacheMutex_);
            hit = ReadFromCacheLocked(offset, dst, size, &hitStart, &hitEnd);
        }
        if (hit > 0) {
            totalBytesRead_.fetch_add(hit);
            if (counters_) counters_->totalBytesRead.fetch_add(hit);
            const int64_t chunkLen = hitEnd - hitStart;
            // Eager 0% read-ahead: as soon as MPV enters a cached data chunk,
            // kick off 1-slot background prefetch for the next chunk to hide high RTT.
            if (chunkLen >= 262144) {
                MaybeStartPrefetch(hitEnd);
            }
            return hit;
        }
    }

    // 2. Check if an in-flight (foreground or prefetched) fetch already covers offset.
    //    Only attach when not yet done (finished chunks are already in LRU cache above,
    //    and a short completed chunk must never mask a missing suffix as premature EOF).
    for (int pass = 0; pass < 2; ++pass) {
        std::shared_ptr<ActiveFetch> af;
        if (pass == 0) {
            std::lock_guard<std::mutex> ptrLock(activePtrMutex_);
            if (activeFetch_ && offset >= activeFetch_->reqStart && offset <= activeFetch_->reqEnd) {
                std::lock_guard<std::mutex> alock(activeFetch_->mu);
                if (!activeFetch_->done || static_cast<int64_t>(activeFetch_->buf.size()) > (offset - activeFetch_->reqStart)) {
                    af = activeFetch_;
                }
            }
        }

        // 3. Otherwise launch a fresh streaming fetch starting at offset.
        if (!af) {
            const int32_t chunkSize = SelectChunkSize();
            int64_t reqEnd = offset + static_cast<int64_t>(chunkSize) - 1;
            const int64_t curSz = knownSize_.load();
            if (curSz > 0) {
                reqEnd = std::min(reqEnd, curSz - 1);
            }
            if (reqEnd < offset) {
                return 0;
            }
            af = LaunchFetch(offset, reqEnd);
            if (!af) {
                return -1;
            }
        }

        // Stream bytes directly as soon as they arrive (1-RTT wake-up even for 4-8 MiB chunks).
        int64_t copied = 0;
        int64_t completedNextOffset = -1;
        bool eofReached = false;
        bool failed = false;
        bool shortChunkRetry = false;
        {
            std::unique_lock<std::mutex> alock(af->mu);
            const int64_t relOff = offset - af->reqStart;
            af->cv.wait(alock, [&]() {
                return canceled_.load() || closed_.load() || af->abort.load()
                    || static_cast<int64_t>(af->buf.size()) > relOff
                    || af->done;
            });

            if (canceled_.load() || closed_.load() || af->abort.load()) {
                return -1;
            }

            const int64_t bufSize = static_cast<int64_t>(af->buf.size());
            if (bufSize > relOff) {
                const size_t avail = static_cast<size_t>(bufSize - relOff);
                const size_t copyLen = std::min(size, avail);
                std::memcpy(dst, af->buf.data() + static_cast<size_t>(relOff), copyLen);
                copied = static_cast<int64_t>(copyLen);
                if (af->done && af->ok) {
                    completedNextOffset = af->reqStart + bufSize;
                }
            } else if (af->done) {
                if (af->ok) {
                    const int64_t curSz = knownSize_.load();
                    if (!af->eofOnServer && relOff > 0 && (curSz < 0 || offset < curSz) && pass == 0) {
                        // Upstream delivered fewer bytes than reqEnd before closing cleanly;
                        // retry with a fresh Range request at exact offset instead of reporting EOF.
                        shortChunkRetry = true;
                    } else {
                        eofReached = true;
                    }
                } else {
                    failed = true;
                }
            }
        }

        if (shortChunkRetry) {
            continue;
        }
        if (copied > 0) {
            totalBytesRead_.fetch_add(copied);
            if (counters_) counters_->totalBytesRead.fetch_add(copied);
            if (completedNextOffset > 0) {
                MaybeStartPrefetch(completedNextOffset);
            }
            return copied;
        }
        if (eofReached) {
            return 0;
        }
        return failed ? -1 : 0;
    }
    return -1;
}

int64_t DirectRangeStream::GetSize() const
{
    return knownSize_.load();
}

void DirectRangeStream::Cancel()
{
    canceled_.store(true);
    AbortActiveFetch();
}

StreamMetrics DirectRangeStream::SnapshotMetrics() const
{
    StreamMetrics m{};
    m.networkSpeedBps = bwEst_ ? bwEst_->EstimatedBps() : 0;
    m.totalBytesRead = totalBytesRead_.load();
    m.retryCount = retryCount_.load();
    m.lastHttpStatus = lastHttpStatus_.load();
    return m;
}

void DirectRangeStream::Close()
{
    closed_.store(true);
    canceled_.store(true);
    AbortActiveFetch();
    {
        std::lock_guard<std::mutex> mgmtLock(threadMgmtMutex_);
        if (workerThread_.joinable()) {
            workerThread_.join();
        }
        std::lock_guard<std::mutex> ptrLock(activePtrMutex_);
        activeFetch_.reset();
    }
    std::lock_guard<std::mutex> cacheLock(cacheMutex_);
    chunks_.clear();
    cachedBytes_ = 0;
}

} // namespace yp_stream
