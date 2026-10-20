// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import os

#if os(iOS)
import UIKit
#endif

protocol Transporter {
    func start(_ config: Configuration)
    func stop()
    func stop(afterSending packages: [Serializable], deadline: TimeInterval)
    func send(package: Serializable)
}

extension Transporter {
    func stop(afterSending packages: [Serializable], deadline: TimeInterval) {
        packages.forEach(send(package:))
        stop()
    }
}

enum WireProtocolCodec {
    typealias Frame = BabylonProtocol.EncodedFrame

    static func frame(
        package: Serializable,
        configuration: Configuration,
        sequence: UInt64,
        messageID: String = UUID().uuidString,
        sentAt: TimeInterval = Date().timeIntervalSince1970,
        nonce: Data? = nil
    ) -> Frame? {
        let message = (package as? Message) ?? wrap(package, clientID: configuration.clientID)
        guard let message else { return nil }
        return frame(
            message: message,
            configuration: configuration,
            sequence: sequence,
            messageID: messageID,
            sentAt: sentAt,
            nonce: nonce
        )
    }

    static func frame(
        message: Message,
        configuration: Configuration,
        sequence: UInt64,
        messageID: String = UUID().uuidString,
        sentAt: TimeInterval = Date().timeIntervalSince1970,
        nonce: Data? = nil
    ) -> Frame? {
        try? BabylonProtocol.encode(
            message: message,
            configuration: configuration,
            sequence: sequence,
            messageID: messageID,
            sentAt: sentAt,
            nonce: nonce
        )
    }

    private static func wrap(_ package: Serializable, clientID: String) -> Message? {
        switch package {
        case is ConnectionPackage:
            Message.buildConnectionMessage(id: clientID, item: package)
        case is WebsocketMessagePackage:
            Message.buildWebSocketMessage(id: clientID, item: package)
        case is RuntimePackage:
            Message.buildRuntimeMessage(id: clientID, item: package)
        default:
            Message.buildTrafficMessage(id: clientID, item: package)
        }
    }
}

struct RetainedFrame {
    let encoded: WireProtocolCodec.Frame
    let createdAt: TimeInterval
    var retries = 0
}

struct PendingDelivery {
    let package: Serializable
    let enqueuedAt: TimeInterval
    let estimatedBytes: Int
}

final class TransportState {
    var configuration: Configuration?
    var epoch: UInt64 = 0
    var sequence: UInt64 = 0
    var pending: [PendingDelivery] = []
    var pendingBytes = 0
    var connections: [NWConnection] = []
    var accumulators: [ObjectIdentifier: ProtocolFrameAccumulator] = [:]
    var intentionallyCancelledConnections: Set<ObjectIdentifier> = []
    var inboundIDs = ProtocolMessageDeduplicator()
    var retained: [String: RetainedFrame] = [:]
    var retainedOrder: [String] = []
    var retainedBytes = 0
    var endpointRetryWindows: [NWEndpoint: BoundedRetryWindow] = [:]
    var endpointRetryTokens: [NWEndpoint: UUID] = [:]
    var endpointsWithConnectionFailures: Set<NWEndpoint> = []
    var discoveredEndpoints: Set<NWEndpoint> = []
    var discoveryRetryWindow: BoundedRetryWindow?
    var discoveryRetryToken: UUID?
    var drainPending: [Serializable] = []
    var drainingMessageIDs: Set<String> = []
    var drainDeadlineToken: UUID?
    var isDraining = false
    var didSendDrainCompletion = false
    var drainHadUndeliveredPackages = false

    func nextSequence() -> UInt64 {
        defer { sequence &+= 1 }
        return sequence
    }

    func enqueue(_ package: Serializable, now: TimeInterval) {
        pending.removeAll { delivery in
            let expired = now - delivery.enqueuedAt >= BabylonConstants.maximumPendingLifetime
            if expired {
                pendingBytes -= delivery.estimatedBytes
            }
            return expired
        }
        let estimatedBytes = Self.estimatedSize(package)
        guard estimatedBytes <= BabylonConstants.maximumPendingBytes else { return }
        if pending.count >= BabylonConstants.maxPendingItems {
            let removed = pending.prefix(pending.count - BabylonConstants.maxPendingItems + 1)
            pendingBytes -= removed.reduce(0) { $0 + $1.estimatedBytes }
            pending.removeFirst(pending.count - BabylonConstants.maxPendingItems + 1)
        }
        while pendingBytes + estimatedBytes > BabylonConstants.maximumPendingBytes, !pending.isEmpty {
            pendingBytes -= pending.removeFirst().estimatedBytes
        }
        pending.append(PendingDelivery(package: package, enqueuedAt: now, estimatedBytes: estimatedBytes))
        pendingBytes += estimatedBytes
    }

    func boundedDrainPackages(_ packages: [Serializable]) -> [Serializable] {
        var selected: [Serializable] = []
        var bytes = 0
        for package in packages.suffix(BabylonConstants.maxPendingItems).reversed() {
            let packageBytes = Self.estimatedSize(package)
            guard packageBytes <= BabylonConstants.maximumPendingBytes,
                  bytes <= BabylonConstants.maximumPendingBytes - packageBytes else { continue }
            selected.append(package)
            bytes += packageBytes
        }
        return Array(selected.reversed())
    }

    private static func estimatedSize(_ package: Serializable) -> Int {
        if let estimatedPackage = package as? CaptureMemoryEstimating {
            return estimatedPackage.captureMemoryEstimate
        }
        return package.toData()?.count ?? BabylonConstants.maximumPendingBytes
    }

    func detach(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        accumulators.removeValue(forKey: ObjectIdentifier(connection))
    }

    @discardableResult
    func removeRetained(_ messageID: String, acknowledged: Bool = false) -> Bool {
        guard let frame = retained.removeValue(forKey: messageID) else { return false }
        retainedOrder.removeAll { $0 == messageID }
        retainedBytes -= frame.encoded.payload.count
        if drainingMessageIDs.remove(messageID) != nil, !acknowledged {
            drainHadUndeliveredPackages = true
        }
        return true
    }

    func clearNetworkState(clearPending: Bool) {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        accumulators.removeAll()
        inboundIDs.reset()
        retained.removeAll()
        retainedOrder.removeAll()
        retainedBytes = 0
        intentionallyCancelledConnections.removeAll()
        endpointRetryWindows.removeAll()
        endpointRetryTokens.removeAll()
        endpointsWithConnectionFailures.removeAll()
        discoveredEndpoints.removeAll()
        discoveryRetryWindow = nil
        discoveryRetryToken = nil
        drainPending.removeAll()
        drainingMessageIDs.removeAll()
        drainDeadlineToken = nil
        isDraining = false
        didSendDrainCompletion = false
        drainHadUndeliveredPackages = false
        configuration = nil
        if clearPending {
            pending.removeAll()
            pendingBytes = 0
        }
    }
}

final class NetServiceTransport: NSObject, Transporter {
    private let logger = Logger(subsystem: "com.amunx.Babylon", category: "Transport")
    private let queue = DispatchQueue(label: "com.amunx.babylon.transport")
    private let state = TransportState()
    private var browser: NWBrowser?

    private let reconnectPolicy: BoundedRetryPolicy
    private let discoveryRetryPolicy: BoundedRetryPolicy
    private let acknowledgementDelay: TimeInterval = 2
    private let maximumAcknowledgementRetries = 2
    private let maximumAcknowledgementLifetime: TimeInterval = 10

    init(
        reconnectPolicy: BoundedRetryPolicy = BoundedRetryPolicy(
            maximumAttempts: 6,
            maximumLifetime: 90,
            initialDelay: 0.5,
            maximumDelay: 12
        ),
        discoveryRetryPolicy: BoundedRetryPolicy = BoundedRetryPolicy(
            maximumAttempts: 5,
            maximumLifetime: 120,
            initialDelay: 1,
            maximumDelay: 20
        )
    ) {
        self.reconnectPolicy = reconnectPolicy
        self.discoveryRetryPolicy = discoveryRetryPolicy
        super.init()
        observeMemoryPressure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        shutDown(clearPending: true)
    }

    func start(_ config: Configuration) {
        #if DEBUG
        queue.async { [weak self] in
            guard let self else { return }
            state.epoch &+= 1
            shutDown(clearPending: false)
            state.configuration = config
            state.sequence = 0

            guard config.hasValidAuthentication else {
                logger.error("Network delivery requires an authentication token")
                return
            }
            #if targetEnvironment(simulator)
            connectSimulator(epoch: state.epoch)
            #else
            state.discoveryRetryWindow = BoundedRetryWindow(startedAt: Date().timeIntervalSince1970)
            browseForDesktop()
            #endif
        }
        #endif
    }

    func startForTesting(_ config: Configuration, endpoint: NWEndpoint) {
        queue.async { [weak self] in
            guard let self else { return }
            state.epoch &+= 1
            shutDown(clearPending: false)
            state.configuration = config
            state.sequence = 0
            state.discoveredEndpoints.insert(endpoint)
            guard config.hasValidAuthentication else { return }
            attach(NWConnection(to: endpoint, using: .tcp), epoch: state.epoch)
        }
    }

    func updateDiscoveredEndpointForTesting(_ endpoint: NWEndpoint, discovered: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if discovered {
                state.discoveredEndpoints.insert(endpoint)
                connectIfEligible(endpoint)
            } else {
                disconnect(endpoint)
            }
        }
    }

    func hasScheduledRetryForTesting(_ endpoint: NWEndpoint) -> Bool {
        queue.sync { state.endpointRetryTokens[endpoint] != nil }
    }

    func hasObservedConnectionFailureForTesting(_ endpoint: NWEndpoint) -> Bool {
        queue.sync { state.endpointsWithConnectionFailures.contains(endpoint) }
    }

    func hasUndeliveredDrainPackagesForTesting() -> Bool {
        queue.sync { state.drainHadUndeliveredPackages }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            state.epoch &+= 1
            shutDown(clearPending: true)
        }
    }

    func stop(afterSending packages: [Serializable], deadline: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !packages.isEmpty, state.configuration?.hasValidAuthentication == true else {
                state.epoch &+= 1
                shutDown(clearPending: true)
                return
            }
            state.isDraining = true
            let drainEvent: [Serializable] = transportEvent("draining").map { [$0] } ?? []
            let selectedPackages = state.boundedDrainPackages(packages)
            state.drainHadUndeliveredPackages = selectedPackages.count < packages.count
            state.drainPending = state.boundedDrainPackages(drainEvent + selectedPackages)
            browser?.cancel()
            browser = nil
            let token = UUID()
            state.drainDeadlineToken = token
            state.endpointRetryWindows.removeAll()
            state.endpointRetryTokens.removeAll()
            queue.asyncAfter(deadline: .now() + max(0, deadline)) { [weak self] in
                guard let self, state.drainDeadlineToken == token else { return }
                logger.info("Graceful transport drain reached its deadline")
                finishDrain()
            }
            drainClosingPackages()
        }
    }

    func send(package: Serializable) {
        queue.async { [weak self] in
            guard let self, state.configuration?.hasValidAuthentication == true else { return }
            if readyConnections.isEmpty {
                state.enqueue(package, now: Date().timeIntervalSince1970)
            } else {
                broadcast(package)
            }
        }
    }
}

private extension NetServiceTransport {
    var readyConnections: [NWConnection] {
        state.connections.filter { $0.state == .ready }
    }

    func connectSimulator(epoch: UInt64) {
        attach(NWConnection(to: simulatorEndpoint(), using: .tcp), epoch: epoch)
    }

    func simulatorEndpoint() -> NWEndpoint {
        let host = NWEndpoint.Host("localhost")
        guard let port = NWEndpoint.Port(rawValue: BabylonConstants.directConnectionPort) else {
            logger.error("Invalid direct connection port")
            return .hostPort(host: host, port: .any)
        }
        return .hostPort(host: host, port: port)
    }

    func browseForDesktop(epoch: UInt64? = nil) {
        let expectedEpoch = epoch ?? state.epoch
        guard expectedEpoch == state.epoch, browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let candidate = NWBrowser(
            for: .bonjour(type: BabylonConstants.serviceType, domain: ""),
            using: parameters
        )
        candidate.stateUpdateHandler = { [weak self, weak candidate] status in
            guard let self, let candidate else { return }
            browserChanged(status, source: candidate, epoch: expectedEpoch)
        }
        candidate.browseResultsChangedHandler = { [weak self, weak candidate] _, changes in
            guard let self,
                  let candidate,
                  browser === candidate,
                  state.epoch == expectedEpoch else { return }
            apply(changes)
        }
        browser = candidate
        candidate.start(queue: queue)
    }

    func browserChanged(_ status: NWBrowser.State, source: NWBrowser, epoch: UInt64) {
        guard epoch == state.epoch, browser === source else { return }
        switch status {
        case .ready:
            state.discoveryRetryWindow = BoundedRetryWindow(startedAt: Date().timeIntervalSince1970)
            state.discoveryRetryToken = nil
            logger.info("Local service discovery is ready")
        case let .failed(error):
            logger.error("Local service discovery failed: \(Self.networkErrorCode(error), privacy: .public)")
            source.cancel()
            if browser === source {
                browser = nil
            }
            scheduleDiscoveryRetry(epoch: epoch)
        case .cancelled:
            if browser === source {
                browser = nil
            }
        case let .waiting(error):
            reportBrowserWait(error)
        case .setup:
            break
        @unknown default:
            break
        }
    }

    func reportBrowserWait(_ error: NWError) {
        if case let .dns(code) = error, Int(code) == kDNSServiceErr_PolicyDenied {
            logger.error("Local network discovery was denied by system policy")
        } else {
            logger.debug("Local service discovery is waiting: \(Self.networkErrorCode(error), privacy: .public)")
        }
    }

    func apply(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case let .added(result):
                state.discoveredEndpoints.insert(result.endpoint)
                connectIfEligible(result.endpoint)
            case let .removed(result):
                disconnect(result.endpoint)
            case let .changed(_, result, _):
                state.discoveredEndpoints.insert(result.endpoint)
                connectIfEligible(result.endpoint)
            default:
                break
            }
        }
    }

    func connectIfEligible(_ endpoint: NWEndpoint) {
        guard !state.connections.contains(where: { $0.endpoint == endpoint }), accepts(endpoint) else { return }
        attach(NWConnection(to: endpoint, using: .tcp), epoch: state.epoch)
    }

    func disconnect(_ endpoint: NWEndpoint) {
        state.discoveredEndpoints.remove(endpoint)
        state.endpointRetryWindows.removeValue(forKey: endpoint)
        state.endpointRetryTokens.removeValue(forKey: endpoint)
        state.endpointsWithConnectionFailures.remove(endpoint)
        let matches = state.connections.filter { $0.endpoint == endpoint }
        for match in matches {
            state.intentionallyCancelledConnections.insert(ObjectIdentifier(match))
            match.cancel()
            state.detach(match)
        }
    }

    func accepts(_ endpoint: NWEndpoint) -> Bool {
        guard let required = state.configuration?.hostName else { return true }
        guard let discovered = Self.hostName(endpoint) else {
            logger.error("Rejected endpoint without a readable hostname")
            return false
        }
        return normalize(discovered) == normalize(required)
    }

    func normalize(_ hostName: String) -> String {
        var result = hostName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.hasSuffix(".") {
            result.removeLast()
        }
        return result
    }

    static func hostName(_ endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case let .hostPort(host, _):
            "\(host)"
        case let .service(name, _, _, _):
            name
        default:
            nil
        }
    }
}

private extension NetServiceTransport {
    func scheduleDiscoveryRetry(epoch: UInt64) {
        guard epoch == state.epoch,
              !state.isDraining,
              var window = state.discoveryRetryWindow else { return }
        let now = Date().timeIntervalSince1970
        guard let delay = window.nextDelay(
            now: now,
            jitter: Double.random(in: 0.75 ... 1.25),
            policy: discoveryRetryPolicy
        ) else {
            state.discoveryRetryWindow = nil
            logger.error("Local service discovery retry limit reached")
            return
        }
        state.discoveryRetryWindow = window
        let token = UUID()
        state.discoveryRetryToken = token
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  epoch == state.epoch,
                  state.discoveryRetryToken == token,
                  browser == nil,
                  state.configuration?.hasValidAuthentication == true else { return }
            state.discoveryRetryToken = nil
            browseForDesktop(epoch: epoch)
        }
    }
}

private extension NetServiceTransport {
    func attach(_ connection: NWConnection, epoch: UInt64) {
        guard epoch == state.epoch else {
            connection.cancel()
            return
        }
        state.connections.append(connection)
        state.accumulators[ObjectIdentifier(connection)] = ProtocolFrameAccumulator()
        connection.stateUpdateHandler = { [weak self] status in
            self?.connectionChanged(connection, status: status, epoch: epoch)
        }
        connection.start(queue: queue)
    }

    func connectionChanged(_ connection: NWConnection, status: NWConnection.State, epoch: UInt64) {
        guard epoch == state.epoch else {
            connection.cancel()
            return
        }
        switch status {
        case .setup, .preparing:
            break
        case .ready:
            let reconnected = state.endpointsWithConnectionFailures.remove(connection.endpoint) != nil
            state.endpointRetryWindows.removeValue(forKey: connection.endpoint)
            state.endpointRetryTokens.removeValue(forKey: connection.endpoint)
            sendIdentity(on: connection)
            if reconnected {
                enqueueTransportEvent("reconnected")
            }
            flushPending()
            receive(on: connection, epoch: epoch)
        case let .waiting(error):
            handleWait(connection, error: error)
        case let .failed(error):
            logger.error("Connection failed: \(Self.networkErrorCode(error), privacy: .public)")
            state.intentionallyCancelledConnections.remove(ObjectIdentifier(connection))
            state.detach(connection)
            scheduleConnectionRetry(
                for: connection.endpoint,
                epoch: epoch,
                failureCode: Self.networkErrorCode(error)
            )
        case .cancelled:
            let identity = ObjectIdentifier(connection)
            let wasIntentional = state.intentionallyCancelledConnections.remove(identity) != nil
            let wasTracked = state.connections.contains { $0 === connection }
            let shouldRetry = wasTracked && !wasIntentional && state.configuration?.hasValidAuthentication == true
            state.detach(connection)
            if shouldRetry {
                scheduleConnectionRetry(for: connection.endpoint, epoch: epoch)
            }
        @unknown default:
            break
        }
    }

    func handleWait(_ connection: NWConnection, error: NWError) {
        logger.info("Connection is waiting: \(Self.networkErrorCode(error), privacy: .public)")
        state.intentionallyCancelledConnections.insert(ObjectIdentifier(connection))
        connection.cancel()
        state.detach(connection)
        scheduleConnectionRetry(
            for: connection.endpoint,
            epoch: state.epoch,
            failureCode: Self.networkErrorCode(error)
        )
    }

    func scheduleConnectionRetry(for endpoint: NWEndpoint, epoch: UInt64, failureCode: String? = nil) {
        guard epoch == state.epoch,
              state.configuration?.hasValidAuthentication == true,
              !state.isDraining || state.drainDeadlineToken != nil else { return }
        #if !targetEnvironment(simulator)
        guard state.discoveredEndpoints.contains(endpoint) else { return }
        #endif
        guard !state.connections.contains(where: { $0.endpoint == endpoint }) else { return }
        var window = state.endpointRetryWindows[endpoint] ?? BoundedRetryWindow(startedAt: Date().timeIntervalSince1970)
        let now = Date().timeIntervalSince1970
        guard let delay = window.nextDelay(
            now: now,
            jitter: Double.random(in: 0.75 ... 1.25),
            policy: reconnectPolicy
        ) else {
            state.endpointRetryWindows.removeValue(forKey: endpoint)
            state.endpointRetryTokens.removeValue(forKey: endpoint)
            state.endpointsWithConnectionFailures.insert(endpoint)
            enqueueTransportEvent("retryExhausted", attempt: window.attempts, failureCode: failureCode)
            logger.error("Connection retry limit reached")
            return
        }
        state.endpointRetryWindows[endpoint] = window
        state.endpointsWithConnectionFailures.insert(endpoint)
        enqueueTransportEvent(
            "reconnecting",
            attempt: window.attempts,
            delay: delay,
            failureCode: failureCode
        )
        let token = UUID()
        state.endpointRetryTokens[endpoint] = token
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  epoch == state.epoch,
                  state.endpointRetryTokens[endpoint] == token,
                  state.configuration?.hasValidAuthentication == true,
                  !state.connections.contains(where: { $0.endpoint == endpoint }) else { return }
            #if !targetEnvironment(simulator)
            guard state.discoveredEndpoints.contains(endpoint) else { return }
            #endif
            logger.info("Retrying the local connection")
            state.endpointRetryTokens.removeValue(forKey: endpoint)
            attach(NWConnection(to: endpoint, using: .tcp), epoch: epoch)
        }
    }

    func enqueueTransportEvent(
        _ transportState: String,
        attempt: Int? = nil,
        delay: TimeInterval? = nil,
        failureCode: String? = nil
    ) {
        guard let configuration = state.configuration else { return }
        var metadata = ["transportState": transportState]
        if let attempt {
            metadata["retryAttempt"] = String(attempt)
        }
        if let delay, delay.isFinite, delay >= 0 {
            metadata["retryDelayMilliseconds"] = String(Int((delay * 1000).rounded()))
        }
        if let failureCode {
            metadata["networkError"] = failureCode
        }
        let package = RuntimePackage(
            kind: .event,
            sessionId: configuration.sessionID,
            name: "Babylon transport \(transportState)",
            metadata: metadata
        )
        state.enqueue(package, now: Date().timeIntervalSince1970)
    }

    func transportEvent(_ transportState: String) -> RuntimePackage? {
        guard let configuration = state.configuration else { return nil }
        return RuntimePackage(
            kind: .event,
            sessionId: configuration.sessionID,
            name: "Babylon transport \(transportState)",
            metadata: ["transportState": transportState]
        )
    }

    static func networkErrorCode(_ error: NWError) -> String {
        switch error {
        case let .posix(code):
            "posix:\(code.rawValue)"
        case let .dns(code):
            "dns:\(code)"
        case let .tls(code):
            "tls:\(code)"
        default:
            "other"
        }
    }
}

private extension NetServiceTransport {
    func sendIdentity(on connection: NWConnection) {
        guard let configuration = state.configuration,
              let message = Message.buildConnectionMessage(
                  id: configuration.id,
                  item: ConnectionPackage(config: configuration)
              ),
              let encoded = WireProtocolCodec.frame(
                  message: message,
                  configuration: configuration,
                  sequence: state.nextSequence()
              ) else {
            logger.error("Could not encode the connection identity")
            return
        }
        _ = retain(encoded)
        transmit(encoded, on: connection)
    }

    func broadcast(_ package: Serializable, isClosingPackage: Bool = false) {
        guard let configuration = state.configuration,
              let encoded = WireProtocolCodec.frame(
                  package: package,
                  configuration: configuration,
                  sequence: state.nextSequence()
              ) else {
            logger.error("Could not encode an outgoing package")
            if isClosingPackage {
                state.drainHadUndeliveredPackages = true
            }
            finishDrainIfComplete()
            return
        }
        guard retain(encoded) else {
            if isClosingPackage {
                state.drainHadUndeliveredPackages = true
            }
            finishDrainIfComplete()
            return
        }
        if isClosingPackage {
            state.drainingMessageIDs.insert(encoded.messageID)
        }
        readyConnections.forEach { transmit(encoded, on: $0) }
    }

    func transmit(_ frame: WireProtocolCodec.Frame, on connection: NWConnection) {
        guard connection.state == .ready else { return }
        let byteCount = frame.header.count + frame.payload.count
        let reservation = CaptureMemoryEstimate.retained(bodyBytes: byteCount, stringBytes: 0)
        guard let sendLease = CaptureMemoryBudget.shared.reserve(reservation) else {
            logger.info("Encrypted frame transmission omitted after the shared memory budget was reached")
            return
        }
        let data = frame.data
        connection.send(content: data, completion: .contentProcessed { [weak self, sendLease] error in
            _ = sendLease
            if let error {
                self?.logger.error("Encrypted frame send failed: \(error.localizedDescription)")
            }
        })
    }

    func flushPending() {
        let now = Date().timeIntervalSince1970
        let packages = state.pending.filter { now - $0.enqueuedAt < BabylonConstants.maximumPendingLifetime }
        state.pending.removeAll()
        state.pendingBytes = 0
        packages.forEach { broadcast($0.package) }
        drainClosingPackages()
    }

    @discardableResult
    func retain(_ encoded: WireProtocolCodec.Frame) -> Bool {
        guard state.retained[encoded.messageID] == nil else { return false }
        let byteCount = encoded.payload.count
        guard byteCount <= BabylonConstants.maximumOutstandingBytes else { return false }

        while state.retainedOrder.count >= BabylonConstants.maxOutstandingFrames ||
            state.retainedBytes + byteCount > BabylonConstants.maximumOutstandingBytes {
            guard let oldest = state.retainedOrder.first else { break }
            state.removeRetained(oldest)
        }
        guard state.retainedBytes + byteCount <= BabylonConstants.maximumOutstandingBytes,
              state.retainedOrder.count < BabylonConstants.maxOutstandingFrames else { return false }
        state.retained[encoded.messageID] = RetainedFrame(encoded: encoded, createdAt: Date().timeIntervalSince1970)
        state.retainedOrder.append(encoded.messageID)
        state.retainedBytes += byteCount
        scheduleRetry(encoded.messageID, epoch: state.epoch)
        return true
    }

    func scheduleRetry(_ messageID: String, epoch: UInt64) {
        queue.asyncAfter(deadline: .now() + acknowledgementDelay) { [weak self] in
            guard let self, epoch == state.epoch, var retained = state.retained[messageID] else { return }
            if Date().timeIntervalSince1970 - retained.createdAt >= maximumAcknowledgementLifetime {
                state.removeRetained(messageID)
                finishDrainIfComplete()
                logger.error("Outgoing message delivery expired before acknowledgement")
                return
            }
            guard retained.retries < maximumAcknowledgementRetries else {
                state.removeRetained(messageID)
                finishDrainIfComplete()
                logger.error("No acknowledgement for outgoing message \(messageID)")
                return
            }
            retained.retries += 1
            state.retained[messageID] = retained
            readyConnections.forEach { self.transmit(retained.encoded, on: $0) }
            scheduleRetry(messageID, epoch: epoch)
        }
    }
}

private extension NetServiceTransport {
    func receive(on connection: NWConnection, epoch: UInt64) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { [weak self] data, _, complete, error in
            guard let self, epoch == state.epoch, connection.state == .ready else { return }
            if let error {
                logger.error("Encrypted frame receive failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                consume(data, from: connection)
            }
            if complete {
                connection.cancel()
            } else {
                receive(on: connection, epoch: epoch)
            }
        }
    }

    func consume(_ data: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        var accumulator = state.accumulators[key] ?? ProtocolFrameAccumulator()
        do {
            let frames = try accumulator.append(data)
            state.accumulators[key] = accumulator
            frames.forEach(processControlFrame)
        } catch {
            state.accumulators.removeValue(forKey: key)
            logger.error("Rejected an invalid transport frame")
            connection.cancel()
        }
    }

    func processControlFrame(_ data: Data) {
        guard let configuration = state.configuration else { return }
        do {
            let decoded = try BabylonProtocol.decode(frameData: data, configuration: configuration)
            guard state.inboundIDs.insert(decoded.frame.messageID) else { return }
            switch decoded.payload.messageType {
            case .ack:
                guard let acknowledgement = try? JSONDecoder().decode(
                    BabylonProtocol.Ack.self,
                    from: decoded.payload.content
                ) else {
                    logger.error("Rejected a malformed acknowledgement")
                    return
                }
                if state.removeRetained(acknowledgement.messageID, acknowledged: true) {
                    state.drainingMessageIDs.remove(acknowledgement.messageID)
                    finishDrainIfComplete()
                }
            case .error:
                guard (try? JSONDecoder().decode(
                    BabylonProtocol.ProtocolError.self,
                    from: decoded.payload.content
                )) != nil else {
                    logger.error("Rejected a malformed protocol error")
                    return
                }
            case .heartbeat:
                break
            case .connection, .traffic, .websocket, .runtime:
                logger.debug("Ignored unexpected inbound payload")
            }
        } catch {
            logger.error("Rejected an unauthenticated transport frame")
        }
    }
}

private extension NetServiceTransport {
    func drainClosingPackages() {
        guard state.isDraining, !state.drainPending.isEmpty, !readyConnections.isEmpty else {
            finishDrainIfComplete()
            return
        }
        let packages = state.drainPending
        state.drainPending.removeAll()
        for package in packages {
            broadcast(package, isClosingPackage: true)
        }
        finishDrainIfComplete()
    }

    func finishDrainIfComplete() {
        guard state.isDraining,
              state.drainPending.isEmpty,
              state.drainingMessageIDs.isEmpty,
              !state.drainHadUndeliveredPackages else { return }
        guard !state.didSendDrainCompletion else {
            finishDrain()
            return
        }
        guard let completion = transportEvent("drainCompleted") else {
            finishDrain()
            return
        }
        state.didSendDrainCompletion = true
        state.drainPending = [completion]
        drainClosingPackages()
    }

    func finishDrain() {
        guard state.isDraining || state.drainDeadlineToken != nil else { return }
        state.epoch &+= 1
        shutDown(clearPending: true)
    }
}

private extension NetServiceTransport {
    func shutDown(clearPending: Bool) {
        browser?.cancel()
        browser = nil
        state.clearNetworkState(clearPending: clearPending)
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
            state.pending.removeAll()
            state.retained.removeAll()
            state.retainedOrder.removeAll()
            state.retainedBytes = 0
            logger.info("Cleared buffered transport data after a memory warning")
        }
    }
}
