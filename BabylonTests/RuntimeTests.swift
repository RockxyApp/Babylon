import Foundation
import Testing
@testable import Babylon

// MARK: - Atomic Tests

struct AtomicTests {
    @Test("Initial value is returned correctly")
    func initialValue() {
        let atomic = Atomic<Int>(42)
        #expect(atomic.value == 42)
    }

    @Test("Mutate transforms the stored value")
    func mutateChangesValue() {
        let atomic = Atomic<String>("hello")
        atomic.mutate { $0 += " world" }
        #expect(atomic.value == "hello world")
    }

    @Test("Concurrent mutations are serialised correctly")
    func threadSafeConcurrentMutations() async {
        let atomic = Atomic<Int>(0)
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< iterations {
                group.addTask {
                    atomic.mutate { $0 += 1 }
                }
            }
        }

        #expect(atomic.value == iterations)
    }
}

// MARK: - URLSessionTask Internal Marker Tests

struct URLSessionTaskInternalTests {
    @Test("Marked task is recognised as Babylon-internal")
    func markAndCheck() throws {
        let task = try URLSession.shared.dataTask(with: #require(URL(string: "https://example.com")))
        task.markAsBabylonInternal()
        #expect(task.isBabylonInternal() == true)
    }

    @Test("Unmarked task is not Babylon-internal")
    func unmarkedTask() throws {
        let task = try URLSession.shared.dataTask(with: #require(URL(string: "https://example.com")))
        #expect(task.isBabylonInternal() == false)
    }
}

// MARK: - GRPCStatusCode Tests

struct GRPCStatusCodeTests {
    @Test("Raw values match the canonical gRPC integer codes")
    func rawValues() {
        #expect(GRPCStatusCode.ok.rawValue == 0)
        #expect(GRPCStatusCode.cancelled.rawValue == 1)
        #expect(GRPCStatusCode.unknown.rawValue == 2)
        #expect(GRPCStatusCode.invalidArgument.rawValue == 3)
        #expect(GRPCStatusCode.deadlineExceeded.rawValue == 4)
        #expect(GRPCStatusCode.notFound.rawValue == 5)
        #expect(GRPCStatusCode.alreadyExists.rawValue == 6)
        #expect(GRPCStatusCode.permissionDenied.rawValue == 7)
        #expect(GRPCStatusCode.resourceExhausted.rawValue == 8)
        #expect(GRPCStatusCode.failedPrecondition.rawValue == 9)
        #expect(GRPCStatusCode.aborted.rawValue == 10)
        #expect(GRPCStatusCode.outOfRange.rawValue == 11)
        #expect(GRPCStatusCode.unimplemented.rawValue == 12)
        #expect(GRPCStatusCode.internalError.rawValue == 13)
        #expect(GRPCStatusCode.unavailable.rawValue == 14)
        #expect(GRPCStatusCode.dataLoss.rawValue == 15)
        #expect(GRPCStatusCode.unauthenticated.rawValue == 16)
    }

    @Test("Initialising from raw value round-trips correctly")
    func initFromRawValue() {
        #expect(GRPCStatusCode(rawValue: 0) == .ok)
        #expect(GRPCStatusCode(rawValue: 13) == .internalError)
        #expect(GRPCStatusCode(rawValue: 16) == .unauthenticated)
        #expect(GRPCStatusCode(rawValue: 99) == nil)
    }

    @Test("Description includes case name and code")
    func description() {
        #expect(GRPCStatusCode.ok.description == "ok (code=0)")
        #expect(GRPCStatusCode.unavailable.description == "unavailable (code=14)")
    }
}
