// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

private let runtimePackageLogger = Logger(subsystem: "com.amunx.Babylon", category: "RuntimePackage")

/// A runtime timeline event sent to Rockxy independently from HTTP/WebSocket traffic.
struct RuntimePackage: Codable, Serializable, CaptureMemoryEstimating {
    enum Kind: String, Codable {
        case sessionStarted
        case sessionFinished
        case traceStarted
        case stepStarted
        case stepFinished
        case traceFinished
        case mark
        case event
        case error
    }

    let id: String
    let kind: Kind
    let sessionId: String
    let traceId: String?
    let stepId: String?
    let parentStepId: String?
    let name: String
    let createdAt: TimeInterval
    let startedAt: TimeInterval?
    let endedAt: TimeInterval?
    let duration: TimeInterval?
    let metadata: [String: String]
    let error: CustomError?

    init(
        kind: Kind,
        sessionId: String,
        traceId: String? = nil,
        stepId: String? = nil,
        parentStepId: String? = nil,
        name: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        startedAt: TimeInterval? = nil,
        endedAt: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        metadata: [String: String] = [:],
        error: CustomError? = nil
    ) {
        id = UUID().uuidString
        self.kind = kind
        self.sessionId = CaptureString.bounded(sessionId, maximumBytes: 512)
        self.traceId = traceId.map { CaptureString.bounded($0, maximumBytes: 512) }
        self.stepId = stepId.map { CaptureString.bounded($0, maximumBytes: 512) }
        self.parentStepId = parentStepId.map { CaptureString.bounded($0, maximumBytes: 512) }
        self.name = CaptureString.bounded(name, maximumBytes: 4096)
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.metadata = RuntimeMetadata.sanitized(metadata)
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case sessionId = "session_id"
        case traceId = "trace_id"
        case stepId = "step_id"
        case parentStepId = "parent_step_id"
        case name
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case duration
        case metadata
        case error
    }

    func toData() -> Data? {
        do {
            return try JSONEncoder().encode(self)
        } catch {
            runtimePackageLogger.error("Failed to encode RuntimePackage: \(error.localizedDescription)")
            return nil
        }
    }

    var captureMemoryEstimate: Int {
        let stringBytes = id.utf8.count + sessionId.utf8.count + (traceId?.utf8.count ?? 0) +
            (stepId?.utf8.count ?? 0) + (parentStepId?.utf8.count ?? 0) + name.utf8.count +
            metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } +
            (error?.message.utf8.count ?? 0)
        return CaptureMemoryEstimate.retained(bodyBytes: 0, stringBytes: stringBytes)
    }
}

enum RuntimeMetadata {
    static let maximumPairCount = 64
    static let maximumKeyLength = 128
    static let maximumValueLength = 4096
    static let maximumTotalBytes = 32768

    static func sanitized(_ metadata: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        sanitized.reserveCapacity(min(metadata.count, maximumPairCount))

        var totalBytes = 0
        for key in metadata.keys.sorted() {
            guard sanitized.count < maximumPairCount else {
                break
            }

            let trimmedKey = CaptureString.bounded(key, maximumBytes: maximumKeyLength)
            guard !trimmedKey.isEmpty else {
                continue
            }
            let remaining = maximumTotalBytes - totalBytes - trimmedKey.utf8.count
            guard remaining > 0 else { break }
            let value = CaptureString.bounded(metadata[key] ?? "", maximumBytes: min(maximumValueLength, remaining))
            sanitized[trimmedKey] = value
            totalBytes += trimmedKey.utf8.count + value.utf8.count
            guard totalBytes < maximumTotalBytes else { break }
        }

        return sanitized
    }
}
