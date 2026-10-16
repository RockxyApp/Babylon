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

private final class CaptureLedger {
    var generation: UInt64 = 0
    var traffic: [String: TrafficPackage] = [:]
    var deferredFrames: [String: [WebsocketMessagePackage]] = [:]
    var ignored: Set<String> = []
    var startedAt: [String: TimeInterval] = [:]
    var taskGeneration: [String: UInt64] = [:]

    func beginGeneration() {
        generation &+= 1
        clear()
    }

    func clear() {
        traffic.removeAll()
        deferredFrames.removeAll()
        ignored.removeAll()
        startedAt.removeAll()
        taskGeneration.removeAll()
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
        var frames = deferredFrames[id, default: []]
        let currentSize = frames.reduce(0) { $0 + $1.capturedBodySize }
        guard frames.count < BabylonConstants.maxPendingItems,
              frame.capturedBodySize <= BabylonConstants.maximumBodySize - currentSize else {
            return
        }
        frames.append(frame)
        deferredFrames[id] = frames
    }

    func forget(_ id: String) {
        traffic.removeValue(forKey: id)
        deferredFrames.removeValue(forKey: id)
        taskGeneration.removeValue(forKey: id)
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
    private let encodingQueue = DispatchQueue(label: "com.amunx.babylon.encoding", qos: .utility)
    private let activeClientID = Atomic<String>("")
    private var ignoredProtocolClasses: [AnyClass] = []
    private let transportEnabled = Atomic<Bool>(true)
    private let playgroundMode = Atomic<Bool>(false)
    private let redactedHeaderKeys = Atomic<Set<String>>(Babylon.defaultRedactedHeaders)
    private let redactedQueryKeys = Atomic<Set<String>>(Babylon.defaultRedactedQueryItems)

    private(set) var configuration = Configuration.default()
    let queue = DispatchQueue(label: "com.amunx.babylon")
    let traceContextStore = TraceContextStore()

    private override init() {
        transporter = NetServiceTransport()
        super.init()
        injector.delegate = self
        observeMemoryPressure()
    }

    @objc
    public class func start(hostName: String? = nil, shouldCaptureWebSocketTraffic: Bool = true) {
        activate(hostName: hostName, authToken: nil, capturesWebSockets: shouldCaptureWebSocketTraffic)
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
            capturesWebSockets: shouldCaptureWebSocketTraffic
        )
    }

    private class func activate(hostName: String?, authToken: String?, capturesWebSockets: Bool) {
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

        let sessionMessage = instance.queue.sync { () -> RuntimePackage? in
            instance.configuration = newConfiguration
            _ = instance.activeClientID.exchange(newConfiguration.clientID)
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
        let closingMessages = instance.queue.sync {
            instance.traceContextStore.finishSession(
                name: instance.configuration.projectName,
                metadata: [:]
            )
        }
        instance.startSendingRuntimeMessages(packages: closingMessages)
        _ = instance.activeClientID.exchange("")
        instance.transporter.stop()
        instance.queue.async {
            instance.configuration = .default()
            instance.ledger.clear()
            instance.traceContextStore.clear()
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
              let request = task.currentRequestSafe,
              let created = TrafficPackage.buildRequest(sessionTask: task, id: id) else {
            Babylon.logger.error("Unable to create capture package for \(String(describing: type(of: object)))")
            return nil
        }

        created.setCorrelationContext(traceContextStore.correlationContext(forPackageId: id))
        if isIgnored(request, from: task) {
            ledger.ignored.insert(id)
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
            return CorrelatedURLRequest(request: request, correlationContext: context)
        }
    }

    func injectorSessionDidCreateTask(task: URLSessionTask, correlationContext: CorrelationContext?) {
        queue.sync {
            guard Babylon.isEnabled.value else { return }
            let id = PackageIdentifier.getID(for: task)
            ledger.enroll(id)
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
        }
    }

    func injectorSessionDidReceiveData(dataTask: URLSessionTask, data: Data) {
        queue.sync {
            guard Babylon.isEnabled.value else { return }
            package(for: dataTask)?.appendResponseData(data)
        }
    }

    func injectorSessionDidComplete(task: URLSessionTask, error: Error?) {
        finish(task, error: error)
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
        deliverWebSocket(task, kind: .pingPong, message: .string("ping"))
    }

    func injectorSessionWebSocketDidReceive(task: URLSessionTask, message: URLSessionWebSocketTask.Message) {
        deliverWebSocket(task, kind: .receive, message: message)
    }

    func injectorSessionWebSocketDidSendMessage(task: URLSessionTask, message: URLSessionWebSocketTask.Message) {
        deliverWebSocket(task, kind: .send, message: message)
    }

    func injectorSessionWebSocketDidSendCancelWithReason(
        task: URLSessionTask,
        closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.sync {
            guard Babylon.isEnabled.value else { return }
            stageWebSocket(task) { id in
                WebsocketMessagePackage(id: id, closeCode: closeCode.rawValue, reason: reason)
            }
            let id = PackageIdentifier.getID(for: task)
            ledger.forget(id)
            traceContextStore.removeCorrelationContext(forPackageId: id)
        }
    }

    private func deliverWebSocket(
        _ task: URLSessionTask,
        kind: WebsocketMessagePackage.MessageType,
        message: URLSessionWebSocketTask.Message
    ) {
        queue.sync {
            guard Babylon.isEnabled.value else { return }
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
        guard let parent = ledger.traffic[id], let frame = builder(id) else { return }
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
        guard transportEnabled.value else { return }
        guard let frames = ledger.deferredFrames.removeValue(forKey: id),
              let parent = ledger.traffic[id] else { return }
        for frame in frames {
            parent.setWebsocketMessagePackage(package: frame)
            enqueueTrafficSnapshot(parent, type: .websocket)
        }
    }

    private func enqueueTrafficSnapshot(_ package: TrafficPackage, type: Message.MessageType) {
        let clientID = activeClientID.value
        guard !clientID.isEmpty else { return }
        let snapshot = package.makeSnapshot()
        encodingQueue.async { [weak self] in
            guard let self,
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
            guard let message, activeClientID.value == clientID else { return }
            transporter.send(package: message)
        }
    }

    private func finish(_ task: AnyObject, error: Error?) {
        queue.sync {
            let id = PackageIdentifier.getID(for: task)
            defer {
                ledger.forget(id)
                traceContextStore.removeCorrelationContext(forPackageId: id)
            }
            guard Babylon.isEnabled.value, let capture = package(for: task, completing: true) else { return }
            capture.updateDidComplete(error)
            startSendingMessage(package: capture)

            if capture.packageType == .websocket {
                flushWebSocketFrames(for: capture.id)
            }
        }
    }
}

private extension Babylon {
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
            ledger.traffic.keys.forEach { self.traceContextStore.removeCorrelationContext(forPackageId: $0) }
            ledger.clear()
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
