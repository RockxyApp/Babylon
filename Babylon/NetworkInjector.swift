// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct NetworkConfiguration {
    let shouldCaptureWebSocketTraffic: Bool

    init(shouldCaptureWebSocketTraffic: Bool = true) {
        self.shouldCaptureWebSocketTraffic = shouldCaptureWebSocketTraffic
    }
}

protocol Injector {
    var delegate: InjectorDelegate? { get set }
    func injectAllNetworkCalls(_ config: NetworkConfiguration)
}

protocol InjectorDelegate: AnyObject {
    func injectorSessionWillCreateTask(request: URLRequest) -> CorrelatedURLRequest
    func injectorSessionDidCreateTask(task: URLSessionTask, correlationContext: CorrelationContext?)
    func injectorSessionDidCallResume(task: URLSessionTask)
    func injectorSessionDidReceiveResponse(dataTask: URLSessionTask, response: URLResponse)
    func injectorSessionDidReceiveData(dataTask: URLSessionTask, data: Data)
    func injectorSessionDidComplete(task: URLSessionTask, error: Error?)
    func injectorSessionDidUpload(task: URLSessionTask, request: NSURLRequest, data: Data?)
    func injectorSessionWebSocketDidSendMessage(task: URLSessionTask, message: URLSessionWebSocketTask.Message)
    func injectorSessionWebSocketDidReceive(task: URLSessionTask, message: URLSessionWebSocketTask.Message)
    func injectorSessionWebSocketDidSendPingPong(task: URLSessionTask)
    func injectorSessionWebSocketDidSendCancelWithReason(
        task: URLSessionTask,
        closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    )
}

final class NetworkInjector: Injector {
    weak var delegate: InjectorDelegate?

    func injectAllNetworkCalls(_ config: NetworkConfiguration = NetworkConfiguration()) {
        #if DEBUG
        DispatchQueue.once(token: "com.amunx.babylon.runtime-hooks.core") {
            installCoreHooks()
        }
        if config.shouldCaptureWebSocketTraffic {
            DispatchQueue.once(token: "com.amunx.babylon.runtime-hooks.websocket") {
                _swizzleURLSessionWebsocketSelector()
            }
        }
        #endif
    }

    #if DEBUG
    private func installCoreHooks() {
        let connectionClass: AnyClass? = NSClassFromString("__NSCFURLLocalSessionConnection")
            ?? NSClassFromString("__NSCFURLSessionConnection")
        if let connectionClass {
            _swizzleURLSessionDataTaskDidReceiveResponse(baseClass: connectionClass)
            _swizzleURLSessionDataTaskDidReceiveData(baseClass: connectionClass)
            _swizzleURLSessionTaskDidCompleteWithError(baseClass: connectionClass)
        }

        _swizzleURLSessionResumeSelector(baseClass: URLSessionTask.self)
        _swizzleURLSessionDataTaskSelector(baseClass: URLSession.self)
        _swizzleURLSessionDownloadTaskSelector(baseClass: URLSession.self)
        _swizzleURLSessionWebSocketTaskFactorySelector(baseClass: URLSession.self)
        _swizzleURLSessionUploadSelector(baseClass: URLSession.self)
    }
    #endif
}
