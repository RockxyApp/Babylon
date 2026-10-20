import Foundation
import Testing

#if os(macOS)
import Network
@testable import Babylon

/// Mutable connection state and readiness waiters are confined to `queue`.
private final class LocalWebSocketServer: @unchecked Sendable {
    private struct ConnectionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let queue = DispatchQueue(label: "com.amunx.babylon.tests.websocket-loopback")
    private let listener: NWListener
    private var connection: NWConnection?
    private let ready = DispatchSemaphore(value: 0)
    private var connectionReadyWaiters: [ConnectionWaiter] = []
    private var isConnectionReady = false

    var port: UInt16? {
        listener.port?.rawValue
    }

    init() throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    self.markConnectionReady()
                }
            }
            connection.start(queue: queue)
            receiveNextMessage(from: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.ready.signal()
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              port != nil else {
            throw LoopbackError.listenerStartTimedOut
        }
    }

    deinit {
        connection?.cancel()
        listener.cancel()
    }

    func waitUntilConnected() async -> Bool {
        await withCheckedContinuation { continuation in
            let waiterID = UUID()
            queue.async {
                guard !self.isConnectionReady else {
                    continuation.resume(returning: true)
                    return
                }
                self.connectionReadyWaiters.append(ConnectionWaiter(id: waiterID, continuation: continuation))
                self.queue.asyncAfter(deadline: .now() + 5) {
                    guard let index = self.connectionReadyWaiters.firstIndex(where: { $0.id == waiterID }) else {
                        return
                    }
                    self.connectionReadyWaiters.remove(at: index).continuation.resume(returning: false)
                }
            }
        }
    }

    private func markConnectionReady() {
        queue.async {
            self.isConnectionReady = true
            let waiters = self.connectionReadyWaiters
            self.connectionReadyWaiters.removeAll()
            waiters.forEach { $0.continuation.resume(returning: true) }
        }
    }

    func sendRemoteClose() {
        queue.async {
            guard let connection = self.connection else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .protocolCode(.normalClosure)
            let context = NWConnection.ContentContext(identifier: "remote-close", metadata: [metadata])
            connection.send(
                content: nil,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
    }

    private func receiveNextMessage(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata else {
                receiveNextMessage(from: connection)
                return
            }
            switch metadata.opcode {
            case .text, .binary:
                let responseMetadata = NWProtocolWebSocket.Metadata(opcode: metadata.opcode)
                let response = NWConnection.ContentContext(identifier: "echo", metadata: [responseMetadata])
                connection.send(
                    content: data,
                    contentContext: response,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] _ in
                        self?.receiveNextMessage(from: connection)
                    }
                )
            case .ping, .pong, .cont:
                receiveNextMessage(from: connection)
            case .close:
                break
            @unknown default:
                receiveNextMessage(from: connection)
            }
        }
    }

    enum LoopbackError: Error {
        case listenerStartTimedOut
    }
}

private final class LocalHTTPServer {
    private let queue = DispatchQueue(label: "com.amunx.babylon.tests.http-loopback")
    private let listener: NWListener
    private let ready = DispatchSemaphore(value: 0)

    var port: UInt16? {
        listener.port?.rawValue
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                guard data != nil, error == nil else { return }
                let body = Data("local-http-ok".utf8)
                var response = Data(
                    "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
                )
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.ready.signal()
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != nil else {
            throw LocalWebSocketServer.LoopbackError.listenerStartTimedOut
        }
    }

    deinit {
        listener.cancel()
    }
}

@Suite(.serialized)
struct WebSocketLoopbackIntegrationTests {
    @Test("A real URLSession HTTP request captures its response end to end")
    func urlSessionHTTPLoopback() async throws {
        let server = try LocalHTTPServer()
        let port = try #require(server.port)
        let delegate = CapturingBabylonDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(delegate)
        Babylon.start(shouldCaptureWebSocketTraffic: true)
        defer {
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/capture"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data("local-http-ok".utf8))

        let package = try #require(await Self.waitForPackage(delegate, requestURL: url.absoluteString))
        #expect(package.request.url == url.absoluteString)
        #expect(package.request.method == "GET")
        #expect(package.response?.statusCode == 200)
        #expect(package.responseBodyData == Data("local-http-ok".utf8))
    }

    @Test("A real URLSession WebSocket captures handshake, send, receive, ping, and remote close")
    func urlSessionWebSocketLifecycle() async throws {
        let server = try LocalWebSocketServer()
        let port = try #require(server.port)
        let delegate = CapturingBabylonDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(delegate)
        Babylon.start(shouldCaptureWebSocketTraffic: true)
        defer {
            Babylon.stop()
            Babylon.setEnableTransportLayer(true)
        }

        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/capture"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: url)
        task.resume()

        try await task.send(.string("loopback-message"))
        let received = try await Self.receiveMessage(task)
        guard case let .string(value) = received else {
            Issue.record("Expected an echoed text WebSocket message")
            return
        }
        #expect(value == "loopback-message")
        #expect(await server.waitUntilConnected())
        try await Self.sendPing(task)

        server.sendRemoteClose()
        do {
            _ = try await Self.receiveMessage(task)
            Issue.record("Expected the server close frame to finish the task")
        } catch {
            #expect(task.closeCode == .normalClosure)
        }

        let package = try #require(await Self.waitForClosePackage(delegate))
        #expect(package.packageType == .websocket)
        #expect(package.response != nil)
        let message = try #require(package.websocketMessagePackage)
        let encoded = try #require(message.toData())
        let object = try JSONSerialization.jsonObject(with: encoded)
        let json = try #require(object as? [String: Any])
        #expect(json["messageType"] as? String == "receiveCloseMessage")
        #expect(json["closeOrigin"] as? String == "remote")
        #expect(json["closeCode"] as? Int == 1000)
    }

    private static func sendPing(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }.get()
    }

    private static func waitForPackage(
        _ delegate: CapturingBabylonDelegate,
        requestURL: String
    ) async -> TrafficPackage? {
        for _ in 0 ..< 500 {
            if let package = delegate.packages.first(where: { $0.request.url == requestURL && $0.response != nil }) {
                return package
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return delegate.packages.first { $0.request.url == requestURL }
    }

    private static func waitForClosePackage(_ delegate: CapturingBabylonDelegate) async -> TrafficPackage? {
        for _ in 0 ..< 500 {
            if let package = delegate.packages.last,
               let message = package.websocketMessagePackage,
               let data = message.toData(),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["messageType"] as? String == "receiveCloseMessage" {
                return package
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return delegate.packages.last
    }

    private static func receiveMessage(
        _ task: URLSessionWebSocketTask
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
            URLSessionWebSocketTask.Message,
            Error
        >) in
            task.receive { result in
                switch result {
                case let .success(message):
                    continuation.resume(returning: message)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
