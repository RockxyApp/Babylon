import Foundation
import Testing
@testable import Babylon

struct DispatchQueueOnceTests {
    // MARK: - Single Execution

    @Test("Block executes exactly once for the same token")
    func blockExecutesOnce() {
        var counter = 0
        let token = "com.babylon.test.single-\(UUID().uuidString)"

        for _ in 0 ..< 10 {
            DispatchQueue.once(token: token) {
                counter += 1
            }
        }

        #expect(counter == 1)
    }

    // MARK: - Independent Tokens

    @Test("Different tokens execute independently")
    func differentTokensExecuteIndependently() {
        var counterA = 0
        var counterB = 0
        let tokenA = "com.babylon.test.tokenA-\(UUID().uuidString)"
        let tokenB = "com.babylon.test.tokenB-\(UUID().uuidString)"

        DispatchQueue.once(token: tokenA) { counterA += 1 }
        DispatchQueue.once(token: tokenB) { counterB += 1 }

        // Call each token again — neither should increment.
        DispatchQueue.once(token: tokenA) { counterA += 1 }
        DispatchQueue.once(token: tokenB) { counterB += 1 }

        #expect(counterA == 1)
        #expect(counterB == 1)
    }

    // MARK: - Thread Safety

    @Test("Block executes exactly once under concurrent access")
    func threadSafety() {
        let iterations = 1000
        let token = "com.babylon.test.concurrent-\(UUID().uuidString)"

        // nonisolated(unsafe) allows mutation from concurrent contexts in Swift 6.
        nonisolated(unsafe) var counter = 0

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            DispatchQueue.once(token: token) {
                counter += 1
            }
        }

        #expect(counter == 1)
    }
}
