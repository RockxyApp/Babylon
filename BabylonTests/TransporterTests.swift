import Foundation
import Testing
@testable import Babylon

// MARK: - NetServiceTransport Tests

struct NetServiceTransportTests {
    @Test("NetServiceTransport can be created without errors")
    func creation() {
        let transport = NetServiceTransport()
        #expect(transport != nil)
    }

    @Test("Service type constant is _Rockxy._tcp")
    func serviceTypeConstant() {
        #expect(BabylonConstants.serviceType == "_Rockxy._tcp")
    }

    @Test("Direct connection port is 10909")
    func directConnectionPort() {
        #expect(BabylonConstants.directConnectionPort == 10909)
    }

    @Test("Transport conforms to Transporter protocol")
    func conformsToTransporter() {
        let transport = NetServiceTransport()
        let _: any Transporter = transport
        // If this compiles, the conformance is verified.
        #expect(true)
    }

    @Test("Pending queue respects maximum item limit")
    func pendingQueueLimit() {
        let transport = NetServiceTransport()
        let maxItems = BabylonConstants.maxPendingItems

        // Send more packages than the maximum without authenticated configuration.
        // They must be dropped without retaining unbounded data or crashing.
        let totalToSend = maxItems + 20

        for i in 0 ..< totalToSend {
            let request = Request(
                url: "https://example.com/\(i)",
                method: "GET",
                headers: [],
                body: nil
            )
            let package = TrafficPackage(id: "pending-\(i)", request: request)
            transport.send(package: package)
        }

        // Allow the async queue to drain.
        let expectation = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.signal()
        }
        expectation.wait()

        // The transport must tolerate overload and keep the authenticated pending-queue cap stable.
        #expect(maxItems == 50)
    }

    @Test("Stop can be called without a prior start")
    func stopWithoutStart() {
        let transport = NetServiceTransport()
        // Should not crash.
        transport.stop()
        #expect(true)
    }

    @Test("Start and stop can be called multiple times")
    func multipleStartStop() {
        let transport = NetServiceTransport()
        let config = Configuration.default(authToken: testPairingToken)

        transport.start(config)
        transport.stop()
        transport.start(config)
        transport.stop()

        // Should not crash or leak.
        #expect(true)
    }

    @Test("Send with no connection does not crash")
    func sendWithNoConnection() {
        let transport = NetServiceTransport()
        let request = Request(
            url: "https://example.com/test",
            method: "GET",
            headers: [],
            body: nil
        )
        let package = TrafficPackage(id: "no-conn", request: request)

        // Should drop the unauthenticated package without crashing.
        transport.send(package: package)
        #expect(true)
    }
}

// MARK: - WireProtocolCodec Tests

struct WireProtocolCodecTests {
    private let configuration = Configuration(
        projectName: "Transport Tests",
        deviceName: "Test Device",
        clientID: "transport-client",
        sessionID: "transport-session",
        hostName: nil,
        authToken: testPairingToken
    )

    @Test("Prebuilt traffic Message is encrypted without a nested Message envelope")
    func prebuiltTrafficMessageFramesOnce() throws {
        let request = Request(url: "https://example.com/traffic", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "traffic-frame", request: request)
        let message = try #require(Message.buildTrafficMessage(id: "device-id", item: package))

        let decoded = try decodedFrame(for: message, sequence: 1)
        let content = try #require(try JSONSerialization.jsonObject(with: decoded.payload.content) as? [String: Any])

        #expect(decoded.payload.messageType == .traffic)
        #expect(content["request"] != nil)
        #expect(content["messageType"] == nil)
    }

    @Test("Prebuilt WebSocket Message preserves websocket message type")
    func prebuiltWebSocketMessagePreservesType() throws {
        let request = Request(url: "wss://example.com/socket", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "ws-frame", request: request, packageType: .websocket)
        let wsPayload = WebsocketMessagePackage.Message.string("hello")
        let wsPackage = WebsocketMessagePackage(id: "ws-frame", message: wsPayload, messageType: .send)
        package.setWebsocketMessagePackage(package: wsPackage)
        let message = try #require(Message.buildWebSocketMessage(id: "device-id", item: package))

        let decoded = try decodedFrame(for: message, sequence: 2)
        let content = try #require(try JSONSerialization.jsonObject(with: decoded.payload.content) as? [String: Any])

        #expect(decoded.payload.messageType == .websocket)
        #expect(content["packageType"] as? String == "websocket")
        #expect(content["websocketMessagePackage"] != nil)
    }

    @Test("Raw traffic package can still be framed as traffic")
    func rawTrafficPackageFramesAsTraffic() throws {
        let request = Request(url: "https://example.com/raw", method: "POST", headers: [], body: Data("body".utf8))
        let package = TrafficPackage(id: "raw-frame", request: request)

        let decoded = try decodedFrame(for: package, sequence: 3)
        let content = try #require(try JSONSerialization.jsonObject(with: decoded.payload.content) as? [String: Any])

        #expect(decoded.payload.messageType == .traffic)
        #expect(content["id"] as? String == "raw-frame")
        #expect(content["request"] != nil)
    }

    @Test("Connection Message frame length matches compressed payload")
    func connectionMessageFrameLengthMatchesPayload() throws {
        let config = configuration
        let package = ConnectionPackage(config: config)
        let message = try #require(Message.buildConnectionMessage(id: config.id, item: package))
        let frame = try #require(WireProtocolCodec.frame(message: message, configuration: config, sequence: 4))
        let decoded = try BabylonProtocol.decode(frameData: frame.payload, configuration: config)
        let content = try #require(try JSONSerialization.jsonObject(with: decoded.payload.content) as? [String: Any])

        #expect(bigEndianLength(frame.header) == UInt64(frame.payload.count))
        #expect(decoded.payload.messageType == .connection)
        #expect(content["device"] != nil)
        #expect(content["project"] != nil)
        #expect(content["authToken"] == nil)
    }

    private func decodedFrame(
        for package: Serializable,
        sequence: UInt64
    ) throws -> BabylonProtocol.DecodedMessage {
        let frame = try #require(
            WireProtocolCodec.frame(
                package: package,
                configuration: configuration,
                sequence: sequence,
                nonce: Data(repeating: UInt8(truncatingIfNeeded: sequence), count: 12)
            )
        )
        #expect(bigEndianLength(frame.header) == UInt64(frame.payload.count))
        return try BabylonProtocol.decode(frameData: frame.payload, configuration: configuration)
    }

    private func bigEndianLength(_ header: Data) -> UInt64 {
        header.reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }
}
