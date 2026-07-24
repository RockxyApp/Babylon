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
        let originalContext = try #require(Babylon.shared.activeCorrelationContextSnapshot())
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

    @Test("Most recently stepped unfinished trace becomes active context")
    func lastSteppedTraceWins() throws {
        _ = startRuntimeCapture()
        defer { stopRuntimeCapture() }

        let first = Babylon.startTrace("First")
        let second = Babylon.startTrace("Second")
        first.step("First Step")
        let contextAfterFirstStep = try #require(Babylon.shared.activeCorrelationContextSnapshot())

        second.step("Second Step")
        let contextAfterSecondStep = try #require(Babylon.shared.activeCorrelationContextSnapshot())

        #expect(contextAfterFirstStep.traceId != contextAfterSecondStep.traceId)
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
