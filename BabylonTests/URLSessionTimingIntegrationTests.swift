import Foundation
import Testing

#if os(macOS)
import Network
@testable import Babylon

private final class MetricsHTTPServer {
    private let queue = DispatchQueue(label: "com.amunx.babylon.tests.metrics-http-loopback")
    private let listener: NWListener
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _acceptedConnections = 0

    var port: UInt16? {
        listener.port?.rawValue
    }

    var acceptedConnections: Int {
        lock.withLock { _acceptedConnections }
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            lock.withLock { self._acceptedConnections += 1 }
            connection.start(queue: queue)
            receiveNextRequest(from: connection, buffered: Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.ready.signal()
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != nil else {
            throw LoopbackError.listenerStartTimedOut
        }
    }

    deinit {
        listener.cancel()
    }

    private func receiveNextRequest(from connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { return }
            var request = buffered
            if let data {
                request.append(data)
            }
            let delimiter = Data("\r\n\r\n".utf8)
            guard let headerEnd = request.range(of: delimiter) else {
                guard !complete else { return }
                receiveNextRequest(from: connection, buffered: request)
                return
            }
            let header = Data(request[..<headerEnd.lowerBound])
            let firstLine = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            if path == "/failure" {
                connection.cancel()
                return
            }

            let isRedirect = path == "/redirect"
            let body = Data((isRedirect ? "redirect" : "metrics-ok").utf8)
            var response = Data(
                "HTTP/1.1 \(isRedirect ? "302 Found" : "200 OK")\r\nContent-Length: \(body.count)\r\n\(isRedirect ? "Location: /final\r\n" : "")Connection: keep-alive\r\n\r\n"
                    .utf8
            )
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { [weak self] sendError in
                guard let self, sendError == nil else { return }
                receiveNextRequest(from: connection, buffered: Data(request[headerEnd.upperBound...]))
            })
        }
    }

    enum LoopbackError: Error {
        case listenerStartTimedOut
    }
}

private final class CallerMetricsDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private var _metrics: [URLSessionTaskMetrics] = []
    private var _errors: [Error] = []

    var metrics: [URLSessionTaskMetrics] {
        lock.withLock { _metrics }
    }

    var errors: [Error] {
        lock.withLock { _errors }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.withLock { _metrics.append(metrics) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.withLock { _errors.append(error) }
        }
    }
}

@Suite(.serialized)
struct URLSessionTimingIntegrationTests {
    @Test("Real URLSession redirect timing preserves transaction order and caller delegate callback")
    func redirectMetricsReachBabylonAndCaller() async throws {
        let server = try MetricsHTTPServer()
        let port = try #require(server.port)
        let captureDelegate = CapturingBabylonDelegate()
        let callerDelegate = CallerMetricsDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(captureDelegate)
        Babylon.start()
        defer {
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        let session = URLSession(configuration: .ephemeral, delegate: callerDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/redirect"))
        let (_, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let package = try #require(await Self.waitForPackage(captureDelegate, path: "/final"))
        #expect(!callerDelegate.metrics.isEmpty)
        #expect(callerDelegate.metrics.first?.redirectCount == 1)
        if let timing = package.urlSessionTiming {
            #expect(timing.schemaVersion == URLSessionTiming.currentSchemaVersion)
            #expect(timing.redirectCount == 1)
            #expect(timing.transactions.count == 2)
            #expect(timing.transactions.map(\.index) == [0, 1])
        } else {
            #expect(package.urlSessionTiming == nil)
        }
    }

    @Test("Reused localhost connection reports its connection and failure remains captured")
    func reusedConnectionAndFailure() async throws {
        let server = try MetricsHTTPServer()
        let port = try #require(server.port)
        let captureDelegate = CapturingBabylonDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(captureDelegate)
        Babylon.start()
        defer {
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let firstURL = try #require(URL(string: "http://127.0.0.1:\(port)/first"))
        let secondURL = try #require(URL(string: "http://127.0.0.1:\(port)/second"))
        _ = try await session.data(from: firstURL)
        _ = try await session.data(from: secondURL)

        let first = try #require(await Self.waitForPackage(captureDelegate, path: "/first"))
        let second = try #require(await Self.waitForPackage(captureDelegate, path: "/second"))
        if let firstTiming = first.urlSessionTiming,
           let firstTransaction = firstTiming.transactions.first,
           let secondTiming = second.urlSessionTiming,
           let secondTransaction = secondTiming.transactions.first {
            #expect(!firstTransaction.reusedConnection)
            #expect(secondTransaction.reusedConnection)
        } else {
            #expect(first.urlSessionTiming == nil)
            #expect(second.urlSessionTiming == nil)
        }
        #expect(server.acceptedConnections == 1)

        let failedURL = try #require(URL(string: "http://127.0.0.1:\(port)/failure"))
        do {
            _ = try await session.data(from: failedURL)
            Issue.record("Expected the loopback server to close the request without a response")
        } catch {
            #expect(error is URLError)
        }
        let failed = try #require(await Self.waitForPackage(captureDelegate, path: "/failure"))
        #expect(failed.error != nil)
    }

    @Test("Stop flushes an HTTP capture whose metrics have not arrived")
    func stopFlushesPendingMetricsCompletion() async throws {
        let captureDelegate = CapturingBabylonDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(captureDelegate)
        Babylon.start()
        let session = URLSession(configuration: .ephemeral)
        defer {
            session.invalidateAndCancel()
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        let url = try #require(URL(string: "http://127.0.0.1/stop-before-metrics"))
        let task = session.dataTask(with: url)
        Babylon.shared.injectorSessionDidCallResume(task: task)
        Babylon.shared.injectorSessionDidComplete(task: task, error: nil)
        #expect(Babylon.shared.pendingMetricsCompletionCountForTesting == 1)

        Babylon.stop()
        Babylon.shared.queue.sync {}

        let package = try #require(await Self.waitForPackage(captureDelegate, path: "/stop-before-metrics"))
        #expect(package.urlSessionTiming == nil)
        #expect(Babylon.shared.pendingMetricsCompletionCountForTesting == 0)
    }

    @Test("Memory pressure cancels a pending metrics completion")
    func memoryPressureCancelsPendingMetricsCompletion() async throws {
        let captureDelegate = CapturingBabylonDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(captureDelegate)
        Babylon.start()
        let session = URLSession(configuration: .ephemeral)
        defer {
            session.invalidateAndCancel()
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        let url = try #require(URL(string: "http://127.0.0.1/memory-before-metrics"))
        let task = session.dataTask(with: url)
        Babylon.shared.injectorSessionDidCallResume(task: task)
        Babylon.shared.injectorSessionDidComplete(task: task, error: nil)
        #expect(Babylon.shared.pendingMetricsCompletionCountForTesting == 1)

        Babylon.shared.handleMemoryPressureForTesting()
        Babylon.shared.queue.sync {}
        try await Task.sleep(for: .milliseconds(300))

        #expect(Babylon.shared.pendingMetricsCompletionCountForTesting == 0)
        #expect(captureDelegate.packages.isEmpty)
    }

    private static func waitForPackage(
        _ delegate: CapturingBabylonDelegate,
        path: String
    ) async -> TrafficPackage? {
        for _ in 0 ..< 500 {
            if let package = delegate.packages.first(where: { $0.request.url.contains(path) && $0.endAt != nil }) {
                return package
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return delegate.packages.first { $0.request.url.contains(path) }
    }
}
#endif
