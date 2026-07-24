import Foundation
import Testing
@testable import Babylon

// MARK: - Stream Size Limit Tests

struct StreamSizeLimitTests {
    @Test("Request does not consume a caller-owned HTTP body stream")
    func bodyStreamIsNotConsumed() throws {
        let url = try #require(URL(string: "https://example.com/stream"))
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"

        let stream = InputStream(data: Data(repeating: 0xFF, count: 1024))
        urlRequest.httpBodyStream = stream

        let request = Request(urlRequest)

        #expect(request != nil)
        #expect(request?.body == nil)
        #expect(stream.streamStatus == .notOpen)
    }
}

// MARK: - Associated Object Atomicity Tests

struct AssociatedObjectAtomicityTests {
    @Test("markAsBabylonInternal and isBabylonInternal concurrent calls do not crash")
    func concurrentMarkAndCheck() {
        let iterations = 100

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            guard let url = URL(string: "https://example.com/\(index)") else { return }
            let task = URLSession.shared.dataTask(with: url)
            task.markAsBabylonInternal()
            let result = task.isBabylonInternal()
            _ = result
        }

        // Reaching here without a crash confirms thread safety.
        #expect(true)
    }
}

// MARK: - debugDescription Safety Tests

struct DebugDescriptionSafetyTests {
    @Test("TrafficPackage.debugDescription does not contain any URL strings")
    func noURLInDebugDescription() {
        let request = Request(
            url: "https://api.private.example.com/v2/secret-endpoint?token=abc123",
            method: "POST",
            headers: [Header(key: "Authorization", value: "Bearer secret-token")],
            body: nil
        )
        let package = TrafficPackage(id: "desc-safe", request: request)

        let description = package.debugDescription

        #expect(!description.contains("api.private.example.com"))
        #expect(!description.contains("secret-endpoint"))
        #expect(!description.contains("token=abc123"))
        #expect(!description.contains("https://"))
    }

    @Test("TrafficPackage.debugDescription contains type= and hasResponse=")
    func debugDescriptionContainsExpectedFields() {
        let request = Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "desc-fields", request: request)

        let description = package.debugDescription

        #expect(description.contains("type="))
        #expect(description.contains("hasResponse="))
    }
}

// MARK: - Selector Constants Tests

struct SelectorConstantsTests {
    @Test("BabylonConstants.Selectors.resume equals resume")
    func resumeSelector() {
        #expect(BabylonConstants.Selectors.resume == "resume")
    }

    @Test("BabylonConstants.Selectors.didReceiveResponseSniff equals _didReceiveResponse:sniff:")
    func didReceiveResponseSniffSelector() {
        #expect(BabylonConstants.Selectors.didReceiveResponseSniff == "_didReceiveResponse:sniff:")
    }

    @Test("BabylonConstants.Selectors.didReceiveData equals _didReceiveData:")
    func didReceiveDataSelector() {
        #expect(BabylonConstants.Selectors.didReceiveData == "_didReceiveData:")
    }

    @Test("BabylonConstants.Selectors.didFinishWithError equals _didFinishWithError:")
    func didFinishWithErrorSelector() {
        #expect(BabylonConstants.Selectors.didFinishWithError == "_didFinishWithError:")
    }

    @Test("All 12 selector constants are non-empty strings")
    func allSelectorsNonEmpty() {
        let selectors = [
            BabylonConstants.Selectors.resume,
            BabylonConstants.Selectors.didReceiveResponseSniff,
            BabylonConstants.Selectors.didReceiveData,
            BabylonConstants.Selectors.didFinishWithError,
            BabylonConstants.Selectors.uploadFromFile,
            BabylonConstants.Selectors.uploadFromFileCompletion,
            BabylonConstants.Selectors.uploadFromData,
            BabylonConstants.Selectors.uploadFromDataCompletion,
            BabylonConstants.Selectors.webSocketSendMessage,
            BabylonConstants.Selectors.webSocketReceiveMessage,
            BabylonConstants.Selectors.webSocketSendPing,
            BabylonConstants.Selectors.webSocketCancelWithCloseCode
        ]

        for selector in selectors {
            #expect(!selector.isEmpty)
        }

        #expect(selectors.count == 12)
    }
}

// MARK: - Header Redaction Tests

@Suite(.serialized)
struct HeaderRedactionTests {
    @Test("After setRedactedHeaders with Authorization, header value is redacted")
    func authorizationHeaderRedacted() throws {
        Babylon.setRedactedHeaders(["Authorization"])

        var urlRequest = try URLRequest(url: #require(URL(string: "https://example.com/auth")))
        urlRequest.allHTTPHeaderFields = [
            "Authorization": "Bearer super-secret-token",
            "Content-Type": "application/json"
        ]

        let request = Request(urlRequest)

        #expect(request != nil)

        let authHeader = request?.headers.first { $0.key == "Authorization" }
        let contentHeader = request?.headers.first { $0.key == "Content-Type" }

        #expect(authHeader?.value == "[REDACTED]")
        #expect(contentHeader?.value == "application/json")

        // Clean up.
        Babylon.setRedactedHeaders([])
    }

    @Test("Secure default headers remain redacted with an empty custom set")
    func secureDefaultsRemainRedacted() throws {
        Babylon.setRedactedHeaders([])

        var urlRequest = try URLRequest(url: #require(URL(string: "https://example.com/no-redact")))
        urlRequest.allHTTPHeaderFields = [
            "Authorization": "Bearer visible-token",
            "X-Api-Key": "my-api-key"
        ]

        let request = Request(urlRequest)

        #expect(request != nil)

        let authHeader = request?.headers.first { $0.key == "Authorization" }
        let apiKeyHeader = request?.headers.first { $0.key == "X-Api-Key" }

        #expect(authHeader?.value == "[REDACTED]")
        #expect(apiKeyHeader?.value == "[REDACTED]")
    }
}
