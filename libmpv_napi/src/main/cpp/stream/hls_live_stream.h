#pragma once

#include "direct_range_stream.h"
#include "load_control.h"
#include "native_http_transport.h"
#include "stream_source.h"
#include "stream_types.h"
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace yp_stream {

/**
 * Native C++20 live HLS media-playlist reader over librcp_c (NativeHttpTransport).
 *
 * Replaces FFmpeg's single-threaded synchronous hls demuxer for live streams:
 * - 1 async playlist refresher thread (keeps segment queue ahead of live edge)
 * - 2 concurrent segment prefetch worker threads (eliminates 2s segment RTT stalls)
 * - Streaming-while-downloading: wakes MPV's ReadAt on the first network packet
 * - Byte-exact mid-segment retry, handover instant retry, and 404/410 live-edge resync
 * - Exposes a non-seekable continuous byte stream (MPEG-TS or fMP4 with EXT-X-MAP)
 */
class HlsLiveStream final : public IStreamSource {
public:
    HlsLiveStream(
        HlsStreamSpec spec,
        std::shared_ptr<NativeHttpTransport> http,
        std::shared_ptr<BandwidthEstimator> bwEst,
        std::shared_ptr<SharedStreamCounters> counters);

    ~HlsLiveStream() override;

    bool Open() override;
    int64_t ReadAt(int64_t offset, uint8_t* dst, size_t size) override;
    int64_t GetSize() const override { return -1; }
    bool IsSeekable() const override { return false; }
    void Cancel() override;
    StreamMetrics SnapshotMetrics() const override;
    void Close() override;

private:
    enum class SegState {
        QUEUED = 0,
        FETCHING = 1,
        READY = 2,
        FAILED = 3,
    };

    struct SegmentEntry {
        int64_t seq = -1;
        std::string url;
        double durationSec = 2.0;
        int64_t byteRangeStart = -1;
        int64_t byteRangeEnd = -1;
        SegState state = SegState::QUEUED;
        std::vector<uint8_t> data;
        bool complete = false;
        int32_t retries = 0;
        int32_t handoverRetries = 0;
        int32_t lastHttpCode = 0;
        bool expiredOrGone = false;
        bool fatalAuth = false;
    };

    struct ParsedSegment {
        int64_t seq = -1;
        std::string url;
        double durationSec = 2.0;
        int64_t byteRangeStart = -1;
        int64_t byteRangeEnd = -1;
    };

    struct ParsedPlaylist {
        bool isMaster = false;
        bool hasEncryption = false;
        bool ended = false;
        double targetDurationSec = 2.0;
        int64_t mediaSequence = 0;
        std::string initMapUrl;
        int64_t initMapRangeStart = -1;
        int64_t initMapRangeEnd = -1;
        std::vector<ParsedSegment> segments;
    };

    static std::string ResolveUrl(const std::string& baseUrl, const std::string& rel);
    static bool ParseByteRange(const std::string& expr, int64_t& prevEndOffset, int64_t& outStart, int64_t& outEnd);
    static bool ParseMediaPlaylist(const std::string& text, const std::string& baseUrl, ParsedPlaylist& out);

    bool FetchTextOnce(const std::string& url, std::string& outBody, int32_t& outHttpCode, HttpFetchStatus& outStatus);
    bool FetchBytesOnce(const std::string& url, int64_t rangeStart, int64_t rangeEnd, std::vector<uint8_t>& outData);
    void MergePlaylistLocked(const ParsedPlaylist& pl, bool isInitial);
    void PruneBelowReadSeqLocked();
    void PlaylistLoop();
    void WorkerLoop(int workerId);
    void JoinThreads();

    HlsStreamSpec spec_;
    std::shared_ptr<NativeHttpTransport> http_;
    std::shared_ptr<BandwidthEstimator> bwEst_;
    std::shared_ptr<SharedStreamCounters> counters_;

    mutable std::mutex mutex_;
    std::condition_variable cv_;

    std::map<int64_t, SegmentEntry> segments_;
    size_t bufferedBytes_ = 0;

    std::vector<uint8_t> initMapData_;
    size_t initMapReadPos_ = 0;
    bool initMapPending_ = false;

    int64_t nextReadSeq_ = -1;
    size_t nextReadPos_ = 0;
    int64_t earliestPlaylistSeq_ = -1;
    int64_t latestPlaylistSeq_ = -1;
    double targetDurationSec_ = 2.0;
    int64_t backSegments_ = 3;
    bool playlistEnded_ = false;
    bool fatalError_ = false;
    bool forceRefreshPlaylist_ = false;
    int32_t consecutivePlaylistFailures_ = 0;
    int32_t consecutiveSegSkips_ = 0;
    int64_t lastPlaylistRefreshUs_ = 0;
    int64_t lastProgressLogUs_ = 0;
    int64_t segmentsServed_ = 0;

    std::atomic<bool> cancelled_{false};
    std::atomic<bool> closed_{false};

    std::thread playlistThread_;
    std::vector<std::thread> workerThreads_;
    bool threadsStarted_ = false;
    bool threadsJoined_ = false;
};

} // namespace yp_stream
