#include "dash_session.h"

#include <chrono>
#include <sstream>

namespace yourpipe {

DashSessionStore& DashSessionStore::instance() {
    static DashSessionStore store;
    return store;
}

std::string DashSessionStore::makeSessionId() {
    auto now = std::chrono::steady_clock::now().time_since_epoch();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
    std::ostringstream oss;
    oss << "s" << ms << "_" << nextId_++;
    return oss.str();
}

std::string DashSessionStore::add(DashSession session) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (session.id.empty()) {
        session.id = makeSessionId();
    }
    std::string id = session.id;
    sessions_[id] = std::make_shared<DashSession>(std::move(session));
    return id;
}

std::shared_ptr<DashSession> DashSessionStore::get(const std::string& id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = sessions_.find(id);
    if (it == sessions_.end()) {
        return nullptr;
    }
    return it->second;
}

bool DashSessionStore::remove(const std::string& id) {
    std::lock_guard<std::mutex> lock(mutex_);
    return sessions_.erase(id) > 0;
}

void DashSessionStore::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    sessions_.clear();
}

} // namespace yourpipe
