import Foundation
import Testing
@testable import Babylon

// MARK: - Message Tests

struct MessageTests {
    // MARK: - Helpers

    /// A minimal Serializable stub for testing message builders.
    private struct StubPayload: Codable, Serializable {
        let value: String

        func toData() -> Data? {
            try? JSONEncoder().encode(self)
        }
    }

    /// A Serializable stub that always fails encoding.
    private struct FailingPayload: Serializable {
        func toData() -> Data? {
            nil
        }
    }

    // MARK: - JSON Structure

    @Test("Encoded JSON contains expected top-level keys")
    func jsonStructure() throws {
        let payload = StubPayload(value: "hello")
        let message = try #require(Message.buildTrafficMessage(id: "struct-1", item: payload))
        let data = try #require(message.toData())

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["id"] != nil)
        #expect(json["messageType"] != nil)
        #expect(json["content"] != nil)
        #expect(json["buildVersion"] != nil)
    }

    // MARK: - Builder Methods

    @Test("buildConnectionMessage produces valid data")
    func buildConnectionMessage() throws {
        let payload = StubPayload(value: "connection")
        let message = try #require(Message.buildConnectionMessage(id: "conn-1", item: payload))
        let data = try #require(message.toData())

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["messageType"] as? String == "connection")
    }

    @Test("buildTrafficMessage produces valid data")
    func buildTrafficMessage() throws {
        let payload = StubPayload(value: "traffic")
        let message = try #require(Message.buildTrafficMessage(id: "traf-1", item: payload))
        let data = try #require(message.toData())

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["messageType"] as? String == "traffic")
    }

    @Test("buildWebSocketMessage produces valid data")
    func buildWebSocketMessage() throws {
        let payload = StubPayload(value: "websocket")
        let message = try #require(Message.buildWebSocketMessage(id: "ws-1", item: payload))
        let data = try #require(message.toData())

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["messageType"] as? String == "websocket")
    }

    // MARK: - Build Version

    @Test("buildVersion matches BabylonConstants.buildVersion")
    func buildVersionMatchesConstant() throws {
        let payload = StubPayload(value: "version-check")
        let message = try #require(Message.buildTrafficMessage(id: "ver-1", item: payload))
        let data = try #require(message.toData())

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["buildVersion"] as? String == BabylonConstants.buildVersion)
    }

    // MARK: - Payload Encoding

    @Test("Content remains raw JSON until secure framing")
    func contentRemainsRawJSON() throws {
        let payload = StubPayload(value: "compress-me")
        let message = try #require(Message.buildTrafficMessage(id: "gzip-1", item: payload))
        let data = try #require(message.toData())

        // The "content" field in the JSON is base64-encoded by Codable for Data.
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let base64Content = try #require(json["content"] as? String)
        let contentData = try #require(Data(base64Encoded: base64Content))

        let content = try #require(try JSONSerialization.jsonObject(with: contentData) as? [String: Any])
        #expect(content["value"] as? String == "compress-me")
    }

    @Test("Connection package never contains authentication token")
    func connectionPackageNeverContainsToken() throws {
        let configuration = Configuration.default(authToken: testPairingToken)
        let package = ConnectionPackage(config: configuration)
        let packageData = try #require(package.toData())
        let message = try #require(Message.buildConnectionMessage(id: configuration.id, item: package))
        let contentData = try #require(message.payloadData)
        let content = try #require(try JSONSerialization.jsonObject(with: contentData) as? [String: Any])

        #expect(content["authToken"] == nil)
        #expect(String(data: packageData, encoding: .utf8)?.contains(testPairingToken) == false)
        #expect(String(data: contentData, encoding: .utf8)?.contains(testPairingToken) == false)
    }

    @Test("Connection package advertises bounded producer capabilities")
    func connectionPackageAdvertisesCapabilities() throws {
        let package = ConnectionPackage(config: .default(authToken: testPairingToken))
        let data = try #require(package.toData())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let capabilities = try #require(json["capabilities"] as? [String: Any])
        let schemas = capabilities["payloadSchemaVersions"] as? [String: Int]
        #expect(capabilities["sdkVersion"] as? String == BabylonConstants.buildVersion)
        #expect(capabilities["platform"] as? String == "macOS")
        #expect(capabilities["maximumBodyBytes"] as? Int == BabylonConstants.maximumBodySize)
        #expect(capabilities["maximumWebSocketFrameBytes"] as? Int == BabylonConstants.maximumWebSocketFrameSize)
        #expect(capabilities["maximumCaptureMemoryBytes"] as? Int == BabylonConstants.maximumCaptureMemoryBytes)
        #expect(schemas?["grpcCapture"] == 1)
        #expect(String(data: data, encoding: .utf8)?.contains(testPairingToken) == false)
    }

    // MARK: - Error Handling

    @Test("Builder returns nil when item encoding fails")
    func builderReturnsNilOnEncodingFailure() {
        let failing = FailingPayload()

        #expect(Message.buildConnectionMessage(id: "fail-1", item: failing) == nil)
        #expect(Message.buildTrafficMessage(id: "fail-2", item: failing) == nil)
        #expect(Message.buildWebSocketMessage(id: "fail-3", item: failing) == nil)
        #expect(Message.buildRuntimeMessage(id: "fail-4", item: failing) == nil)
    }

    // MARK: - Serializable Conformance

    @Test("Message conforms to Serializable and produces non-nil data")
    func serializableConformance() throws {
        let payload = StubPayload(value: "serializable")
        let message = try #require(Message.buildTrafficMessage(id: "ser-1", item: payload))

        let data = message.toData()
        #expect(data != nil)
        #expect(try #require(data?.count) > 0)
    }
}
