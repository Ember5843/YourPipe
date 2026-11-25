#include "hls_live_stream.h"
#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <hilog/log.h>
#include <sstream>

namespace yp_stream {

namespace {

constexpr unsigned int kLogDomain = 0xFF00;
constexpr const char* kLogTag = "mpv-hls";
constexpr int kWorkerCount = 2;
constexpr int64_t kMaxAheadSegments = 8;
constexpr size_t kMaxBufferedBytes = 24ULL * 1024ULL * 1024ULL; // 24 MiB cap
constexpr int32_t kMaxSegRetries = 4;
constexpr int32_t kMaxHandoverRetries = 3;
constexpr int32_t kMaxPlaylistFailures = 8;
constexpr int32_t kMaxConsecutiveSegSkips = 3;
constexpr int64_t kReadStallTimeoutUs = 18LL * 1000LL * 1000LL; // 18s live stall guard

std::string TrimAscii(const std::string& s)
{
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) {
        ++start;
    }
    size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) {
        --end;
    }
    return s.substr(start, end - start);
}

std::string ExtractAttr(const std::string& line, const std::string& key)
{
    const std::string needle = key + "=";
    size_t pos = line.find(needle);
    if (pos == std::string::npos) return "";
    pos += needle.size();
    if (pos >= line.size()) return "";
    if (line[pos] == '"') {
        size_t end = line.find('"', pos + 1);
        if (end == std::string::npos) return "";
        return line.substr(pos + 1, end - pos - 1);
    }
    size_t end = line.find(',', pos);
    if (end == std::string::npos) {
        return TrimAscii(line.substr(pos));
    }
    return TrimAscii(line.substr(pos, end - pos));
}

} // namespace

HlsLiveStream::HlsLiveStream(
    HlsStreamSpec spec,
    std::shared_ptr<NativeHttpTransport> http,
    std::shared_ptr<BandwidthEstimator> bwEst,
    std::shared_ptr<SharedStreamCounters> counters)
    : spec_(std::move(spec)),
      http_(std::move(http)),
      bwEst_(std::move(bwEst)),
      counters_(std::move(counters))
{
}

HlsLiveStream::~HlsLiveStream()
{
    Close();
}

std::string HlsLiveStream::ResolveUrl(const std::string& baseUrl, const std::string& rel)
{
    if (rel.empty()) return "";
    if (rel.rfind("http://", 0) == 0 || rel.rfind("https://", 0) == 0) {
        return rel;
    }
    const size_t schemeEnd = baseUrl.find("://");
    if (schemeEnd == std::string::npos) {
        return rel;
    }
    const std::string scheme = baseUrl.substr(0, schemeEnd);
    if (rel.rfind("//", 0) == 0) {
        return scheme + ":" + rel;
    }
    const size_t hostStart = schemeEnd + 3;
    const size_t pathStart = baseUrl.find('/', hostStart);
    const std::string origin = (pathStart == std::string::npos) ? baseUrl : baseUrl.substr(0, pathStart);
    if (rel[0] == '/') {
        return origin + rel;
    }
    const size_t qPos = baseUrl.find_first_of("?#");
    const std::string cleanBase = (qPos == std::string::npos) ? baseUrl : baseUrl.substr(0, qPos);
    const size_t lastSlash = cleanBase.rfind('/');
    if (lastSlash == std::string::npos || lastSlash < hostStart) {
        return origin + "/" + rel;
    }
    return cleanBase.substr(0, lastSlash + 1) + rel;
}

bool HlsLiveStream::ParseByteRange(const std::string& expr, int64_t& prevEndOffset, int64_t& outStart, int64_t& outEnd)
{
    const std::string trimmed = TrimAscii(expr);
    if (trimmed.empty()) return false;
    const size_t at = trimmed.find('@');
    int64_t len = 0;
    int64_t start = prevEndOffset >= 0 ? prevEndOffset : 0;
    if (at == std::string::npos) {
        len = std::strtoll(trimmed.c_str(), nullptr, 10);
    } else {
        len = std::strtoll(trimmed.substr(0, at).c_str(), nullptr, 10);
        start = std::strtoll(trimmed.substr(at + 1).c_str(), nullptr, 10);
    }
    if (len <= 0 || start < 0) return false;
    outStart = start;
    outEnd = start + len - 1;
    prevEndOffset = outEnd + 1;
    return true;
}

bool HlsLiveStream::ParseMediaPlaylist(const std::string& text, const std::string& baseUrl, ParsedPlaylist& out)
{
    out = ParsedPlaylist{};
    std::istringstream iss(text);
    std::string rawLine;
    double pendingDur = -1.0;
    int64_t pendingRangeStart = -1;
    int64_t pendingRangeEnd = -1;
    int64_t rollingRangeOffset = 0;
    int64_t segIndex = 0;

    while (std::getline(iss, rawLine)) {
        const std::string line = TrimAscii(rawLine);
        if (line.empty()) continue;

        if (line[0] == '#') {
            if (line.rfind("#EXT-X-STREAM-INF:", 0) == 0) {
                out.isMaster = true;
            } else if (line.rfind("#EXT-X-TARGETDURATION:", 0) == 0) {
                double d = std::strtod(line.c_str() + 22, nullptr);
                if (d >= 0.5 && d <= 30.0) {
                    out.targetDurationSec = d;
                }
            } else if (line.rfind("#EXT-X-MEDIA-SEQUENCE:", 0) == 0) {
                out.mediaSequence = std::strtoll(line.c_str() + 22, nullptr, 10);
            } else if (line.rfind("#EXT-X-ENDLIST", 0) == 0) {
                out.ended = true;
            } else if (line.rfind("#EXT-X-KEY:", 0) == 0) {
                const std::string method = ExtractAttr(line, "METHOD");
                if (!method.empty() && method != "NONE") {
                    out.hasEncryption = true;
                }
            } else if (line.rfind("#EXT-X-MAP:", 0) == 0) {
                const std::string uri = ExtractAttr(line, "URI");
                if (!uri.empty() && out.initMapUrl.empty()) {
                    out.initMapUrl = ResolveUrl(baseUrl, uri);
                    const std::string br = ExtractAttr(line, "BYTERANGE");
                    if (!br.empty()) {
                        int64_t dummyPrev = 0;
                        ParseByteRange(br, dummyPrev, out.initMapRangeStart, out.initMapRangeEnd);
                    }
                }
            } else if (line.rfind("#EXT-X-BYTERANGE:", 0) == 0) {
                ParseByteRange(line.substr(17), rollingRangeOffset, pendingRangeStart, pendingRangeEnd);
            } else if (line.rfind("#EXTINF:", 0) == 0) {
                pendingDur = std::strtod(line.c_str() + 8, nullptr);
                if (pendingDur <= 0.0 || pendingDur > 60.0) {
                    pendingDur = out.targetDurationSec;
                }
            }
            continue;
        }

        if (pendingDur > 0.0) {
            ParsedSegment seg;
            seg.seq = out.mediaSequence + segIndex;
            seg.url = ResolveUrl(baseUrl, line);
            seg.durationSec = pendingDur;
            seg.byteRangeStart = pendingRangeStart;
            seg.byteRangeEnd = pendingRangeEnd;
            out.segments.push_back(std::move(seg));
            ++segIndex;
            pendingDur = -1.0;
            pendingRangeStart = -1;
            pendingRangeEnd = -1;
        }
    }

    return !out.isMaster && !out.hasEncryption && !out.segments.empty();
}

bool HlsLiveStream::FetchTextOnce(
    const std::string& url,
    std::string& outBody,
    int32_t& outHttpCode,
    HttpFetchStatus& outStatus)
{
    outBody.clear();
    outHttpCode = 0;
    outStatus = HttpFetchStatus::NET_ERROR;
    if (!http_ || cancelled_.load() || closed_.load()) {
        outStatus = HttpFetchStatus::ABORTED;
        return false;
    }
    const uint64_t reqEpoch = http_->CurrentEpoch();
    std::string buf;
    buf.reserve(8192);
    const HttpFetchResult res = http_->FetchRangeStream(
        url,
        -1,
        -1,
        spec_.headers,
        spec_.userAgent,
        reqEpoch,
        cancelled_,
        [&buf](const uint8_t* data, size_t len) -> bool {
            if (buf.size() + len > 2 * 1024 * 1024) {
                return false; // sanity cap for media playlist
            }
            buf.append(reinterpret_cast<const char*>(data), len);
            return true;
        });
    outHttpCode = res.httpCode;
    outStatus = res.status;
    if (counters_ && res.httpCode > 0) {
        counters_->lastHttpStatus.store(res.httpCode);
    }
    if (res.status == HttpFetchStatus::OK && !buf.empty()) {
        outBody = std::move(buf);
        return true;
    }
    return false;
}

bool HlsLiveStream::FetchBytesOnce(
    const std::string& url,
    int64_t rangeStart,
    int64_t rangeEnd,
    std::vector<uint8_t>& outData)
{
    outData.clear();
    if (!http_ || cancelled_.load() || closed_.load()) {
        return false;
    }
    const uint64_t reqEpoch = http_->CurrentEpoch();
    std::vector<uint8_t> buf;
    const HttpFetchResult res = http_->FetchRangeStream(
        url,
        rangeStart,
        rangeEnd,
        spec_.headers,
        spec_.userAgent,
        reqEpoch,
        cancelled_,
        [&buf](const uint8_t* data, size_t len) -> bool {
            if (buf.size() + len > 4 * 1024 * 1024) {
                return false;
            }
            buf.insert(buf.end(), data, data + len);
            return true;
        });
    if (res.status == HttpFetchStatus::OK && !buf.empty()) {
        outData = std::move(buf);
        return true;
    }
    return false;
}

void HlsLiveStream::PruneBelowReadSeqLocked()
{
    auto it = segments_.begin();
    while (it != segments_.end() && it->first < nextReadSeq_) {
        bufferedBytes_ = (bufferedBytes_ >= it->second.data.size())
            ? (bufferedBytes_ - it->second.data.size())
            : 0;
        it = segments_.erase(it);
    }
}

void HlsLiveStream::MergePlaylistLocked(const ParsedPlaylist& pl, bool isInitial)
{
    if (pl.segments.empty()) return;

    targetDurationSec_ = std::clamp(pl.targetDurationSec, 1.0, 15.0);
    backSegments_ = (targetDurationSec_ <= 2.5) ? 3 : 2;
    const int64_t firstSeq = pl.segments.front().seq;
    const int64_t lastSeq = pl.segments.back().seq;
    earliestPlaylistSeq_ = firstSeq;
    if (lastSeq > latestPlaylistSeq_) {
        latestPlaylistSeq_ = lastSeq;
    }
    if (pl.ended) {
        playlistEnded_ = true;
    }

    if (isInitial) {
        nextReadSeq_ = std::max(firstSeq, lastSeq - backSegments_);
        nextReadPos_ = 0;
    } else if (nextReadSeq_ < earliestPlaylistSeq_) {
        // Snap forward to live edge if nextReadSeq_ rolled off the live DVR window:
        // - If we haven't started emitting nextReadSeq_ yet (nextReadPos_ == 0) AND we are
        //   far behind the live edge (e.g. long pause or background audio-only), discard
        //   stale prefetched segments and re-anchor at live edge immediately.
        // - Otherwise keep finishing the currently streaming segment if already in-progress.
        auto curIt = segments_.find(nextReadSeq_);
        const bool severelyBehind = (nextReadPos_ == 0) &&
            (latestPlaylistSeq_ - nextReadSeq_ > kMaxAheadSegments + 4);
        const bool stillUsable = !severelyBehind && (curIt != segments_.end()) &&
            (curIt->second.state == SegState::READY ||
             (curIt->second.state == SegState::FETCHING && curIt->second.data.size() > nextReadPos_) ||
             nextReadPos_ > 0);
        if (!stillUsable) {
            const int64_t newSeq = std::max(earliestPlaylistSeq_, latestPlaylistSeq_ - backSegments_);
            OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                         "live window roll-off itag=%{public}d snap seq %{public}lld -> %{public}lld (window=[%{public}lld..%{public}lld])",
                         spec_.itag,
                         static_cast<long long>(nextReadSeq_),
                         static_cast<long long>(newSeq),
                         static_cast<long long>(firstSeq),
                         static_cast<long long>(lastSeq));
            nextReadSeq_ = newSeq;
            nextReadPos_ = 0;
            PruneBelowReadSeqLocked();
        }
    }

    for (const auto& seg : pl.segments) {
        if (seg.seq < nextReadSeq_) continue;
        auto it = segments_.find(seg.seq);
        if (it == segments_.end()) {
            SegmentEntry entry;
            entry.seq = seg.seq;
            entry.url = seg.url;
            entry.durationSec = seg.durationSec;
            entry.byteRangeStart = seg.byteRangeStart;
            entry.byteRangeEnd = seg.byteRangeEnd;
            entry.state = SegState::QUEUED;
            segments_.emplace(seg.seq, std::move(entry));
        } else if (it->second.state == SegState::QUEUED) {
            // Refresh signed segment URL if playlist rotated query params.
            it->second.url = seg.url;
        }
    }
}

bool HlsLiveStream::Open()
{
    if (!http_ || spec_.url.empty()) {
        return false;
    }

    ParsedPlaylist initialPl;
    bool ok = false;
    int32_t lastCode = 0;
    for (int attempt = 0; attempt < 3 && !cancelled_.load() && !closed_.load(); ++attempt) {
        std::string body;
        HttpFetchStatus status = HttpFetchStatus::NET_ERROR;
        const uint64_t epochBefore = http_->CurrentEpoch();
        if (FetchTextOnce(spec_.url, body, lastCode, status)) {
            if (ParseMediaPlaylist(body, spec_.url, initialPl)) {
                ok = true;
                break;
            }
            OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                         "Open: unsupported playlist itag=%{public}d master=%{public}d enc=%{public}d segs=%{public}zu",
                         spec_.itag, initialPl.isMaster ? 1 : 0, initialPl.hasEncryption ? 1 : 0,
                         initialPl.segments.size());
            return false;
        }
        if (lastCode == 403 || lastCode == 404 || lastCode == 410 || status == HttpFetchStatus::HTTP_PROXY_AUTH) {
            OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                         "Open: playlist fatal http=%{public}d itag=%{public}d", lastCode, spec_.itag);
            return false;
        }
        if (http_->CurrentEpoch() != epochBefore) {
            continue; // handover: retry immediately
        }
        if (attempt < 2) {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait_for(lock, std::chrono::milliseconds(300 * (attempt + 1)), [this]() {
                return cancelled_.load() || closed_.load();
            });
        }
    }

    if (!ok || cancelled_.load() || closed_.load()) {
        OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                     "Open: initial playlist fetch failed itag=%{public}d http=%{public}d", spec_.itag, lastCode);
        return false;
    }

    // Optional fMP4 init segment (#EXT-X-MAP)
    if (!initialPl.initMapUrl.empty()) {
        if (!FetchBytesOnce(initialPl.initMapUrl, initialPl.initMapRangeStart, initialPl.initMapRangeEnd, initMapData_)) {
            OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                         "Open: EXT-X-MAP fetch failed itag=%{public}d", spec_.itag);
            return false;
        }
        initMapReadPos_ = 0;
        initMapPending_ = !initMapData_.empty();
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        MergePlaylistLocked(initialPl, true);
        lastPlaylistRefreshUs_ = SteadyNowUs();
        lastProgressLogUs_ = lastPlaylistRefreshUs_;
        OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                     "Open ok itag=%{public}d audio=%{public}d targetDur=%{public}.1fs window=[%{public}lld..%{public}lld] startSeq=%{public}lld map=%{public}zuB",
                     spec_.itag,
                     spec_.isAudio ? 1 : 0,
                     targetDurationSec_,
                     static_cast<long long>(earliestPlaylistSeq_),
                     static_cast<long long>(latestPlaylistSeq_),
                     static_cast<long long>(nextReadSeq_),
                     initMapData_.size());
        threadsStarted_ = true;
    }

    playlistThread_ = std::thread(&HlsLiveStream::PlaylistLoop, this);
    workerThreads_.reserve(kWorkerCount);
    for (int i = 0; i < kWorkerCount; ++i) {
        workerThreads_.emplace_back(&HlsLiveStream::WorkerLoop, this, i);
    }
    return true;
}

void HlsLiveStream::PlaylistLoop()
{
    while (!cancelled_.load() && !closed_.load()) {
        int64_t waitMs = 1000;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            if (playlistEnded_ || fatalError_) {
                break;
            }
            waitMs = static_cast<int64_t>(std::clamp(targetDurationSec_ * 500.0, 900.0, 3000.0));
            cv_.wait_for(lock, std::chrono::milliseconds(waitMs), [this]() {
                return cancelled_.load() || closed_.load() || playlistEnded_ || fatalError_ || forceRefreshPlaylist_;
            });
            if (cancelled_.load() || closed_.load() || playlistEnded_ || fatalError_) {
                break;
            }
            forceRefreshPlaylist_ = false;
        }

        const uint64_t epochBefore = http_->CurrentEpoch();
        std::string body;
        int32_t httpCode = 0;
        HttpFetchStatus status = HttpFetchStatus::NET_ERROR;
        const bool fetched = FetchTextOnce(spec_.url, body, httpCode, status);

        if (cancelled_.load() || closed_.load()) {
            break;
        }

        if (fetched) {
            ParsedPlaylist pl;
            if (ParseMediaPlaylist(body, spec_.url, pl)) {
                std::lock_guard<std::mutex> lock(mutex_);
                consecutivePlaylistFailures_ = 0;
                lastPlaylistRefreshUs_ = SteadyNowUs();
                const int64_t prevLatest = latestPlaylistSeq_;
                MergePlaylistLocked(pl, false);
                if (latestPlaylistSeq_ == prevLatest && !playlistEnded_) {
                    // No new segment yet: avoid spinning, next loop waits ~targetDur/2.
                }
                cv_.notify_all();
                continue;
            }
        }

        if (http_->CurrentEpoch() != epochBefore) {
            // Network handover: refresh immediately on the new network.
            std::lock_guard<std::mutex> lock(mutex_);
            forceRefreshPlaylist_ = true;
            continue;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        if (httpCode == 403 || status == HttpFetchStatus::HTTP_PROXY_AUTH) {
            OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                         "PlaylistLoop fatal http=%{public}d itag=%{public}d", httpCode, spec_.itag);
            fatalError_ = true;
            cv_.notify_all();
            break;
        }
        ++consecutivePlaylistFailures_;
        if (counters_) {
            counters_->retryCount.fetch_add(1);
        }
        OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                     "PlaylistLoop refresh failed itag=%{public}d http=%{public}d fail=%{public}d/%{public}d",
                     spec_.itag, httpCode, consecutivePlaylistFailures_, kMaxPlaylistFailures);
        if (consecutivePlaylistFailures_ >= kMaxPlaylistFailures) {
            fatalError_ = true;
            cv_.notify_all();
            break;
        }
    }
}

void HlsLiveStream::WorkerLoop(int /*workerId*/)
{
    while (!cancelled_.load() && !closed_.load()) {
        int64_t targetSeq = -1;
        std::string segUrl;
        int64_t rangeStart = -1;
        int64_t rangeEnd = -1;
        size_t existingBytes = 0;

        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this, &targetSeq]() {
                if (cancelled_.load() || closed_.load() || fatalError_) {
                    return true;
                }
                for (auto& kv : segments_) {
                    const int64_t seq = kv.first;
                    if (seq < nextReadSeq_) continue;
                    if (kv.second.state != SegState::QUEUED) continue;
                    const bool isImmediate = (seq == nextReadSeq_);
                    const bool withinWindow = (seq < nextReadSeq_ + kMaxAheadSegments) &&
                        (bufferedBytes_ < kMaxBufferedBytes);
                    if (isImmediate || withinWindow) {
                        targetSeq = seq;
                        return true;
                    }
                    break; // ordered map: higher seqs won't fit either
                }
                return false;
            });

            if (cancelled_.load() || closed_.load() || fatalError_) {
                break;
            }
            auto it = segments_.find(targetSeq);
            if (it == segments_.end() || it->second.state != SegState::QUEUED) {
                continue;
            }
            it->second.state = SegState::FETCHING;
            segUrl = it->second.url;
            rangeStart = it->second.byteRangeStart;
            rangeEnd = it->second.byteRangeEnd;
            existingBytes = it->second.data.size();
        }

        const uint64_t reqEpoch = http_->CurrentEpoch();
        size_t receivedThisAttempt = 0;

        const HttpFetchResult res = http_->FetchRangeStream(
            segUrl,
            rangeStart,
            rangeEnd,
            spec_.headers,
            spec_.userAgent,
            reqEpoch,
            cancelled_,
            [this, targetSeq, existingBytes, &receivedThisAttempt](const uint8_t* data, size_t len) -> bool {
                if (cancelled_.load() || closed_.load()) {
                    return false;
                }
                const size_t prevTotal = receivedThisAttempt;
                receivedThisAttempt += len;
                // Byte-exact resume on mid-segment retry: skip prefix already appended.
                if (receivedThisAttempt <= existingBytes) {
                    return true;
                }
                size_t skip = 0;
                if (prevTotal < existingBytes) {
                    skip = existingBytes - prevTotal;
                }
                const uint8_t* appendPtr = data + skip;
                const size_t appendLen = len - skip;
                if (appendLen == 0) {
                    return true;
                }

                std::lock_guard<std::mutex> lock(mutex_);
                auto it = segments_.find(targetSeq);
                if (it == segments_.end() || targetSeq < nextReadSeq_) {
                    return false; // consumer already moved past this segment
                }
                it->second.data.insert(it->second.data.end(), appendPtr, appendPtr + appendLen);
                bufferedBytes_ += appendLen;
                if (counters_) {
                    counters_->totalBytesRead.fetch_add(static_cast<int64_t>(appendLen));
                }
                cv_.notify_all();
                return true;
            });

        if (cancelled_.load() || closed_.load()) {
            break;
        }

        if (counters_ && res.httpCode > 0) {
            counters_->lastHttpStatus.store(res.httpCode);
        }

        int32_t retryDelayMs = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = segments_.find(targetSeq);
            if (it == segments_.end()) {
                continue;
            }
            auto& entry = it->second;
            entry.lastHttpCode = res.httpCode;

            if (res.status == HttpFetchStatus::OK && (res.bytesReceived > 0 || !entry.data.empty())) {
                entry.state = SegState::READY;
                entry.complete = true;
                if (bwEst_ && res.bytesReceived > 0) {
                    bwEst_->OnBytesTransferred(res.bytesReceived, res.elapsedUs, res.firstByteUs);
                }
                cv_.notify_all();
                continue;
            }

            if (res.httpCode == 403 || res.status == HttpFetchStatus::HTTP_PROXY_AUTH) {
                entry.state = SegState::FAILED;
                entry.fatalAuth = true;
                fatalError_ = true;
                OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                             "seg fatal auth seq=%{public}lld itag=%{public}d http=%{public}d",
                             static_cast<long long>(targetSeq), spec_.itag, res.httpCode);
                cv_.notify_all();
                break;
            }

            if (res.httpCode == 404 || res.httpCode == 410) {
                entry.state = SegState::FAILED;
                entry.expiredOrGone = true;
                forceRefreshPlaylist_ = true;
                OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                             "seg gone seq=%{public}lld itag=%{public}d http=%{public}d (resyncing live edge)",
                             static_cast<long long>(targetSeq), spec_.itag, res.httpCode);
                cv_.notify_all();
                continue;
            }

            // Network handover: retry immediately without burning normal retry budget.
            if (http_->CurrentEpoch() != reqEpoch && entry.handoverRetries < kMaxHandoverRetries) {
                ++entry.handoverRetries;
                entry.state = SegState::QUEUED;
                forceRefreshPlaylist_ = true;
                cv_.notify_all();
                continue;
            }

            ++entry.retries;
            if (counters_) {
                counters_->retryCount.fetch_add(1);
            }
            if (entry.retries <= kMaxSegRetries) {
                retryDelayMs = std::min(250 * entry.retries, 1000);
                OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                             "seg retry seq=%{public}lld itag=%{public}d status=%{public}d http=%{public}d try=%{public}d/%{public}d",
                             static_cast<long long>(targetSeq), spec_.itag,
                             static_cast<int>(res.status), res.httpCode, entry.retries, kMaxSegRetries);
            } else {
                entry.state = SegState::FAILED;
                OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                             "seg failed seq=%{public}lld itag=%{public}d http=%{public}d after %{public}d retries",
                             static_cast<long long>(targetSeq), spec_.itag, res.httpCode, kMaxSegRetries);
                cv_.notify_all();
                continue;
            }
        }

        if (retryDelayMs > 0) {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait_for(lock, std::chrono::milliseconds(retryDelayMs), [this]() {
                return cancelled_.load() || closed_.load();
            });
            if (cancelled_.load() || closed_.load()) {
                break;
            }
            auto it = segments_.find(targetSeq);
            if (it != segments_.end() && it->second.state == SegState::FETCHING) {
                it->second.state = SegState::QUEUED;
                cv_.notify_all();
            }
        }
    }
}

int64_t HlsLiveStream::ReadAt(int64_t /*offset*/, uint8_t* dst, size_t size)
{
    if (!dst || size == 0) return -1;
    if (cancelled_.load() || closed_.load()) return -1;

    // Emit optional fMP4 EXT-X-MAP init segment bytes first.
    if (initMapPending_) {
        if (initMapReadPos_ < initMapData_.size()) {
            const size_t n = std::min(size, initMapData_.size() - initMapReadPos_);
            std::memcpy(dst, initMapData_.data() + initMapReadPos_, n);
            initMapReadPos_ += n;
            if (initMapReadPos_ >= initMapData_.size()) {
                initMapPending_ = false;
                initMapData_.clear();
                initMapData_.shrink_to_fit();
            }
            return static_cast<int64_t>(n);
        }
        initMapPending_ = false;
    }

    const int64_t waitStartUs = SteadyNowUs();
    std::unique_lock<std::mutex> lock(mutex_);

    while (!cancelled_.load() && !closed_.load()) {
        auto it = segments_.find(nextReadSeq_);
        if (it != segments_.end()) {
            auto& entry = it->second;
            if (entry.data.size() > nextReadPos_) {
                const size_t avail = std::min(size, entry.data.size() - nextReadPos_);
                std::memcpy(dst, entry.data.data() + nextReadPos_, avail);
                nextReadPos_ += avail;
                consecutiveSegSkips_ = 0;

                if (entry.complete && nextReadPos_ >= entry.data.size()) {
                    const size_t freed = entry.data.size();
                    bufferedBytes_ = (bufferedBytes_ >= freed) ? (bufferedBytes_ - freed) : 0;
                    segments_.erase(it);
                    ++nextReadSeq_;
                    nextReadPos_ = 0;
                    ++segmentsServed_;

                    const int64_t nowUs = SteadyNowUs();
                    if (nowUs - lastProgressLogUs_ >= 20LL * 1000LL * 1000LL) {
                        lastProgressLogUs_ = nowUs;
                        int32_t readyCnt = 0;
                        for (const auto& kv : segments_) {
                            if (kv.second.state == SegState::READY) ++readyCnt;
                        }
                        OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag,
                                     "live health itag=%{public}d served=%{public}lld nextSeq=%{public}lld latest=%{public}lld ready=%{public}d bufKB=%{public}zu",
                                     spec_.itag,
                                     static_cast<long long>(segmentsServed_),
                                     static_cast<long long>(nextReadSeq_),
                                     static_cast<long long>(latestPlaylistSeq_),
                                     readyCnt,
                                     bufferedBytes_ / 1024);
                    }
                    cv_.notify_all();
                }
                return static_cast<int64_t>(avail);
            }

            if (entry.complete) {
                // Finished delivering all bytes of this segment (either streamed to the end
                // before OnResponseDone set complete=true, or an empty segment): free accounting.
                const size_t freed = entry.data.size();
                bufferedBytes_ = (bufferedBytes_ >= freed) ? (bufferedBytes_ - freed) : 0;
                segments_.erase(it);
                ++nextReadSeq_;
                nextReadPos_ = 0;
                ++segmentsServed_;
                cv_.notify_all();
                continue;
            }

            if (entry.state == SegState::FAILED) {
                if (entry.fatalAuth) {
                    return -1;
                }
                const bool expired = entry.expiredOrGone;
                const size_t freed = entry.data.size();
                bufferedBytes_ = (bufferedBytes_ >= freed) ? (bufferedBytes_ - freed) : 0;
                segments_.erase(it);
                nextReadPos_ = 0;

                if (expired) {
                    const int64_t snap = std::max(nextReadSeq_ + 1,
                        std::max(earliestPlaylistSeq_, latestPlaylistSeq_ - backSegments_));
                    nextReadSeq_ = snap;
                    PruneBelowReadSeqLocked();
                    forceRefreshPlaylist_ = true;
                    cv_.notify_all();
                    continue;
                }

                ++consecutiveSegSkips_;
                if (consecutiveSegSkips_ >= kMaxConsecutiveSegSkips) {
                    OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                                 "ReadAt aborting itag=%{public}d: %{public}d consecutive segment failures",
                                 spec_.itag, consecutiveSegSkips_);
                    return -1;
                }
                ++nextReadSeq_;
                forceRefreshPlaylist_ = true;
                cv_.notify_all();
                continue;
            }

            // Still QUEUED or FETCHING with no unread bytes yet: wake workers and wait.
            if (entry.state == SegState::QUEUED) {
                cv_.notify_all();
            }
        } else {
            // nextReadSeq_ not yet in playlist queue
            if (playlistEnded_ && nextReadSeq_ > latestPlaylistSeq_) {
                return 0; // clean live broadcast EOF
            }
            if (fatalError_) {
                return -1;
            }
            if (earliestPlaylistSeq_ > 0 && nextReadSeq_ < earliestPlaylistSeq_) {
                nextReadSeq_ = std::max(earliestPlaylistSeq_, latestPlaylistSeq_ - backSegments_);
                nextReadPos_ = 0;
                PruneBelowReadSeqLocked();
                continue;
            }
            const int64_t nowUs = SteadyNowUs();
            if (nowUs - lastPlaylistRefreshUs_ >= 400LL * 1000LL) {
                forceRefreshPlaylist_ = true;
                cv_.notify_all();
            }
        }

        if (fatalError_) {
            return -1;
        }
        if (SteadyNowUs() - waitStartUs >= kReadStallTimeoutUs) {
            OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                         "ReadAt stall timeout itag=%{public}d nextSeq=%{public}lld latest=%{public}lld",
                         spec_.itag,
                         static_cast<long long>(nextReadSeq_),
                         static_cast<long long>(latestPlaylistSeq_));
            return -1;
        }

        cv_.wait_for(lock, std::chrono::milliseconds(100));
    }

    return -1;
}

void HlsLiveStream::Cancel()
{
    cancelled_.store(true);
    cv_.notify_all();
}

StreamMetrics HlsLiveStream::SnapshotMetrics() const
{
    StreamMetrics m{};
    m.networkSpeedBps = bwEst_ ? bwEst_->EstimatedBps() : 0;
    if (counters_) {
        m.totalBytesRead = counters_->totalBytesRead.load();
        m.retryCount = counters_->retryCount.load();
        m.lastHttpStatus = counters_->lastHttpStatus.load();
    }
    return m;
}

void HlsLiveStream::JoinThreads()
{
    if (!threadsStarted_ || threadsJoined_) {
        return;
    }
    threadsJoined_ = true;
    if (playlistThread_.joinable()) {
        playlistThread_.join();
    }
    for (auto& t : workerThreads_) {
        if (t.joinable()) {
            t.join();
        }
    }
    workerThreads_.clear();
}

void HlsLiveStream::Close()
{
    cancelled_.store(true);
    closed_.store(true);
    cv_.notify_all();
    JoinThreads();
    std::lock_guard<std::mutex> lock(mutex_);
    segments_.clear();
    bufferedBytes_ = 0;
    initMapData_.clear();
}

} // namespace yp_stream
