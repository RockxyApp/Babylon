// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

struct Message: Codable, Serializable, CaptureMemoryEstimating {
    enum MessageType: String, Codable {
        case connection
        case traffic
        case websocket
        case runtime
        case heartbeat
        case ack
        case error
    }

    private let id: String
    private let messageType: MessageType
    private let content: Data?
    private let buildVersion: String?
    // The runtime lease is excluded from CodingKeys; decoding must restore an unleased message.
    // swiftlint:disable:next implicit_optional_initialization
    var captureMemoryLease: CaptureMemoryLease? = nil

    private enum CodingKeys: String, CodingKey {
        case id, messageType, content, buildVersion
    }

    var payloadType: BabylonProtocol.MessageType {
        BabylonProtocol.MessageType(rawValue: messageType.rawValue) ?? .error
    }

    var payloadData: Data? {
        content
    }

    var captureMemoryEstimate: Int {
        CaptureMemoryEstimate.retained(bodyBytes: content?.count ?? 0, stringBytes: id.utf8.count)
    }

    static func buildConnectionMessage(id: String, item: Serializable) -> Message? {
        make(id: id, type: .connection, item: item)
    }

    static func buildTrafficMessage(id: String, item: Serializable) -> Message? {
        make(id: id, type: .traffic, item: item)
    }

    static func buildWebSocketMessage(id: String, item: Serializable) -> Message? {
        make(id: id, type: .websocket, item: item)
    }

    static func buildRuntimeMessage(id: String, item: Serializable) -> Message? {
        make(id: id, type: .runtime, item: item)
    }

    func toData() -> Data? {
        Self.encode(self, context: "message envelope")
    }

    private init(id: String, type: MessageType, content: Data, captureMemoryLease: CaptureMemoryLease) {
        self.id = CaptureString.bounded(id, maximumBytes: 512)
        messageType = type
        self.content = content
        buildVersion = BabylonConstants.buildVersion
        self.captureMemoryLease = captureMemoryLease
    }

    private static let logger = Logger(subsystem: "com.amunx.Babylon", category: "WireMessage")

    private static func make(id: String, type: MessageType, item: Serializable) -> Message? {
        let estimated = (item as? CaptureMemoryEstimating)?.captureMemoryEstimate ?? 4096
        let (reservation, overflow) = max(4096, estimated).multipliedReportingOverflow(by: 2)
        guard !overflow, let lease = CaptureMemoryBudget.shared.reserve(reservation) else {
            return nil
        }
        guard let payload = item.toData() else {
            logger.error("Unable to encode \(type.rawValue, privacy: .public) payload")
            return nil
        }
        guard lease.resize(to: max(reservation, payload.count * 2)) else { return nil }
        return Message(id: id, type: type, content: payload, captureMemoryLease: lease)
    }

    private static func encode(_ value: some Encodable, context: String) -> Data? {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            logger
                .error("Unable to encode \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
