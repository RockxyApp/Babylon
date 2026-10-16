// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct BoundedRetryPolicy: Equatable {
    let maximumAttempts: Int
    let maximumLifetime: TimeInterval
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval

    func delay(attempt: Int, jitter: Double) -> TimeInterval? {
        guard attempt > 0, attempt <= maximumAttempts else { return nil }
        let exponent = min(attempt - 1, 30)
        let exponential = min(maximumDelay, initialDelay * pow(2, Double(exponent)))
        return min(maximumDelay, max(0, exponential * min(1.5, max(0.5, jitter))))
    }
}

struct BoundedRetryWindow {
    private(set) var attempts = 0
    let startedAt: TimeInterval

    mutating func nextDelay(
        now: TimeInterval,
        jitter: Double,
        policy: BoundedRetryPolicy
    ) -> TimeInterval? {
        guard now >= startedAt, now - startedAt < policy.maximumLifetime else { return nil }
        let nextAttempt = attempts + 1
        guard let delay = policy.delay(attempt: nextAttempt, jitter: jitter) else { return nil }
        guard now + delay - startedAt <= policy.maximumLifetime else { return nil }
        attempts = nextAttempt
        return delay
    }
}
