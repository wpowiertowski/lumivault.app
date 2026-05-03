import Foundation

/// Type-erased cancellation for heterogeneous channel collections.
/// Marked nonisolated so detached pipeline stages can call `cancel()`
/// without an actor hop.
protocol CancellableChannel: Sendable {
    nonisolated func cancel() async
}

/// Bounded async channel with backpressure via AsyncSemaphore.
/// Producers block when the buffer is full; consumers iterate via AsyncStream.
/// All operations are nonisolated so producers/consumers can run on any actor.
struct AsyncChannel<Element: Sendable>: Sendable, CancellableChannel {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let semaphore: AsyncSemaphore

    nonisolated init(bufferSize: Int) {
        let sem = AsyncSemaphore(count: bufferSize)
        var cont: AsyncStream<Element>.Continuation!
        let s = AsyncStream<Element>(bufferingPolicy: .unbounded) { c in
            cont = c
        }
        self.stream = s
        self.continuation = cont
        self.semaphore = sem
    }

    /// Send an element into the channel. Suspends if buffer is full.
    nonisolated func send(_ element: Element) async {
        await semaphore.wait()
        continuation.yield(element)
    }

    /// Signal that no more elements will be sent.
    nonisolated func finish() {
        continuation.finish()
    }

    /// Signal that one element has been consumed, freeing a buffer slot.
    nonisolated func consumed() async {
        await semaphore.signal()
    }

    /// Cancel the channel: unblock any producers waiting on backpressure
    /// and terminate the stream so consumers stop iterating.
    nonisolated func cancel() async {
        await semaphore.cancelAll()
        continuation.finish()
    }
}
