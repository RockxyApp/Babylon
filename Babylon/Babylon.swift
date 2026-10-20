// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ObjectiveC
import os

#if os(iOS)
import UIKit
#endif

public protocol BabylonDelegate: AnyObject {
    func babylonDidCapturePackage(_ package: TrafficPackage)
}

final class CaptureLedger {
    private(set) var deferredFrameCount = 0
    private(set) var deferredFrameBytes = 0
    var generation: UInt64 = 0
    var traffic: [String: TrafficPackage] = [:]
    var deferredFrames: [String: [WebsocketMessagePackage]] = [:]
    var deferredFrameLeases: [String: [CaptureMemoryLease]] = [:]
    var localCloseTasks: Set<String> = []
    var remoteCloseTasks: Set<String> = []
    var pendingRemoteCloseTasks: Set<String> = []
    var webSocketReceiveCounts: [String: Int] = [:]
    var ignored: Set<String> = []
    var startedAt: [String: TimeInterval] = [:]
    var taskGeneration: [String: UInt64] = [:]
    var taskCaptureDecisions: [String: CapturePolicyDecision] = [:]

    func beginGeneration() {
        generation &+= 1
        clear()
    }

    func clear() {
        traffic.removeAll()
        deferredFrames.removeAll()
        deferredFrameLeases.removeAll()
        localCloseTasks.removeAll()
        remoteCloseTasks.removeAll()
        pendingRemoteCloseTasks.removeAll()
        webSocketReceiveCounts.removeAll()
        deferredFrameCount = 0
        deferredFrameBytes = 0
        ignored.removeAll()
        startedAt.removeAll()
        taskGeneration.removeAll()
        taskCaptureDecisions.removeAll()
    }

    func enroll(_ id: String) {
        if taskGeneration[id] == nil {
            taskGeneration[id] = generation
        }
    }

    func belongsToCurrentGeneration(_ id: String) -> Bool {
        taskGeneration[id] == generation
    }

    func deferFrame(_ frame: WebsocketMessagePackage, for id: String) {
        var frames = deferredFrames[id] ?? []
        let taskBytes = frames.reduce(0) { $0 + $1.captureMemoryEstimate }
        guard frames.count < BabylonConstants.maxPendingItems,
              frame.captureMemoryEstimate <= BabylonConstants.maximumDeferredWebSocketBytesPerTask - taskBytes,
              deferredFrameCount < BabylonConstants.maximumDeferredWebSocketFrames,
              frame.captureMemoryEstimate <= BabylonConstants.maximumDeferredWebSocketBytes - deferredFrameBytes,
              let lease = CaptureMemoryBudget.shared.reserve(frame.captureMemoryEstimate) else {
            return
        }
        frames.append(frame)
        deferredFrames[id] = frames
        deferredFrameLeases[id, default: []].append(lease)
        deferredFrameCount += 1
        deferredFrameBytes += frame.captureMemoryEstimate
    }

    func takeDeferredFrames(for id: String) -> [WebsocketMessagePackage] {
        guard let frames = deferredFrames.removeValue(forKey: id) else { return [] }
        deferredFrameCount -= frames.count
        deferredFrameBytes -= frames.reduce(0) { $0 + $1.captureMemoryEstimate }
        deferredFrameLeases.removeValue(forKey: id)
        return frames
    }

    func markLocalClose(for id: String) {
        localCloseTasks.insert(id)
    }

    func markRemoteClose(for id: String) {
        remoteCloseTasks.insert(id)
    }

    func beginWebSocketReceive(for id: String) {
        webSocketReceiveCounts[id, default: 0] += 1
    }

    func completeWebSocketReceive(for id: String) {
        let count = webSocketReceiveCounts[id, default: 0]
        if count <= 1 {
            webSocketReceiveCounts.removeValue(forKey: id)
        } else {
            webSocketReceiveCounts[id] = count - 1
        }
    }

    func markPendingRemoteClose(for id: String) {
        pendingRemoteCloseTasks.insert(id)
    }

    func forget(_ id: String) {
        traffic.removeValue(forKey: id)
        if let frames = deferredFrames.removeValue(forKey: id) {
            deferredFrameCount -= frames.count
            deferredFrameBytes -= frames.reduce(0) { $0 + $1.captureMemoryEstimate }
        }
        deferredFrameLeases.removeValue(forKey: id)
        localCloseTasks.remove(id)
        remoteCloseTasks.remove(id)
        pendingRemoteCloseTasks.remove(id)
        webSocketReceiveCounts.removeValue(forKey: id)
        taskGeneration.removeValue(forKey: id)
        taskCaptureDecisions.removeValue(forKey: id)
        ignored.remove(id)
        startedAt.removeValue(forKey: id)
    }
}

@objc
public final class Babylon: NSObject {
    static let shared = Babylon()
    static var isEnabled = Atomic<Bool>(false)
    private static let defaultRedactedHeaders: Set = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "x-auth-token"
    ]
    private static let defaultRedactedQueryItems: Set = [
        "access_token",
        "api_key",
        "apikey",
        "auth",
        "code",
        "key",
        "password",
        "secret",
        "sig",
        "signature",
        "token"
    ]

    private static let logger = Logger(subsystem: "com.amunx.Babylon", category: "Babylon")
    private weak var delegate: BabylonDelegate?
    private var transporter: Transporter
    private var injector: Injector = NetworkInjector()
    private let ledger = CaptureLedger()
    let encodingQueue = BoundedCaptureWorkQueue(label: "com.amunx.babylon.encoding")
    private let encodingGeneration = Atomic<UInt64>(0)
    private let activeClientID = Atomic<String>("")
    private let capturesWebSocketTraffic = Atomic<Bool>(false)
    private var ignoredProtocolClasses: [AnyClass] = []
    private let transportEnabled = Atomic<Bool>(true)
    private let playgroundMode = Atomic<Bool>(false)
    private let redactedHeaderKeys = Atomic<Set<String>>(Babylon.defaultRedactedHeaders)
    private let redactedQueryKeys = Atomic<Set<String>>(Babylon.defaultRedactedQueryItems)
    private var capturePolicy = CapturePolicy()
    private(set) var captureOmissions: [CaptureOmission] = []
    private struct PendingWebSocketCompletion {
        let task: URLSessionTask
        let error: Error?
    }

    private struct PendingMetricsCompletion {
        let workItem: DispatchWorkItem
        let task: URLSessionTask
        let error: Error?
        let package: TrafficPackage
    }

    private var pendingWebSocketCompletions: [String: PendingWebSocketCompletion] = [:]
    private var pendingMetricsCompletions: [String: PendingMetricsCompletion] = [:]

    private(set) var configuration = Configuration.default()
    let queue = DispatchQueue(label: "com.amunx.babylon")
    let traceContextStore = TraceContextStore()

    var deferredWebSocketFrameCountForTesting: Int {
        queue.sync { ledger.deferredFrameCount }
    }

    var pendingMetricsCompletionCountForTesting: Int {
        queue.sync { pendingMetricsCompletions.count }
    }

    func trafficPackageForTesting(_ task: URLSessionTask) -> TrafficPackage? {
        queue.sync { ledger.traffic[PackageIdentifier.getID(for: task)] }
    }

    func handleMemoryPressureForTesting() {
        handleMemoryPressure()
    }

    private override init() {
        transporter = NetServiceTransport()
        super.init()
        injector.delegate = self
        observeMemoryPressure()
    }

    @objc
    public class func start(
        hostName: String? = nil,
        shouldCaptureWebSocketTraffic: Bool = true
    ) {
        activate(
            hostName: hostName,
            authToken: nil,
            capturesWebSockets: shouldCaptureWebSocketTraffic,
            capturePolicy: CapturePolicy()
        )
    }

    public class func start(
        hostName: String? = nil,
        shouldCaptureWebSocketTraffic: Bool = true,
        capturePolicy: CapturePolicy
    ) {
        activate(
            hostName: hostName,
            authToken: nil,
            capturesWebSockets: shouldCaptureWebSocketTraffic,
            capturePolicy: capturePolicy
        )
    }

    @objc(startWithAuthToken:hostName:shouldCaptureWebSocketTraffic:)
    public class func start(
        authToken: String,
        hostName: String? = nil,
        shouldCaptureWebSocketTraffic: Bool = true
    ) {
        activate(
            hostName: hostName,
            authToken: authToken,
            capturesWebSockets: shouldCaptureWebSocketTraffic,
            capturePolicy: CapturePolicy()
        )
    }

    public class func start(
        authToken: String,
        hostName: String? = nil,
        shouldCaptureWebSocketTraffic: Bool = true,
        capturePolicy: CapturePolicy
    ) {
        activate(
            hostName: hostName,
            authToken: authToken,
            capturesWebSockets: shouldCaptureWebSocketTraffic,
            capturePolicy: capturePolicy
        )
    }

    private class func activate(
        hostName: String?,
        authToken: String?,
        capturesWebSockets: Bool,
        capturePolicy: CapturePolicy
    ) {
        #if DEBUG
        let instance = Babylon.shared
        let newConfiguration = Configuration.default(hostName: hostName, authToken: authToken)

        let shouldStartTransport = instance.transportEnabled.value && newConfiguration.authToken != nil
        if shouldStartTransport {
            guard newConfiguration.hasValidAuthentication else {
                logger.error("Babylon pairing token must be 64 lowercase hexadecimal characters")
                return
            }
            instance.logHostRequirements()
            guard isDiscoveryAvailable else { return }
        }
        guard isEnabled.compareExchange(expected: false, desired: true) else { return }
        _ = instance.capturesWebSocketTraffic.exchange(capturesWebSockets)

        let sessionMessage = instance.queue.sync { () -> RuntimePackage? in
            instance.configuration = newConfiguration
            instance.capturePolicy = capturePolicy
            instance.captureOmissions.removeAll(keepingCapacity: true)
            _ = instance.activeClientID.exchange(newConfiguration.clientID)
            instance.pendingWebSocketCompletions.removeAll()
            instance.ledger.beginGeneration()
            return instance.traceContextStore.startSession(
                name: newConfiguration.projectName,
                metadata: [:]
            )
        }

        instance.injector.injectAllNetworkCalls(
            NetworkConfiguration(shouldCaptureWebSocketTraffic: capturesWebSockets)
        )
        if shouldStartTransport {
            instance.transporter.start(newConfiguration)
        }
        instance.startSendingRuntimeMessages(packages: sessionMessage.map { [$0] } ?? [])
        #else
        logger.error("Babylon can only be activated by a DEBUG build")
        #endif
    }

    @objc
    public class func stop() {
        guard isEnabled.compareExchange(expected: true, desired: false) else { return }
        let instance = Babylon.shared
        _ = instance.capturesWebSocketTraffic.exchange(false)
        let transport = instance.transporter
        _ = instance.activeClientID.exchange("")
        instance.invalidateEncodingWork()
        instance.queue.async {
            let configuration = instance.configuration
            for pending in instance.pendingMetricsCompletions.values {
                pending.workItem.cancel()
                instance.completeCapturedTask(pending.task, error: pending.error, capture: pending.package)
            }
            instance.pendingMetricsCompletions.removeAll()
            let closingPackages = instance.traceContextStore.finishSession(
                name: configuration.projectName,
                metadata: [:]
            )
            let closingMessages = instance.transportEnabled.value
                ? closingPackages.compactMap { Message.buildRuntimeMessage(id: configuration.id, item: $0) }
                : []
            instance.configuration = .default()
            instance.capturePolicy = CapturePolicy()
            instance.ledger.clear()
            instance.pendingWebSocketCompletions.removeAll()
            instance.traceContextStore.clear()
            transport.stop(
                afterSending: closingMessages,
                deadline: BabylonConstants.gracefulTransportDrainDeadline
            )
        }
    }

    public class func setDelegate(_ delegate: BabylonDelegate) {
        Babylon.shared.queue.sync { Babylon.shared.delegate = delegate }
    }

    public class func setIgnoreProtocols(_ protocols: [AnyClass]) {
        Babylon.shared.queue.sync { Babylon.shared.ignoredProtocolClasses = protocols }
    }

    public class func setEnableTransportLayer(_ isEnabled: Bool) {
        let instance = Babylon.shared
        let wasEnabled = instance.transportEnabled.exchange(isEnabled)
        guard wasEnabled != isEnabled else { return }
        if !isEnabled {
            instance.transporter.stop()
        } else {
            let configuration = instance.queue.sync { instance.configuration }
            if Babylon.isEnabled.value,
               configuration.hasValidAuthentication,
               Babylon.isDiscoveryAvailable {
                instance.transporter.start(configuration)
            }
        }
    }

    public class func setIsRunningOniOSPlayground(_ isEnabled: Bool) {
        Babylon.shared.playgroundMode.mutate { $0 = isEnabled }
    }

    public class func setRedactedHeaders(_ keys: Set<String>) {
        Babylon.shared.redactedHeaderKeys.mutate {
            $0 = Babylon.defaultRedactedHeaders.union(keys.lazy.map { $0.lowercased() })
        }
    }

    public class func setRedactedQueryItems(_ keys: Set<String>) {
        Babylon.shared.redactedQueryKeys.mutate {
            $0 = Babylon.defaultRedactedQueryItems.union(keys.lazy.map { $0.lowercased() })
        }
    }

    private static var isDiscoveryAvailable: Bool {
        #if os(iOS)
        if Babylon.shared.playgroundMode.value {
            return true
        }
        if #available(iOS 14, *) {
            return Bundle.main.hasBonjourServices && Bundle.main.hasLocalNetworkUsageDescription
        }
        #endif
        return true
    }
}

#if DEBUG
extension Babylon {
    static func setTransporterForTesting(_ transporter: Transporter) {
        retainedTestTransporters.append(Babylon.shared.transporter)
        Babylon.shared.transporter = transporter
    }
}

private var retainedTestTransporters: [Transporter] = []
#endif

extension Babylon {
    var redactedHeaderKeysSnapshot: Set<String> {
        redactedHeaderKeys.value
    }

    var redactedQueryKeysSnapshot: Set<String> {
        redactedQueryKeys.value
    }

    func recordCaptureOmission(reason: CapturePolicyDecision.OmissionReason, observedBytes: Int) {
        guard captureOmissions.count < 256 else { return }
        captureOmissions.append(CaptureOmission(reason: reason, observedBytes: observedBytes))
    }

    func logHostRequirements() {
        if Babylon.isDiscoveryAvailable {
            Babylon.logger.info("Babylon (BabylonConstants.buildVersion) is active")
        }
        if playgroundMode.value {
            Babylon.logger.info("Local-network checks skipped for playground mode")
            return
        }

        #if os(iOS)
        if #available(iOS 14, *) {
            var missing: [String] = []
            if !Bundle.main.hasLocalNetworkUsageDescription {
                missing.append("NSLocalNetworkUsageDescription")
            }
            if !Bundle.main.hasBonjourServices {
                missing.append("NSBonjourServices with \(BabylonConstants.serviceType)")
            }
            if !missing.isEmpty {
                Babylon.logger.warning("Missing Info.plist keys: \(missing.joined(separator: ", "))")
            }
        }
        #endif
    }

    func package(for object: AnyObject, completing: Bool = false) -> TrafficPackage? {
        let id = PackageIdentifier.getID(for: object)
        guard ledger.belongsToCurrentGeneration(id) else { return nil }

        if ledger.ignored.contains(id) {
            if completing {
                ledger.ignored.remove(id)
            }
            return nil
        }
        if let existing = ledger.traffic[id] {
            return existing
        }
        guard let task = object as? URLSessionTask,
              let request = task.currentRequestSafe else {
            Babylon.logger.error("Unable to create capture package for \(String(describing: type(of: object)))")
            return nil
        }
        let decision = ledger.taskCaptureDecisions[id] ?? capturePolicy.decision(for: request)
        guard decision.included else {
            recordCaptureOmission(reason: decision.reason ?? .rule, observedBytes: request.httpBody?.count ?? 0)
            ledger.ignored.insert(id)
            return nil
        }
        guard let created = TrafficPackage.buildRequest(
            sessionTask: task,
            id: id,
            maximumRequestBodyBytes: capturePolicy.maximumRequestBodyBytes,
            metadataOnly: capturePolicy.metadataOnly
        ) else {
            Babylon.logger.error("Unable to create capture package for \(String(describing: type(of: object)))")
            return nil
        }
        created.setCorrelationContext(traceContextStore.correlationContext(forPackageId: id))
        created.configureCaptureLimits(
            requestBytes: capturePolicy.maximumRequestBodyBytes,
            responseBytes: capturePolicy.maximumResponseBodyBytes,
            metadataOnly: capturePolicy.metadataOnly,
            policy: capturePolicy,
            request: request,
            observedRequestBodyBytes: task.originalRequestBodySafe?.count ?? request.httpBody?.count
        )
        if isIgnored(request, from: task) {
            ledger.ignored.insert(id)
            return nil
        }
        guard created.admitCapture() else {
            ledger.ignored.insert(id)
            Babylon.logger.info("Capture omitted after the shared memory budget was reached")
            return nil
        }
        ledger.traffic[id] = created
        return created
    }

    func isIgnored(_ request: URLRequest, from task: URLSessionTask) -> Bool {
        guard !ignoredProtocolClasses.isEmpty else { return false }
        let sessionSelector = NSSelectorFromString("session")
        guard let session = Runtime.object(from: task, selector: sessionSelector, as: URLSession.self) else { return false }

        let configuredNames = Set((session.configuration.protocolClasses ?? []).map(NSStringFromClass))
        let ignoredNames = Set(ignoredProtocolClasses.map(NSStringFromClass))
        let matchingClasses = configuredNames.intersection(ignoredNames).compactMap(NSClassFromString)
        return matchingClasses.contains { protocolClass in
            let selector = NSSelectorFromString("canInitWithRequest:")
            guard let method = class_getClassMethod(protocolClass, selector) else {
                Babylon.logger.warning("Ignored URLProtocol has no canInitWithRequest: selector")
                return false
            }
            typealias Function = @convention(c) (AnyClass, Selector, NSURLRequest) -> Bool
            let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
            return function(protocolClass, selector, request as NSURLRequest)
        }
    }

    func ensureCorrelation(for id: String) {
        if !traceContextStore.hasCapturedCorrelationContext(forPackageId: id) {
            traceContextStore.setCorrelationContext(traceContextStore.activeCorrelationContext(), forPackageId: id)
        }
    }
}

extension Babylon {
    func scheduleManualCapture(_ operation: @escaping (CorrelationContext?) -> Void) {
        guard Babylon.isEnabled.value else { return }
        let scope = BabylonTraceScope.current
        let (generation, context) = queue.sync {
            (ledger.generation, traceContextStore.activeCorrelationContext(scope: scope))
        }
        queue.async { [weak self] in
            guard let self,
                  Babylon.isEnabled.value,
                  generation == ledger.generation else { return }
            operation(context)
        }
    }
}

extension Babylon: InjectorDelegate {
    func injectorSessionWillCreateTask(request: URLRequest) -> CorrelatedURLRequest {
        let scope = BabylonTraceScope.current
        return queue.sync {
            let context = Babylon.isEnabled.value ? traceContextStore.activeCorrelationContext(scope: scope) : nil
            let decision = Babylon.isEnabled.value ? capturePolicy.decision(for: request) : .included
            if !decision.included {
                recordCaptureOmission(
                    reason: decision.reason ?? .rule,
                    observedBytes: min(request.httpBody?.count ?? 0, BabylonConstants.maximumBodySize * 1024)
                )
            }
            return CorrelatedURLRequest(request: request, correlationContext: context, capturePolicyDecision: decision)
        }
    }

    func injectorSessionDidCreateTask(
        task: URLSessionTask,
        correlationContext: CorrelationContext?,
        capturePolicyDecision: CapturePolicyDecision = .included
    ) {
        queue.sync {
            guard Babylon.isEnabled.value else { return }
            let id = PackageIdentifier.getID(for: task)
            ledger.enroll(id)
            ledger.taskCaptureDecisions[id] = capturePolicyDecision
            if !capturePolicyDecision.included {
                ledger.ignored.insert(id)
            }
            traceContextStore.setCorrelationContext(correlationContext, forPackageId: id)
        }
    }

    func injectorSessionDidCallResume(task: URLSessionTask) {
        queue.sync {
            guard Babylon.isEnabled.value else { return }
            let id = PackageIdentifier.getID(for: task)
            ledger.enroll(id)
            if ledger.startedAt[id] == nil {
                ledger.startedAt[id] = Date().timeIntervalSince1970
            }
            ensureCorrelation(for: id)
        }
    }

    func injectorSessionDidReceiveResponse(dataTask: URLSessionTask, response: URLResponse) {
        queue.sync {
            guard Babylon.isEnabled.value else { return }
            let id = PackageIdentifier.getID(for: dataTask)
            let capture = package(for: dataTask)
            if let timestamp = ledger.startedAt[id] {
                capture?.updateStartTime(timestamp)
            }
            capture?.updateResponse(response)
            if (dataTask as? URLSessionWebSocketTask) != nil, capture?.response != nil {
                flushWebSocketFrames(for: id)
            }
        }
    }

    func injectorSessionDidReceiveData(dataTask: URLSessionTask, data: Data) {
        queue.sync {
            guard Babylon.isEnabled.value else { return }
            package(for: dataTask)?.appendResponseData(data)
        }
    }

    func injectorSessionDidComplete(task: URLSessionTask, error: Error?) {
        if let webSocketTask = task as? URLSessionWebSocketTask,
           error == nil,
           webSocketTask.closeCode == .invalid {
            return
        }
        finish(task, error: error)
    }

    func injectorSessionDidCollectMetrics(task: URLSessionTask, metrics: URLSessionTaskMetrics) {
        guard let timing = URLSessionTiming.capture(metrics) else { return }
        queue.sync {
            guard Babylon.isEnabled.value else { return }
            let id = PackageIdentifier.getID(for: task)
            guard let capture = package(for: task) else { return }
            capture.setURLSessionTiming(timing)
            guard let pending = pendingMetricsCompletions.removeValue(forKey: id) else { return }
            pending.workItem.cancel()
            completeCapturedTask(pending.task, error: pending.error, capture: pending.package)
        }
    }

    func injectorSessionDidUpload(task: URLSessionTask, request: NSURLRequest, data: Data?) {
        queue.sync {
            guard Babylon.isEnabled.value else { return }
            let id = PackageIdentifier.getID(for: task)
            ledger.enroll(id)
            let capture = package(for: task)
            if let data {
                capture?.appendRequestData(data)
            }
            ensureCorrelation(for: id)
            capture?.setCorrelationContext(traceContextStore.correlationContext(forPackageId: id))
        }
    }
}

extension Babylon {
    func injectorSessionWebSocketDidSendPingPong(task: URLSessionTask) {
        guard capturesWebSocketTraffic.value else { return }
        deliverWebSocket(task, kind: .ping, message: .string("ping"))
    }

    func injectorSessionWebSocketDidReceivePong(task: URLSessionTask) {
        guard capturesWebSocketTraffic.value else { return }
        deliverWebSocket(task, kind: .pong, message: .string(""))
    }

    func injectorSessionWebSocketDidReceive(task: URLSessionTask, message: URLSessionWebSocketTask.Message) {
        guard capturesWebSocketTraffic.value else { return }
        deliverWebSocket(task, kind: .receive, message: message)
    }

    func injectorSessionWebSocketWillReceive(task: URLSessionWebSocketTask) {
        queue.sync {
            guard Babylon.isEnabled.value, capturesWebSocketTraffic.value else { return }
            let id = PackageIdentifier.getID(for: task)
            ledger.beginWebSocketReceive(for: id)
        }
    }

    func injectorSessionWebSocketDidCompleteReceive(task: URLSessionWebSocketTask, error: Error?) {
        let pendingCompletion = queue.sync { () -> PendingWebSocketCompletion? in
            guard Babylon.isEnabled.value, capturesWebSocketTraffic.value else { return nil }
            let id = PackageIdentifier.getID(for: task)
            ledger.completeWebSocketReceive(for: id)
            if error != nil, !ledger.localCloseTasks.contains(id) {
                ledger.markPendingRemoteClose(for: id)
                return nil
            }
            guard ledger.webSocketReceiveCounts[id] == nil,
                  !ledger.pendingRemoteCloseTasks.contains(id) else { return nil }
            return pendingWebSocketCompletions.removeValue(forKey: id)
        }
        if let pendingCompletion {
            finish(pendingCompletion.task, error: pendingCompletion.error)
        }
    }

    func injectorSessionWebSocketDidReceiveClose(task: URLSessionWebSocketTask, error: Error) {
        let pendingCompletion = queue.sync { () -> PendingWebSocketCompletion? in
            guard Babylon.isEnabled.value, capturesWebSocketTraffic.value else { return nil }
            let id = PackageIdentifier.getID(for: task)
            if !ledger.localCloseTasks.contains(id) {
                let closeCode = task.closeCode == .invalid ? nil : task.closeCode.rawValue
                stageWebSocket(task) { id in
                    WebsocketMessagePackage(
                        id: id,
                        closeCode: closeCode,
                        reason: task.closeReason,
                        origin: "remote",
                        abnormal: closeCode == nil
                    )
                }
                ledger.markRemoteClose(for: id)
            }
            ledger.pendingRemoteCloseTasks.remove(id)
            return pendingWebSocketCompletions.removeValue(forKey: id)
        }
        if let pendingCompletion {
            finish(pendingCompletion.task, error: pendingCompletion.error)
        } else {
            finish(task, error: error)
        }
    }

    func injectorSessionWebSocketDidSendMessage(task: URLSessionTask, message: URLSessionWebSocketTask.Message) {
        guard capturesWebSocketTraffic.value else { return }
        deliverWebSocket(task, kind: .send, message: message)
    }

    func injectorSessionWebSocketDidSendCancelWithReason(
        task: URLSessionTask,
        closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.sync {
            guard Babylon.isEnabled.value, capturesWebSocketTraffic.value else { return }
            stageWebSocket(task) { id in
                if closeCode == .invalid {
                    return WebsocketMessagePackage(
                        id: id,
                        closeCode: nil,
                        reason: reason,
                        origin: "local",
                        abnormal: true
                    )
                }
                return WebsocketMessagePackage(id: id, closeCode: closeCode.rawValue, reason: reason)
            }
            ledger.markLocalClose(for: PackageIdentifier.getID(for: task))
        }
    }

    private func deliverWebSocket(
        _ task: URLSessionTask,
        kind: WebsocketMessagePackage.MessageType,
        message: URLSessionWebSocketTask.Message
    ) {
        guard capturesWebSocketTraffic.value else { return }
        queue.sync {
            guard Babylon.isEnabled.value, capturesWebSocketTraffic.value else { return }
            stageWebSocket(task) { id in
                guard let payload = WebsocketMessagePackage.Message(message: message) else { return nil }
                return WebsocketMessagePackage(id: id, message: payload, messageType: kind)
            }
        }
    }

    private func stageWebSocket(
        _ task: URLSessionTask,
        builder: (String) -> WebsocketMessagePackage?
    ) {
        let id = PackageIdentifier.getID(for: task)
        guard let frame = builder(id) else { return }
        guard let parent = ledger.traffic[id] else {
            ledger.deferFrame(frame, for: id)
            ledger.enroll(id)
            return
        }
        if parent.response == nil {
            ledger.deferFrame(frame, for: id)
        } else {
            parent.setWebsocketMessagePackage(package: frame)
            startSendingWebsocketMessage(parent)
        }
    }
}

extension Babylon {
    func startSendingMessage(package: TrafficPackage) {
        if let delegate {
            DispatchQueue.main.async { delegate.babylonDidCapturePackage(package) }
        }
        guard transportEnabled.value else { return }
        enqueueTrafficSnapshot(package, type: .traffic)
    }

    func startSendingRuntimeMessages(packages: [RuntimePackage]) {
        guard transportEnabled.value else { return }
        for package in packages {
            if let message = Message.buildRuntimeMessage(id: configuration.id, item: package) {
                transporter.send(package: message)
            }
        }
    }

    func startSendingWebsocketMessage(_ package: TrafficPackage) {
        guard transportEnabled.value else { return }
        guard package.response != nil else {
            if let frame = package.websocketMessagePackage {
                ledger.deferFrame(frame, for: package.id)
            }
            return
        }
        flushWebSocketFrames(for: package.id)
        enqueueTrafficSnapshot(package, type: .websocket)
    }

    private func flushWebSocketFrames(for id: String) {
        guard let parent = ledger.traffic[id] else { return }
        let frames = ledger.takeDeferredFrames(for: id)
        for frame in frames {
            parent.setWebsocketMessagePackage(package: frame)
            enqueueTrafficSnapshot(parent, type: .websocket)
        }
    }

    private func enqueueTrafficSnapshot(_ package: TrafficPackage, type: Message.MessageType) {
        let clientID = activeClientID.value
        let generation = encodingGeneration.value
        guard !clientID.isEmpty else { return }
        guard let snapshot = package.makeSnapshot() else { return }
        guard encodingQueue.enqueue({ [weak self] in
            guard let self,
                  encodingGeneration.value == generation,
                  transportEnabled.value,
                  activeClientID.value == clientID else { return }
            let message: Message? = switch type {
            case .traffic:
                Message.buildTrafficMessage(id: clientID, item: snapshot)
            case .websocket:
                Message.buildWebSocketMessage(id: clientID, item: snapshot)
            case .connection,
                 .runtime,
                 .heartbeat,
                 .ack,
                 .error:
                nil
            }
            guard let message,
                  encodingGeneration.value == generation,
                  activeClientID.value == clientID else { return }
            transporter.send(package: message)
        }) else {
            Babylon.logger.info("Capture omitted because the encoding queue is full")
            return
        }
    }

    private func finish(_ task: AnyObject, error: Error?) {
        queue.sync {
            let id = PackageIdentifier.getID(for: task)
            if ledger.pendingRemoteCloseTasks.contains(id) || ledger.webSocketReceiveCounts[id] != nil {
                guard let task = task as? URLSessionTask else { return }
                pendingWebSocketCompletions[id] = PendingWebSocketCompletion(task: task, error: error)
                return
            }
            guard pendingMetricsCompletions[id] == nil else { return }
            guard Babylon.isEnabled.value, let capture = package(for: task, completing: true) else { return }
            capture.updateDidComplete(error)
            if capture.packageType == .http,
               capture.urlSessionTiming == nil,
               pendingMetricsCompletions.count < BabylonConstants.maximumPendingMetricsCompletions,
               let sessionTask = task as? URLSessionTask {
                scheduleMetricsCompletion(for: sessionTask, error: error, package: capture, id: id)
                return
            }
            completeCapturedTask(task, error: error, capture: capture)
        }
    }

    private func scheduleMetricsCompletion(
        for task: URLSessionTask,
        error: Error?,
        package: TrafficPackage,
        id: String
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let pending = pendingMetricsCompletions.removeValue(forKey: id) else { return }
            completeCapturedTask(pending.task, error: pending.error, capture: pending.package)
        }
        pendingMetricsCompletions[id] = PendingMetricsCompletion(
            workItem: workItem,
            task: task,
            error: error,
            package: package
        )
        queue.asyncAfter(deadline: .now() + BabylonConstants.urlSessionMetricsGracePeriod, execute: workItem)
    }

    private func completeCapturedTask(_ task: AnyObject, error: Error?, capture: TrafficPackage) {
        let id = PackageIdentifier.getID(for: task)
        defer {
            ledger.forget(id)
            traceContextStore.removeCorrelationContext(forPackageId: id)
        }
        if capturesWebSocketTraffic.value,
           capture.packageType == .websocket,
           let webSocketTask = task as? URLSessionWebSocketTask,
           !ledger.localCloseTasks.contains(capture.id),
           !ledger.remoteCloseTasks.contains(capture.id) {
            let closeCode = webSocketTask.closeCode.rawValue == URLSessionWebSocketTask.CloseCode.invalid.rawValue
                ? nil
                : webSocketTask.closeCode.rawValue
            let abnormal = error != nil && closeCode == nil
            if error != nil || closeCode != nil {
                let reason = webSocketTask.closeReason
                stageWebSocket(webSocketTask) { id in
                    WebsocketMessagePackage(
                        id: id,
                        closeCode: closeCode,
                        reason: reason,
                        origin: "remote",
                        abnormal: abnormal
                    )
                }
            }
        }
        startSendingMessage(package: capture)

        if capture.packageType == .websocket {
            flushWebSocketFrames(for: capture.id)
        }
    }
}

private extension Babylon {
    func invalidateEncodingWork() {
        encodingGeneration.mutate { $0 &+= 1 }
        encodingQueue.clear()
    }

    func observeMemoryPressure() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryPressure),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        #endif
    }

    @objc
    func handleMemoryPressure() {
        queue.async { [weak self] in
            guard let self else { return }
            pendingMetricsCompletions.values.forEach { $0.workItem.cancel() }
            pendingMetricsCompletions.removeAll()
            ledger.traffic.keys.forEach { self.traceContextStore.removeCorrelationContext(forPackageId: $0) }
            ledger.clear()
            invalidateEncodingWork()
            Babylon.logger.info("Cleared in-flight captures after a memory warning")
        }
    }
}

extension Bundle {
    var hasLocalNetworkUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String != nil
    }

    var hasBonjourServices: Bool {
        guard let services = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] else {
            return false
        }
        return services.contains(BabylonConstants.serviceType)
    }
}
