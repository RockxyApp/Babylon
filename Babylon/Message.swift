// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

struct Message: Codable, Serializable {
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

    var payloadType: BabylonProtocol.MessageType {
        BabylonProtocol.MessageType(rawValue: messageType.rawValue) ?? .error
    }

    var payloadData: Data? {
        content
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

    private init(id: String, type: MessageType, content: Data) {
        self.id = id
        messageType = type
        self.content = content
        buildVersion = BabylonConstants.buildVersion
    }

    private static let logger = Logger(subsystem: "com.amunx.Babylon", category: "WireMessage")

    private static func make(id: String, type: MessageType, item: Serializable) -> Message? {
        guard let payload = item.toData() else {
            logger.error("Unable to encode \(type.rawValue, privacy: .public) payload")
            return nil
        }
        return Message(id: id, type: type, content: payload)
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
