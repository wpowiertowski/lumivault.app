import Testing
import Foundation
@testable import LumiVault

// MARK: - AsyncSemaphore

@Suite
@MainActor
struct AsyncSemaphoreTests {

    @Test func waitConsumesAvailableCount() async {
        let sem = AsyncSemaphore(count: 3)
        await sem.wait()
        await sem.wait()
        await sem.wait()
        // Three slots consumed; a fourth wait would suspend (not exercised here).
    }

    @Test func signalWithoutWaitersIncreasesCount() async {
        let sem = AsyncSemaphore(count: 0)
        await sem.signal()
        await sem.signal()
        // Two signals queued; these two waits return immediately.
        await sem.wait()
        await sem.wait()
    }

    @Test func waitSuspendsWhenCountIsZero() async {
        let sem = AsyncSemaphore(count: 0)
        let resumed = AsyncFlag()

        let waiter = Task {
            await sem.wait()
            await resumed.fire()
        }

        // Give the waiter a moment to suspend. Without a signal, the flag must stay unset.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await resumed.value == false)

        await sem.signal()
        _ = await waiter.value
        #expect(await resumed.value == true)
    }

    @Test func cancelAllResumesEveryWaiter() async {
        let sem = AsyncSemaphore(count: 0)
        let counter = AsyncCounter()

        let waiters = (0..<5).map { _ in
            Task {
                await sem.wait()
                await counter.increment()
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.value == 0)

        await sem.cancelAll()

        for w in waiters { _ = await w.value }
        #expect(await counter.value == 5)
    }

    @Test func waitAfterCancelDoesNotSuspend() async {
        let sem = AsyncSemaphore(count: 0)
        await sem.cancelAll()

        // If cancellation state was broken, `wait()` would suspend on a
        // CheckedContinuation and the test would hang until the suite-level
        // timeout fires. Reaching the line after `wait()` is the assertion.
        await sem.wait()
    }
}

// MARK: - MemoryBudgetSemaphore

@Suite
@MainActor
struct MemoryBudgetSemaphoreTests {

    @Test func acquireWithinBudgetDoesNotSuspend() async {
        let sem = MemoryBudgetSemaphore(capacity: 1000)
        await sem.acquire(400)
        await sem.acquire(400)   // 800 <= 1000, still fits
        // Reaching here without suspending is the assertion.
    }

    @Test func acquireBeyondBudgetSuspendsUntilRelease() async {
        let sem = MemoryBudgetSemaphore(capacity: 1000)
        await sem.acquire(800)
        let resumed = AsyncFlag()

        let waiter = Task {
            await sem.acquire(400)   // 800 + 400 > 1000 → suspends
            await resumed.fire()
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await resumed.value == false)

        await sem.release(800)       // frees the budget → waiter admitted
        _ = await waiter.value
        #expect(await resumed.value == true)
    }

    @Test func oversizedRequestRunsSoloWhenIdle() async {
        let sem = MemoryBudgetSemaphore(capacity: 1000)
        // A single request larger than the whole budget is clamped to capacity
        // and admitted when the budget is idle, rather than deadlocking.
        await sem.acquire(5000)
        // Reaching here is the assertion.
    }

    @Test func laterSmallRequestCannotJumpAQueuedLarge() async {
        let sem = MemoryBudgetSemaphore(capacity: 1000)
        await sem.acquire(700)

        let largeAdmitted = AsyncFlag()
        let smallAdmitted = AsyncFlag()

        // Large needs 500: 700 + 500 > 1000 → queues.
        let large = Task {
            await sem.acquire(500)
            await largeAdmitted.fire()
        }
        try? await Task.sleep(for: .milliseconds(30))   // large is now head of the queue

        // Small needs 200: 700 + 200 = 900 ≤ 1000 and WOULD fit right now, but
        // FIFO must keep it behind the already-queued large request.
        let small = Task {
            await sem.acquire(200)
            await smallAdmitted.fire()
        }
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await largeAdmitted.value == false)   // doesn't fit yet
        #expect(await smallAdmitted.value == false)   // FIFO-blocked, not starving the large one

        await sem.release(700)   // budget idle → large admitted first, then small
        _ = await large.value
        _ = await small.value
        #expect(await largeAdmitted.value == true)
        #expect(await smallAdmitted.value == true)
    }

    @Test func cancelAllResumesBlockedWaiters() async {
        let sem = MemoryBudgetSemaphore(capacity: 100)
        await sem.acquire(100)   // full
        let counter = AsyncCounter()

        let waiters = (0..<3).map { _ in
            Task {
                await sem.acquire(50)
                await counter.increment()
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.value == 0)

        await sem.cancelAll()
        for w in waiters { _ = await w.value }
        #expect(await counter.value == 3)
    }
}

// MARK: - AsyncChannel

@Suite
@MainActor
struct AsyncChannelTests {

    @Test func sendAndReceive() async {
        let channel = AsyncChannel<Int>(bufferSize: 4)

        let producer = Task {
            for i in 0..<3 {
                await channel.send(i)
            }
            channel.finish()
        }

        var received: [Int] = []
        for await value in channel.stream {
            await channel.consumed()
            received.append(value)
        }
        _ = await producer.value

        #expect(received == [0, 1, 2])
    }

    @Test func backpressureBlocksProducerWhenBufferFull() async {
        let channel = AsyncChannel<Int>(bufferSize: 2)

        // Fill the buffer (size 2) — the third send must suspend until the consumer drains.
        let thirdSendCompleted = AsyncFlag()

        let producer = Task {
            await channel.send(1)
            await channel.send(2)
            await channel.send(3)        // suspends here
            await thirdSendCompleted.fire()
            channel.finish()
        }

        // Let the producer try to send all three.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await thirdSendCompleted.value == false)

        // Drain one slot — that should unblock the third send.
        var iterator = channel.stream.makeAsyncIterator()
        _ = await iterator.next()
        await channel.consumed()

        // Wait for the producer to finish.
        _ = await producer.value
        #expect(await thirdSendCompleted.value == true)

        // Drain the remaining items so we don't leak the task.
        while await iterator.next() != nil {
            await channel.consumed()
        }
    }

    @Test func finishEndsConsumerLoop() async {
        let channel = AsyncChannel<Int>(bufferSize: 1)
        await channel.send(42)
        channel.finish()

        var values: [Int] = []
        for await v in channel.stream {
            await channel.consumed()
            values.append(v)
        }
        #expect(values == [42])
    }

    @Test func cancelUnblocksProducerAndTerminatesConsumer() async {
        let channel = AsyncChannel<Int>(bufferSize: 1)
        await channel.send(1)            // fills the only slot

        let producerDone = AsyncFlag()
        let producer = Task {
            await channel.send(2)         // suspends — buffer full
            await producerDone.fire()
        }

        try? await Task.sleep(for: .milliseconds(50))
        #expect(await producerDone.value == false)

        await channel.cancel()
        _ = await producer.value
        #expect(await producerDone.value == true)

        // Consumer loop should terminate cleanly even though we never called finish().
        var drained = 0
        for await _ in channel.stream {
            drained += 1
            if drained > 10 { break }     // guard against runaway loop on regression
        }
        #expect(drained <= 1)              // at most the first buffered element
    }

    @Test func multipleProducersAndOneConsumer() async {
        let channel = AsyncChannel<Int>(bufferSize: 4)
        let producerCount = 3
        let itemsPerProducer = 10
        let counter = AsyncCounter()

        // Consumer must run concurrently with producers — otherwise the producers
        // would fill the bounded buffer (size 4) and block forever.
        let consumer = Task {
            for await _ in channel.stream {
                await channel.consumed()
                await counter.increment()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for p in 0..<producerCount {
                group.addTask {
                    for i in 0..<itemsPerProducer {
                        await channel.send(p * 100 + i)
                    }
                }
            }
        }
        channel.finish()
        _ = await consumer.value

        #expect(await counter.value == producerCount * itemsPerProducer)
    }
}

// MARK: - Test Helpers

/// Single-shot flag observable across actor boundaries.
private actor AsyncFlag {
    private var fired = false
    var value: Bool { fired }
    func fire() { fired = true }
}

/// Thread-safe counter for verifying concurrent execution counts.
private actor AsyncCounter {
    private var current = 0
    var value: Int { current }
    func increment() { current += 1 }
}

