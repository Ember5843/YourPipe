#pragma once

#include "load_control.h"
#include "native_http_transport.h"
#include "stream_source.h"
#include <atomic>
#include <condition_variable>
#include <list>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace yp_stream {

struct SharedStreamCounters {
    std::atomic<int64_t> totalBytesRead{0};
    std::atomic<int32_t> retryCount{0};
    std::atomic<int32_t> lastHttpStatus{0};
};

/**
 * HTTP Range chunked IStreamSource for a single direct track (video or audio):
 * - 1-RTT header/SIDX/Cues prime on Open()
 * - RTT-aware adaptive 256 KiB..4 MiB chunks via BandwidthEstimator
 * - Streaming-while-downloading: ReadAt() wakes on the first received packet
 *   (keeps Seek & startup at 1 RTT even with 2-4 MiB chunks)
 * - 1-slot background read-ahead prefetch hiding high-RTT VPN/proxy latency
 * - Byte-exact mid-chunk resume on transient disconnect/timeout
 * - Bounded LRU chunk cache preserving header chunk (start == 0, <= 512 KiB)
 * - Instant Cancel() interrupting only this stream's in-flight RCP request
 */
class DirectRangeStream final : public IStreamSource {
public:
    DirectRangeStream(DirectStreamSpec spec,
                      std::shared_ptr<NativeHttpTransport> http,
                      std::shared_ptr<BandwidthEstimator> bwEst,
                      std::shared_ptr<LoadController> loadCtrl,
                      std::shared_ptr<SharedStreamCounters> counters);
    ~DirectRangeStream() override;

    bool Open() override;
    int64_t ReadAt(int64_t offset, uint8_t* dst, size_t size) override;
    int64_t GetSize() const override;
    void Cancel() override;
    StreamMetrics SnapshotMetrics() const override;
    void Close() override;

private:
    struct CachedChunk {
        int64_t start = 0;
        std::vector<uint8_t> data;
    };

    struct ActiveFetch {
        int64_t reqStart = 0;
        int64_t reqEnd = 0;
        std::atomic<bool> abort{false};
        std::mutex mu;
        std::condition_variable cv;
        std::vector<uint8_t> buf;
        bool done = false;
        bool ok = false;
        bool eofOnServer = false;
    };

    int32_t SelectChunkSize() const;
    int64_t ReadFromCacheLocked(int64_t offset, uint8_t* dst, size_t size,
                                int64_t* outChunkStart, int64_t* outChunkEnd);
    bool IsOffsetCachedLocked(int64_t offset) const;
    void InsertChunkLocked(int64_t start, std::vector<uint8_t>&& bytes);
    void EvictCacheLocked(int64_t maxBackBytes, int64_t maxTotalBytes);
    std::shared_ptr<ActiveFetch> LaunchFetch(int64_t reqStart, int64_t reqEnd);
    void MaybeStartPrefetch(int64_t nextOffset);
    void RunFetchWorker(std::shared_ptr<ActiveFetch> af);
    void AbortActiveFetch();

    DirectStreamSpec spec_;
    std::shared_ptr<NativeHttpTransport> http_;
    std::shared_ptr<BandwidthEstimator> bwEst_;
    std::shared_ptr<LoadController> loadCtrl_;
    std::shared_ptr<SharedStreamCounters> counters_;

    std::atomic<int64_t> knownSize_{-1};
    std::atomic<int64_t> lastReadOffset_{0};
    std::atomic<bool> canceled_{false};
    std::atomic<bool> closed_{false};
    std::atomic<int32_t> fatalErrorCategory_{static_cast<int32_t>(StreamErrorCategory::NONE)};
    std::atomic<int32_t> lastHttpStatus_{0};
    std::atomic<int32_t> retryCount_{0};
    std::atomic<int64_t> totalBytesRead_{0};

    mutable std::mutex cacheMutex_;
    std::list<CachedChunk> chunks_; // MRU front -> LRU back
    int64_t cachedBytes_ = 0;

    // Lock order: threadMgmtMutex_ -> activePtrMutex_ -> ActiveFetch::mu (never reversed).
    // workerThread_ ONLY locks ActiveFetch::mu and cacheMutex_.
    std::mutex threadMgmtMutex_;
    mutable std::mutex activePtrMutex_;
    std::shared_ptr<ActiveFetch> activeFetch_;
    std::thread workerThread_;
};

} // namespace yp_stream
