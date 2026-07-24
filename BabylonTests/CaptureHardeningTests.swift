import Foundation
import Testing
@testable import Babylon

#if os(iOS)
import UIKit
#endif

@Suite(.serialized)
struct CaptureHardeningTests {
    @Test("Response capture replaces an oversized body before serialization")
    func responseBodyIsBoundedDuringCapture() {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let oversized = Data(repeating: 0x41, count: BabylonConstants.maximumBodySize + 1)
        let package = TrafficPackage(id: "oversized-response", request: request, responseBodyData: oversized)

        #expect(package.responseBodyData == Data("<Skip Large Body>".utf8))
    }

    @Test("Repeated equal response chunks are preserved")
    func repeatedEqualChunksArePreserved() {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "repeated-chunks", request: request)
        let chunk = Data("same".utf8)

        package.appendResponseData(chunk)
        package.appendResponseData(chunk)

        #expect(package.responseBodyData == Data("samesame".utf8))
    }

    @Test("Oversized WebSocket data is replaced before encoding")
    func websocketBodyIsBoundedDuringCapture() throws {
        let oversized = Data(repeating: 0x42, count: BabylonConstants.maximumBodySize + 1)
        let package = WebsocketMessagePackage(id: "ws", message: .data(oversized), messageType: .send)
        let encoded = try #require(package.toData())
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedBody = try #require(json["dataValue"] as? String)
        let body = try #require(Data(base64Encoded: encodedBody))

        #expect(body == Data("<Skip Large Body>".utf8))
    }

    @Test("A traffic package enforces one aggregate 50 MiB body budget")
    func aggregateBodyBudgetIsBounded() throws {
        let requestBody = Data(repeating: 0x43, count: BabylonConstants.maximumBodySize - 2)
        let request = Request(url: "https://example.com", method: "POST", headers: [], body: requestBody)

        let responsePackage = TrafficPackage(
            id: "aggregate-response",
            request: request,
            responseBodyData: Data(repeating: 0x44, count: 4)
        )
        #expect(responsePackage.responseBodyData == Data("<Skip Large Body>".utf8))

        let websocketPackage = TrafficPackage(id: "aggregate-websocket", request: request, packageType: .websocket)
        websocketPackage.setWebsocketMessagePackage(
            package: WebsocketMessagePackage(
                id: "aggregate-websocket",
                message: .data(Data(repeating: 0x45, count: 4)),
                messageType: .send
            )
        )
        let encoded = try #require(websocketPackage.toData())
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let message = try #require(json["websocketMessagePackage"] as? [String: Any])
        let encodedBody = try #require(message["dataValue"] as? String)
        let body = try #require(Data(base64Encoded: encodedBody))

        #expect(body == Data("<Skip Large Body>".utf8))
    }

    @Test("Active correlation context does not mutate the outgoing request")
    func correlationDoesNotAddHeaders() throws {
        Babylon.stop()
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        defer {
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        _ = Babylon.startTrace("Checkout")
        var request = try URLRequest(url: #require(URL(string: "https://example.com/checkout")))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let correlated = Babylon.shared.injectorSessionWillCreateTask(request: request)

        #expect(correlated.correlationContext != nil)
        #expect(correlated.request == request)
        #expect(correlated.request.value(forHTTPHeaderField: "x-rockxy-session-id") == nil)
        #expect(correlated.request.value(forHTTPHeaderField: "x-rockxy-trace-id") == nil)
        #expect(correlated.request.value(forHTTPHeaderField: "x-rockxy-step-id") == nil)
    }

    @Test("Default redaction covers sensitive request, response, and query values")
    func defaultRedactionPolicy() throws {
        let request = Request(
            url: "https://example.com/path?token=secret-value&view=compact",
            method: "GET",
            headers: [
                Header(key: "Authorization", value: "Bearer secret-value"),
                Header(key: "Accept", value: "application/json")
            ],
            body: nil
        )
        let response = Response(statusCode: 200, headers: [
            Header(key: "Set-Cookie", value: "session=secret-value"),
            Header(key: "Content-Type", value: "application/json")
        ])

        let components = try #require(URLComponents(string: request.url))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(query["token"] == "[REDACTED]")
        #expect(query["view"] == "compact")
        #expect(request.headers.first { $0.key == "Authorization" }?.value == "[REDACTED]")
        #expect(request.headers.first { $0.key == "Accept" }?.value == "application/json")
        #expect(response.headers.first { $0.key == "Set-Cookie" }?.value == "[REDACTED]")
        #expect(response.headers.first { $0.key == "Content-Type" }?.value == "application/json")
    }

    @Test("Traffic snapshots keep the WebSocket frame captured at snapshot time")
    func websocketSnapshotIsImmutable() throws {
        let request = Request(url: "wss://example.com/socket", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "snapshot", request: request, packageType: .websocket)
        package.setWebsocketMessagePackage(package: WebsocketMessagePackage(
            id: "snapshot",
            message: .string("first"),
            messageType: .send
        ))
        let snapshot = package.makeSnapshot()

        package.setWebsocketMessagePackage(package: WebsocketMessagePackage(
            id: "snapshot",
            message: .string("second"),
            messageType: .send
        ))

        let data = try #require(snapshot.toData())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let frame = try #require(json["websocketMessagePackage"] as? [String: Any])
        #expect(frame["stringValue"] as? String == "first")
    }

    #if os(iOS)
    @Test("Memory warnings discard in-flight traffic packages")
    @MainActor
    func memoryWarningClearsInFlightCapture() throws {
        Babylon.stop()
        Babylon.setEnableTransportLayer(false)
        let delegate = CapturingBabylonDelegate()
        Babylon.setDelegate(delegate)
        Babylon.start()
        defer {
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        let url = try #require(URL(string: "https://example.com/large"))
        let task = URLSession.shared.dataTask(with: url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        Babylon.shared.injectorSessionDidCallResume(task: task)
        Babylon.shared.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        Babylon.shared.injectorSessionDidReceiveData(dataTask: task, data: Data("partial".utf8))

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        Babylon.shared.queue.sync {}
        Babylon.shared.injectorSessionDidComplete(task: task, error: nil)

        #expect(delegate.packages.isEmpty)
        task.cancel()
    }
    #endif
}
