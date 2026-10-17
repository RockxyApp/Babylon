import Foundation
import Testing
@testable import Babylon

@Suite(.serialized)
struct GRPCCaptureTests {
    @Test("Manual gRPC API keeps explicit service and method for absolute endpoints")
    func manualCallUsesExplicitOperationIdentity() throws {
        let delegate = CapturingBabylonDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(delegate)
        Babylon.start()
        defer {
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        Babylon.addGRPCCall(
            endpoint: "https://api.example.test/example.Greeter/SayHello",
            service: "example.Greeter",
            method: "SayHello",
            authority: "api.example.test",
            callType: .unary,
            trailers: [Header(key: "grpc-status", value: "14")],
            statusCode: 14,
            messages: []
        )

        #expect(delegate.semaphore.wait(timeout: .now() + 2) == .success)
        let capture = try #require(delegate.packages.last?.grpcCapture)
        #expect(capture.endpoint == "https://api.example.test/example.Greeter/SayHello")
        #expect(capture.authority == "api.example.test")
        #expect(capture.service == "example.Greeter")
        #expect(capture.method == "SayHello")
        #expect(capture.statusCode == 14)
    }

    @Test("Typed gRPC payload preserves call type, ordered messages, trailers, and bounds")
    func typedPayloadRoundTrip() throws {
        let request = Data([0x0A, 0x03, 0x66, 0x6F, 0x6F])
        let response = Data([0x12, 0x02, 0x6F, 0x6B])
        let capture = GRPCCapture(
            endpoint: "/example.Greeter/SayHello",
            authority: "api.example.test",
            service: "example.Greeter",
            method: "SayHello",
            callType: .bidirectionalStreaming,
            requestMetadata: [Header(key: "x-client", value: "ios")],
            responseMetadata: [Header(key: "x-server", value: "api")],
            trailers: [Header(key: "grpc-status", value: "0"), Header(key: "grpc-message", value: "ok")],
            statusCode: 0,
            statusMessage: "ok",
            requestCompression: "gzip",
            responseCompression: "identity",
            messages: [
                GRPCCapture.Message(sequence: 0, direction: .request, data: request),
                GRPCCapture.Message(sequence: 0, direction: .response, data: response)
            ]
        )
        let package = TrafficPackage(
            id: "grpc-roundtrip",
            request: Request(url: capture.endpoint, method: "POST", headers: [], body: request),
            response: Response(statusCode: 200, headers: []),
            responseBodyData: response,
            packageType: .grpc
        )
        package.setGRPCCapture(capture)
        let encoded = try #require(package.toData())
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let grpc = try #require(json["grpcCapture"] as? [String: Any])
        #expect(grpc["schemaVersion"] as? Int == 1)
        #expect(grpc["callType"] as? String == "bidirectionalStreaming")
        #expect((grpc["messages"] as? [[String: Any]])?.count == 2)
        #expect((grpc["trailers"] as? [[String: Any]])?.count == 2)
    }

    @Test("All gRPC call types preserve ordered message direction, status, compression, and trailers")
    func callTypesPreserveSemantics() throws {
        let callTypes: [GRPCCapture.CallType] = [
            .unary,
            .clientStreaming,
            .serverStreaming,
            .bidirectionalStreaming
        ]
        let messages = [
            GRPCCapture.Message(
                sequence: 0,
                direction: .request,
                data: Data([0x01]),
                compressed: true,
                timestamp: 1
            ),
            GRPCCapture.Message(
                sequence: 1,
                direction: .request,
                data: Data([0x02]),
                timestamp: 2
            ),
            GRPCCapture.Message(
                sequence: 0,
                direction: .response,
                data: Data([0x03]),
                timestamp: 3
            )
        ]

        for callType in callTypes {
            let capture = GRPCCapture(
                endpoint: "https://api.example.test/example.Greeter/Stream",
                authority: "api.example.test",
                service: "example.Greeter",
                method: "Stream",
                callType: callType,
                requestMetadata: [Header(key: "x-client", value: "ios")],
                responseMetadata: [Header(key: "content-type", value: "application/grpc")],
                trailers: [Header(key: "grpc-status", value: "14"), Header(key: "grpc-message", value: "unavailable")],
                statusCode: 14,
                statusMessage: "unavailable",
                requestCompression: "gzip",
                responseCompression: "identity",
                messages: messages
            )

            let encoded = try JSONEncoder().encode(capture)
            let decoded = try JSONDecoder().decode(GRPCCapture.self, from: encoded)
            #expect(decoded.callType == callType)
            #expect(decoded.statusCode == 14)
            #expect(decoded.statusMessage == "unavailable")
            #expect(decoded.requestCompression == "gzip")
            #expect(decoded.responseCompression == "identity")
            #expect(decoded.requestMetadata.map(\.key) == ["x-client"])
            #expect(decoded.responseMetadata.map(\.key) == ["content-type"])
            #expect(decoded.trailers.map(\.key) == ["grpc-message", "grpc-status"])
            #expect(decoded.messages.map(\.sequence) == [0, 1, 0])
            #expect(decoded.messages.map(\.direction) == [.request, .request, .response])
            #expect(decoded.messages.first?.compressed == true)
        }
    }

    @Test("Typed gRPC messages are bounded by aggregate body policy")
    func bodyLimitMarksOmission() throws {
        let oversized = Data(repeating: 7, count: BabylonConstants.maximumBodySize + 1)
        let capture = GRPCCapture(
            endpoint: "/service/Method",
            service: "service",
            method: "Method",
            callType: .unary,
            messages: [GRPCCapture.Message(sequence: 0, direction: .request, data: oversized)]
        )
        let package = TrafficPackage(
            id: "grpc-limit",
            request: Request(url: capture.endpoint, method: "POST", headers: [], body: nil),
            packageType: .grpc
        )
        package.setGRPCCapture(capture)
        let encoded = try #require(package.toData())
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let grpc = try #require(json["grpcCapture"] as? [String: Any])
        let messages = try #require(grpc["messages"] as? [[String: Any]])
        #expect(messages[0]["omitted"] as? Bool == true)
        #expect(messages[0]["observedBytes"] as? Int == BabylonConstants.maximumBodySize + 1)
        #expect((messages[0]["data"] as? String).map { Data(base64Encoded: $0)?.count ?? 0 } == BabylonConstants
            .maximumWebSocketFrameSize)
    }

    @Test("GRPCapture bounds aggregate message bytes before package attachment")
    func modelEnforcesAggregateBodyLimit() {
        let messages = (0 ..< 6).map { index in
            GRPCCapture.Message(
                sequence: index,
                direction: .request,
                data: Data(repeating: UInt8(index), count: BabylonConstants.maximumWebSocketFrameSize)
            )
        }
        let capture = GRPCCapture(
            endpoint: "/service/Method",
            service: "service",
            method: "Method",
            callType: .clientStreaming,
            messages: messages
        )

        #expect(capture.capturedBodySize == BabylonConstants.maximumBodySize)
        #expect(capture.messages.count == 6)
        #expect(capture.messages.last?.data?.isEmpty == true)
        #expect(capture.messages.last?.omitted == true)
        #expect(capture.messages.last?.observedBytes == BabylonConstants.maximumWebSocketFrameSize)
    }

    @Test("Typed gRPC decoding applies capture bounds to untrusted payload fields")
    func decodingAppliesCaptureBounds() throws {
        let oversizedBody = Data(repeating: 9, count: BabylonConstants.maximumWebSocketFrameSize + 1)
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "endpoint": String(repeating: "e", count: 3000),
            "authority": String(repeating: "a", count: 1000),
            "service": String(repeating: "s", count: 1000),
            "method": String(repeating: "m", count: 1000),
            "callType": "unary",
            "requestMetadata": [["key": "x-test", "value": String(repeating: "v", count: 20000)]],
            "responseMetadata": [],
            "trailers": [],
            "messages": [[
                "sequence": -1,
                "direction": "request",
                "data": oversizedBody.base64EncodedString(),
                "observedBytes": Int.max,
                "omitted": false,
                "compressed": false,
                "timestamp": 1.0
            ]]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(GRPCCapture.self, from: encoded)
        let message = try #require(decoded.messages.first)

        #expect(decoded.endpoint.utf8.count <= 2048)
        #expect(decoded.authority?.utf8.count ?? 0 <= 512)
        #expect(decoded.service.utf8.count <= 512)
        #expect(decoded.method.utf8.count <= 256)
        #expect(decoded.requestMetadata.first?.value.utf8.count ?? 0 <= 4096)
        #expect(message.sequence == 0)
        #expect(message.data?.count == BabylonConstants.maximumWebSocketFrameSize)
        #expect(message.omitted)
        #expect(message.observedBytes <= BabylonConstants.maximumBodySize * 1024)
    }
}
