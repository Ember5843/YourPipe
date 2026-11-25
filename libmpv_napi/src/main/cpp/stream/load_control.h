#pragma once

#include "stream_types.h"
#include <cstdint>
#include <mutex>

namespace yp_stream {

/**
 * Dual-EWMA bandwidth estimator (separating wire transfer speed from RTT/TTFB)
 * and bitrate + RTT-aware adaptive HTTP range chunk selector.
 */
class BandwidthEstimator {
public:
    void Reset();
    void OnBytesTransferred(int64_t bytes, int64_t totalElapsedUs, int64_t firstByteUs = 0);
    int64_t EstimatedBps() const;
    int64_t EstimatedWireBps() const;
    int64_t EstimatedTtfbUs() const;
    int32_t SelectAdaptiveChunkSize(int32_t minBytes, int32_t maxBytes, int32_t bitrateBps = 0) const;

private:
    mutable std::mutex mutex_;
    double fastEffectiveBps_ = 0.0;
    double slowEffectiveBps_ = 0.0;
    double fastWireBps_ = 0.0;
    double slowWireBps_ = 0.0;
    double ewmaTtfbUs_ = 0.0;
    int32_t samples_ = 0;
};

class LoadController {
public:
    void SetConfig(const StreamLoadControlConfig& cfg);
    StreamLoadControlConfig GetConfig() const;

private:
    mutable std::mutex mutex_;
    StreamLoadControlConfig config_{};
};

} // namespace yp_stream
