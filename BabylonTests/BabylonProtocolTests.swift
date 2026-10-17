import CryptoKit
import Foundation
import Testing
@testable import Babylon

@Suite("Babylon Protocol v1 Tests")
struct BabylonProtocolTests {
    private let configuration = Configuration(
        projectName: "Protocol Tests",
        deviceName: "Test Device",
        clientID: "com.example.protocol-tests-device",
        sessionID: "11111111-2222-3333-4444-555555555555",
        hostName: "test-mac.local",
        authToken: testPairingToken
    )

    @Test("Secure frame round-trips every payload type", arguments: BabylonProtocol.MessageType.allCases)
    func roundTripEveryMessageType(type: BabylonProtocol.MessageType) throws {
        let content = Data("payload-\(type.rawValue)".utf8)
        let payload = BabylonProtocol.PayloadEnvelope(messageType: type, sentAt: 1_725_000_000, content: content)
        let frame = try BabylonProtocol.encode(
            payload: payload,
            configuration: configuration,
            sequence: 42,
            messageID: "message-42",
            nonce: Data(repeating: 0x2A, count: 12)
        )

        let decoded = try BabylonProtocol.decode(frameData: frame.payload, configuration: configuration)

        #expect(decoded.frame.protocolVersion == 1)
        #expect(decoded.frame.sequence == 42)
        #expect(decoded.frame.compression == .gzip)
        #expect(decoded.payload.messageType == type)
        #expect(decoded.payload.sentAt == 1_725_000_000)
        #expect(decoded.payload.content == content)
    }

    @Test("Fixed nonce and identifiers produce deterministic encrypted bytes")
    func deterministicFrame() throws {
        let payload = BabylonProtocol.PayloadEnvelope(
            messageType: .traffic,
            sentAt: 1_725_000_000,
            content: Data("deterministic-content".utf8)
        )
        let first = try BabylonProtocol.encode(
            payload: payload,
            configuration: configuration,
            sequence: 7,
            messageID: "deterministic-message",
            nonce: Data(0 ..< 12)
        )
        let second = try BabylonProtocol.encode(
            payload: payload,
            configuration: configuration,
            sequence: 7,
            messageID: "deterministic-message",
            nonce: Data(0 ..< 12)
        )

        let expectedFixture =
            "eyJjaXBoZXJ0ZXh0Ijoic3ZEZXJ0XC9IMTQxbm9SeDJNajV5engyNTViU25qN08rYW9WbnRjdXd1T0pYXC9keTFKNEp1clJmSkMz" +
            "V1diMWE3NEFFMythSkhHdW5jUmswMkxjVG1LV0dBY3g0ckJQemJwMktvdEZhNlFSVThwUDl4bUtDNDhcL0IyajNHT2ZBV0JDdz09" +
            "IiwiY2xpZW50SUQiOiJjb20uZXhhbXBsZS5wcm90b2NvbC10ZXN0cy1kZXZpY2UiLCJjb21wcmVzc2lvbiI6Imd6aXAiLCJtZXNz" +
            "YWdlSUQiOiJkZXRlcm1pbmlzdGljLW1lc3NhZ2UiLCJub25jZSI6IkFBRUNBd1FGQmdjSUNRb0wiLCJwcm90b2NvbFZlcnNpb24i" +
            "OjEsInNlcXVlbmNlIjo3LCJzZXNzaW9uSUQiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUiLCJ0YWciOiJ5" +
            "b3FQN01HOTB1ZTRWUDFkYTBLVzd3PT0ifQ=="

        #expect(first.header == second.header)
        #expect(first.payload == second.payload)
        #expect(first.payload.base64EncodedString() == expectedFixture)
    }

    @Test("Ambiguous or oversized frame identifiers are rejected")
    func invalidIdentifiers() {
        let payload = BabylonProtocol.PayloadEnvelope(
            messageType: .heartbeat,
            sentAt: 1,
            content: Data("{}".utf8)
        )

        #expect(throws: BabylonProtocol.CodecError.identityMismatch) {
            try BabylonProtocol.encode(
                payload: payload,
                configuration: configuration,
                sequence: 1,
                messageID: "ambiguous:message"
            )
        }
        #expect(throws: BabylonProtocol.CodecError.identityMismatch) {
            try BabylonProtocol.encode(
                payload: payload,
                configuration: configuration,
                sequence: 1,
                messageID: String(repeating: "m", count: BabylonProtocol.maximumMessageIDSize + 1)
            )
        }
    }

    @Test("Wrong token cannot decrypt a frame")
    func wrongTokenRejected() throws {
        let frame = try makeFrame()
        let wrongConfiguration = configuration.withAuthToken(alternateTestPairingToken)

        do {
            _ = try BabylonProtocol.decode(frameData: frame.payload, configuration: wrongConfiguration)
            Issue.record("Frame decrypted with the wrong token")
        } catch {
            #expect(error is CryptoKitError)
        }
    }

    @Test("AAD rejects sequence tampering")
    func tamperedSequenceRejected() throws {
        let frame = try makeFrame()
        let decoded = try JSONDecoder().decode(BabylonProtocol.SecureFrame.self, from: frame.payload)
        let tampered = BabylonProtocol.SecureFrame(
            protocolVersion: decoded.protocolVersion,
            messageID: decoded.messageID,
            sessionID: decoded.sessionID,
            clientID: decoded.clientID,
            sequence: decoded.sequence + 1,
            compression: decoded.compression,
            nonce: decoded.nonce,
            ciphertext: decoded.ciphertext,
            tag: decoded.tag
        )

        do {
            _ = try BabylonProtocol.decode(
                frameData: JSONEncoder().encode(tampered),
                configuration: configuration
            )
            Issue.record("Frame decrypted after its authenticated sequence was modified")
        } catch {
            #expect(error is CryptoKitError)
        }
    }

    @Test("Token is not serialized into SecureFrame JSON")
    func tokenNotSerialized() throws {
        let frame = try makeFrame()
        let json = try #require(try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])

        #expect(json["authToken"] == nil)
        #expect(json["token"] == nil)
        #expect(String(data: frame.payload, encoding: .utf8)?.contains(configuration.normalizedAuthToken) == false)
    }

    @Test("Frame accumulator handles fragmented and coalesced frames")
    func fragmentedAndCoalescedFrames() throws {
        let first = try makeFrame(sequence: 1, messageID: "one")
        let second = try makeFrame(sequence: 2, messageID: "two")
        let bytes = first.data + second.data
        var accumulator = ProtocolFrameAccumulator()

        #expect(try accumulator.append(Data(bytes.prefix(3))).isEmpty)
        #expect(try accumulator.append(Data(bytes.dropFirst(3).prefix(17))).isEmpty)
        let frames = try accumulator.append(Data(bytes.dropFirst(20)))

        #expect(frames == [first.payload, second.payload])
    }

    @Test("Frame accumulator rejects length above 72 MiB before payload arrives")
    func oversizedFrameRejected() {
        var accumulator = ProtocolFrameAccumulator()
        let header = BabylonProtocol.lengthHeader(for: BabylonConstants.maximumFrameSize + 1)

        #expect(throws: BabylonProtocol.CodecError.payloadTooLarge) {
            try accumulator.append(header)
        }
    }

    @Test("Inbound decompression is bounded before JSON decoding")
    func decompressionBombRejected() throws {
        let payload = BabylonProtocol.PayloadEnvelope(
            messageType: .ack,
            sentAt: 1_725_000_000,
            content: Data(repeating: 0, count: 800_000)
        )
        let frame = try BabylonProtocol.encode(
            payload: payload,
            configuration: configuration,
            sequence: 99,
            messageID: "oversized-plaintext",
            nonce: Data(repeating: 0x63, count: 12)
        )

        #expect(throws: BabylonProtocol.CodecError.payloadTooLarge) {
            try BabylonProtocol.decode(frameData: frame.payload, configuration: configuration)
        }
    }

    @Test("Message deduplicator rejects repeats and evicts oldest IDs")
    func messageDeduplication() {
        var deduplicator = ProtocolMessageDeduplicator(capacity: 2)

        let first = deduplicator.insert("one")
        let duplicate = deduplicator.insert("one")
        let second = deduplicator.insert("two")
        let third = deduplicator.insert("three")
        let evicted = deduplicator.insert("one")

        #expect(first)
        #expect(!duplicate)
        #expect(second)
        #expect(third)
        #expect(evicted)
    }

    @Test("Configuration has fresh opaque client and session IDs")
    func configurationIdentities() {
        let first = Configuration.default(authToken: testPairingToken)
        let second = Configuration.default(authToken: testPairingToken)

        #expect(first.clientID != second.clientID)
        #expect(first.sessionID != second.sessionID)
        #expect(first.hasValidAuthentication)
    }

    private func makeFrame(
        sequence: UInt64 = 9,
        messageID: String = "message-9"
    ) throws -> BabylonProtocol.EncodedFrame {
        let payload = try BabylonProtocol.PayloadEnvelope(
            messageType: .ack,
            sentAt: 1_725_000_000,
            content: JSONEncoder().encode(BabylonProtocol.Ack(messageID: "outbound-message"))
        )
        return try BabylonProtocol.encode(
            payload: payload,
            configuration: configuration,
            sequence: sequence,
            messageID: messageID,
            nonce: Data(repeating: UInt8(truncatingIfNeeded: sequence), count: 12)
        )
    }
}

@Suite("Shared Rockxy protocol fixtures")
struct RockxyProtocolFixtureTests {
    @Test("Versioned payload fixtures decode into producer and receiver models")
    func sharedFixturesDecode() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BabylonTests/
            .appendingPathComponent("Fixtures/RockxyProtocol/v1")
        let decoder = JSONDecoder()
        let connection = try decoder.decode(
            ConnectionPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("connection.json"))
        )
        let success = try decoder.decode(
            TrafficPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("traffic-success.json"))
        )
        let failure = try decoder.decode(
            TrafficPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("traffic-error.json"))
        )
        let websocket = try decoder.decode(
            TrafficPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("websocket.json"))
        )
        let grpc = try decoder.decode(
            TrafficPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("grpc.json"))
        )
        let timing = try decoder.decode(
            TrafficPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("url-session-timing.json"))
        )
        let runtime = try decoder.decode(
            RuntimePackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("runtime.json"))
        )

        #expect(connection.project.bundleIdentifier == "com.example.fixture")
        #expect(success.id == "traffic-success")
        #expect(success.startAt == 1_725_000_000)
        #expect(success.packageType == .http)
        #expect(success.correlationContext?.traceId == "trace-success")
        #expect(failure.error?.code == -1001)
        #expect(websocket.packageType == .websocket)
        #expect(grpc.request.method == "POST")
        #expect(grpc.packageType == .grpc)
        #expect(grpc.request.url == "/example.Greeter/SayHello")
        #expect(grpc.request.body == Data([0x08, 0x01]))
        #expect(grpc.responseBodyData == Data([0x08, 0x02]))
        #expect(grpc.grpcCapture?.schemaVersion == 1)
        #expect(grpc.grpcCapture?.callType == .unary)
        #expect(grpc.grpcCapture?.trailers.first(where: { $0.key == "grpc-status" })?.value == "0")
        #expect(timing.urlSessionTiming?.schemaVersion == URLSessionTiming.currentSchemaVersion)
        #expect(timing.urlSessionTiming?.redirectCount == 1)
        #expect(timing.urlSessionTiming?.transactions.map(\.index) == [0, 1])
        #expect(timing.urlSessionTiming?.transactions.last?.reusedConnection == true)
        #expect(timing.urlSessionTiming?.transactions.first?.secureConnectDuration == nil)
        #expect(connection.capabilities.payloadSchemaVersions["urlSessionTiming"] == 1)
        #expect(runtime.id == "runtime-event-1")
        let acknowledgement = try decoder.decode(
            BabylonProtocol.Ack.self,
            from: Data(contentsOf: directory.appendingPathComponent("ack.json"))
        )
        let rejection = try decoder.decode(
            BabylonProtocol.ProtocolError.self,
            from: Data(contentsOf: directory.appendingPathComponent("rejection.json"))
        )
        #expect(acknowledgement.messageID == "traffic-success")
        #expect(rejection.code == "unsupported_version")
        #expect(BabylonProtocol.MessageType.allCases.map(\.rawValue).contains("ack"))
    }
}
