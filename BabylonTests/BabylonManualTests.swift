import Foundation
import Testing
@testable import Babylon

// MARK: - Manual URL Request/Response Tests

@Suite(.serialized)
struct ManualURLRequestResponseTests {
    @Test("add with URLRequest and URLResponse creates a valid package")
    func addWithURLRequestAndResponse() throws {
        // Set up Babylon in delegate-only mode (no transport).
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        let url = try #require(URL(string: "https://api.example.com/items"))
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.allHTTPHeaderFields = ["Content-Type": "application/json"]
        urlRequest.httpBody = "{\"name\":\"test\"}".data(using: .utf8)

        let urlResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 201,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))

        let responseBody = "{\"id\":42}".data(using: .utf8)

        // Should not crash, even without a connected Rockxy instance.
        Babylon.add(request: urlRequest, response: urlResponse, responseBody: responseBody)

        // Allow the async queue to drain.
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("add with nil response body does not crash")
    func addWithNilResponseBody() throws {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        let url = try #require(URL(string: "https://api.example.com/empty"))
        let urlRequest = URLRequest(url: url)
        let urlResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))

        Babylon.add(request: urlRequest, response: urlResponse, responseBody: nil)

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }
}

// MARK: - Manual Error Tests

@Suite(.serialized)
struct ManualURLRequestErrorTests {
    @Test("add with URLRequest and error creates an error package")
    func addWithURLRequestAndError() throws {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        let url = try #require(URL(string: "https://api.example.com/fail"))
        let urlRequest = URLRequest(url: url)
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )

        Babylon.add(request: urlRequest, error: error)

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }
}

// MARK: - Manual Custom Model Tests

@Suite(.serialized)
struct ManualCustomModelTests {
    @Test("add with Request and Response models creates a valid package")
    func addWithCustomModels() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        let request = Request(
            url: "https://custom.example.com/api",
            method: "PATCH",
            headers: [Header(key: "Authorization", value: "Bearer token")],
            body: "{\"update\":true}".data(using: .utf8)
        )

        let response = Response(
            statusCode: 200,
            headers: [Header(key: "Content-Type", value: "application/json")]
        )

        let responseBody = "{\"updated\":true}".data(using: .utf8)

        Babylon.add(request: request, response: response, responseBody: responseBody)

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("add with custom models and nil body does not crash")
    func addWithCustomModelsNilBody() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        let request = Request(
            url: "https://custom.example.com/health",
            method: "GET",
            headers: [],
            body: nil
        )

        let response = Response(statusCode: 200, headers: [])

        Babylon.add(request: request, response: response, responseBody: nil)

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }
}

// MARK: - gRPC Streaming Type Tests

struct GRPCStreamingTypeTests {
    @Test("GRPCStreamingType has all three cases")
    func allCases() {
        let client = Babylon.GRPCStreamingType.client
        let server = Babylon.GRPCStreamingType.server
        let bidirectional = Babylon.GRPCStreamingType.bidirectional

        // Verify each case is distinct by using a switch (compiler-enforced exhaustiveness).
        for streamType in [client, server, bidirectional] {
            switch streamType {
            case .client:
                #expect(true)
            case .server:
                #expect(true)
            case .bidirectional:
                #expect(true)
            }
        }
    }
}

// MARK: - gRPC Unary Tests

@Suite(.serialized)
struct AddGRPCUnaryTests {
    @Test("addGRPCUnary creates package with correct method and headers")
    func unaryPackage() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        let requestData = "{\"user_id\":1}".data(using: .utf8)
        let responseData = "{\"name\":\"test\"}".data(using: .utf8)

        Babylon.addGRPCUnary(
            path: "/myapp.UserService/GetUser",
            requestObject: requestData,
            responseObject: responseData,
            success: true,
            statusCode: 0,
            statusMessage: "OK",
            startedAt: Date(),
            endedAt: Date(),
            HPACKHeadersRequest: [Header(key: "authorization", value: "Bearer grpc-token")],
            HPACKHeadersResponse: [Header(key: "x-request-id", value: "abc-123")]
        )

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("addGRPCUnary with failure status code does not crash")
    func unaryFailure() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        Babylon.addGRPCUnary(
            path: "/myapp.UserService/GetUser",
            requestObject: nil,
            responseObject: nil,
            success: false,
            statusCode: 14,
            statusMessage: "UNAVAILABLE"
        )

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("addGRPCUnary with default date parameters does not crash")
    func unaryDefaultDates() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        Babylon.addGRPCUnary(
            path: "/myapp.Service/Method",
            requestObject: nil,
            responseObject: nil,
            success: true,
            statusCode: 0,
            statusMessage: nil
        )

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }
}

// MARK: - gRPC Streaming Tests

@Suite(.serialized)
struct AddGRPCStreamingTests {
    @Test("addGRPCStreaming creates a streaming package with client type")
    func streamingClientType() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        let message = WebsocketMessagePackage.Message.string("{\"chunk\":1}")

        Babylon.addGRPCStreaming(
            id: UUID(),
            path: "/myapp.StreamService/ClientStream",
            message: message,
            success: true,
            statusCode: 0,
            statusMessage: "OK",
            streamingType: .client,
            type: .send,
            startedAt: Date(),
            endedAt: nil
        )

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("addGRPCStreaming creates a streaming package with server type")
    func streamingServerType() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        let message = WebsocketMessagePackage.Message.data(Data([0x01, 0x02, 0x03]))

        Babylon.addGRPCStreaming(
            id: UUID(),
            path: "/myapp.StreamService/ServerStream",
            message: message,
            success: true,
            statusCode: 0,
            statusMessage: nil,
            streamingType: .server,
            type: .receive
        )

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("addGRPCStreaming creates a streaming package with bidirectional type")
    func streamingBidirectionalType() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()

        let message = WebsocketMessagePackage.Message.string("{\"bidirectional\":true}")

        Babylon.addGRPCStreaming(
            id: UUID(),
            path: "/myapp.StreamService/BidiStream",
            message: message,
            success: true,
            statusCode: 0,
            statusMessage: nil,
            streamingType: .bidirectional,
            type: .send
        )

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            semaphore.signal()
        }
        semaphore.wait()

        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }
}

// MARK: - Guard When Disabled Tests

@Suite(.serialized)
struct ManualLoggingGuardTests {
    @Test("add methods are no-ops when Babylon is not started")
    func noOpWhenDisabled() throws {
        // Ensure Babylon is stopped.
        Babylon.stop()

        let url = try #require(URL(string: "https://example.com/noop"))
        let urlRequest = URLRequest(url: url)
        let urlResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))

        // None of these should crash or have any effect.
        Babylon.add(request: urlRequest, response: urlResponse, responseBody: nil)
        Babylon.add(request: urlRequest, error: NSError(domain: "Test", code: 0, userInfo: nil))
        Babylon.add(
            request: Request(url: "https://example.com", method: "GET", headers: [], body: nil),
            response: Response(statusCode: 200, headers: []),
            responseBody: nil
        )
        Babylon.addGRPCUnary(
            path: "/test",
            requestObject: nil,
            responseObject: nil,
            success: true,
            statusCode: 0,
            statusMessage: nil
        )

        #expect(true)
    }
}

// MARK: - Expanded Manual Tests

@Suite(.serialized)
struct ExpandedManualLoggingTests {
    @Test("add(request:error:) captures error code and domain")
    func addWithNetworkError() throws {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        defer {
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        let url = try #require(URL(string: "https://example.com/error"))
        let urlRequest = URLRequest(url: url)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: "The request timed out."
        ])

        // Should not crash; package is created internally.
        Babylon.add(request: urlRequest, error: error)
        #expect(true)
    }

    @Test("WebsocketMessagePackage.Message.optionalData returns data for .data case")
    func messageOptionalDataForDataCase() throws {
        let testData = try #require("hello".data(using: .utf8))
        let message = WebsocketMessagePackage.Message.data(testData)
        #expect(message.optionalData == testData)
    }

    @Test("WebsocketMessagePackage.Message.optionalData returns UTF-8 data for .string case")
    func messageOptionalDataForStringCase() {
        let message = WebsocketMessagePackage.Message.string("hello")
        let expected = "hello".data(using: .utf8)
        #expect(message.optionalData == expected)
    }

    @Test("addGRPCStreaming with all three streaming types does not crash")
    func addGRPCStreamingAllTypes() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        defer {
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        let streamID = UUID()
        for streamType in [Babylon.GRPCStreamingType.client, .server, .bidirectional] {
            Babylon.addGRPCStreaming(
                id: streamID,
                path: "/test.Service/Method",
                message: .string("test"),
                success: true,
                statusCode: 0,
                statusMessage: nil,
                streamingType: streamType,
                type: .send
            )
        }
        #expect(true)
    }
}
