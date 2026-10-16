// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Opaque runtime identifiers used to correlate application execution with captured traffic.
public struct CorrelationContext: Codable, Equatable, Sendable {
    public let sessionId: String
    public let traceId: String
    public let stepId: String
    public let createdAt: TimeInterval

    init(
        sessionId: String,
        traceId: String,
        stepId: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.sessionId = CaptureString.bounded(sessionId, maximumBytes: 512)
        self.traceId = CaptureString.bounded(traceId, maximumBytes: 512)
        self.stepId = CaptureString.bounded(stepId, maximumBytes: 512)
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case traceId = "trace_id"
        case stepId = "step_id"
        case createdAt = "created_at"
    }
}

struct CorrelationScope: Sendable {
    let context: CorrelationContext?
}

enum BabylonTraceScope {
    @TaskLocal static var current: CorrelationScope?
}

struct CorrelatedURLRequest {
    let request: URLRequest
    let correlationContext: CorrelationContext?
}
