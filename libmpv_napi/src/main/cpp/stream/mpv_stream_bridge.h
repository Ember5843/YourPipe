#pragma once

#include "direct_range_stream.h"
#include "load_control.h"
#include "native_http_transport.h"
#include "stream_source.h"
#include "stream_types.h"
#include <atomic>
#include <map>
#include <memory>
#include <mpv/stream_cb.h>
#include <mutex>
#include <string>
#include <vector>

namespace yp_stream {

/**
 * Process-wide registry and MPV mpv_stream_cb_add_ro bridge for the "ypstream://"
 * pluggable C++ streaming protocol.
 */
class MpvStreamBridge {
public:
    static MpvStreamBridge& Instance();

    std::string RegisterDirectStreamJson(const std::string& specJson);
    std::string RegisterHlsStreamJson(const std::string& specJson);
    void UnregisterStream(const std::string& urlOrId);
    void UpdateProxyJson(const std::string& proxyJson);
    void AbortAllInFlight();
    StreamMetrics SnapshotMetrics() const;

    // Registered via mpv_stream_cb_add_ro(mpv, "ypstream", nullptr, &MpvStreamBridge::OpenRoCallback)
    static int OpenRoCallback(void* userData, char* uri, mpv_stream_cb_info* info);

private:
    MpvStreamBridge();

    static std::string ExtractStreamId(const std::string& urlOrId);

    std::shared_ptr<NativeHttpTransport> http_;
    std::shared_ptr<BandwidthEstimator> bwEst_;
    std::shared_ptr<LoadController> loadCtrl_;
    std::shared_ptr<SharedStreamCounters> counters_;

    mutable std::mutex mutex_;
    std::atomic<uint64_t> seq_{1};
    std::map<std::string, DirectStreamSpec> specs_;
    std::map<std::string, HlsStreamSpec> hlsSpecs_;
    std::map<std::string, std::vector<std::weak_ptr<IStreamSource>>> activeSources_;
};

} // namespace yp_stream
