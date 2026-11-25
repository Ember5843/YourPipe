#pragma once

#include "stream_types.h"
#include <cstddef>
#include <cstdint>

namespace yp_stream {

/**
 * Pluggable C++20 byte-stream source fed directly into MPV via mpv_stream_cb_add_ro
 * (zero local HTTP loopback proxy, zero socket copy).
 * Implementations: DirectRangeStream (VOD/DASH tracks), future HlsStreamSource & SabrStreamSource.
 */
class IStreamSource {
public:
    virtual ~IStreamSource() = default;

    virtual bool Open() = 0;
    virtual int64_t ReadAt(int64_t offset, uint8_t* dst, size_t size) = 0;
    virtual int64_t GetSize() const = 0;
    virtual bool IsSeekable() const { return true; }
    virtual void Cancel() = 0;
    virtual StreamMetrics SnapshotMetrics() const = 0;
    virtual void Close() = 0;
};

} // namespace yp_stream
