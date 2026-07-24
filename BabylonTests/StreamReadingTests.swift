import Foundation
import Testing
@testable import Babylon

// MARK: - Stream Preservation via Request.init

struct StreamReadingTests {
    @Test("Request leaves a small caller-owned body stream untouched")
    func smallStreamIsNotConsumed() throws {
        let url = try #require(URL(string: "https://example.com/stream"))
        let bodyString = "Hello, stream body!"
        let bodyData = try #require(bodyString.data(using: .utf8))

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        let stream = InputStream(data: bodyData)
        urlRequest.httpBodyStream = stream

        let request = try #require(Request(urlRequest))

        #expect(request.body == nil)
        #expect(stream.streamStatus == .notOpen)
    }

    @Test("Request leaves a 1 MiB caller-owned body stream untouched")
    func largeStreamIsNotConsumed() throws {
        let url = try #require(URL(string: "https://example.com/large-stream"))

        // Generate 1 MB of repeating bytes.
        let oneMB = 1_048_576
        var largeData = Data(count: oneMB)
        for i in 0 ..< oneMB {
            largeData[i] = UInt8(i % 256)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        let stream = InputStream(data: largeData)
        urlRequest.httpBodyStream = stream

        let request = try #require(Request(urlRequest))

        #expect(request.body == nil)
        #expect(stream.streamStatus == .notOpen)
    }

    @Test("Request from URLRequest with empty httpBodyStream has nil body")
    func emptyStream() throws {
        let url = try #require(URL(string: "https://example.com/empty-stream"))

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBodyStream = InputStream(data: Data())

        let request = try #require(Request(urlRequest))

        // An empty stream should produce nil body since no bytes were read.
        #expect(request.body == nil)
    }

    @Test("Request URL is correctly captured from URLRequest with stream")
    func urlCaptured() throws {
        let url = try #require(URL(string: "https://api.example.com/v2/upload"))
        let bodyData = try #require("stream-data".data(using: .utf8))

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBodyStream = InputStream(data: bodyData)

        let request = try #require(Request(urlRequest))

        #expect(request.url == "https://api.example.com/v2/upload")
    }

    @Test("Request method is correctly captured from URLRequest with stream")
    func methodCaptured() throws {
        let url = try #require(URL(string: "https://example.com/method-test"))
        let bodyData = try #require("data".data(using: .utf8))

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PATCH"
        urlRequest.httpBodyStream = InputStream(data: bodyData)

        let request = try #require(Request(urlRequest))

        #expect(request.method == "PATCH")
    }

    @Test("Request headers are correctly captured from URLRequest with stream")
    func headersCaptured() throws {
        let url = try #require(URL(string: "https://example.com/headers-test"))
        let bodyData = try #require("data".data(using: .utf8))

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.allHTTPHeaderFields = [
            "Content-Type": "application/octet-stream",
            "X-Custom": "test-value"
        ]
        urlRequest.httpBodyStream = InputStream(data: bodyData)

        let request = try #require(Request(urlRequest))

        let headerKeys = request.headers.map(\.key)
        #expect(headerKeys.contains("Content-Type"))
        #expect(headerKeys.contains("X-Custom"))

        let customHeader = request.headers.first { $0.key == "X-Custom" }
        #expect(customHeader?.value == "test-value")
    }

    @Test("Multiple Request initializers do not consume independent streams")
    func independentStreamsAreNotConsumed() throws {
        let url = try #require(URL(string: "https://example.com/independent"))

        let bodyA = try #require("stream-A".data(using: .utf8))
        let bodyB = try #require("stream-B-longer-content".data(using: .utf8))

        var urlRequestA = URLRequest(url: url)
        urlRequestA.httpMethod = "POST"
        let streamA = InputStream(data: bodyA)
        urlRequestA.httpBodyStream = streamA

        var urlRequestB = URLRequest(url: url)
        urlRequestB.httpMethod = "POST"
        let streamB = InputStream(data: bodyB)
        urlRequestB.httpBodyStream = streamB

        let requestA = try #require(Request(urlRequestA))
        let requestB = try #require(Request(urlRequestB))

        #expect(requestA.body == nil)
        #expect(requestB.body == nil)
        #expect(streamA.streamStatus == .notOpen)
        #expect(streamB.streamStatus == .notOpen)
    }
}
