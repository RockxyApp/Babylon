import Foundation
import Testing
@testable import Babylon

@Suite(.serialized)
struct BabylonRuntimeTests {
    @Test("Trace lifecycle emits ordered runtime messages")
    func traceLifecycleMessages() {
        let transport = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let trace = Babylon.startTrace("Checkout", metadata: ["cart": "123"])
        trace.step("Load Cart")
        trace.finish(metadata: ["result": "ok"])

        let packages = decodedRuntimePackages(from: transport)
        let kinds = packages.map(\.kind)

        #expect(kinds.contains(.sessionStarted))
        #expect(kinds.contains(.traceStarted))
        #expect(kinds.contains(.stepFinished))
        #expect(kinds.contains(.stepStarted))
        #expect(kinds.contains(.traceFinished))
        #expect(packages.first { $0.kind == .traceStarted }?.metadata["cart"] == "123")
    }

    @Test("Trace finish is idempotent and steps after finish are no-ops")
    func finishIsIdempotent() {
        let transport = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let trace = Babylon.startTrace("Checkout")
        trace.finish()
        trace.finish()
        trace.step("Ignored")

        let packages = decodedRuntimePackages(from: transport)
        let traceFinishedCount = packages.filter { $0.kind == .traceFinished }.count
        let ignoredStepCount = packages.filter { $0.name == "Ignored" }.count

        #expect(traceFinishedCount == 1)
        #expect(ignoredStepCount == 0)
    }

    @Test("Runtime APIs no-op while Babylon is stopped")
    func runtimeNoOpsWhenStopped() {
        Babylon.stop()
        let transport = MockTransporter()
        Babylon.setTransporterForTesting(transport)

        let trace = Babylon.startTrace("Stopped")
        trace.step("Ignored")
        trace.finish()
        Babylon.mark("Ignored")
        Babylon.event("Ignored")
        Babylon.error("Ignored", error: NSError(domain: "Test", code: 1))

        #expect(transport.sentPackages.isEmpty)
    }

    @Test("Stop is non-blocking and delivers closing trace and session packages")
    func stopDrainsClosingRuntimePackagesWithoutBlocking() {
        let transport = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let trace = Babylon.startTrace("Active at stop")
        trace.step("Final step")

        let queueEntered = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        Babylon.shared.queue.async {
            queueEntered.signal()
            _ = releaseQueue.wait(timeout: .now() + 5)
        }
        #expect(queueEntered.wait(timeout: .now() + 2) == .success)

        let startedAt = Date()
        Babylon.stop()
        let stopDuration = Date().timeIntervalSince(startedAt)
        releaseQueue.signal()

        #expect(stopDuration < 0.5)
        #expect(transport.waitForStopCall(timeout: 2))
        let packages = decodedRuntimePackages(from: transport)
        let kinds = packages.map(\.kind)
        let stepFinishedIndex = kinds.firstIndex(of: .stepFinished)
        let traceFinishedIndex = kinds.firstIndex(of: .traceFinished)
        let sessionFinishedIndex = kinds.firstIndex(of: .sessionFinished)

        #expect(stepFinishedIndex != nil)
        #expect(traceFinishedIndex != nil)
        #expect(sessionFinishedIndex != nil)
        if let stepFinishedIndex, let traceFinishedIndex, let sessionFinishedIndex {
            #expect(stepFinishedIndex < traceFinishedIndex)
            #expect(traceFinishedIndex < sessionFinishedIndex)
        }
    }

    @Test("Manual HTTP package includes active correlation context")
    func manualTrafficIncludesCorrelationContext() throws {
        let transport = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        _ = Babylon.startTrace("Checkout")
        let url = try #require(URL(string: "https://example.com/cart"))
        let request = URLRequest(url: url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        ))

        Babylon.add(request: request, response: response, responseBody: nil)

        let traffic = try waitForTrafficPackage(from: transport)
        #expect(traffic?.correlationContext?.traceId != nil)
        #expect(traffic?.correlationContext?.sessionId != nil)
        #expect(traffic?.correlationContext?.stepId != nil)
    }

    @Test("Task package keeps context from task creation after a later step")
    func taskCreationContextWinsOverLaterStep() throws {
        let transport = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let trace = Babylon.startTrace("Checkout")
        let originalContext = try #require(trace.correlationContext)
        let url = try #require(URL(string: "https://example.com/cart"))
        let task = URLSession.shared.dataTask(with: URLRequest(url: url))
        Babylon.shared.injectorSessionDidCreateTask(task: task, correlationContext: originalContext)

        trace.step("Payment")

        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        ))
        Babylon.shared.injectorSessionDidCallResume(task: task)
        Babylon.shared.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        Babylon.shared.injectorSessionDidComplete(task: task, error: nil)

        let traffic = try waitForTrafficPackage(from: transport)
        #expect(traffic?.correlationContext == originalContext)
        task.cancel()
    }

    @Test("Legacy inference is available only when one trace is active")
    func legacyInferenceRequiresUnambiguousTrace() throws {
        _ = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let first = Babylon.startTrace("First")
        let firstContext = try #require(Babylon.currentCorrelationContext)
        let second = Babylon.startTrace("Second")
        first.step("First Step")
        #expect(Babylon.currentCorrelationContext == nil)

        second.finish()
        let contextAfterSecondFinishes = try #require(Babylon.currentCorrelationContext)
        #expect(contextAfterSecondFinishes.traceId == first.correlationContext?.traceId)
        #expect(firstContext.traceId == first.correlationContext?.traceId)
    }

    @Test("Scoped contexts isolate interleaved traces and inherit into child tasks")
    func scopedConcurrentTraceContexts() async throws {
        _ = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let first = Babylon.startTrace("Checkout")
        let second = Babylon.startTrace("Background Sync")
        let firstID = try #require(first.correlationContext?.traceId)
        let secondID = try #require(second.correlationContext?.traceId)

        let results = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await Babylon.withTrace(first) {
                    await Task.yield()
                    return await withTaskGroup(of: String?.self) { childTasks in
                        childTasks.addTask { Babylon.currentCorrelationContext?.traceId }
                        return await childTasks.next() ?? nil
                    }
                }
            }
            group.addTask {
                await Babylon.withTrace(second) {
                    await Task.yield()
                    return await withTaskGroup(of: String?.self) { childTasks in
                        childTasks.addTask { Babylon.currentCorrelationContext?.traceId }
                        return await childTasks.next() ?? nil
                    }
                }
            }

            var values: Set<String> = []
            for await traceID in group {
                if let traceID {
                    values.insert(traceID)
                }
            }
            return values
        }

        #expect(results == [firstID, secondID])
        #expect(Babylon.currentCorrelationContext == nil)
    }

    @Test("Explicit context propagates to detached and callback work")
    func explicitContextPropagation() async throws {
        _ = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let trace = Babylon.startTrace("Checkout")
        _ = Babylon.startTrace("Background Sync")
        let context = try #require(trace.correlationContext)
        let detachedContext = await Task.detached {
            Babylon.withTraceContext(context) {
                Babylon.currentCorrelationContext
            }
        }.value
        let callbackQueue = DispatchQueue(label: "BabylonRuntimeTests.explicit-context")
        let callbackContext = callbackQueue.sync {
            Babylon.withTraceContext(context) {
                Babylon.currentCorrelationContext
            }
        }

        #expect(detachedContext == context)
        #expect(callbackContext == context)
        #expect(Babylon.currentCorrelationContext == nil)
    }

    @Test("Task creation snapshots scoped context without mutating requests")
    func scopedTaskCreationSnapshotDoesNotMutateRequest() throws {
        _ = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let first = Babylon.startTrace("Checkout")
        _ = Babylon.startTrace("Background Sync")
        let url = try #require(URL(string: "https://example.com/cart"))
        var request = URLRequest(url: url)
        request.setValue("caller-value", forHTTPHeaderField: "X-Correlation")

        let correlated = Babylon.withTrace(first) {
            Babylon.shared.injectorSessionWillCreateTask(request: request)
        }

        #expect(correlated.correlationContext?.traceId == first.correlationContext?.traceId)
        #expect(correlated.request == request)
        #expect(correlated.request.value(forHTTPHeaderField: "X-Correlation") == "caller-value")
    }

    @Test("Ambiguous nil context stays unset when a URLSession task resumes later")
    func ambiguousTaskSnapshotDoesNotAcquireLaterTrace() throws {
        let transport = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let first = Babylon.startTrace("Checkout")
        let second = Babylon.startTrace("Background Sync")
        let url = try #require(URL(string: "https://example.com/cart"))
        let task = URLSession.shared.dataTask(with: URLRequest(url: url))
        let creation = Babylon.shared.injectorSessionWillCreateTask(request: URLRequest(url: url))
        #expect(creation.correlationContext == nil)
        Babylon.shared.injectorSessionDidCreateTask(task: task, correlationContext: creation.correlationContext)

        second.finish()
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        ))
        Babylon.shared.injectorSessionDidCallResume(task: task)
        Babylon.shared.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        Babylon.shared.injectorSessionDidComplete(task: task, error: nil)

        let traffic = try waitForTrafficPackage(from: transport)
        #expect(traffic?.correlationContext == nil)
        #expect(Babylon.currentCorrelationContext?.traceId == first.correlationContext?.traceId)
        task.cancel()
    }

    @Test("Old explicit contexts do not cross a stop and restart boundary")
    func contextDoesNotCrossSessionRestart() throws {
        _ = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let oldTrace = Babylon.startTrace("Old Session")
        let oldContext = try #require(oldTrace.correlationContext)

        Babylon.stop()
        let transport = MockTransporter()
        Babylon.setTransporterForTesting(transport)
        Babylon.start()
        let newTrace = Babylon.startTrace("New Session")

        let resolved = Babylon.withTraceContext(oldContext) {
            Babylon.currentCorrelationContext
        }
        #expect(resolved == nil)
        #expect(Babylon.currentCorrelationContext?.sessionId != oldContext.sessionId)
        newTrace.finish()
    }

    @Test("Cancelled scoped work does not leak context to its parent")
    func cancelledScopeDoesNotLeak() async {
        _ = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let trace = Babylon.startTrace("Checkout")
        _ = Babylon.startTrace("Background Sync")
        let task = Task {
            await Babylon.withTrace(trace) {
                try? await Task.sleep(for: .seconds(30))
                return Babylon.currentCorrelationContext
            }
        }
        task.cancel()
        let taskContext = await task.value

        #expect(taskContext?.traceId == trace.correlationContext?.traceId)
        #expect(Babylon.currentCorrelationContext == nil)
    }

    @Test("Concurrent runtime calls do not crash")
    func concurrentRuntimeCalls() {
        _ = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        DispatchQueue.concurrentPerform(iterations: 20) { index in
            let trace = Babylon.startTrace("Trace \(index)")
            trace.step("Step \(index)")
            Babylon.event("Event \(index)")
            trace.finish()
        }

        #expect(true)
    }

    private func startRuntimeCapture() -> MockTransporter {
        Babylon.stop()
        let transport = MockTransporter()
        Babylon.setTransporterForTesting(transport)
        Babylon.setEnableTransportLayer(true)
        Babylon.setIsRunningOniOSPlayground(true)
        Babylon.start()
        return transport
    }

    private func stopRuntimeCapture() {
        Babylon.stop()
        Babylon.setIsRunningOniOSPlayground(false)
        Babylon.setEnableTransportLayer(true)
    }

    private func decodedRuntimePackages(from transport: MockTransporter) -> [RuntimePackage] {
        transport.sentPackages.compactMap { package in
            guard let message = package as? Message else { return nil }
            return try? decodeMessageContent(RuntimePackage.self, from: message)
        }
    }

    private func waitForTrafficPackage(from transport: MockTransporter) throws -> TrafficPackage? {
        for _ in 0 ..< 20 {
            if let package = transport.sentPackages.compactMap({ package -> TrafficPackage? in
                guard let message = package as? Message else { return nil }
                return try? decodeMessageContent(TrafficPackage.self, from: message)
            }).first {
                return package
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func decodeMessageContent<T: Decodable>(_ type: T.Type, from message: Message) throws -> T {
        let content = try #require(message.payloadData)
        return try JSONDecoder().decode(type, from: content)
    }
}
