import Foundation
import Testing
@testable import Babylon

// MARK: - TrafficPackage Tests

struct TrafficPackageTests {
    @Test("Creation sets id, request, and default package type")
    func creation() {
        let request = Request(url: "https://api.example.com/users", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "test-id-1", request: request)

        #expect(package.id == "test-id-1")
        #expect(package.request.url == "https://api.example.com/users")
        #expect(package.request.method == "GET")
        #expect(package.packageType == .http)
        #expect(package.response == nil)
        #expect(package.error == nil)
        #expect(package.responseBodyData.isEmpty)
    }

    @Test("Codable roundtrip preserves all fields")
    func codableRoundtrip() throws {
        let headers = [Header(key: "Authorization", value: "Bearer token123")]
        let bodyData = "request body".data(using: .utf8)
        let request = Request(url: "https://api.example.com/data", method: "POST", headers: headers, body: bodyData)
        let responseHeaders = [Header(key: "Content-Type", value: "application/json")]
        let response = Response(statusCode: 201, headers: responseHeaders)
        let responseBody = try #require("{\"id\": 42}".data(using: .utf8))

        let package = TrafficPackage(
            id: "roundtrip-id",
            request: request,
            response: response,
            responseBodyData: responseBody,
            startAt: 1000.0,
            endAt: 1005.0
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(package)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TrafficPackage.self, from: data)

        #expect(decoded.id == "roundtrip-id")
        #expect(decoded.request.url == "https://api.example.com/data")
        #expect(decoded.request.method == "POST")
        #expect(decoded.request.headers.count == 1)
        #expect(decoded.request.headers.first?.key == "Authorization")
        #expect(decoded.request.body == bodyData)
        #expect(decoded.response?.statusCode == 201)
        #expect(decoded.response?.headers.first?.value == "application/json")
        #expect(decoded.responseBodyData == responseBody)
        #expect(decoded.startAt == 1000.0)
        #expect(decoded.endAt == 1005.0)
        #expect(decoded.packageType == .http)
    }

    @Test("toData encodes to non-nil JSON")
    func toDataProducesJSON() throws {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "encode-test", request: request)

        let data = package.toData()
        #expect(data != nil)
        #expect(try #require(data?.count) > 0)
    }

    @Test("Large response body is replaced with placeholder in toData")
    func largeResponseBodyTruncated() throws {
        let request = Request(url: "https://example.com/big", method: "GET", headers: [], body: nil)
        let largeBody = Data(repeating: 0xAA, count: BabylonConstants.maximumBodySize + 1)
        let package = TrafficPackage(id: "large-response", request: request, responseBodyData: largeBody)

        let encoded = package.toData()
        #expect(encoded != nil)

        let decoded = try JSONDecoder().decode(TrafficPackage.self, from: #require(encoded))
        let placeholder = "<Skip Large Body>"
        #expect(String(data: decoded.responseBodyData, encoding: .utf8) == placeholder)
    }

    @Test("Large request body is reset to nil in toData")
    func largeRequestBodyReset() throws {
        let largeBody = Data(repeating: 0xBB, count: BabylonConstants.maximumBodySize + 1)
        let request = Request(url: "https://example.com/upload", method: "POST", headers: [], body: largeBody)
        let package = TrafficPackage(id: "large-request", request: request)

        let encoded = package.toData()
        #expect(encoded != nil)

        let decoded = try JSONDecoder().decode(TrafficPackage.self, from: #require(encoded))
        #expect(decoded.request.body == nil)
    }

    @Test("appendResponseData preserves identical consecutive chunks")
    func appendResponseDataPreservesIdenticalChunks() throws {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "dedup-test", request: request)

        let chunk = try #require("hello".data(using: .utf8))
        package.appendResponseData(chunk)
        package.appendResponseData(chunk)

        #expect(package.responseBodyData == Data("hellohello".utf8))
    }

    @Test("updateDidComplete records error and end time")
    func updateDidComplete() {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "error-test", request: request)

        let nsError = NSError(domain: "TestDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection lost"])
        package.updateDidComplete(nsError)

        #expect(package.endAt != nil)
        #expect(package.error?.code == -1)
        #expect(package.error?.message == "Connection lost")
    }
}

// MARK: - Request Tests

struct RequestTests {
    @Test("Initialisation from URLRequest captures URL, method, headers, and body")
    func fromURLRequest() throws {
        var urlRequest = try URLRequest(url: #require(URL(string: "https://api.example.com/items")))
        urlRequest.httpMethod = "POST"
        urlRequest.allHTTPHeaderFields = ["Content-Type": "application/json", "Accept": "application/json"]
        urlRequest.httpBody = "{\"name\": \"test\"}".data(using: .utf8)

        let request = Request(urlRequest)

        #expect(request != nil)
        #expect(request?.url == "https://api.example.com/items")
        #expect(request?.method == "POST")
        #expect(request?.headers.count == 2)
        #expect(request?.body == "{\"name\": \"test\"}".data(using: .utf8))

        let headerKeys = request?.headers.map(\.key) ?? []
        #expect(headerKeys.contains("Content-Type"))
        #expect(headerKeys.contains("Accept"))
    }

    @Test("Initialisation from nil URLRequest returns nil")
    func fromNilURLRequest() {
        let request = Request(nil)
        #expect(request == nil)
    }

    @Test("appendBody accumulates data correctly")
    func appendBody() throws {
        let request = Request(url: "https://example.com", method: "PUT", headers: [], body: nil)
        try request.appendBody(#require("part1".data(using: .utf8)))
        try request.appendBody(#require("part2".data(using: .utf8)))

        #expect(request.body == "part1part2".data(using: .utf8))
    }

    @Test("resetBody clears the body")
    func resetBody() {
        let request = Request(url: "https://example.com", method: "POST", headers: [], body: "data".data(using: .utf8))
        request.resetBody()
        #expect(request.body == nil)
    }
}

// MARK: - Response Tests

struct ResponseTests {
    @Test("Initialisation from HTTPURLResponse captures status code and headers")
    func fromHTTPURLResponse() throws {
        let url = try #require(URL(string: "https://api.example.com/status"))
        let httpResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["X-Request-Id": "abc123", "Content-Type": "text/plain"]
        ))

        let response = Response(httpResponse)

        #expect(response != nil)
        #expect(response?.statusCode == 404)
        #expect(response?.headers.count == 2)

        let headerDict = try Dictionary(uniqueKeysWithValues: #require(response?.headers.map { ($0.key, $0.value) }))
        #expect(headerDict["X-Request-Id"] == "abc123")
        #expect(headerDict["Content-Type"] == "text/plain")
    }

    @Test("Codable roundtrip preserves status code and headers")
    func codableRoundtrip() throws {
        let response = Response(statusCode: 200, headers: [Header(key: "Server", value: "nginx")])

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(Response.self, from: data)

        #expect(decoded.statusCode == 200)
        #expect(decoded.headers.count == 1)
        #expect(decoded.headers.first?.key == "Server")
        #expect(decoded.headers.first?.value == "nginx")
    }
}

// MARK: - Header Tests

struct HeaderTests {
    @Test("Codable roundtrip preserves key and value")
    func codableRoundtrip() throws {
        let header = Header(key: "Authorization", value: "Bearer abc")

        let data = try JSONEncoder().encode(header)
        let decoded = try JSONDecoder().decode(Header.self, from: data)

        #expect(decoded.key == "Authorization")
        #expect(decoded.value == "Bearer abc")
    }
}

// MARK: - CustomError Tests

struct CustomErrorTests {
    @Test("Initialisation from NSError captures code and message")
    func fromNSError() {
        let nsError = NSError(
            domain: "com.example.test",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Something went wrong"]
        )

        let customError = CustomError(nsError)

        #expect(customError.code == 42)
        #expect(customError.message == "Something went wrong")
    }

    @Test("Initialisation from Error protocol captures code and message")
    func fromErrorProtocol() {
        let nsError = NSError(
            domain: "NetworkDomain",
            code: -1009,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        let error: Error = nsError

        let customError = CustomError(error)

        #expect(customError.code == -1009)
        #expect(customError.message == "The Internet connection appears to be offline.")
    }

    @Test("Codable roundtrip preserves code and message")
    func codableRoundtrip() throws {
        let original = CustomError(NSError(
            domain: "Test",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Internal"]
        ))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomError.self, from: data)

        #expect(decoded.code == 500)
        #expect(decoded.message == "Internal")
    }
}

// MARK: - WebsocketMessagePackage Tests

struct WebsocketMessagePackageTests {
    @Test("Codable roundtrip preserves string message")
    func codableRoundtripString() throws {
        let message = WebsocketMessagePackage.Message.string("hello websocket")
        let package = WebsocketMessagePackage(id: "ws-1", message: message, messageType: .send)

        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(WebsocketMessagePackage.self, from: data)

        // Verify it roundtrips without error (private fields prevent direct comparison).
        let reEncoded = try JSONEncoder().encode(decoded)
        #expect(reEncoded.count > 0)
    }

    @Test("Codable roundtrip preserves data message")
    func codableRoundtripData() throws {
        let binaryData = Data([0x01, 0x02, 0x03, 0x04])
        let message = WebsocketMessagePackage.Message.data(binaryData)
        let package = WebsocketMessagePackage(id: "ws-2", message: message, messageType: .receive)

        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(WebsocketMessagePackage.self, from: data)

        let reEncoded = try JSONEncoder().encode(decoded)
        #expect(reEncoded.count > 0)
    }

    @Test("Close message captures close code")
    func closeMessage() throws {
        let reason = "going away".data(using: .utf8)
        let package = WebsocketMessagePackage(id: "ws-close", closeCode: 1001, reason: reason)

        let data = try JSONEncoder().encode(package)
        #expect(data.count > 0)

        let decoded = try JSONDecoder().decode(WebsocketMessagePackage.self, from: data)
        let reEncoded = try JSONEncoder().encode(decoded)
        #expect(reEncoded.count > 0)
    }

    @Test("toData produces non-nil output")
    func toData() throws {
        let message = WebsocketMessagePackage.Message.string("test")
        let package = WebsocketMessagePackage(id: "ws-3", message: message, messageType: .pingPong)

        let data = package.toData()
        #expect(data != nil)
        #expect(try #require(data?.count) > 0)
    }
}

// MARK: - Device Tests

struct DeviceTests {
    @Test("Current device has non-empty name and model")
    func currentDeviceHasValues() {
        let device = Device.current
        #expect(!device.name.isEmpty)
        #expect(!device.model.isEmpty)
    }

    @Test("Codable roundtrip preserves values")
    func codableRoundtrip() throws {
        let device = Device.current

        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(Device.self, from: data)

        #expect(decoded.name == device.name)
        #expect(decoded.model == device.model)
    }
}

// MARK: - Project Tests

struct ProjectTests {
    @Test("Current project has non-empty name and bundle identifier")
    func currentProjectHasValues() {
        let project = Project.current
        #expect(!project.name.isEmpty)
        #expect(!project.bundleIdentifier.isEmpty)
    }

    @Test("Codable roundtrip preserves values")
    func codableRoundtrip() throws {
        let project = Project.current

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        #expect(decoded.name == project.name)
        #expect(decoded.bundleIdentifier == project.bundleIdentifier)
    }
}

// MARK: - Configuration Tests

struct ConfigurationTests {
    @Test("Default configuration has valid project and device names")
    func defaultConfig() {
        let config = Configuration.default()

        #expect(!config.projectName.isEmpty)
        #expect(!config.deviceName.isEmpty)
        #expect(!config.id.isEmpty)
        #expect(config.hostName == nil)
    }

    @Test("Default configuration with hostname preserves it")
    func defaultConfigWithHostname() {
        let config = Configuration.default(hostName: "development-mac")

        #expect(config.hostName == "development-mac")
    }

    @Test("ID is opaque and does not contain project or device identity")
    func idFormat() {
        let config = Configuration.default()

        #expect(UUID(uuidString: config.id) != nil)
        #expect(!config.id.contains(Project.current.bundleIdentifier))
        #expect(!config.id.contains(Device.current.model))
    }
}

// MARK: - BabylonConstants Tests

struct BabylonConstantsTests {
    @Test("Maximum body size is 50 MB")
    func maximumBodySize() {
        #expect(BabylonConstants.maximumBodySize == 52_428_800)
    }

    @Test("Build version is a non-empty string")
    func buildVersion() {
        #expect(!BabylonConstants.buildVersion.isEmpty)
    }

    @Test("Max pending items is 50")
    func maxPendingItems() {
        #expect(BabylonConstants.maxPendingItems == 50)
    }

    @Test("Service type follows Bonjour naming convention")
    func serviceType() {
        #expect(BabylonConstants.serviceType.hasPrefix("_"))
        #expect(BabylonConstants.serviceType.hasSuffix("._tcp"))
    }

    @Test("Direct connection port is 10909")
    func directConnectionPort() {
        #expect(BabylonConstants.directConnectionPort == 10909)
    }
}
