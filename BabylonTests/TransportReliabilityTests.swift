import Foundation
import Testing
@testable import Babylon

struct TransportReliabilityTests {
    @Test("Reconnect retries grow exponentially, apply jitter, and cap delay")
    func retryDelayUsesBoundedExponentialBackoff() {
        let policy = BoundedRetryPolicy(
            maximumAttempts: 5,
            maximumLifetime: 60,
            initialDelay: 1,
            maximumDelay: 8
        )

        #expect(policy.delay(attempt: 1, jitter: 1) == 1)
        #expect(policy.delay(attempt: 2, jitter: 1) == 2)
        #expect(policy.delay(attempt: 3, jitter: 1) == 4)
        #expect(policy.delay(attempt: 4, jitter: 1) == 8)
        #expect(policy.delay(attempt: 5, jitter: 1.25) == 8)
        #expect(policy.delay(attempt: 1, jitter: 0) == 0.5)
        #expect(policy.delay(attempt: 1, jitter: 2) == 1.5)
        #expect(policy.delay(attempt: 0, jitter: 1) == nil)
        #expect(policy.delay(attempt: 6, jitter: 1) == nil)
    }

    @Test("Retry lifetime and exhaustion stop scheduling future attempts")
    func retryWindowStopsAtAttemptAndLifetimeLimits() {
        let policy = BoundedRetryPolicy(
            maximumAttempts: 2,
            maximumLifetime: 10,
            initialDelay: 1,
            maximumDelay: 4
        )
        var attempts = BoundedRetryWindow(startedAt: 100)

        #expect(attempts.nextDelay(now: 100, jitter: 1, policy: policy) == 1)
        #expect(attempts.nextDelay(now: 101, jitter: 1, policy: policy) == 2)
        #expect(attempts.nextDelay(now: 102, jitter: 1, policy: policy) == nil)

        var expired = BoundedRetryWindow(startedAt: 100)
        #expect(expired.nextDelay(now: 110, jitter: 1, policy: policy) == nil)
        #expect(expired.nextDelay(now: 99, jitter: 1, policy: policy) == nil)

        let lifetimePolicy = BoundedRetryPolicy(
            maximumAttempts: 3,
            maximumLifetime: 10,
            initialDelay: 2,
            maximumDelay: 8
        )
        var lastAttemptWouldExceedLifetime = BoundedRetryWindow(startedAt: 100)
        #expect(lastAttemptWouldExceedLifetime.nextDelay(now: 109, jitter: 1, policy: lifetimePolicy) == nil)
    }

    @Test("Pending deliveries stay within the aggregate byte cap")
    func pendingDeliveryByteLimit() {
        let state = TransportState()
        let body = Data(repeating: 0x2A, count: 2_000_000)
        var deliveries: [Serializable] = []
        for index in 0 ..< 40 {
            let request = Request(
                url: "https://example.com/\(index)",
                method: "POST",
                headers: [],
                body: body
            )
            let package = TrafficPackage(id: "pending-\(index)", request: request)
            state.enqueue(package, now: 100)
            deliveries.append(package)
        }

        #expect(state.pendingBytes <= BabylonConstants.maximumPendingBytes)
        #expect(state.pending.count < 40)

        let drain = state.boundedDrainPackages(deliveries)
        #expect(drain.count < deliveries.count)
        #expect((drain.last as? TrafficPackage)?.id == "pending-39")
        let drainBytes = drain.reduce(0) { total, delivery in
            total + ((delivery as? CaptureMemoryEstimating)?.captureMemoryEstimate ?? 0)
        }
        #expect(drainBytes <= BabylonConstants.maximumPendingBytes)
    }
}
