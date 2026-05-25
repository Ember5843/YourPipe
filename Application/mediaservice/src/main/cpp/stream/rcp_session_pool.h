#pragma once
#include <string>

/**
 * Stub: replaced RCP session pool with libcurl internal connection reuse.
 * RcpSessionPool::clear() is now a no-op since libcurl handles connection
 * pooling per easy handle automatically.
 */
class RcpSessionPool {
public:
    static RcpSessionPool* instance() {
        static RcpSessionPool pool;
        return &pool;
    }
    void clear() {}
private:
    RcpSessionPool() = default;
};
