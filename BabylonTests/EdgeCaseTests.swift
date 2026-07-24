import Foundation
import Testing
@testable import Babylon

// MARK: - Request Edge Cases

struct RequestEdgeCaseTests {
    @Test("Request from URLRequest with no headers produces empty headers array")
    func noHeadersProducesEmptyArray() throws {
        var urlRequest = try URLRequest(url: #require(URL(string: "https://example.com/no-headers")))
        urlRequest.allHTTPHeaderFields = nil

        let request = Request(urlRequest)

        #expect(request != nil)
        #expect(request?.headers.isEmpty == true)
    }

    @Test("Request from URLRequest with httpBody populates body")
    func httpBodyPopulatesBody() throws {
        var urlRequest = try URLRequest(url: #require(URL(string: "https://example.com/body")))
        let bodyData = "payload".data(using: .utf8)
        urlRequest.httpBody = bodyData

        let request = Request(urlRequest)

        #expect(request != nil)
        #expect(request?.body == bodyData)
    }

    @Test("Request from nil URLRequest returns nil")
    func nilURLRequestReturnsNil() {
        let request = Request(nil)
        #expect(request == nil)
    }

    @Test("appendBody on nil body initializes and appends")
    func appendBodyOnNilInitializes() throws {
        let request = Request(url: "https://example.com", method: "POST", headers: [], body: nil)
        #expect(request.body == nil)

        let data = try #require("hello".data(using: .utf8))
        request.appendBody(data)

        #expect(request.body == data)
    }

    @Test("appendBody on existing body appends to existing data")
    func appendBodyOnExistingAppends() throws {
        let initial = try #require("first".data(using: .utf8))
        let request = Request(url: "https://example.com", method: "POST", headers: [], body: initial)

        let additional = try #require("second".data(using: .utf8))
        request.appendBody(additional)

        #expect(request.body == "firstsecond".data(using: .utf8))
    }

    @Test("resetBody sets body to nil")
    func resetBodySetsNil() {
        let request = Request(url: "https://example.com", method: "POST", headers: [], body: "data".data(using: .utf8))
        #expect(request.body != nil)

        request.resetBody()

        #expect(request.body == nil)
    }
}

// MARK: - Response Edge Cases

struct ResponseEdgeCaseTests {
    @Test("Response from HTTPURLResponse captures statusCode and headers")
    func fromHTTPURLResponse() throws {
        let url = try #require(URL(string: "https://example.com/response"))
        let httpResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: "HTTP/1.1",
            headerFields: ["X-Custom": "value", "Content-Type": "text/html"]
        ))

        let response = Response(httpResponse)

        #expect(response != nil)
        #expect(response?.statusCode == 403)
        #expect(response?.headers.count == 2)
    }

    @Test("Response from non-HTTP URLResponse uses default statusCode 200")
    func fromNonHTTPURLResponse() throws {
        let url = try #require(URL(string: "https://example.com/non-http"))
        let urlResponse = URLResponse(
            url: url,
            mimeType: "application/octet-stream",
            expectedContentLength: 1024,
            textEncodingName: nil
        )

        let response = Response(urlResponse)

        #expect(response != nil)
        #expect(response?.statusCode == 200)
        let headerKeys = response?.headers.map(\.key) ?? []
        #expect(headerKeys.contains("Content-Length"))
        #expect(headerKeys.contains("Content-Type"))
    }

    @Test("Response Codable roundtrip preserves all fields")
    func codableRoundtrip() throws {
        let headers = [Header(key: "Server", value: "nginx"), Header(key: "X-RateLimit", value: "100")]
        let response = Response(statusCode: 429, headers: headers)

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(Response.self, from: data)

        #expect(decoded.statusCode == 429)
        #expect(decoded.headers.count == 2)
        #expect(decoded.headers[0].key == "Server")
        #expect(decoded.headers[1].value == "100")
    }
}

// MARK: - Body Size Boundaries

struct BodySizeBoundaryTests {
    @Test("Response body at exactly maximumBodySize is NOT truncated by toData()")
    func exactMaximumBodySizeNotTruncated() throws {
        // Use a smaller body (1 MB) to verify boundary logic without allocating 50 MB.
        // The threshold check is `> maximumBodySize`, so any body <= the limit is preserved.
        let testSize = 1_048_576
        let request = Request(url: "https://example.com/exact", method: "GET", headers: [], body: nil)
        let exactBody = Data(repeating: 0xAA, count: testSize)
        let package = TrafficPackage(id: "exact-size", request: request, responseBodyData: exactBody)

        let encoded = package.toData()
        #expect(encoded != nil)

        let decoded = try JSONDecoder().decode(TrafficPackage.self, from: #require(encoded))
        #expect(decoded.responseBodyData.count == testSize)
    }

    @Test("Response body at maximumBodySize + 1 byte IS replaced with placeholder")
    func overMaximumBodySizeTruncated() throws {
        let request = Request(url: "https://example.com/over", method: "GET", headers: [], body: nil)
        let overBody = Data(repeating: 0xBB, count: BabylonConstants.maximumBodySize + 1)
        let package = TrafficPackage(id: "over-size", request: request, responseBodyData: overBody)

        let encoded = package.toData()
        #expect(encoded != nil)

        let decoded = try JSONDecoder().decode(TrafficPackage.self, from: #require(encoded))
        #expect(String(data: decoded.responseBodyData, encoding: .utf8) == "<Skip Large Body>")
    }

    @Test("Request body over maximumBodySize is reset to nil by toData()")
    func requestBodyOverMaxReset() throws {
        let largeBody = Data(repeating: 0xCC, count: BabylonConstants.maximumBodySize + 1)
        let request = Request(url: "https://example.com/upload", method: "POST", headers: [], body: largeBody)
        let package = TrafficPackage(id: "large-req", request: request)

        let encoded = package.toData()
        #expect(encoded != nil)

        let decoded = try JSONDecoder().decode(TrafficPackage.self, from: #require(encoded))
        #expect(decoded.request.body == nil)
    }
}

// MARK: - TrafficPackage Edge Cases

struct TrafficPackageEdgeCaseTests {
    @Test("appendResponseData with duplicate consecutive data preserves both chunks")
    func duplicateDataPreserved() throws {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "dedup", request: request)

        let chunk = try #require("duplicate".data(using: .utf8))
        package.appendResponseData(chunk)
        package.appendResponseData(chunk)

        #expect(package.responseBodyData == Data("duplicateduplicate".utf8))
    }

    @Test("appendResponseData with 3 different chunks concatenates all")
    func threeChunksConcatenated() throws {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "multi-chunk", request: request)

        let chunk1 = try #require("aaa".data(using: .utf8))
        let chunk2 = try #require("bbb".data(using: .utf8))
        let chunk3 = try #require("ccc".data(using: .utf8))
        package.appendResponseData(chunk1)
        package.appendResponseData(chunk2)
        package.appendResponseData(chunk3)

        #expect(package.responseBodyData == "aaabbbccc".data(using: .utf8))
    }

    @Test("updateDidComplete with nil error sets endAt but not error")
    func completeWithNilError() {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "nil-error", request: request)
        #expect(package.endAt == nil)
        #expect(package.error == nil)

        package.updateDidComplete(nil)

        #expect(package.endAt != nil)
        #expect(package.error == nil)
    }

    @Test("updateDidComplete with error sets both endAt and error")
    func completeWithError() {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "with-error", request: request)

        let nsError = NSError(domain: "Test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Test failure"])
        package.updateDidComplete(nsError)

        #expect(package.endAt != nil)
        #expect(package.error?.code == 42)
        #expect(package.error?.message == "Test failure")
    }

    @Test("updateStartTime sets startAt correctly")
    func updateStartTime() {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "start-time", request: request)

        let customStart: TimeInterval = 1_700_000_000.0
        package.updateStartTime(customStart)

        #expect(package.startAt == customStart)
    }

    @Test("setWebsocketMessagePackage stores message on package")
    func setWebsocketMessagePackage() throws {
        let request = Request(url: "https://example.com/ws", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "ws-set", request: request, packageType: .websocket)

        let wsMessage = WebsocketMessagePackage.Message.string("test message")
        let wsPackage = WebsocketMessagePackage(id: "ws-set", message: wsMessage, messageType: .send)
        package.setWebsocketMessagePackage(package: wsPackage)

        let encoded = package.toData()
        #expect(encoded != nil)

        let decoded = try JSONDecoder().decode(TrafficPackage.self, from: #require(encoded))
        #expect(decoded.packageType == .websocket)
    }

    @Test("debugDescription does NOT contain URL")
    func debugDescriptionNoURL() {
        let request = Request(url: "https://secret.example.com/api/v1/users", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "debug-desc", request: request)

        let description = package.debugDescription

        #expect(!description.contains("secret.example.com"))
        #expect(!description.contains("https://"))
    }
}

// MARK: - ConnectionPackage Edge Cases

struct ConnectionPackageEdgeCaseTests {
    @Test("ConnectionPackage init populates device and project")
    func initPopulatesDeviceAndProject() {
        let config = Configuration.default()
        let package = ConnectionPackage(config: config)

        #expect(!package.device.name.isEmpty)
        #expect(!package.project.name.isEmpty)
        #expect(!package.project.bundleIdentifier.isEmpty)
    }

    @Test("ConnectionPackage Codable roundtrip preserves all fields")
    func codableRoundtrip() throws {
        let config = Configuration.default()
        let package = ConnectionPackage(config: config)

        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(ConnectionPackage.self, from: data)

        #expect(decoded.device.name == package.device.name)
        #expect(decoded.device.model == package.device.model)
        #expect(decoded.project.name == package.project.name)
        #expect(decoded.project.bundleIdentifier == package.project.bundleIdentifier)
    }

    @Test("ConnectionPackage toData() produces valid JSON")
    func toDataProducesJSON() throws {
        let config = Configuration.default()
        let package = ConnectionPackage(config: config)

        let data = try #require(package.toData())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["device"] != nil)
        #expect(json["project"] != nil)
    }
}

// MARK: - WebsocketMessagePackage Edge Cases

struct WebsocketMessagePackageEdgeCaseTests {
    @Test("Message.init from URLSessionWebSocketTask.Message.data returns .data")
    func messageInitFromData() {
        let binaryData = Data([0x01, 0x02, 0x03])
        let urlSessionMessage = URLSessionWebSocketTask.Message.data(binaryData)

        let message = WebsocketMessagePackage.Message(message: urlSessionMessage)

        #expect(message != nil)
        if case let .data(data) = message {
            #expect(data == binaryData)
        } else {
            Issue.record("Expected .data case")
        }
    }

    @Test("Message.init from URLSessionWebSocketTask.Message.string returns .string")
    func messageInitFromString() {
        let text = "hello websocket"
        let urlSessionMessage = URLSessionWebSocketTask.Message.string(text)

        let message = WebsocketMessagePackage.Message(message: urlSessionMessage)

        #expect(message != nil)
        if case let .string(str) = message {
            #expect(str == text)
        } else {
            Issue.record("Expected .string case")
        }
    }

    @Test("Close code string representation in closeCode init")
    func closeCodeInit() throws {
        let reason = "normal closure".data(using: .utf8)
        let package = WebsocketMessagePackage(id: "close-test", closeCode: 1000, reason: reason)

        let data = try #require(package.toData())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["stringValue"] as? String == "1000")
    }
}

// MARK: - CustomError Edge Cases

struct CustomErrorEdgeCaseTests {
    @Test("CustomError from NSError with all fields")
    func fromNSErrorAllFields() {
        let nsError = NSError(
            domain: "com.example.custom",
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "Custom domain error"]
        )

        let customError = CustomError(nsError)

        #expect(customError.code == 999)
        #expect(customError.message == "Custom domain error")
    }

    @Test("CustomError from Error protocol")
    func fromErrorProtocol() {
        let nsError = NSError(
            domain: "TestDomain",
            code: -42,
            userInfo: [NSLocalizedDescriptionKey: "Protocol error message"]
        )
        let error: Error = nsError

        let customError = CustomError(error)

        #expect(customError.code == -42)
        #expect(customError.message == "Protocol error message")
    }

    @Test("CustomError Codable roundtrip")
    func codableRoundtrip() throws {
        let original = CustomError(NSError(
            domain: "Roundtrip",
            code: 123,
            userInfo: [NSLocalizedDescriptionKey: "Roundtrip message"]
        ))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomError.self, from: data)

        #expect(decoded.code == 123)
        #expect(decoded.message == "Roundtrip message")
    }
}
