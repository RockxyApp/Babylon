import Foundation
@testable import Babylon

let testPairingToken = String(repeating: "a", count: 64)
let alternateTestPairingToken = String(repeating: "b", count: 64)

// MARK: - MockInjectorDelegate

/// Records all ``InjectorDelegate`` callbacks with their method name and arguments
/// for verification in tests.
final class MockInjectorDelegate: InjectorDelegate {
    struct Call {
        let method: String
        let arguments: [String: Any]
    }

    private let queue = DispatchQueue(label: "com.amunx.babylon.tests.mockinjector")
    private var _calls: [Call] = []

    var calls: [Call] {
        queue.sync { _calls }
    }

    private func record(_ method: String, _ arguments: [String: Any] = [:]) {
        queue.sync {
            _calls.append(Call(method: method, arguments: arguments))
        }
    }

    func injectorSessionWillCreateTask(request: URLRequest) -> CorrelatedURLRequest {
        record("injectorSessionWillCreateTask", ["request": request])
        return CorrelatedURLRequest(request: request, correlationContext: nil)
    }

    func injectorSessionDidCreateTask(
        task: URLSessionTask,
        correlationContext: CorrelationContext?,
        capturePolicyDecision: CapturePolicyDecision = .included
    ) {
        var args: [String: Any] = ["task": task]
        if let correlationContext {
            args["correlationContext"] = correlationContext
        }
        record("injectorSessionDidCreateTask", args)
    }

    func injectorSessionDidCallResume(task: URLSessionTask) {
        record("injectorSessionDidCallResume", ["task": task])
    }

    func injectorSessionDidReceiveResponse(dataTask: URLSessionTask, response: URLResponse) {
        record("injectorSessionDidReceiveResponse", ["dataTask": dataTask, "response": response])
    }

    func injectorSessionDidReceiveData(dataTask: URLSessionTask, data: Data) {
        record("injectorSessionDidReceiveData", ["dataTask": dataTask, "data": data])
    }

    func injectorSessionDidComplete(task: URLSessionTask, error: Error?) {
        var args: [String: Any] = ["task": task]
        if let error {
            args["error"] = error
        }
        record("injectorSessionDidComplete", args)
    }

    func injectorSessionDidCollectMetrics(task: URLSessionTask, metrics: URLSessionTaskMetrics) {
        record("injectorSessionDidCollectMetrics", ["task": task, "metrics": metrics])
    }

    func injectorSessionDidUpload(task: URLSessionTask, request: NSURLRequest, data: Data?) {
        var args: [String: Any] = ["task": task, "request": request]
        if let data {
            args["data"] = data
        }
        record("injectorSessionDidUpload", args)
    }

    func injectorSessionWebSocketDidSendMessage(task: URLSessionTask, message: URLSessionWebSocketTask.Message) {
        record("injectorSessionWebSocketDidSendMessage", ["task": task, "message": message])
    }

    func injectorSessionWebSocketDidReceive(task: URLSessionTask, message: URLSessionWebSocketTask.Message) {
        record("injectorSessionWebSocketDidReceive", ["task": task, "message": message])
    }

    func injectorSessionWebSocketWillReceive(task: URLSessionWebSocketTask) {
        record("injectorSessionWebSocketWillReceive", ["task": task])
    }

    func injectorSessionWebSocketDidCompleteReceive(task: URLSessionWebSocketTask, error: Error?) {
        record("injectorSessionWebSocketDidCompleteReceive", ["task": task, "error": error as Any])
    }

    func injectorSessionWebSocketDidReceiveClose(task: URLSessionWebSocketTask, error: Error) {
        record("injectorSessionWebSocketDidReceiveClose", ["task": task, "error": error])
    }

    func injectorSessionWebSocketDidSendPingPong(task: URLSessionTask) {
        record("injectorSessionWebSocketDidSendPingPong", ["task": task])
    }

    func injectorSessionWebSocketDidReceivePong(task: URLSessionTask) {
        record("injectorSessionWebSocketDidReceivePong", ["task": task])
    }

    func injectorSessionWebSocketDidSendCancelWithReason(
        task: URLSessionTask,
        closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        var args: [String: Any] = ["task": task, "closeCode": closeCode]
        if let reason {
            args["reason"] = reason
        }
        record("injectorSessionWebSocketDidSendCancelWithReason", args)
    }
}

// MARK: - CapturingBabylonDelegate

/// Records ``TrafficPackage`` deliveries and signals via ``DispatchSemaphore``
/// so tests can wait for asynchronous delegate calls.
final class CapturingBabylonDelegate: BabylonDelegate {
    private let queue = DispatchQueue(label: "com.amunx.babylon.tests.capturingdelegate")
    private var _packages: [TrafficPackage] = []
    let semaphore = DispatchSemaphore(value: 0)

    var packages: [TrafficPackage] {
        queue.sync { _packages }
    }

    func babylonDidCapturePackage(_ package: TrafficPackage) {
        queue.sync {
            _packages.append(package)
        }
        semaphore.signal()
    }
}

// MARK: - MockTransporter

/// A mock ``Transporter`` that captures sent ``Serializable`` items without
/// performing any network operations.
final class MockTransporter: Transporter {
    private let queue = DispatchQueue(label: "com.amunx.babylon.tests.mocktransporter")
    private var _sentPackages: [Serializable] = []
    private let stopped = DispatchSemaphore(value: 0)
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastConfig: Configuration?

    var sentPackages: [Serializable] {
        queue.sync { _sentPackages }
    }

    func start(_ config: Configuration) {
        queue.sync {
            startCallCount += 1
            lastConfig = config
        }
    }

    func stop() {
        queue.sync {
            stopCallCount += 1
        }
        stopped.signal()
    }

    func send(package: Serializable) {
        queue.sync {
            _sentPackages.append(package)
        }
    }

    func waitForStopCall(timeout: TimeInterval) -> Bool {
        stopped.wait(timeout: .now() + timeout) == .success
    }
}
