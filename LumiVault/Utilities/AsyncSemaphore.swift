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

/// A weighted semaphore that bounds the total *bytes* of concurrent
/// memory-heavy work in flight. Used to keep the encryption and PAR2 stages
/// from stacking multiple large videos' worth of buffers — CPU `Data` plus,
/// for GPU PAR2, Metal buffers in unified memory — into multi-gigabyte peaks
/// that wedge the import. Photos are tiny and effectively never block; only
/// large videos serialize against each other.
///
/// A single request larger than the whole budget is clamped to the budget so
/// an oversized file still runs (solo, once the budget is otherwise idle)
/// rather than deadlocking. Admission is FIFO: a stream of small requests can't
/// starve a queued large one.
actor MemoryBudgetSemaphore {
    private let capacity: Int64
    private var used: Int64 = 0
    private var waiters: [(weight: Int64, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelled = false

    init(capacity: Int64) {
        self.capacity = max(1, capacity)
    }

    /// Acquire `weight` bytes of budget, suspending until they fit. The weight is
    /// clamped to `[0, capacity]`; a request at capacity runs only when the budget
    /// is otherwise idle.
    func acquire(_ weight: Int64) async {
        let need = min(max(0, weight), capacity)
        if cancelled { return }
        // Admit immediately only when nobody is queued (preserving FIFO) and it fits.
        if waiters.isEmpty && used + need <= capacity {
            used += need
            return
        }
        await withCheckedContinuation { continuation in
            if cancelled {
                continuation.resume()
            } else {
                waiters.append((need, continuation))
            }
        }
    }

    /// Release `weight` bytes and admit as many head-of-line waiters as now fit.
    func release(_ weight: Int64) {
        let give = min(max(0, weight), capacity)
        used = max(0, used - give)
        // FIFO: only ever admit from the head, so a small tail request can't jump
        // ahead of a large queued one.
        while let head = waiters.first, used + head.weight <= capacity {
            used += head.weight
            waiters.removeFirst()
            head.continuation.resume()
        }
    }

    /// Resume all blocked waiters so they can observe cancellation.
    func cancelAll() {
        cancelled = true
        used = 0
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume()
        }
    }
}
