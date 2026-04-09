import Foundation

/// Counting semaphore for bounding async channel buffers.
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false

    init(count: Int) {
        self.count = count
    }

    func wait() async {
        if cancelled || count > 0 {
            count -= 1
            return
        }
        await withCheckedContinuation { continuation in
            if cancelled {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if waiters.isEmpty {
            count += 1
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    /// Resume all blocked waiters so they can observe cancellation.
    func cancelAll() {
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
