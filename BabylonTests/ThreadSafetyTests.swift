import Foundation
import Testing
@testable import Babylon

// MARK: - Babylon Lifecycle Thread Safety

@Suite(.serialized)
struct BabylonLifecycleThreadSafetyTests {
    @Test("100 concurrent start/stop calls produce no crash")
    func concurrentStartStop() {
        Babylon.setEnableTransportLayer(false)

        nonisolated(unsafe) var completedCount = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i % 2 == 0 {
                Babylon.start()
            } else {
                Babylon.stop()
            }
            lock.lock()
            completedCount += 1
            lock.unlock()
        }

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)

        #expect(completedCount == 100)
    }

    @Test("Rapid start-stop cycle 50 times produces no crash")
    func rapidStartStopCycle() {
        Babylon.setEnableTransportLayer(false)

        for _ in 0 ..< 50 {
            Babylon.start()
            Babylon.stop()
        }

        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("Concurrent setDelegate calls during capture produce no crash")
    func concurrentSetDelegate() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        nonisolated(unsafe) var completedCount = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            let delegate = ConcurrentTestDelegate()
            Babylon.setDelegate(delegate)
            lock.lock()
            completedCount += 1
            lock.unlock()
        }

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)

        #expect(completedCount == 100)
    }

    @Test("Concurrent setIgnoreProtocols calls produce no crash")
    func concurrentSetIgnoreProtocols() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        nonisolated(unsafe) var completedCount = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i % 2 == 0 {
                Babylon.setIgnoreProtocols([URLProtocol.self])
            } else {
                Babylon.setIgnoreProtocols([])
            }
            lock.lock()
            completedCount += 1
            lock.unlock()
        }

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)

        #expect(completedCount == 100)
    }

    @Test("100 concurrent manual add calls produce no crash")
    func concurrentManualAdd() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        nonisolated(unsafe) var completedCount = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 100) { i in
            let request = Request(
                url: "https://example.com/\(i)",
                method: "GET",
                headers: [],
                body: nil
            )
            let response = Response(statusCode: 200, headers: [])
            Babylon.add(request: request, response: response, responseBody: nil)

            lock.lock()
            completedCount += 1
            lock.unlock()
        }

        // Allow async queues to drain.
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)

        #expect(completedCount == 100)
    }
}

// MARK: - Atomic Thread Safety

struct AtomicThreadSafetyTests {
    @Test("Atomic<Bool> 1000 concurrent reads + 1000 writes has correct final value")
    func atomicBoolConcurrentReadWrite() {
        let atomic = Atomic<Bool>(false)

        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            if i < 1000 {
                _ = atomic.value
            } else {
                atomic.mutate { $0 = true }
            }
        }

        #expect(atomic.value == true)
    }

    @Test("Atomic<Int> 1000 concurrent mutations yields final value 1000")
    func atomicIntConcurrentMutations() {
        let atomic = Atomic<Int>(0)

        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            atomic.mutate { $0 += 1 }
        }

        #expect(atomic.value == 1000)
    }
}

// MARK: - PackageIdentifier Thread Safety

struct PackageIdentifierThreadSafetyTests {
    /// PackageIdentifier.getID is documented as not thread-safe on its own.
    /// Callers must serialize via Babylon.shared.queue. This test verifies
    /// that serialised concurrent calls on the same object produce a single ID.
    @Test("Serialised concurrent getID calls on same object return same ID")
    func serialisedConcurrentGetIDSameObject() {
        let object = NSObject()
        let serialQueue = DispatchQueue(label: "com.babylon.test.pkgid")

        nonisolated(unsafe) var ids: [String] = []
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            let id = serialQueue.sync { PackageIdentifier.getID(for: object) }
            lock.lock()
            ids.append(id)
            lock.unlock()
        }

        let uniqueIDs = Set(ids)
        #expect(uniqueIDs.count == 1, "All serialised calls on the same object should return the same ID")
    }

    @Test("Serialised concurrent getID calls on different objects return different IDs")
    func serialisedConcurrentGetIDDifferentObjects() {
        let objects = (0 ..< 100).map { _ in NSObject() }
        let serialQueue = DispatchQueue(label: "com.babylon.test.pkgid-diff")

        nonisolated(unsafe) var ids: [String] = []
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 100) { i in
            let id = serialQueue.sync { PackageIdentifier.getID(for: objects[i]) }
            lock.lock()
            ids.append(id)
            lock.unlock()
        }

        let uniqueIDs = Set(ids)
        #expect(uniqueIDs.count == 100, "Each distinct object should receive a unique ID")
    }
}

// MARK: - DispatchQueue.once Thread Safety

struct DispatchQueueOnceThreadSafetyTests {
    @Test("1000 concurrent calls execute block exactly once")
    func concurrentOnceCallsExecuteOnce() {
        let token = "com.babylon.test.thread-safety-once-\(UUID().uuidString)"

        nonisolated(unsafe) var counter = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            DispatchQueue.once(token: token) {
                lock.lock()
                counter += 1
                lock.unlock()
            }
        }

        #expect(counter == 1, "Block should execute exactly once regardless of concurrency")
    }
}

// MARK: - Test Helpers

private final class ConcurrentTestDelegate: BabylonDelegate {
    func babylonDidCapturePackage(_ package: TrafficPackage) {
        // No-op for concurrency tests.
    }
}
