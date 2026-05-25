#pragma once

#include <cstdint>
#include <vector>

namespace yourpipe {

struct SidxSegment {
    int64_t offset;
    int64_t size;
    double duration;
};

struct SidxInfo {
    uint32_t timescale = 0;
    std::vector<SidxSegment> segments;
    double totalDuration = 0;
    bool valid = false;
};

// Parse an ISO 14496-12 sidx box.
// data/dataLen: raw bytes of the sidx box (starting from box size field).
// sidxEndOffset: absolute file offset of the byte AFTER the sidx box
//                (i.e., indexRangeEnd + 1). First segment starts at
//                sidxEndOffset + first_offset.
SidxInfo parseSidxBox(const uint8_t* data, size_t dataLen, int64_t sidxEndOffset);

} // namespace yourpipe
