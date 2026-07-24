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
    func send(package: Serializable)
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

private struct RetainedFrame {
    let encoded: WireProtocolCodec.Frame
    var retries = 0
}

private final class TransportState {
    var configuration: Configuration?
    var epoch: UInt64 = 0
    var sequence: UInt64 = 0
    var simulatorAttempts = 0
    var pending: [Serializable] = []
    var connections: [NWConnection] = []
    var accumulators: [ObjectIdentifier: ProtocolFrameAccumulator] = [:]
    var inboundIDs = ProtocolMessageDeduplicator()
    var retained: [String: RetainedFrame] = [:]
    var retainedOrder: [String] = []
    var retainedBytes = 0

    func nextSequence() -> UInt64 {
        defer { sequence &+= 1 }
        return sequence
    }

    func enqueue(_ package: Serializable) {
        if pending.count >= BabylonConstants.maxPendingItems {
            pending.removeFirst(pending.count - BabylonConstants.maxPendingItems + 1)
        }
        pending.append(package)
    }

    func detach(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        accumulators.removeValue(forKey: ObjectIdentifier(connection))
    }

    func removeRetained(_ messageID: String) {
        guard let frame = retained.removeValue(forKey: messageID) else { return }
        retainedOrder.removeAll { $0 == messageID }
        retainedBytes -= frame.encoded.payload.count
    }

    func clearNetworkState(clearPending: Bool) {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        accumulators.removeAll()
        inboundIDs.reset()
        retained.removeAll()
        retainedOrder.removeAll()
        retainedBytes = 0
        simulatorAttempts = 0
        configuration = nil
        if clearPending {
            pending.removeAll()
        }
    }
}

final class NetServiceTransport: NSObject, Transporter {
    private let logger = Logger(subsystem: "com.amunx.Babylon", category: "Transport")
    private let queue = DispatchQueue(label: "com.amunx.babylon.transport")
    private let state = TransportState()
    private var browser: NWBrowser?

    private let maximumSimulatorAttempts = 5
    private let acknowledgementDelay: TimeInterval = 2
    private let maximumAcknowledgementRetries = 2

    override init() {
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
            browseForDesktop()
            #endif
        }
        #endif
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            state.epoch &+= 1
            shutDown(clearPending: true)
        }
    }

    func send(package: Serializable) {
        queue.async { [weak self] in
            guard let self, state.configuration?.hasValidAuthentication == true else { return }
            if readyConnections.isEmpty {
                state.enqueue(package)
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
        state.simulatorAttempts = 0
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

    func browseForDesktop() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let candidate = NWBrowser(
            for: .bonjour(type: BabylonConstants.serviceType, domain: ""),
            using: parameters
        )
        candidate.stateUpdateHandler = { [weak self, weak candidate] status in
            guard let self, let candidate else { return }
            browserChanged(status, source: candidate)
        }
        candidate.browseResultsChangedHandler = { [weak self] _, changes in
            self?.apply(changes)
        }
        browser = candidate
        candidate.start(queue: queue)
    }

    func browserChanged(_ status: NWBrowser.State, source: NWBrowser) {
        switch status {
        case .ready:
            logger.info("Local service discovery is ready")
        case let .failed(error):
            logger.error("Local service discovery failed: \(Self.networkErrorCode(error), privacy: .public)")
            source.cancel()
            if browser === source {
                browser = nil
            }
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
                connectIfEligible(result.endpoint)
            case let .removed(result):
                disconnect(result.endpoint)
            case let .changed(_, result, _):
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
        let matches = state.connections.filter { $0.endpoint == endpoint }
        for match in matches {
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
            state.simulatorAttempts = 0
            sendIdentity(on: connection)
            flushPending()
            receive(on: connection, epoch: epoch)
        case let .waiting(error):
            handleWait(connection, error: error)
        case let .failed(error):
            logger.error("Connection failed: \(Self.networkErrorCode(error), privacy: .public)")
            state.detach(connection)
        case .cancelled:
            state.detach(connection)
        @unknown default:
            break
        }
    }

    func handleWait(_ connection: NWConnection, error: NWError) {
        #if targetEnvironment(simulator)
        connection.cancel()
        state.detach(connection)
        guard state.simulatorAttempts < maximumSimulatorAttempts else {
            logger.error("Simulator connection retry limit reached")
            return
        }
        state.simulatorAttempts += 1
        let epoch = state.epoch
        let attempt = state.simulatorAttempts
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, epoch == state.epoch else { return }
            logger.info("Simulator connection retry \(attempt)")
            attach(NWConnection(to: simulatorEndpoint(), using: .tcp), epoch: epoch)
        }
        #else
        logger.info("Connection is waiting: \(Self.networkErrorCode(error), privacy: .public)")
        #endif
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
        retain(encoded)
        transmit(encoded, on: connection)
    }

    func broadcast(_ package: Serializable) {
        guard let configuration = state.configuration,
              let encoded = WireProtocolCodec.frame(
                  package: package,
                  configuration: configuration,
                  sequence: state.nextSequence()
              ) else {
            logger.error("Could not encode an outgoing package")
            return
        }
        retain(encoded)
        readyConnections.forEach { transmit(encoded, on: $0) }
    }

    func transmit(_ frame: WireProtocolCodec.Frame, on connection: NWConnection) {
        guard connection.state == .ready else { return }
        connection.send(content: frame.data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("Encrypted frame send failed: \(error.localizedDescription)")
            }
        })
    }

    func flushPending() {
        guard !state.pending.isEmpty else { return }
        let packages = state.pending
        state.pending.removeAll()
        packages.forEach(broadcast)
    }

    func retain(_ encoded: WireProtocolCodec.Frame) {
        guard state.retained[encoded.messageID] == nil else { return }
        let byteCount = encoded.payload.count
        guard byteCount <= BabylonConstants.maximumOutstandingBytes else { return }

        while state.retainedOrder.count >= BabylonConstants.maxOutstandingFrames ||
            state.retainedBytes + byteCount > BabylonConstants.maximumOutstandingBytes {
            guard let oldest = state.retainedOrder.first else { break }
            state.removeRetained(oldest)
        }
        state.retained[encoded.messageID] = RetainedFrame(encoded: encoded)
        state.retainedOrder.append(encoded.messageID)
        state.retainedBytes += byteCount
        scheduleRetry(encoded.messageID, epoch: state.epoch)
    }

    func scheduleRetry(_ messageID: String, epoch: UInt64) {
        queue.asyncAfter(deadline: .now() + acknowledgementDelay) { [weak self] in
            guard let self, epoch == state.epoch, var retained = state.retained[messageID] else { return }
            let connections = readyConnections
            if connections.isEmpty {
                scheduleRetry(messageID, epoch: epoch)
                return
            }
            guard retained.retries < maximumAcknowledgementRetries else {
                state.removeRetained(messageID)
                logger.error("No acknowledgement for outgoing message \(messageID)")
                return
            }
            retained.retries += 1
            state.retained[messageID] = retained
            connections.forEach { self.transmit(retained.encoded, on: $0) }
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
                state.removeRetained(acknowledgement.messageID)
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
