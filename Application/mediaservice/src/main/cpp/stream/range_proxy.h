#pragma once

#include "dash_session.h"
#include "http_client.h"

#include <cstdint>
#include <string>

namespace yourpipe {

struct ByteRange {
    int64_t start = 0;
    int64_t end = -1;
    bool hasRange = false;
    bool suffix = false;
};

class RangeProxy {
public:
    static bool parseRangeHeader(const std::string& headerValue, ByteRange& out);
    static bool serve(int clientFd,
                      const DashStreamResource& resource,
                      const std::string& rangeHeader,
                      bool headOnly);

private:
    static bool sendAll(int fd, const void* data, size_t size);
    static bool sendString(int fd, const std::string& value);
    static std::string contentTypeFor(const DashStreamResource& resource);
    static bool sendUpstreamError(int fd,
                                  const DashStreamResource& resource,
                                  const HttpResponse& resp,
                                  const std::string& range);
};

} // namespace yourpipe
