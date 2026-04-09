import Foundation

/// Type-erased cancellation for heterogeneous channel collections.
protocol CancellableChannel: Sendable {
    func cancel() async
}

/// Bounded async channel with backpressure via AsyncSemaphore.
/// Producers block when the buffer is full; consumers iterate via AsyncStream.
struct AsyncChannel<Element: Sendable>: Sendable, CancellableChannel {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let semaphore: AsyncSemaphore

    init(bufferSize: Int) {
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
    func send(_ element: Element) async {
        await semaphore.wait()
        continuation.yield(element)
    }

    /// Signal that no more elements will be sent.
    func finish() {
        continuation.finish()
    }

    /// Signal that one element has been consumed, freeing a buffer slot.
    func consumed() async {
        await semaphore.signal()
    }

    /// Cancel the channel: unblock any producers waiting on backpressure
    /// and terminate the stream so consumers stop iterating.
    func cancel() async {
        await semaphore.cancelAll()
        continuation.finish()
    }
}
