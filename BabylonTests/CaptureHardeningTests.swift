import Foundation
import Testing
@testable import Babylon

#if os(macOS)
import Darwin
#endif

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
        let oversized = Data(repeating: 0x42, count: BabylonConstants.maximumWebSocketFrameSize + 1)
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
        let snapshot = try #require(package.makeSnapshot())

        package.setWebsocketMessagePackage(package: WebsocketMessagePackage(
            id: "snapshot",
            message: .string("second"),
            messageType: .send
        ))

        let data = try #require(snapshot.toData())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedReference = try JSONEncoder().encode(snapshot)
        let referenceJSON = try #require(JSONSerialization.jsonObject(with: encodedReference) as? [String: Any])
        #expect(NSDictionary(dictionary: json).isEqual(to: referenceJSON))
        let frame = try #require(json["websocketMessagePackage"] as? [String: Any])
        #expect(frame["stringValue"] as? String == "first")
        #expect(package.basePayloadEncodingCount == 1)

        package.setWebsocketMessagePackage(package: WebsocketMessagePackage(
            id: "snapshot",
            message: .string("third"),
            messageType: .send
        ))
        let nextSnapshot = try #require(package.makeSnapshot())
        let nextData = try #require(nextSnapshot.toData())
        let nextJSON = try #require(JSONSerialization.jsonObject(with: nextData) as? [String: Any])
        let nextFrame = try #require(nextJSON["websocketMessagePackage"] as? [String: Any])
        #expect(nextFrame["stringValue"] as? String == "third")
        #expect(package.basePayloadEncodingCount == 1)
    }

    @Test("Shared capture memory leases bound retained package pressure and release on drop")
    func sharedMemoryBudgetBoundsRetainedPackages() {
        let budget = CaptureMemoryBudget(limit: 16 * 1024 * 1024)
        var retained: [TrafficPackage] = []
        var rejected = 0
        #if os(macOS)
        let initialPeakRSS = residentPeakBytes()
        #endif

        for index in 0 ..< 8 {
            let body = Data(repeating: UInt8(index), count: 6 * 1024 * 1024)
            let request = Request(url: "https://example.com/\(index)", method: "POST", headers: [], body: body)
            let package = TrafficPackage(id: "stress-\(index)", request: request)
            if package.admitCapture(using: budget) {
                retained.append(package)
            } else {
                rejected += 1
            }
        }

        let peak = budget.snapshot
        #expect(peak.usedBytes <= peak.limitBytes)
        #expect(peak.highWaterBytes <= peak.limitBytes)
        #expect(peak.droppedReservations == rejected)
        #expect(rejected > 0)
        #expect(retained.count <= 2)
        #if os(macOS)
        let peakRSSGrowth = max(0, residentPeakBytes() - initialPeakRSS)
        #expect(peakRSSGrowth < 80 * 1024 * 1024)
        #endif

        retained.removeAll()
        #expect(budget.snapshot.usedBytes == 0)
    }

    @Test("Capture budget refuses an over-limit stage and resizes leases atomically")
    func captureBudgetAdmissionAndResize() throws {
        let budget = CaptureMemoryBudget(limit: 1024)
        let first = try #require(budget.reserve(700))
        #expect(budget.reserve(400) == nil)
        #expect(first.resize(to: 900))
        #expect(!first.resize(to: 1100))
        #expect(budget.snapshot.usedBytes == 900)
        #expect(budget.snapshot.droppedReservations == 2)
        #expect(first.resize(to: 300))
        #expect(budget.snapshot.usedBytes == 300)
    }

    @Test("Encrypted frames keep the capture lease until the frame is released")
    func encryptedFrameRetainsSharedCaptureLease() throws {
        let budget = CaptureMemoryBudget.shared
        let initialBytes = budget.snapshot.usedBytes
        func makeFrame() throws -> BabylonProtocol.EncodedFrame {
            var package: TrafficPackage? = TrafficPackage(
                id: "budgeted-frame",
                request: Request(
                    url: "https://example.com",
                    method: "POST",
                    headers: [],
                    body: Data(repeating: 0x61, count: 1024)
                )
            )
            #expect(package?.admitCapture() == true)

            let snapshot = try #require(package?.makeSnapshot())
            let message = try #require(Message.buildTrafficMessage(id: "budgeted-client", item: snapshot))
            let frame = try BabylonProtocol.encode(
                message: message,
                configuration: .default(authToken: testPairingToken),
                sequence: 1,
                messageID: "budgeted-frame",
                nonce: Data(repeating: 0x61, count: 12)
            )
            package = nil
            return frame
        }

        var frame: BabylonProtocol.EncodedFrame? = try makeFrame()
        #expect(frame?.captureMemoryLease != nil)
        #expect(budget.snapshot.usedBytes > initialBytes)

        frame = nil
        #expect(budget.snapshot.usedBytes == initialBytes)
    }

    @Test("Encoder work queue drops overload and clears pending leases")
    func boundedEncoderQueueDropsAndClearsPendingWork() throws {
        let workQueue = BoundedCaptureWorkQueue(label: "com.amunx.babylon.tests.capture", maximumItems: 2)
        let budget = CaptureMemoryBudget(limit: 1024)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        #expect(workQueue.enqueue {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            completed.signal()
        })
        #expect(started.wait(timeout: .now() + 2) == .success)
        do {
            let lease = try #require(budget.reserve(256))
            #expect(workQueue.enqueue { withExtendedLifetime(lease) {} })
        }
        do {
            let lease = try #require(budget.reserve(256))
            #expect(workQueue.enqueue { withExtendedLifetime(lease) {} })
        }
        #expect(!workQueue.enqueue {})
        #expect(workQueue.pendingCount == 2)
        #expect(workQueue.droppedWorkCount == 1)
        #expect(budget.snapshot.usedBytes == 512)

        workQueue.clear()
        #expect(workQueue.pendingCount == 0)
        #expect(workQueue.droppedWorkCount == 3)
        #expect(budget.snapshot.usedBytes == 0)
        release.signal()
        #expect(completed.wait(timeout: .now() + 2) == .success)
    }

    @Test("Capture strings and headers are bounded by UTF-8 bytes")
    func captureStringsRespectByteBounds() {
        let emoji = String(repeating: "🧪", count: 10000)
        let request = Request(
            url: "https://example.com/\(emoji)",
            method: "GET",
            headers: (0 ..< 200).map { Header(key: "x-\($0)", value: emoji) },
            body: nil
        )

        #expect(request.url.utf8.count <= BabylonConstants.maximumCaptureStringBytes)
        #expect(request.headers.count <= BabylonConstants.maximumCaptureHeaderCount)
        #expect(request.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } <=
            BabylonConstants.maximumCaptureHeaderBytes)
        #expect(request.headers.allSatisfy { $0.value.utf8.count <= 4096 })

        let runtime = RuntimePackage(
            kind: .event,
            sessionId: emoji,
            traceId: emoji,
            name: emoji,
            metadata: Dictionary(uniqueKeysWithValues: (0 ..< 80).map { ("key-\($0)", emoji) })
        )
        let metadataBytes = runtime.metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        #expect(runtime.sessionId.utf8.count <= 512)
        #expect((runtime.traceId?.utf8.count ?? 0) <= 512)
        #expect(runtime.name.utf8.count <= 4096)
        #expect(metadataBytes <= RuntimeMetadata.maximumTotalBytes)

        let correlation = CorrelationContext(sessionId: emoji, traceId: emoji, stepId: emoji)
        #expect(correlation.sessionId.utf8.count <= 512)
        #expect(correlation.traceId.utf8.count <= 512)
        #expect(correlation.stepId.utf8.count <= 512)
    }

    @Test("Response metadata that exceeds the remaining capture budget is omitted")
    func responseMetadataRespectsRemainingCaptureBudget() {
        let budget = CaptureMemoryBudget(limit: 8192)
        let package = TrafficPackage(
            id: "bounded-response",
            request: Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        )
        #expect(package.admitCapture(using: budget))
        let retainedBytes = budget.snapshot.usedBytes
        guard let response = HTTPURLResponse(
            url: URL(filePath: "/"),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["X-Large": String(repeating: "x", count: 16000)]
        ) else {
            Issue.record("Unable to create the HTTP response fixture")
            return
        }

        package.updateResponse(response)

        #expect(package.response == nil)
        #expect(budget.snapshot.usedBytes == retainedBytes)
    }

    @Test("Correlation metadata is omitted when it exceeds the remaining capture budget")
    func correlationMetadataRespectsRemainingCaptureBudget() {
        let budget = CaptureMemoryBudget(limit: 9000)
        let package = TrafficPackage(
            id: "bounded-correlation",
            request: Request(url: "https://example.com", method: "GET", headers: [], body: nil)
        )
        #expect(package.admitCapture(using: budget))
        let retainedBytes = budget.snapshot.usedBytes

        package.setCorrelationContext(CorrelationContext(
            sessionId: String(repeating: "s", count: 512),
            traceId: String(repeating: "t", count: 512),
            stepId: String(repeating: "p", count: 512)
        ))

        #expect(package.correlationContext == nil)
        #expect(budget.snapshot.usedBytes == retainedBytes)
    }

    #if os(macOS)
    private func residentPeakBytes() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int(usage.ru_maxrss)
    }
    #endif

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
