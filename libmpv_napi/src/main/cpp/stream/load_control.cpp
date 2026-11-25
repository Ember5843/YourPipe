#include "load_control.h"
#include <algorithm>

namespace yp_stream {

void BandwidthEstimator::Reset()
{
    std::lock_guard<std::mutex> lock(mutex_);
    fastEffectiveBps_ = 0.0;
    slowEffectiveBps_ = 0.0;
    fastWireBps_ = 0.0;
    slowWireBps_ = 0.0;
    ewmaTtfbUs_ = 0.0;
    samples_ = 0;
}

void BandwidthEstimator::OnBytesTransferred(int64_t bytes, int64_t totalElapsedUs, int64_t firstByteUs)
{
    if (bytes < 65536 || totalElapsedUs <= 1000) {
        return;
    }
    const double effBps = (static_cast<double>(bytes) * 1000000.0) / static_cast<double>(totalElapsedUs);
    if (effBps <= 0.0 || effBps > 5e8) {
        return;
    }

    // Separate pure payload transfer time from RTT/TTFB so high-RTT VPN/proxy
    // links do not underestimate wire capacity and get trapped in small chunks.
    int64_t transferUs = totalElapsedUs;
    int64_t clampedTtfbUs = 0;
    if (firstByteUs > 0 && firstByteUs < totalElapsedUs) {
        clampedTtfbUs = firstByteUs;
        transferUs = std::max<int64_t>(5000, totalElapsedUs - firstByteUs);
    }
    double wireBps = (static_cast<double>(bytes) * 1000000.0) / static_cast<double>(transferUs);
    wireBps = std::clamp(wireBps, effBps, 2e8);

    std::lock_guard<std::mutex> lock(mutex_);
    if (samples_ == 0) {
        fastEffectiveBps_ = effBps;
        slowEffectiveBps_ = effBps;
        fastWireBps_ = wireBps;
        slowWireBps_ = wireBps;
        ewmaTtfbUs_ = static_cast<double>(clampedTtfbUs);
    } else {
        fastEffectiveBps_ = 0.35 * effBps + 0.65 * fastEffectiveBps_;
        slowEffectiveBps_ = 0.12 * effBps + 0.88 * slowEffectiveBps_;
        fastWireBps_ = 0.35 * wireBps + 0.65 * fastWireBps_;
        slowWireBps_ = 0.15 * wireBps + 0.85 * slowWireBps_;
        if (clampedTtfbUs > 0) {
            ewmaTtfbUs_ = ewmaTtfbUs_ > 0.0
                ? (0.25 * static_cast<double>(clampedTtfbUs) + 0.75 * ewmaTtfbUs_)
                : static_cast<double>(clampedTtfbUs);
        }
    }
    samples_++;
}

int64_t BandwidthEstimator::EstimatedBps() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (samples_ == 0) {
        return 0;
    }
    return static_cast<int64_t>(std::min(fastEffectiveBps_, slowEffectiveBps_));
}

int64_t BandwidthEstimator::EstimatedWireBps() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (samples_ == 0) {
        return 0;
    }
    return static_cast<int64_t>(std::min(fastWireBps_, slowWireBps_));
}

int64_t BandwidthEstimator::EstimatedTtfbUs() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return static_cast<int64_t>(ewmaTtfbUs_);
}

int32_t BandwidthEstimator::SelectAdaptiveChunkSize(int32_t minBytes, int32_t maxBytes, int32_t bitrateBps) const
{
    const int32_t lo = std::max<int32_t>(65536, minBytes);
    const int32_t hi = std::max<int32_t>(lo, maxBytes);

    // Low-bitrate audio tracks: fixed 512 KiB (~30s of 128kbps audio in 1 RTT).
    if (bitrateBps > 0 && bitrateBps < 300000) {
        return std::clamp<int32_t>(524288, lo, hi);
    }

    // Bitrate-tiered floor and cap so high-bitrate 1080p60/2K/4K60 streams never
    // starve behind high-RTT VPN/proxy links, while low-bitrate streams stay frugal.
    int32_t bitrateFloor = 1048576; // 1 MiB default when bitrate is unknown
    int32_t bitrateCap = hi;
    if (bitrateBps > 40000000) {
        // >40 Mbps (e.g. 4K60 VP9 76 Mbps): 4 MiB floor, up to 8 MiB
        bitrateFloor = 4194304;
        bitrateCap = std::min<int32_t>(hi, 8388608);
    } else if (bitrateBps > 16000000) {
        // 16..40 Mbps (2K60 / 4K30): 4 MiB floor, up to 6 MiB
        bitrateFloor = 4194304;
        bitrateCap = std::min<int32_t>(hi, 6291456);
    } else if (bitrateBps > 4000000) {
        // 4..16 Mbps (1080p / 1080p60 / 2K30): 2 MiB floor, up to 4 MiB
        bitrateFloor = 2097152;
        bitrateCap = std::min<int32_t>(hi, 4194304);
    } else if (bitrateBps > 0) {
        // <=4 Mbps (480p..720p): 512 KiB floor, up to 2 MiB
        bitrateFloor = 524288;
        bitrateCap = std::min<int32_t>(hi, 2097152);
    }

    double wireBps = 0.0;
    double ttfbSec = 0.0;
    int32_t samples = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        samples = samples_;
        wireBps = std::max(fastWireBps_, slowWireBps_ * 0.85);
        ttfbSec = ewmaTtfbUs_ / 1000000.0;
    }

    double rawTarget = static_cast<double>(bitrateFloor);
    if (samples > 0 && wireBps > 0.0) {
        // Aim for payload transfer time >= max(0.40s, 2.5 * RTT) capped at 1.40s.
        const double targetTransferSec = std::clamp(std::max(0.40, ttfbSec * 2.5), 0.40, 1.40);
        const double bwTarget = wireBps * targetTransferSec;
        if (bwTarget > rawTarget) {
            rawTarget = bwTarget;
        }
    }

    int32_t chosen = 262144;
    if (rawTarget < 393216.0) {
        chosen = 262144;  // 256 KiB
    } else if (rawTarget < 786432.0) {
        chosen = 524288;  // 512 KiB
    } else if (rawTarget < 1572864.0) {
        chosen = 1048576; // 1 MiB
    } else if (rawTarget < 3145728.0) {
        chosen = 2097152; // 2 MiB
    } else if (rawTarget < 5242880.0) {
        chosen = 4194304; // 4 MiB
    } else if (rawTarget < 7340032.0) {
        chosen = 6291456; // 6 MiB
    } else {
        chosen = 8388608; // 8 MiB
    }
    const int32_t effHi = std::max(lo, bitrateCap);
    return std::clamp(chosen, lo, effHi);
}

void LoadController::SetConfig(const StreamLoadControlConfig& cfg)
{
    std::lock_guard<std::mutex> lock(mutex_);
    config_ = cfg;
}

StreamLoadControlConfig LoadController::GetConfig() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return config_;
}

} // namespace yp_stream
