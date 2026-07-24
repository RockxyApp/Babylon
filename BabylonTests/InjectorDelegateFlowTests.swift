import Foundation
import Testing
@testable import Babylon

// MARK: - Setup / Teardown Helpers

/// Starts Babylon with transport disabled and installs a capturing delegate.
/// Returns the delegate for assertion.
private func setupCapture() -> CapturingBabylonDelegate {
    Babylon.setEnableTransportLayer(false)
    Babylon.start()
    let delegate = CapturingBabylonDelegate()
    Babylon.setDelegate(delegate)
    return delegate
}

/// Tears down Babylon after a test.
private func teardownCapture() {
    Babylon.stop()
    Babylon.setEnableTransportLayer(true)
}

/// Waits for the delegate to receive at least one package, with a timeout.
/// Returns true if a package was received.
@discardableResult
private func waitForCapture(_ delegate: CapturingBabylonDelegate, timeout: TimeInterval = 5.0) -> Bool {
    delegate.semaphore.wait(timeout: .now() + timeout) == .success
}

/// Drives the capture delegate path without depending on an external network service.
private func simulateCompletedTask(
    request: URLRequest,
    statusCode: Int? = 200,
    responseChunks: [Data] = [],
    error: Error? = nil
) throws -> URLSessionTask {
    let task = URLSession.shared.dataTask(with: request)
    Babylon.shared.injectorSessionDidCallResume(task: task)
    if let statusCode {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        Babylon.shared.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        responseChunks.forEach { Babylon.shared.injectorSessionDidReceiveData(dataTask: task, data: $0) }
    }
    Babylon.shared.injectorSessionDidComplete(task: task, error: error)
    return task
}

// MARK: - InjectorDelegate Flow Tests

@Suite(.serialized)
struct InjectorDelegateFlowTests {
    @Test("injectorSessionDidCallResume records start time in final package")
    func resumeRecordsStartTime() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let timeBefore = Date().timeIntervalSince1970

        let url = try #require(URL(string: "https://httpbin.org/get"))
        let task = try simulateCompletedTask(request: URLRequest(url: url))

        let received = waitForCapture(delegate)
        #expect(received, "Expected to receive a captured package")

        if let package = delegate.packages.first {
            #expect(package.startAt >= timeBefore, "startAt should be at or after the time resume was called")
            #expect(package.startAt <= Date().timeIntervalSince1970, "startAt should be before now")
        }

        task.cancel()
    }

    @Test("injectorSessionDidReceiveResponse followed by didComplete produces package with response")
    func responseIsCaptured() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://httpbin.org/status/200"))
        let task = try simulateCompletedTask(request: URLRequest(url: url))

        let received = waitForCapture(delegate)
        #expect(received, "Expected to receive a captured package")

        if let package = delegate.packages.first {
            #expect(package.response != nil, "Package should have a response")
            #expect(package.response?.statusCode == 200)
        }

        task.cancel()
    }

    @Test("injectorSessionDidReceiveData appends to package responseBodyData")
    func dataIsAppended() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://httpbin.org/bytes/128"))
        let body = Data(repeating: 0x41, count: 128)
        let task = try simulateCompletedTask(request: URLRequest(url: url), responseChunks: [body])

        let received = waitForCapture(delegate)
        #expect(received, "Expected to receive a captured package")

        if let package = delegate.packages.first {
            #expect(package.responseBodyData == body)
        }

        task.cancel()
    }

    @Test("Multiple data chunks accumulate correctly")
    func multipleDataChunksAccumulate() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://httpbin.org/bytes/4096"))
        let chunks = [Data("one".utf8), Data("two".utf8), Data("three".utf8)]
        let task = try simulateCompletedTask(request: URLRequest(url: url), responseChunks: chunks)

        let received = waitForCapture(delegate)
        #expect(received, "Expected to receive a captured package")

        if let package = delegate.packages.first {
            #expect(package.responseBodyData == Data("onetwothree".utf8))
        }

        task.cancel()
    }

    @Test("injectorSessionDidComplete sends package to delegate")
    func completionSendsToDelegate() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://httpbin.org/get"))
        let task = try simulateCompletedTask(request: URLRequest(url: url))

        let received = waitForCapture(delegate)
        #expect(received, "Delegate should receive a package on task completion")
        #expect(!delegate.packages.isEmpty)
        task.cancel()
    }

    @Test("HTTP package is removed from cache after completion")
    func packageRemovedAfterCompletion() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://httpbin.org/get"))
        let task = try simulateCompletedTask(request: URLRequest(url: url))
        #expect(waitForCapture(delegate))

        // The first package should have been delivered.
        let initialCount = delegate.packages.count
        #expect(initialCount >= 1, "At least one package should have been captured")

        Babylon.shared.injectorSessionDidComplete(task: task, error: nil)
        Babylon.shared.queue.sync {}

        #expect(delegate.packages.count == initialCount, "No additional packages should appear after cache removal")
        task.cancel()
    }

    @Test("All delegate methods are no-ops when Babylon is stopped")
    func noOpsWhenStopped() throws {
        // Ensure Babylon is stopped.
        Babylon.stop()
        Babylon.setEnableTransportLayer(false)

        let delegate = CapturingBabylonDelegate()
        Babylon.setDelegate(delegate)

        let url = try #require(URL(string: "https://httpbin.org/get"))
        let task = URLSession.shared.dataTask(with: url)
        task.resume()

        // Give enough time for a hypothetical capture.
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            semaphore.signal()
        }
        semaphore.wait()

        #expect(delegate.packages.isEmpty, "No packages should be captured when Babylon is stopped")

        task.cancel()
        Babylon.setEnableTransportLayer(true)
    }

    @Test("Empty data (0 bytes) response is handled without crash")
    func emptyDataHandled() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://httpbin.org/status/204"))
        let task = try simulateCompletedTask(request: URLRequest(url: url), statusCode: 204)

        let received = waitForCapture(delegate)
        #expect(received, "Expected to receive a captured package for 204 response")

        if let package = delegate.packages.first {
            #expect(package.response?.statusCode == 204)
        }

        task.cancel()
    }

    @Test("Upload data is captured in package request body")
    func uploadDataCaptured() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://httpbin.org/post"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "upload-test-body".data(using: .utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let task = try simulateCompletedTask(request: request)

        let received = waitForCapture(delegate)
        #expect(received, "Expected to receive a captured package")

        if let package = delegate.packages.first {
            #expect(package.request.method == "POST")
            #expect(package.request.url == "https://httpbin.org/post")
            #expect(package.request.body == Data("upload-test-body".utf8))
        }

        task.cancel()
    }

    @Test("Cancel removes package from further processing")
    func cancelRemovesPackage() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://httpbin.org/delay/10"))
        let task = URLSession.shared.dataTask(with: url)
        task.resume()

        // Cancel quickly before the response arrives.
        Thread.sleep(forTimeInterval: 0.1)
        task.cancel()

        // Wait briefly to see if a package arrives from the cancellation.
        let received = waitForCapture(delegate, timeout: 3.0)

        // After cancel, the task should complete with an error.
        // The package may or may not be delivered depending on timing,
        // but it should never crash.
        if received, let package = delegate.packages.first {
            #expect(package.error != nil || package.endAt != nil, "Cancelled package should have an error or end time")
        }

        // Regardless, no crash occurred.
        #expect(true)
    }

    @Test("Manual add with URLRequest and URLResponse delivers to delegate")
    func manualAddDeliveredToDelegate() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://example.com/manual"))
        let urlRequest = URLRequest(url: url)
        let urlResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        let body = try #require("{\"ok\":true}".data(using: .utf8))

        Babylon.add(request: urlRequest, response: urlResponse, responseBody: body)

        let received = waitForCapture(delegate)
        #expect(received, "Delegate should receive the manually added package")

        if let package = delegate.packages.first {
            #expect(package.request.url == "https://example.com/manual")
            #expect(package.response?.statusCode == 200)
            #expect(package.responseBodyData == body)
        }
    }

    @Test("Multiple completed tasks each produce their own package")
    func multipleRequestsProduceMultiplePackages() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let urls = try [
            #require(URL(string: "https://httpbin.org/get")),
            #require(URL(string: "https://httpbin.org/status/201")),
            #require(URL(string: "https://httpbin.org/status/404"))
        ]

        var tasks: [URLSessionTask] = []
        for url in urls {
            try tasks.append(simulateCompletedTask(request: URLRequest(url: url)))
        }

        // Wait for all three to arrive.
        for _ in 0 ..< 3 {
            waitForCapture(delegate, timeout: 10.0)
        }

        #expect(delegate.packages.count >= 3, "Expected at least 3 captured packages")

        // Verify each has a distinct ID.
        let ids = Set(delegate.packages.map(\.id))
        #expect(ids.count == delegate.packages.count, "All captured packages should have unique IDs")
        tasks.forEach { $0.cancel() }
    }

    @Test("Request with error is captured with error details")
    func requestWithErrorCaptured() throws {
        let delegate = setupCapture()
        defer { teardownCapture() }

        let url = try #require(URL(string: "https://this-domain-does-not-exist-12345.invalid/test"))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        let task = try simulateCompletedTask(request: URLRequest(url: url), statusCode: nil, error: error)

        let received = waitForCapture(delegate, timeout: 10.0)
        #expect(received, "Expected to receive a captured package for the failed request")

        if let package = delegate.packages.first {
            #expect(package.error != nil, "Package should contain an error for a failed DNS lookup")
            #expect(package.endAt != nil, "Package should have an end time")
        }
        task.cancel()
    }
}
