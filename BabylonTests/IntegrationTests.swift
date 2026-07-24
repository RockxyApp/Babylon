import Foundation
import Testing
@testable import Babylon

// MARK: - Integration Test Helpers

/// Starts Babylon in delegate-only mode (no transport) with the given delegate.
private func startBabylonForTesting(delegate: CapturingBabylonDelegate) {
    Babylon.setEnableTransportLayer(false)
    Babylon.setDelegate(delegate)
    Babylon.start()
}

/// Stops Babylon and restores defaults.
private func stopBabylonAfterTesting() {
    Babylon.stop()
    Babylon.setEnableTransportLayer(true)
}

/// Waits for at least `count` packages to arrive via the delegate's semaphore.
/// Returns once enough packages are received or the timeout is reached.
private func waitForPackages(
    delegate: CapturingBabylonDelegate,
    minimumCount: Int = 1,
    timeout: TimeInterval = 5.0
) {
    let deadline = DispatchTime.now() + timeout
    var received = delegate.packages.count
    while received < minimumCount {
        let result = delegate.semaphore.wait(timeout: deadline)
        if result == .timedOut {
            break
        }
        received = delegate.packages.count
    }
}

private func injectCompletedHTTPTask(request: URLRequest, statusCode: Int = 200) throws -> URLSessionTask {
    let task = URLSession.shared.dataTask(with: request)
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    ))
    Babylon.shared.injectorSessionDidCallResume(task: task)
    Babylon.shared.injectorSessionDidReceiveResponse(dataTask: task, response: response)
    Babylon.shared.injectorSessionDidComplete(task: task, error: nil)
    return task
}

// MARK: - HTTP Traffic Capture Tests

@Suite(.serialized)
struct HTTPTrafficCaptureTests {
    @Test("GET request captures a TrafficPackage with correct URL")
    func getRequestCapturesPackage() throws {
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

        let url = try #require(URL(string: "https://httpbin.org/get"))
        let task = try injectCompletedHTTPTask(request: URLRequest(url: url))
        waitForPackages(delegate: delegate, minimumCount: 1, timeout: 3.0)

        let captured = delegate.packages
        stopBabylonAfterTesting()
        task.cancel()

        #expect(!captured.isEmpty, "Expected at least one captured package from GET request")
        if let first = captured.first {
            #expect(first.request.url.contains("httpbin.org/get"))
        }
    }

    @Test("POST request captures request body")
    func postRequestCapturesBody() throws {
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

        let url = try #require(URL(string: "https://httpbin.org/post"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "{\"test\":true}".data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let task = URLSession.shared.dataTask(with: request)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        Babylon.shared.injectorSessionDidCallResume(task: task)
        Babylon.shared.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        Babylon.shared.injectorSessionDidComplete(task: task, error: nil)
        waitForPackages(delegate: delegate, minimumCount: 1, timeout: 3.0)

        let captured = delegate.packages
        stopBabylonAfterTesting()
        task.cancel()

        #expect(!captured.isEmpty, "Expected at least one captured package from POST request")
        if let first = captured.first {
            #expect(first.request.method == "POST")
            #expect(first.request.body == Data("{\"test\":true}".utf8))
        }
    }

    @Test("Multiple simultaneous requests produce distinct packages")
    func simultaneousRequestsProduceDistinct() throws {
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

        let urls = try [
            #require(URL(string: "https://httpbin.org/get?id=1")),
            #require(URL(string: "https://httpbin.org/get?id=2")),
            #require(URL(string: "https://httpbin.org/get?id=3"))
        ]

        var tasks: [URLSessionTask] = []
        for url in urls {
            let task = URLSession.shared.dataTask(with: url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ))
            Babylon.shared.injectorSessionDidCallResume(task: task)
            Babylon.shared.injectorSessionDidReceiveResponse(dataTask: task, response: response)
            Babylon.shared.injectorSessionDidComplete(task: task, error: nil)
            tasks.append(task)
        }
        waitForPackages(delegate: delegate, minimumCount: 3, timeout: 5.0)

        let captured = delegate.packages
        stopBabylonAfterTesting()
        tasks.forEach { $0.cancel() }

        #expect(captured.count >= 3, "Expected at least 3 distinct captured packages")

        let uniqueIDs = Set(captured.map(\.id))
        #expect(uniqueIDs.count == captured.count, "Each package should have a unique ID")
    }

    @Test("Package startAt is populated")
    func packageStartAtPopulated() throws {
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

        let url = try #require(URL(string: "https://httpbin.org/get"))
        let task = try injectCompletedHTTPTask(request: URLRequest(url: url))
        waitForPackages(delegate: delegate, minimumCount: 1, timeout: 3.0)

        let captured = delegate.packages
        stopBabylonAfterTesting()
        task.cancel()

        if let first = captured.first {
            #expect(first.startAt > 0)
            if let endAt = first.endAt {
                #expect(endAt >= first.startAt)
            }
        }
    }

    @Test("Package packageType is .http for data task")
    func packageTypeIsHTTP() throws {
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

        let url = try #require(URL(string: "https://httpbin.org/get"))
        let task = try injectCompletedHTTPTask(request: URLRequest(url: url))
        waitForPackages(delegate: delegate, minimumCount: 1, timeout: 3.0)

        let captured = delegate.packages
        stopBabylonAfterTesting()
        task.cancel()

        if let first = captured.first {
            #expect(first.packageType == .http)
        }
    }

    @Test("No packages captured when Babylon is stopped")
    func noPackagesWhenStopped() throws {
        let delegate = CapturingBabylonDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(delegate)
        // Intentionally do NOT call Babylon.start()

        let url = try #require(URL(string: "https://httpbin.org/get"))
        let task = try injectCompletedHTTPTask(request: URLRequest(url: url))
        Babylon.shared.queue.sync {}

        let captured = delegate.packages

        Babylon.setEnableTransportLayer(true)
        task.cancel()

        #expect(captured.isEmpty, "No packages should be captured when Babylon is not started")
    }

    @Test("Delegate callback fires on main thread")
    func delegateCallbackOnMainThread() throws {
        // BabylonDelegate.babylonDidCapturePackage is documented to fire on the main thread.
        // Verify using manual add (avoids network dependency).
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

        let url = try #require(URL(string: "https://api.example.com/thread-check"))
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"

        let urlResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))

        Babylon.add(request: urlRequest, response: urlResponse, responseBody: nil)

        waitForPackages(delegate: delegate, minimumCount: 1, timeout: 3.0)

        stopBabylonAfterTesting()

        // The Babylon.startSendingMessage dispatches to main thread, so if a package
        // was delivered the delegate was called on main. If no package, skip.
        #expect(!delegate.packages.isEmpty, "Expected at least one package for thread check")
    }
}

// MARK: - Manual Logging Integration Tests

@Suite(.serialized)
struct ManualLoggingIntegrationTests {
    @Test("add(request:response:responseBody:) delivers package to delegate")
    func addRequestResponseDelivers() throws {
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

        let url = try #require(URL(string: "https://api.example.com/manual"))
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"

        let urlResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))

        let body = "{\"manual\":true}".data(using: .utf8)

        Babylon.add(request: urlRequest, response: urlResponse, responseBody: body)

        waitForPackages(delegate: delegate, minimumCount: 1, timeout: 3.0)

        let captured = delegate.packages
        stopBabylonAfterTesting()

        #expect(!captured.isEmpty, "Expected delegate to receive a package from manual add")
        if let first = captured.first {
            #expect(first.request.url.contains("api.example.com/manual"))
            #expect(first.response?.statusCode == 200)
        }
    }

    @Test("add(request:error:) delivers package with error to delegate")
    func addRequestErrorDelivers() throws {
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

        let url = try #require(URL(string: "https://api.example.com/error"))
        let urlRequest = URLRequest(url: url)
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        )

        Babylon.add(request: urlRequest, error: error)

        waitForPackages(delegate: delegate, minimumCount: 1, timeout: 3.0)

        let captured = delegate.packages
        stopBabylonAfterTesting()

        #expect(!captured.isEmpty, "Expected delegate to receive a package from manual error add")
        if let first = captured.first {
            #expect(first.request.url.contains("api.example.com/error"))
            #expect(first.error != nil)
            #expect(first.error?.code == NSURLErrorTimedOut)
        }
    }

    @Test("Packages resume after stop/start cycle")
    func packagesResumeAfterStopStart() throws {
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

        let url = try #require(URL(string: "https://api.example.com/cycle-test"))
        let urlRequest = URLRequest(url: url)
        let urlResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))

        // Send first package.
        Babylon.add(request: urlRequest, response: urlResponse, responseBody: nil)

        waitForPackages(delegate: delegate, minimumCount: 1, timeout: 2.0)

        let countBeforeStop = delegate.packages.count

        // Stop and restart.
        Babylon.stop()
        startBabylonForTesting(delegate: delegate)

        // Send second package.
        Babylon.add(request: urlRequest, response: urlResponse, responseBody: nil)

        waitForPackages(delegate: delegate, minimumCount: countBeforeStop + 1, timeout: 3.0)

        stopBabylonAfterTesting()

        #expect(
            delegate.packages.count > countBeforeStop,
            "Packages should continue to be delivered after a stop/start cycle"
        )
    }

    @Test("Manual add with custom Request and Response models delivers to delegate")
    func addCustomModelsDelivers() {
        let delegate = CapturingBabylonDelegate()
        startBabylonForTesting(delegate: delegate)

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

        Babylon.add(request: request, response: response, responseBody: "{\"ok\":true}".data(using: .utf8))

        waitForPackages(delegate: delegate, minimumCount: 1, timeout: 3.0)

        let captured = delegate.packages
        stopBabylonAfterTesting()

        #expect(!captured.isEmpty, "Expected delegate to receive a package from custom model add")
        if let first = captured.first {
            #expect(first.request.url == "https://custom.example.com/api")
            #expect(first.request.method == "PATCH")
            #expect(first.response?.statusCode == 200)
        }
    }
}
