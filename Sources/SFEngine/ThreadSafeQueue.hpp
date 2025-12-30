// ThreadSafeQueue.hpp
// Simple blocking queue for passing commands between threads.
#pragma once

#include <condition_variable>
#include <deque>
#include <mutex>
#include <utility>

namespace SFEmbedded {

// Minimal thread-safe queue with close semantics.
// - push() adds work; pop() blocks until work arrives or the queue is closed.
// - close() unblocks waiters and prevents future pushes.
// - pop() returns false when closed and empty (used as an EOF signal).
template<typename T>
class ThreadSafeQueue {
   public:
    // Enqueue a value. No-op after close().
    void push(T value) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (closed_)
                return;
            queue_.push_back(std::move(value));
        }
        cv_.notify_one();
    }

    // Blocks until an item is available or the queue is closed.
    // Returns false if the queue is closed and empty.
    bool pop(T& out) {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [&] { return closed_ || !queue_.empty(); });
        if (queue_.empty())
            return false;

        out = std::move(queue_.front());
        queue_.pop_front();
        return true;
    }

    // Close the queue: future pops will return false once drained.
    void close() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            closed_ = true;
        }
        cv_.notify_all();
    }

    // Query closed state (thread-safe).
    bool closed() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return closed_;
    }

   private:
    mutable std::mutex              mutex_;
    std::condition_variable         cv_;
    std::deque<T>                   queue_;
    bool                            closed_ = false;
};

}  // namespace SFEmbedded
