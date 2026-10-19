import Foundation
import Testing
@testable import Babylon

@Suite(.serialized)
struct WebSocketCaptureLifecycleTests {
    @Test("Restarting with WebSocket capture disabled suppresses installed callbacks")
    func restartDisabledSuppressesCallbacks() throws {
        let babylon = Babylon.shared
        Babylon.setEnableTransportLayer(false)
        Babylon.start(shouldCaptureWebSocketTraffic: true)
        defer {
            Babylon.stop()
            babylon.queue.sync {}
            Babylon.setEnableTransportLayer(true)
        }
        let firstTask = try URLSession.shared.webSocketTask(with: #require(URL(string: "wss://example.com/first")))
        babylon.injectorSessionDidCallResume(task: firstTask)
        babylon.injectorSessionWebSocketDidSendMessage(task: firstTask, message: .string("captured"))
        babylon.injectorSessionWebSocketDidSendCancelWithReason(
            task: firstTask,
            closeCode: .normalClosure,
            reason: Data("done".utf8)
        )
        #expect(babylon.deferredWebSocketFrameCountForTesting == 2)

        Babylon.stop()
        babylon.queue.sync {}
        Babylon.start(shouldCaptureWebSocketTraffic: false)
        let nextTask = try URLSession.shared.webSocketTask(with: #require(URL(string: "wss://example.com/next")))
        babylon.injectorSessionDidCallResume(task: nextTask)
        babylon.injectorSessionWebSocketDidSendMessage(task: nextTask, message: .string("excluded"))
        #expect(babylon.deferredWebSocketFrameCountForTesting == 0)

        Babylon.stop()
        babylon.queue.sync {}
        Babylon.setEnableTransportLayer(true)
    }

    @Test("A failed task releases frames captured before its upgrade response")
    func failureReleasesPreUpgradeFrames() throws {
        let babylon = Babylon.shared
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        defer {
            Babylon.stop()
            babylon.queue.sync {}
            Babylon.setEnableTransportLayer(true)
        }
        let task = try URLSession.shared.webSocketTask(with: #require(URL(string: "wss://example.com/failure")))
        babylon.injectorSessionDidCallResume(task: task)
        babylon.injectorSessionWebSocketDidSendMessage(task: task, message: .string("before-upgrade"))
        #expect(babylon.deferredWebSocketFrameCountForTesting == 1)

        babylon.injectorSessionDidComplete(task: task, error: URLError(.networkConnectionLost))

        #expect(babylon.deferredWebSocketFrameCountForTesting == 0)
        Babylon.stop()
        babylon.queue.sync {}
        Babylon.setEnableTransportLayer(true)
    }

    @Test("A local close staged before upgrade is retained when the response arrives")
    func localCloseBeforeUpgradeIsCapturedAfterResponse() throws {
        let babylon = Babylon.shared
        let delegate = CapturingBabylonDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(delegate)
        Babylon.start()
        defer {
            Babylon.stop()
            babylon.queue.sync {}
            Babylon.setEnableTransportLayer(true)
        }

        let task = try URLSession.shared.webSocketTask(with: #require(URL(string: "wss://example.com/early-close")))
        babylon.injectorSessionDidCallResume(task: task)
        babylon.injectorSessionWebSocketDidSendCancelWithReason(
            task: task,
            closeCode: .normalClosure,
            reason: Data("closed before upgrade".utf8)
        )
        #expect(babylon.deferredWebSocketFrameCountForTesting == 1)

        let url = try #require(URL(string: "wss://example.com/early-close"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 101,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        babylon.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        babylon.injectorSessionDidComplete(task: task, error: URLError(.cancelled))
        #expect(delegate.semaphore.wait(timeout: .now() + 2) == .success)
        let package = try #require(delegate.packages.last)
        let frame = try #require(package.websocketMessagePackage)
        let data = try #require(frame.toData())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["messageType"] as? String == "sendCloseMessage")
        #expect(object["closeCode"] as? Int == 1000)
        #expect(object["closeOrigin"] as? String == "local")
        #expect(object["closeReason"] as? String == "closed before upgrade")
        #expect(babylon.deferredWebSocketFrameCountForTesting == 0)
    }

    @Test("Stopping clears deferred WebSocket frames without an upgrade response")
    func stopClearsDeferredFrames() throws {
        let babylon = Babylon.shared
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        let task = try URLSession.shared.webSocketTask(with: #require(URL(string: "wss://example.com/stop")))
        babylon.injectorSessionDidCallResume(task: task)
        babylon.injectorSessionWebSocketDidSendMessage(task: task, message: .string("pending"))
        #expect(babylon.deferredWebSocketFrameCountForTesting == 1)

        Babylon.stop()
        babylon.queue.sync {}

        #expect(babylon.deferredWebSocketFrameCountForTesting == 0)
        Babylon.setEnableTransportLayer(true)
    }

    @Test("Memory pressure clears deferred WebSocket frames")
    func memoryPressureClearsDeferredFrames() throws {
        let babylon = Babylon.shared
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        defer {
            Babylon.stop()
            babylon.queue.sync {}
            Babylon.setEnableTransportLayer(true)
        }

        let task = try URLSession.shared.webSocketTask(with: #require(URL(string: "wss://example.com/memory")))
        babylon.injectorSessionDidCallResume(task: task)
        babylon.injectorSessionWebSocketDidSendMessage(task: task, message: .string("pending"))
        #expect(babylon.deferredWebSocketFrameCountForTesting == 1)

        babylon.handleMemoryPressureForTesting()
        babylon.queue.sync {}

        #expect(babylon.deferredWebSocketFrameCountForTesting == 0)
    }

    @Test("Frames staged before upgrade stay ordered and transfer out of deferred state")
    func preUpgradeFramesKeepOrder() throws {
        let ledger = CaptureLedger()
        ledger.deferFrame(
            WebsocketMessagePackage(id: "ws", message: .string("first"), messageType: .send),
            for: "ws"
        )
        ledger.deferFrame(
            WebsocketMessagePackage(id: "ws", message: .string("second"), messageType: .receive),
            for: "ws"
        )

        let frames = ledger.takeDeferredFrames(for: "ws")
        let values = try frames.map { frame -> String in
            let data = try #require(frame.toData())
            let object = try JSONSerialization.jsonObject(with: data)
            let json = try #require(object as? [String: Any])
            return try #require(json["stringValue"] as? String)
        }

        #expect(values == ["first", "second"])
        #expect(ledger.deferredFrameCount == 0)
        #expect(ledger.deferredFrameBytes == 0)
        #expect(ledger.deferredFrameLeases.isEmpty)
    }

    @Test("Deferred frames flush in capture order after the upgrade response")
    func framesFlushInOrderAfterUpgrade() throws {
        let babylon = Babylon.shared
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        defer {
            Babylon.stop()
            babylon.queue.sync {}
            Babylon.setEnableTransportLayer(true)
        }
        let task = try URLSession.shared.webSocketTask(with: #require(URL(string: "wss://example.com/upgrade")))
        babylon.injectorSessionDidCallResume(task: task)
        babylon.injectorSessionWebSocketDidSendMessage(task: task, message: .string("first"))
        babylon.injectorSessionWebSocketDidReceive(task: task, message: .string("second"))
        #expect(babylon.deferredWebSocketFrameCountForTesting == 2)

        let taskURL = try #require(task.currentRequest?.url)
        let responseValue = HTTPURLResponse(
            url: taskURL,
            statusCode: 101,
            httpVersion: "HTTP/1.1",
            headerFields: ["Upgrade": "websocket"]
        )
        let response = try #require(responseValue)
        babylon.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        babylon.queue.sync {}

        let package = try #require(babylon.trafficPackageForTesting(task))
        let frame = try #require(package.websocketMessagePackage)
        let frameData = try #require(frame.toData())
        let frameObject = try JSONSerialization.jsonObject(with: frameData)
        let json = try #require(frameObject as? [String: Any])
        #expect(json["stringValue"] as? String == "second")
        #expect(babylon.deferredWebSocketFrameCountForTesting == 0)

        Babylon.stop()
        babylon.queue.sync {}
        #expect(babylon.deferredWebSocketFrameCountForTesting == 0)
        Babylon.setEnableTransportLayer(true)
    }

    @Test("A remote abnormal termination is captured when the WebSocket task completes")
    func remoteAbnormalTerminationOnCompletion() throws {
        let babylon = Babylon.shared
        let delegate = CapturingBabylonDelegate()
        Babylon.setEnableTransportLayer(false)
        Babylon.setDelegate(delegate)
        Babylon.start()
        defer {
            Babylon.stop()
            babylon.queue.sync {}
            Babylon.setEnableTransportLayer(true)
        }
        let task = try URLSession.shared.webSocketTask(with: #require(URL(string: "wss://example.com/close")))
        babylon.injectorSessionDidCallResume(task: task)
        let taskURL = try #require(task.currentRequest?.url)
        let responseValue = HTTPURLResponse(
            url: taskURL,
            statusCode: 101,
            httpVersion: "HTTP/1.1",
            headerFields: ["Upgrade": "websocket"]
        )
        let response = try #require(responseValue)
        babylon.injectorSessionDidReceiveResponse(dataTask: task, response: response)

        babylon.injectorSessionDidComplete(task: task, error: URLError(.networkConnectionLost))

        #expect(delegate.semaphore.wait(timeout: .now() + 2) == .success)
        let package = try #require(delegate.packages.last)
        let frame = try #require(package.websocketMessagePackage)
        let frameData = try #require(frame.toData())
        let frameObject = try JSONSerialization.jsonObject(with: frameData)
        let json = try #require(frameObject as? [String: Any])
        #expect(json["messageType"] as? String == "abnormalTermination")
        #expect(json["closeOrigin"] as? String == "remote")
    }

    @Test("WebSocket capture policy follows each session configuration")
    func policyCanBeDisabledAfterHooksWereInstalled() {
        let injector = NetworkInjector()

        injector.updateSessionConfiguration(NetworkConfiguration(shouldCaptureWebSocketTraffic: true))
        #expect(injector.shouldCaptureWebSocketTraffic)

        injector.updateSessionConfiguration(NetworkConfiguration(shouldCaptureWebSocketTraffic: false))
        #expect(!injector.shouldCaptureWebSocketTraffic)

        injector.updateSessionConfiguration(NetworkConfiguration(shouldCaptureWebSocketTraffic: true))
        #expect(injector.shouldCaptureWebSocketTraffic)
    }

    @Test("Deferred WebSocket frames obey aggregate count and byte limits")
    func deferredFramesHaveAggregateLimitsAndReleaseOnForget() {
        let ledger = CaptureLedger()
        let body = Data(repeating: 0x2A, count: 1_000_000)
        var taskIDs: [String] = []
        ledger.markLocalClose(for: "ws-0")

        for taskIndex in 0 ..< 100 {
            let id = "ws-\(taskIndex)"
            taskIDs.append(id)
            for _ in 0 ..< 10 {
                let frame = WebsocketMessagePackage(id: id, message: .data(body), messageType: .send)
                ledger.deferFrame(frame, for: id)
            }
        }

        #expect(ledger.deferredFrameCount <= BabylonConstants.maximumDeferredWebSocketFrames)
        #expect(ledger.deferredFrameBytes <= BabylonConstants.maximumDeferredWebSocketBytes)
        #expect(ledger.deferredFrameCount < 1000)

        taskIDs.forEach(ledger.forget)
        #expect(ledger.deferredFrameCount == 0)
        #expect(ledger.deferredFrameBytes == 0)
        #expect(ledger.deferredFrames.isEmpty)
        #expect(ledger.deferredFrameLeases.isEmpty)
        #expect(ledger.localCloseTasks.isEmpty)
    }

    @Test("Close lifecycle packages preserve origin, code, reason, and abnormal state")
    func closeLifecycleMetadataEncodes() throws {
        let local = WebsocketMessagePackage(id: "ws", closeCode: 1000, reason: Data("done".utf8))
        let remote = WebsocketMessagePackage(
            id: "ws",
            closeCode: 1001,
            reason: Data("going away".utf8),
            origin: "remote",
            abnormal: false
        )
        let abnormal = WebsocketMessagePackage(
            id: "ws",
            closeCode: nil,
            reason: Data("connection lost".utf8),
            origin: "remote",
            abnormal: true
        )

        let localData = try #require(local.toData())
        let localObject = try JSONSerialization.jsonObject(with: localData)
        let localJSON = try #require(localObject as? [String: Any])
        let remoteData = try #require(remote.toData())
        let remoteObject = try JSONSerialization.jsonObject(with: remoteData)
        let remoteJSON = try #require(remoteObject as? [String: Any])
        let abnormalData = try #require(abnormal.toData())
        let abnormalObject = try JSONSerialization.jsonObject(with: abnormalData)
        let abnormalJSON = try #require(abnormalObject as? [String: Any])

        #expect(localJSON["messageType"] as? String == "sendCloseMessage")
        #expect(localJSON["closeCode"] as? Int == 1000)
        #expect(localJSON["closeOrigin"] as? String == "local")
        #expect(localJSON["closeReason"] as? String == "done")
        #expect(remoteJSON["messageType"] as? String == "receiveCloseMessage")
        #expect(remoteJSON["closeCode"] as? Int == 1001)
        #expect(remoteJSON["closeOrigin"] as? String == "remote")
        #expect(remoteJSON["closeReason"] as? String == "going away")
        #expect(abnormalJSON["messageType"] as? String == "abnormalTermination")
        #expect(abnormalJSON["abnormal"] as? Bool == true)
    }

    @Test("WebSocket payloads respect the receiver frame limit")
    func payloadsUseReceiverFrameLimit() throws {
        let oversized = Data(repeating: 0x2A, count: BabylonConstants.maximumWebSocketFrameSize + 1)
        let package = WebsocketMessagePackage(id: "ws", message: .data(oversized), messageType: .send)
        let packageData = try #require(package.toData())
        let packageObject = try JSONSerialization.jsonObject(with: packageData)
        let json = try #require(packageObject as? [String: Any])
        let encoded = try #require(json["dataValue"] as? String)
        let body = try #require(Data(base64Encoded: encoded))

        #expect(body == Data("<Skip Large Body>".utf8))
    }
}
