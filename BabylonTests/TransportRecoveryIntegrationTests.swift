import Foundation
import Network
import Testing
@testable import Babylon

@Suite(.serialized)
struct TransportRecoveryIntegrationTests {
    @Test("Lost acknowledgement retransmits a retained frame with the same message ID")
    func lostAcknowledgementRetransmitsFrame() throws {
        let configuration = testConfiguration()
        let receiver = try LoopbackTransportReceiver(configuration: configuration, dropsFirstRuntimeAck: true)
        defer { receiver.stop() }
        let transport = NetServiceTransport()
        defer { transport.stop() }
        let endpoint = receiver.endpoint
        transport.startForTesting(configuration, endpoint: endpoint)

        #expect(receiver.waitForConnectionCount(1, timeout: 3))
        transport.send(package: runtimeMessage(configuration: configuration, name: "ack-loss"))

        #expect(receiver.waitForRuntimeFrameCount(2, timeout: 7))
        let identifiers = receiver.runtimeMessageIDs
        #expect(identifiers.count >= 2)
        #expect(identifiers.first == identifiers.dropFirst().first)
    }

    @Test("Receiver restart reconnects and flushes eligible pending runtime work")
    func receiverRestartFlushesPendingWork() throws {
        let configuration = testConfiguration()
        let receiver = try LoopbackTransportReceiver(configuration: configuration)
        let transport = NetServiceTransport()
        defer {
            receiver.stop()
            transport.stop()
        }
        let endpoint = receiver.endpoint
        transport.startForTesting(configuration, endpoint: endpoint)
        #expect(receiver.waitForConnectionCount(1, timeout: 3))

        #expect(receiver.stopAndWait())
        #expect(waitUntil(timeout: 4) { transport.hasScheduledRetryForTesting(endpoint) })
        transport.send(package: runtimeMessage(configuration: configuration, name: "queued-during-restart"))

        try receiver.restart()
        #expect(receiver.waitForRuntimeFrameCount(3, timeout: 8))
        #expect(receiver.runtimeEventStates.contains("reconnecting"))
        #expect(receiver.runtimeEventStates.contains("reconnected"))
        #expect(receiver.runtimeEventNames.contains("queued-during-restart"))
        let retryMetadata = try #require(receiver.runtimeEventMetadata.first { $0["transportState"] == "reconnecting" })
        #expect(retryMetadata["retryAttempt"] == "1")
        #expect(retryMetadata["retryDelayMilliseconds"] != nil)
        if let networkError = retryMetadata["networkError"] {
            #expect(["posix:", "dns:", "tls:", "other"].contains { networkError.hasPrefix($0) })
        }
        #expect(receiver.runtimeMessageIDs.count == 3)
    }

    @Test("Endpoint removal cancels retries until rediscovery")
    func endpointRemovalWaitsForRediscovery() throws {
        let configuration = testConfiguration()
        let receiver = try LoopbackTransportReceiver(configuration: configuration)
        let transport = NetServiceTransport()
        defer {
            receiver.stop()
            transport.stop()
        }
        let endpoint = receiver.endpoint
        transport.startForTesting(configuration, endpoint: endpoint)
        #expect(receiver.waitForConnectionCount(1, timeout: 3))

        transport.updateDiscoveredEndpointForTesting(endpoint, discovered: false)
        receiver.stop()
        transport.send(package: runtimeMessage(configuration: configuration, name: "queued-until-rediscovery"))
        try receiver.restart()
        Thread.sleep(forTimeInterval: 0.8)
        #expect(receiver.runtimeMessageIDs.isEmpty)

        transport.updateDiscoveredEndpointForTesting(endpoint, discovered: true)
        #expect(receiver.waitForRuntimeFrameCount(1, timeout: 5))
    }

    @Test("Reconnect stops after the configured retry budget is exhausted")
    func reconnectStopsAfterRetryExhaustion() throws {
        let configuration = testConfiguration()
        let receiver = try LoopbackTransportReceiver(configuration: configuration)
        defer { receiver.stop() }
        let endpoint = receiver.endpoint
        receiver.stop()

        let transport = NetServiceTransport(
            reconnectPolicy: BoundedRetryPolicy(
                maximumAttempts: 1,
                maximumLifetime: 1,
                initialDelay: 0.05,
                maximumDelay: 0.05
            )
        )
        defer { transport.stop() }
        transport.startForTesting(configuration, endpoint: endpoint)

        #expect(waitUntil(timeout: 2) { transport.hasScheduledRetryForTesting(endpoint) })
        #expect(waitUntil(timeout: 2) { !transport.hasScheduledRetryForTesting(endpoint) })

        try receiver.restart()
        Thread.sleep(forTimeInterval: 0.5)
        #expect(receiver.runtimeMessageIDs.isEmpty)
    }

    @Test("Retry exhaustion state is delivered after the endpoint returns")
    func retryExhaustionStateFlushesAfterRediscovery() throws {
        let configuration = testConfiguration()
        let receiver = try LoopbackTransportReceiver(configuration: configuration)
        defer { receiver.stop() }
        let endpoint = receiver.endpoint
        #expect(receiver.stopAndWait())

        let transport = NetServiceTransport(
            reconnectPolicy: BoundedRetryPolicy(
                maximumAttempts: 1,
                maximumLifetime: 1,
                initialDelay: 0.05,
                maximumDelay: 0.05
            )
        )
        defer { transport.stop() }
        transport.startForTesting(configuration, endpoint: endpoint)

        #expect(waitUntil(timeout: 2) { transport.hasScheduledRetryForTesting(endpoint) })
        #expect(waitUntil(timeout: 2) { !transport.hasScheduledRetryForTesting(endpoint) })
        try receiver.restart()
        transport.updateDiscoveredEndpointForTesting(endpoint, discovered: false)
        transport.updateDiscoveredEndpointForTesting(endpoint, discovered: true)

        #expect(receiver.waitForRuntimeFrameCount(1, timeout: 3))
        #expect(receiver.runtimeEventStates.suffix(2) == ["reconnecting", "retryExhausted"])
    }

    @Test("Graceful shutdown waits for acknowledgements of closing runtime messages")
    func gracefulShutdownDeliversClosingMessages() throws {
        let configuration = testConfiguration()
        let receiver = try LoopbackTransportReceiver(configuration: configuration)
        defer { receiver.stop() }
        let transport = NetServiceTransport()
        defer { transport.stop() }
        transport.startForTesting(configuration, endpoint: receiver.endpoint)
        #expect(receiver.waitForConnectionCount(1, timeout: 3))

        let closingMessage = runtimeMessage(configuration: configuration, name: "trace-finished")
        transport.stop(afterSending: [closingMessage], deadline: 3)

        #expect(receiver.waitForRuntimeFrameCount(3, timeout: 3))
        #expect(receiver.runtimeEventStates.contains("draining"))
        #expect(receiver.runtimeEventStates.contains("drainCompleted"))
        #expect(receiver.runtimeEventNames.contains("trace-finished"))
        #expect(receiver.runtimeMessageIDs.count == 3)
    }

    @Test("Graceful shutdown does not report completion when closing messages are not acknowledged")
    func gracefulShutdownDoesNotCompleteAfterAcknowledgementLoss() throws {
        let configuration = testConfiguration()
        let receiver = try LoopbackTransportReceiver(configuration: configuration, dropsRuntimeAcks: true)
        defer { receiver.stop() }
        let transport = NetServiceTransport()
        defer { transport.stop() }
        transport.startForTesting(configuration, endpoint: receiver.endpoint)
        #expect(receiver.waitForConnectionCount(1, timeout: 3))

        transport.stop(
            afterSending: [runtimeMessage(configuration: configuration, name: "trace-finished")],
            deadline: 8
        )

        #expect(receiver.waitForRuntimeFrameCount(2, timeout: 3))
        #expect(waitUntil(timeout: 7) { transport.hasUndeliveredDrainPackagesForTesting() })
        #expect(receiver.runtimeEventStates.contains("draining"))
        #expect(!receiver.runtimeEventStates.contains("drainCompleted"))
    }

    private func testConfiguration() -> Configuration {
        Configuration(
            projectName: "Transport recovery tests",
            deviceName: "Loopback",
            clientID: UUID().uuidString,
            sessionID: UUID().uuidString,
            hostName: nil,
            authToken: testPairingToken
        )
    }

    private func runtimeMessage(configuration: Configuration, name: String) -> Message {
        let package = RuntimePackage(kind: .event, sessionId: configuration.sessionID, name: name)
        guard let message = Message.buildRuntimeMessage(id: configuration.id, item: package) else {
            Issue.record("Could not encode loopback runtime message")
            fatalError("Runtime message encoding failed")
        }
        return message
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }
}

private final class LoopbackTransportReceiver {
    private final class ConnectionContext {
        var accumulator = ProtocolFrameAccumulator()
        var acknowledgementSequence: UInt64 = 0
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.amunx.babylon.tests.loopback-receiver")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var receivedRuntimeIDs: [String] = []
    private var receivedRuntimeNames: [String] = []
    private var receivedTransportStates: [String] = []
    private var receivedTransportMetadata: [[String: String]] = []
    private var acceptedConnectionCount = 0
    private var shouldDropFirstRuntimeAck: Bool
    private let dropsRuntimeAcks: Bool
    private var didDropRuntimeAck = false
    private(set) var endpoint: NWEndpoint

    init(
        configuration: Configuration,
        dropsFirstRuntimeAck: Bool = false,
        dropsRuntimeAcks: Bool = false
    ) throws {
        self.configuration = configuration
        shouldDropFirstRuntimeAck = dropsFirstRuntimeAck
        self.dropsRuntimeAcks = dropsRuntimeAcks
        guard let port = NWEndpoint.Port(rawValue: 0) else { throw LoopbackReceiverError.startTimedOut }
        endpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)
        try startListener(on: port)
    }

    var runtimeMessageIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return receivedRuntimeIDs
    }

    var runtimeEventNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return receivedRuntimeNames
    }

    var runtimeEventStates: [String] {
        lock.lock()
        defer { lock.unlock() }
        return receivedTransportStates
    }

    var runtimeEventMetadata: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return receivedTransportMetadata
    }

    func waitForConnectionCount(_ count: Int, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            lock.lock()
            defer { lock.unlock() }
            return acceptedConnectionCount >= count
        }
    }

    func waitForRuntimeFrameCount(_ count: Int, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { runtimeMessageIDs.count >= count }
    }

    func stop() {
        _ = stopAndWait()
    }

    @discardableResult
    func stopAndWait(timeout: TimeInterval = 2) -> Bool {
        lock.lock()
        let currentListener = listener
        let currentConnections = connections
        listener = nil
        connections.removeAll()
        lock.unlock()
        currentListener?.cancel()
        currentConnections.forEach { $0.cancel() }
        guard let currentListener else { return true }
        return waitUntil(timeout: timeout) { currentListener.state == .cancelled }
    }

    func restart() throws {
        guard case let .hostPort(_, port) = endpoint else { return }
        stop()
        Thread.sleep(forTimeInterval: 0.15)
        try startListener(on: port)
    }

    private func startListener(on port: NWEndpoint.Port) throws {
        let newListener = try NWListener(using: .tcp, on: port)
        let ready = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var startupError: NWError?
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                resultLock.lock()
                endpoint = newListener.port.map {
                    .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: $0)
                } ?? endpoint
                resultLock.unlock()
                ready.signal()
            case let .failed(error):
                resultLock.lock()
                startupError = error
                resultLock.unlock()
                ready.signal()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        lock.lock()
        listener = newListener
        lock.unlock()
        newListener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success else {
            newListener.cancel()
            throw LoopbackReceiverError.startTimedOut
        }
        resultLock.lock()
        let error = startupError
        resultLock.unlock()
        if let error {
            throw error
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        acceptedConnectionCount += 1
        lock.unlock()
        let context = ConnectionContext()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, state == .ready else { return }
            receive(from: connection, context: context)
        }
        connection.start(queue: queue)
    }

    private func receive(from connection: NWConnection, context: ConnectionContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let frames = try context.accumulator.append(data)
                    for frame in frames {
                        try process(frame, on: connection, context: context)
                    }
                } catch {
                    connection.cancel()
                    return
                }
            }
            if complete || error != nil {
                connection.cancel()
            } else {
                receive(from: connection, context: context)
            }
        }
    }

    private func process(_ frameData: Data, on connection: NWConnection, context: ConnectionContext) throws {
        let decoded = try BabylonProtocol.decode(frameData: frameData, configuration: configuration)
        if decoded.payload.messageType == .runtime {
            let package = try JSONDecoder().decode(RuntimePackage.self, from: decoded.payload.content)
            lock.lock()
            receivedRuntimeIDs.append(decoded.frame.messageID)
            receivedRuntimeNames.append(package.name)
            if let transportState = package.metadata["transportState"] {
                receivedTransportStates.append(transportState)
                receivedTransportMetadata.append(package.metadata)
            }
            let shouldDropAck = dropsRuntimeAcks || (shouldDropFirstRuntimeAck && !didDropRuntimeAck)
            if shouldDropAck {
                didDropRuntimeAck = didDropRuntimeAck || shouldDropFirstRuntimeAck
            }
            lock.unlock()
            if shouldDropAck {
                return
            }
        }

        let ack = BabylonProtocol.Ack(messageID: decoded.frame.messageID)
        let content = try JSONEncoder().encode(ack)
        let payload = BabylonProtocol.PayloadEnvelope(
            messageType: .ack,
            sentAt: Date().timeIntervalSince1970,
            content: content
        )
        let response = try BabylonProtocol.encode(
            payload: payload,
            configuration: configuration,
            sequence: context.acknowledgementSequence
        )
        context.acknowledgementSequence &+= 1
        connection.send(content: response.data, completion: .contentProcessed { _ in })
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }
}

private enum LoopbackReceiverError: Error {
    case startTimedOut
}
