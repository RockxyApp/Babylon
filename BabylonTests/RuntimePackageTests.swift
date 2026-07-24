import Foundation
import Testing
@testable import Babylon

@Suite("RuntimePackage Tests")
struct RuntimePackageTests {
    @Test("RuntimePackage encodes snake case identifiers")
    func runtimePackageEncoding() throws {
        let package = RuntimePackage(
            kind: .traceStarted,
            sessionId: "session-1",
            traceId: "trace-1",
            stepId: "step-1",
            name: "Checkout",
            metadata: ["screen": "cart"]
        )

        let data = try #require(package.toData())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["kind"] as? String == "traceStarted")
        #expect(json["session_id"] as? String == "session-1")
        #expect(json["trace_id"] as? String == "trace-1")
        #expect(json["step_id"] as? String == "step-1")
        #expect(json["metadata"] != nil)
    }

    @Test("Runtime message uses runtime message type")
    func runtimeMessageType() throws {
        let package = RuntimePackage(kind: .event, sessionId: "session-1", name: "UserAuthenticated")
        let message = try #require(Message.buildRuntimeMessage(id: "device-1", item: package))
        let data = try #require(message.toData())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["messageType"] as? String == "runtime")
    }

    @Test("Metadata is capped before encoding")
    func metadataCaps() {
        var metadata: [String: String] = [:]
        for index in 0 ..< 80 {
            metadata["key-\(index)-" + String(repeating: "k", count: 200)] = String(repeating: "v", count: 5000)
        }

        let sanitized = RuntimeMetadata.sanitized(metadata)

        #expect(sanitized.count == RuntimeMetadata.maximumPairCount)
        #expect(sanitized.keys.allSatisfy { $0.count <= RuntimeMetadata.maximumKeyLength })
        #expect(sanitized.values.allSatisfy { $0.count <= RuntimeMetadata.maximumValueLength })
    }
}
