// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A bounded, transport-neutral snapshot of one gRPC call.
public struct GRPCCapture: Codable, Sendable {
    public enum CallType: String, Codable, Sendable {
        case unary
        case clientStreaming
        case serverStreaming
        case bidirectionalStreaming
    }

    public enum Direction: String, Codable, Sendable {
        case request
        case response
    }

    public struct Message: Codable, Sendable {
        public let sequence: Int
        public let direction: Direction
        public let data: Data?
        public let observedBytes: Int
        public let omitted: Bool
        public let compressed: Bool
        public let timestamp: TimeInterval

        public init(
            sequence: Int,
            direction: Direction,
            data: Data?,
            observedBytes: Int? = nil,
            compressed: Bool = false,
            timestamp: TimeInterval = Date().timeIntervalSince1970
        ) {
            self.sequence = max(0, sequence)
            self.direction = direction
            let value = data.map { Data($0.prefix(BabylonConstants.maximumWebSocketFrameSize)) }
            self.data = value
            self.observedBytes = Self.boundedObservedBytes(max(data?.count ?? 0, observedBytes ?? 0))
            omitted = (data != nil && value?.count != data?.count) || (observedBytes ?? 0) > (value?.count ?? 0)
            self.compressed = compressed
            self.timestamp = timestamp
        }

        var captureMemoryEstimate: Int {
            CaptureMemoryEstimate.retained(bodyBytes: data?.count ?? 0, stringBytes: 64)
        }

        func bounded(maximumBytes: Int) -> Message {
            guard let data, data.count > maximumBytes else { return self }
            return Message(
                sequence: sequence,
                direction: direction,
                data: Data(data.prefix(max(0, maximumBytes))),
                observedBytes: observedBytes,
                compressed: compressed,
                timestamp: timestamp,
                omitted: true
            )
        }

        private init(
            sequence: Int,
            direction: Direction,
            data: Data?,
            observedBytes: Int,
            compressed: Bool,
            timestamp: TimeInterval,
            omitted: Bool
        ) {
            self.sequence = sequence
            self.direction = direction
            self.data = data
            self.observedBytes = observedBytes
            self.compressed = compressed
            self.timestamp = timestamp
            self.omitted = omitted
        }

        private enum CodingKeys: String, CodingKey {
            case sequence, direction, data, observedBytes, omitted, compressed, timestamp
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sequence = try max(0, values.decode(Int.self, forKey: .sequence))
            direction = try values.decode(Direction.self, forKey: .direction)
            let decodedData = try values.decodeIfPresent(Data.self, forKey: .data)
            data = decodedData.map { Data($0.prefix(BabylonConstants.maximumWebSocketFrameSize)) }
            let decodedObservedBytes = try values.decode(Int.self, forKey: .observedBytes)
            observedBytes = Self.boundedObservedBytes(max(decodedData?.count ?? 0, decodedObservedBytes))
            omitted = try values.decode(Bool.self, forKey: .omitted) ||
                data?.count != decodedData?.count || decodedObservedBytes > (data?.count ?? 0)
            compressed = try values.decode(Bool.self, forKey: .compressed)
            timestamp = try values.decode(TimeInterval.self, forKey: .timestamp)
        }

        private static func boundedObservedBytes(_ value: Int) -> Int {
            min(max(0, value), BabylonConstants.maximumBodySize * 1024)
        }
    }

    public let schemaVersion: Int
    public let endpoint: String
    public let authority: String?
    public let service: String
    public let method: String
    public let callType: CallType
    public let requestMetadata: [Header]
    public let responseMetadata: [Header]
    public let trailers: [Header]
    public let statusCode: Int?
    public let statusMessage: String?
    public let requestCompression: String?
    public let responseCompression: String?
    public let messages: [Message]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, endpoint, authority, service, method, callType
        case requestMetadata, responseMetadata, trailers, statusCode, statusMessage
        case requestCompression, responseCompression, messages
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try max(1, values.decode(Int.self, forKey: .schemaVersion))
        endpoint = try CaptureString.bounded(values.decode(String.self, forKey: .endpoint), maximumBytes: 2048)
        authority = try values.decodeIfPresent(String.self, forKey: .authority)
            .map { CaptureString.bounded($0, maximumBytes: 512) }
        service = try CaptureString.bounded(values.decode(String.self, forKey: .service), maximumBytes: 512)
        method = try CaptureString.bounded(values.decode(String.self, forKey: .method), maximumBytes: 256)
        callType = try values.decode(CallType.self, forKey: .callType)
        requestMetadata = try CaptureString.headers(values.decode([Header].self, forKey: .requestMetadata))
        responseMetadata = try CaptureString.headers(values.decode([Header].self, forKey: .responseMetadata))
        trailers = try CaptureString.headers(values.decode([Header].self, forKey: .trailers))
        statusCode = try values.decodeIfPresent(Int.self, forKey: .statusCode)
        statusMessage = try values.decodeIfPresent(String.self, forKey: .statusMessage)
            .map { CaptureString.bounded($0, maximumBytes: 4096) }
        requestCompression = try values.decodeIfPresent(String.self, forKey: .requestCompression)
            .map { CaptureString.bounded($0, maximumBytes: 128) }
        responseCompression = try values.decodeIfPresent(String.self, forKey: .responseCompression)
            .map { CaptureString.bounded($0, maximumBytes: 128) }
        let decodedMessages = try Array(values.decode([Message].self, forKey: .messages).prefix(1024))
        messages = Self.boundedMessages(decodedMessages, maximumBodyBytes: BabylonConstants.maximumBodySize)
    }

    public init(
        endpoint: String,
        authority: String? = nil,
        service: String,
        method: String,
        callType: CallType,
        requestMetadata: [Header] = [],
        responseMetadata: [Header] = [],
        trailers: [Header] = [],
        statusCode: Int? = nil,
        statusMessage: String? = nil,
        requestCompression: String? = nil,
        responseCompression: String? = nil,
        messages: [Message] = []
    ) {
        schemaVersion = 1
        self.endpoint = CaptureString.bounded(endpoint, maximumBytes: 2048)
        self.authority = authority.map { CaptureString.bounded($0, maximumBytes: 512) }
        self.service = CaptureString.bounded(service, maximumBytes: 512)
        self.method = CaptureString.bounded(method, maximumBytes: 256)
        self.callType = callType
        self.requestMetadata = CaptureString.headers(requestMetadata)
        self.responseMetadata = CaptureString.headers(responseMetadata)
        self.trailers = CaptureString.headers(trailers)
        self.statusCode = statusCode
        self.statusMessage = statusMessage.map { CaptureString.bounded($0, maximumBytes: 4096) }
        self.requestCompression = requestCompression.map { CaptureString.bounded($0, maximumBytes: 128) }
        self.responseCompression = responseCompression.map { CaptureString.bounded($0, maximumBytes: 128) }
        self.messages = Self.boundedMessages(
            Array(messages.prefix(1024)),
            maximumBodyBytes: BabylonConstants.maximumBodySize
        )
    }

    var capturedBodySize: Int {
        messages.reduce(0) { $0 + ($1.data?.count ?? 0) }
    }

    var captureMemoryStringSize: Int {
        endpoint.utf8.count + (authority?.utf8.count ?? 0) + service.utf8.count + method.utf8.count +
            (statusMessage?.utf8.count ?? 0) + messages.count * 64
    }

    var captureMemoryEstimate: Int {
        CaptureMemoryEstimate.retained(bodyBytes: capturedBodySize, stringBytes: captureMemoryStringSize)
    }

    func bounded(maximumBodySize: Int) -> GRPCCapture {
        GRPCCapture(
            endpoint: endpoint,
            authority: authority,
            service: service,
            method: method,
            callType: callType,
            requestMetadata: requestMetadata,
            responseMetadata: responseMetadata,
            trailers: trailers,
            statusCode: statusCode,
            statusMessage: statusMessage,
            requestCompression: requestCompression,
            responseCompression: responseCompression,
            messages: Self.boundedMessages(messages, maximumBodyBytes: maximumBodySize)
        )
    }

    private static func boundedMessages(_ messages: [Message], maximumBodyBytes: Int) -> [Message] {
        var remaining = min(max(0, maximumBodyBytes), BabylonConstants.maximumBodySize)
        return messages.map { message in
            let bounded = message.bounded(maximumBytes: remaining)
            remaining -= bounded.data?.count ?? 0
            return bounded
        }
    }
}
