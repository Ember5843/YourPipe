#include "sidx_parser.h"

namespace yourpipe {

static uint32_t readU32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

static uint64_t readU64(const uint8_t* p) {
    return (uint64_t(readU32(p)) << 32) | uint64_t(readU32(p + 4));
}

static uint16_t readU16(const uint8_t* p) {
    return (uint16_t(p[0]) << 8) | uint16_t(p[1]);
}

SidxInfo parseSidxBox(const uint8_t* data, size_t dataLen, int64_t sidxEndOffset) {
    SidxInfo info;
    if (!data || dataLen < 12) return info;

    size_t pos = 0;
    uint32_t boxSize = readU32(data + pos);
    pos += 4;
    uint32_t boxType = readU32(data + pos);
    pos += 4;

    // Verify box type is 'sidx' (0x73696478)
    if (boxType != 0x73696478) return info;

    if (boxSize == 1) {
        if (dataLen < 16) return info;
        pos += 8; // skip largesize
    }

    if (pos + 4 > dataLen) return info;
    uint8_t version = data[pos];
    pos += 4; // version(1) + flags(3)

    if (pos + 4 > dataLen) return info;
    pos += 4; // reference_id

    if (pos + 4 > dataLen) return info;
    info.timescale = readU32(data + pos);
    pos += 4;
    if (info.timescale == 0) return info;

    int64_t firstOffset = 0;
    if (version == 0) {
        if (pos + 8 > dataLen) return info;
        pos += 4; // earliest_presentation_time
        firstOffset = (int64_t)readU32(data + pos);
        pos += 4;
    } else {
        if (pos + 16 > dataLen) return info;
        pos += 8; // earliest_presentation_time (64-bit)
        firstOffset = (int64_t)readU64(data + pos);
        pos += 8;
    }

    if (pos + 4 > dataLen) return info;
    pos += 2; // reserved
    uint16_t refCount = readU16(data + pos);
    pos += 2;

    size_t needed = pos + (size_t)refCount * 12;
    if (needed > dataLen) return info;

    int64_t currentOffset = sidxEndOffset + firstOffset;
    info.segments.reserve(refCount);
    info.totalDuration = 0;

    for (uint16_t i = 0; i < refCount; i++) {
        uint32_t word0 = readU32(data + pos);
        uint32_t duration = readU32(data + pos + 4);
        pos += 12; // skip SAP fields too

        uint32_t refSize = word0 & 0x7FFFFFFF;
        double segDur = (double)duration / (double)info.timescale;

        info.segments.push_back({currentOffset, (int64_t)refSize, segDur});
        currentOffset += (int64_t)refSize;
        info.totalDuration += segDur;
    }

    info.valid = !info.segments.empty();
    return info;
}

} // namespace yourpipe
