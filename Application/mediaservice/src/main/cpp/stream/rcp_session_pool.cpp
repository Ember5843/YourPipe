#include "rcp_session_pool.h"
#include <hilog/log.h>
#include <algorithm>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "RcpSessionPool"
#define LOG_DOMAIN 0x3203

// ------------------------------------------------------------------
// PooledSession
// ------------------------------------------------------------------

void PooledSession::close() {
    bool expected = false;
    if (!closed.compare_exchange_strong(expected, true)) {
        return; // already closed
    }
    inUse = false;
    if (session) {
        HMS_Rcp_CloseSession(&session);
        session = nullptr;
    }
}

bool PooledSession::isExpired(int ttlMs) const {
    if (closed.load() || inUse.load()) {
        return true;
    }
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastUsed).count();
    return elapsed > ttlMs;
}

bool PooledSession::acquire() {
    bool expected = false;
    if (!inUse.compare_exchange_strong(expected, true)) {
        return false; // already in use
    }
    if (closed.load()) {
        inUse = false;
        return false;
    }
    return true;
}

void PooledSession::release() {
    lastUsed = std::chrono::steady_clock::now();
    inUse = false;
}

// ------------------------------------------------------------------
// RcpSessionPool
// ------------------------------------------------------------------

RcpSessionPool::~RcpSessionPool() {
    clear();
}

RcpSessionPool* RcpSessionPool::instance() {
    static RcpSessionPool pool;
    return &pool;
}

std::string RcpSessionPool::extractDomain(const std::string& url) {
    // Extract host from scheme://host/path
    size_t schemeEnd = url.find("://");
    size_t start = (schemeEnd == std::string::npos) ? 0 : schemeEnd + 3;
    size_t end = url.find('/', start);
    if (end == std::string::npos) {
        end = url.find('?', start);
    }
    std::string host = (end == std::string::npos)
                           ? url.substr(start)
                           : url.substr(start, end - start);
    // Strip port if present
    size_t portPos = host.find(':');
    if (portPos != std::string::npos) {
        host = host.substr(0, portPos);
    }
    return host;
}

std::shared_ptr<PooledSession> RcpSessionPool::createSession(const std::string& domain) {
    auto ps = std::make_shared<PooledSession>();
    ps->domain = domain;

    uint32_t errCode = 0;
    ps->session = HMS_Rcp_CreateSession(nullptr, &errCode);
    if (!ps->session || errCode != 0) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] Failed to create session for domain=%{public}s err=%{public}u",
                     LOG_TAG, domain.c_str(), errCode);
        ps->session = nullptr;
    } else {
        OH_LOG_INFO(LOG_APP, "[%{public}s] Created new session for domain=%{public}s",
                    LOG_TAG, domain.c_str());
    }
    ps->lastUsed = std::chrono::steady_clock::now();
    return ps;
}

std::shared_ptr<PooledSession> RcpSessionPool::borrow(const std::string& url) {
    if (!config_.enabled) {
        // Pool disabled: return a standalone session (not pooled).
        auto ps = createSession(extractDomain(url));
        ps->acquire(); // mark in-use so returnSession won't put it back
        return ps;
    }

    std::string domain = extractDomain(url);
    std::lock_guard<std::mutex> lk(mtx_);

    evictUnderLock();

    auto it = pool_.find(domain);
    if (it != pool_.end()) {
        auto ps = it->second;
        if (ps && !ps->isExpired(config_.sessionTtlMs) && ps->acquire()) {
            ps->useCount++;
            OH_LOG_DEBUG(LOG_APP, "[%{public}s] Reuse session for domain=%{public}s useCount=%{public}d",
                         LOG_TAG, domain.c_str(), ps->useCount.load());
            return ps;
        }
        if (ps && ps->inUse.load() && !ps->closed.load()) {
            // RCP sessions cannot be borrowed concurrently. Keep the in-flight
            // session alive and create a replacement for the new request.
            auto replacement = createSession(domain);
            if (replacement->session) {
                replacement->acquire();
                replacement->useCount = 1;
                pool_[domain] = replacement;
            }
            return replacement;
        }
        // Expired or failed to acquire: remove stale entry
        if (ps) {
            ps->close();
        }
        pool_.erase(it);
    }

    // Create new session and add to pool (still marked in-use)
    auto ps = createSession(domain);
    if (ps->session) {
        ps->acquire();
        ps->useCount = 1;
        pool_[domain] = ps;
    }
    return ps;
}

void RcpSessionPool::returnSession(std::shared_ptr<PooledSession> ps) {
    if (!ps) {
        return;
    }

    // If pool is disabled, this session was created as standalone -- close it.
    if (!config_.enabled) {
        ps->close();
        return;
    }

    ps->release();

    std::lock_guard<std::mutex> lk(mtx_);

    // If expired or session handle is null, close and remove.
    if (ps->isExpired(config_.sessionTtlMs) || !ps->session) {
        ps->close();
        auto it = pool_.find(ps->domain);
        if (it != pool_.end() && it->second == ps) {
            pool_.erase(it);
        }
        return;
    }

    // Ensure the entry is still in the pool.
    auto it = pool_.find(ps->domain);
    if (it == pool_.end() || it->second != ps) {
        // Not in pool (maybe evicted while in use) -- close it.
        ps->close();
    }
}

void RcpSessionPool::evictUnderLock() {
    // Remove expired entries
    for (auto it = pool_.begin(); it != pool_.end();) {
        auto& ps = it->second;
        if (!ps || ps->isExpired(config_.sessionTtlMs)) {
            if (ps) {
                ps->close();
            }
            it = pool_.erase(it);
        } else {
            ++it;
        }
    }

    // If still over maxDomains, evict oldest (least recently used)
    while (pool_.size() > config_.maxDomains) {
        auto oldest = pool_.begin();
        for (auto it = pool_.begin(); it != pool_.end(); ++it) {
            if (it->second && it->second->lastUsed < oldest->second->lastUsed) {
                oldest = it;
            }
        }
        if (oldest != pool_.end()) {
            if (oldest->second) {
                oldest->second->close();
            }
            pool_.erase(oldest);
        } else {
            break;
        }
    }
}

void RcpSessionPool::clear() {
    std::lock_guard<std::mutex> lk(mtx_);
    for (auto& kv : pool_) {
        if (kv.second) {
            kv.second->close();
        }
    }
    pool_.clear();
}

size_t RcpSessionPool::size() const {
    std::lock_guard<std::mutex> lk(mtx_);
    return pool_.size();
}
