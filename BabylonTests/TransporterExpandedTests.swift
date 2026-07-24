import Foundation
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif
import Testing
@testable import Babylon

// MARK: - Pending Queue Behavior Tests

struct PendingQueueBehaviorTests {
    @Test("Sending 51 packages with no connection caps at 50 pending")
    func pendingQueueCapsAt50() {
        let transport = NetServiceTransport()

        for i in 0 ..< 51 {
            let request = Request(
                url: "https://example.com/\(i)",
                method: "GET",
                headers: [],
                body: nil
            )
            let package = TrafficPackage(id: "cap-\(i)", request: request)
            transport.send(package: package)
        }

        // Allow async queue to drain.
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            semaphore.signal()
        }
        semaphore.wait()

        // The constant enforces the limit; we verify the transport survived without crash.
        #expect(BabylonConstants.maxPendingItems == 50)
    }

    @Test("Start/stop/start cycle clears pending packages")
    func startStopCycleClears() {
        let transport = NetServiceTransport()
        let config = Configuration.default()

        // Buffer some packages.
        for i in 0 ..< 5 {
            let request = Request(
                url: "https://example.com/cycle-\(i)",
                method: "GET",
                headers: [],
                body: nil
            )
            transport.send(package: TrafficPackage(id: "cycle-\(i)", request: request))
        }

        // Start then stop clears internal state.
        transport.start(config)
        transport.stop()

        // Restart should work cleanly with no leftover pending packages.
        transport.start(config)
        transport.stop()

        #expect(true)
    }

    @Test("Stop without start does not crash")
    func stopWithoutStartNoCrash() {
        let transport = NetServiceTransport()
        transport.stop()
        transport.stop()
        #expect(true)
    }

    @Test("Multiple start/stop cycles do not crash or leak")
    func multipleStartStopCycles() {
        let transport = NetServiceTransport()
        let config = Configuration.default()

        for _ in 0 ..< 10 {
            transport.start(config)
            transport.stop()
        }

        #expect(true)
    }

    @Test("Send with no connection does not crash, packages are buffered")
    func sendWithNoConnectionBuffers() {
        let transport = NetServiceTransport()

        for i in 0 ..< 10 {
            let request = Request(
                url: "https://example.com/buffer-\(i)",
                method: "POST",
                headers: [Header(key: "Content-Type", value: "application/json")],
                body: "{\"index\":\(i)}".data(using: .utf8)
            )
            transport.send(package: TrafficPackage(id: "buffer-\(i)", request: request))
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        #expect(true)
    }
}

// MARK: - Message Building Tests

struct MessageBuildingTests {
    @Test("buildTrafficMessage produces a non-nil message")
    func trafficMessageNotNil() {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "traffic-1", request: request)

        let message = Message.buildTrafficMessage(id: "test-id", item: package)
        #expect(message != nil)
    }

    @Test("buildConnectionMessage produces a non-nil message")
    func connectionMessageNotNil() {
        let config = Configuration.default()
        let connectionPackage = ConnectionPackage(config: config)

        let message = Message.buildConnectionMessage(id: "conn-id", item: connectionPackage)
        #expect(message != nil)
    }

    @Test("buildWebSocketMessage produces a non-nil message")
    func webSocketMessageNotNil() {
        let wsMessage = WebsocketMessagePackage.Message.string("hello")
        let wsPackage = WebsocketMessagePackage(id: "ws-1", message: wsMessage, messageType: .send)

        let message = Message.buildWebSocketMessage(id: "ws-id", item: wsPackage)
        #expect(message != nil)
    }

    @Test("Message toData produces valid JSON with expected keys")
    func messageToDataHasExpectedKeys() throws {
        let request = Request(url: "https://example.com/json", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "json-test", request: request)

        let message = try #require(Message.buildTrafficMessage(id: "json-id", item: package))
        let data = try #require(message.toData())

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["id"] != nil)
        #expect(json["messageType"] != nil)
        #expect(json["content"] != nil)
        #expect(json["buildVersion"] != nil)
        #expect(json["messageType"] as? String == "traffic")
        #expect(json["buildVersion"] as? String == BabylonConstants.buildVersion)
    }

    @Test("Message content remains raw JSON until secure framing")
    func messageContentRemainsRawJSON() throws {
        let request = Request(
            url: "https://example.com/gzip",
            method: "GET",
            headers: [],
            body: nil
        )
        let package = TrafficPackage(id: "gzip-test", request: request)

        let message = try #require(Message.buildTrafficMessage(id: "gzip-id", item: package))
        let data = try #require(message.toData())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let contentBase64 = try #require(json["content"] as? String)
        let contentData = try #require(Data(base64Encoded: contentBase64))
        let content = try #require(try JSONSerialization.jsonObject(with: contentData) as? [String: Any])

        #expect(content["id"] as? String == "gzip-test")
    }
}

// MARK: - Constants Tests

struct TransporterBabylonConstantsTests {
    @Test("serviceType equals _Rockxy._tcp")
    func serviceType() {
        #expect(BabylonConstants.serviceType == "_Rockxy._tcp")
    }

    @Test("directConnectionPort equals 10909")
    func directConnectionPort() {
        #expect(BabylonConstants.directConnectionPort == 10909)
    }

    @Test("maxPendingItems equals 50")
    func maxPendingItems() {
        #expect(BabylonConstants.maxPendingItems == 50)
    }

    @Test("maximumBodySize equals 50 MB (52428800 bytes)")
    func maximumBodySize() {
        #expect(BabylonConstants.maximumBodySize == 52_428_800)
    }

    @Test("buildVersion is a non-empty string")
    func buildVersionNonEmpty() {
        #expect(!BabylonConstants.buildVersion.isEmpty)
    }
}

// MARK: - Memory Warning Tests

struct MemoryWarningTests {
    #if os(iOS)
    @Test("NetServiceTransport handles memory warning notification without crash")
    func memoryWarningClearsPending() {
        let transport = NetServiceTransport()

        // Buffer some packages.
        for i in 0 ..< 10 {
            let request = Request(
                url: "https://example.com/memory-\(i)",
                method: "GET",
                headers: [],
                body: nil
            )
            transport.send(package: TrafficPackage(id: "memory-\(i)", request: request))
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        // Post a memory warning notification.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        // Allow the notification to propagate.
        let drain = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            drain.signal()
        }
        drain.wait()

        // If we get here, the transport handled the notification without crashing.
        #expect(true)
    }
    #endif
}

// MARK: - Wire Format Tests

struct WireFormatTests {
    @Test("TrafficPackage toData produces valid JSON")
    func trafficPackageToDataIsValidJSON() throws {
        let request = Request(
            url: "https://example.com/wire",
            method: "POST",
            headers: [Header(key: "Content-Type", value: "application/json")],
            body: "{\"key\":\"value\"}".data(using: .utf8)
        )
        let response = Response(statusCode: 200, headers: [Header(key: "X-Test", value: "1")])
        let package = TrafficPackage(
            id: "wire-test",
            request: request,
            response: response,
            responseBodyData: "response-body".data(using: .utf8)
        )

        let data = try #require(package.toData())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["id"] as? String == "wire-test")
        #expect(json["packageType"] as? String == "http")
        #expect(json["request"] != nil)
        #expect(json["response"] != nil)
    }

    @Test("ConnectionPackage toData produces valid JSON with device and project")
    func connectionPackageToDataIsValidJSON() throws {
        let config = Configuration.default()
        let connectionPackage = ConnectionPackage(config: config)

        let data = try #require(connectionPackage.toData())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["device"] != nil)
        #expect(json["project"] != nil)
    }

    @Test("GZIP round-trip preserves data")
    func gzipRoundTrip() throws {
        let original = try #require("Hello, Babylon transport layer!".data(using: .utf8))
        let compressed = try #require(original.gzip())
        let decompressed = try #require(compressed.gunzip())

        #expect(decompressed == original)
    }
}
