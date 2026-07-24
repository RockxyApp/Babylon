// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

#if DEBUG
private let runtimeHookLogger = Logger(subsystem: "com.amunx.Babylon", category: "RuntimeHooks")

private enum RuntimeHook {
    static func resolve(_ selectorName: String, on baseClass: AnyClass) -> (Selector, Method, IMP)? {
        let selector = NSSelectorFromString(selectorName)
        guard baseClass.instancesRespond(to: selector),
              let method = class_getInstanceMethod(baseClass, selector) else {
            runtimeHookLogger.error(
                "Hook unavailable: \(selectorName, privacy: .public) on \(String(describing: baseClass), privacy: .public)"
            )
            return nil
        }
        return (selector, method, method_getImplementation(method))
    }

    static func install(_ block: Any, on method: Method) {
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

extension NetworkInjector {
    func _swizzleURLSessionResumeSelector(baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(
            BabylonConstants.Selectors.resume,
            on: baseClass
        ) else { return }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let replacement: @convention(block) (AnyObject) -> Void = { [weak self] receiver in
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector)
            guard let task = receiver as? URLSessionTask, !task.isBabylonInternal() else { return }
            self?.delegate?.injectorSessionDidCallResume(task: task)
        }
        RuntimeHook.install(replacement, on: method)
    }

    func _swizzleURLSessionDataTaskDidReceiveResponse(baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(
            BabylonConstants.Selectors.didReceiveResponseSniff,
            on: baseClass
        ) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
        typealias Block = @convention(block) (AnyObject, AnyObject, Bool) -> Void
        let replacement: Block = { [weak self] receiver, rawResponse, sniff in
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector, rawResponse, sniff)
            guard let self,
                  let task = sessionTask(ownedBy: receiver),
                  let response = rawResponse as? URLResponse else { return }
            delegate?.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        }
        RuntimeHook.install(replacement, on: method)
    }

    func _swizzleURLSessionDataTaskDidReceiveData(baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(
            BabylonConstants.Selectors.didReceiveData,
            on: baseClass
        ) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let replacement: @convention(block) (AnyObject, AnyObject) -> Void = { [weak self] receiver, rawData in
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector, rawData)
            guard let self,
                  let task = sessionTask(ownedBy: receiver),
                  let data = rawData as? Data else { return }
            delegate?.injectorSessionDidReceiveData(dataTask: task, data: data)
        }
        RuntimeHook.install(replacement, on: method)
    }

    func _swizzleURLSessionTaskDidCompleteWithError(baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(
            BabylonConstants.Selectors.didFinishWithError,
            on: baseClass
        ) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { [weak self] receiver, rawError in
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector, rawError)
            guard let self, let task = sessionTask(ownedBy: receiver) else { return }
            delegate?.injectorSessionDidComplete(task: task, error: rawError as? Error)
        }
        RuntimeHook.install(replacement, on: method)
    }
}

extension NetworkInjector {
    func _swizzleURLSessionDataTaskSelector(baseClass: AnyClass) {
        installFactory(BabylonConstants.Selectors.dataTaskWithRequest, on: baseClass, completion: false)
        installFactory(BabylonConstants.Selectors.dataTaskWithRequestCompletion, on: baseClass, completion: true)
        installFactory(BabylonConstants.Selectors.dataTaskWithURL, on: baseClass, completion: false)
        installFactory(BabylonConstants.Selectors.dataTaskWithURLCompletion, on: baseClass, completion: true)
    }

    func _swizzleURLSessionDownloadTaskSelector(baseClass: AnyClass) {
        installFactory(BabylonConstants.Selectors.downloadTaskWithRequest, on: baseClass, completion: false)
        installFactory(BabylonConstants.Selectors.downloadTaskWithRequestCompletion, on: baseClass, completion: true)
        installFactory(BabylonConstants.Selectors.downloadTaskWithURL, on: baseClass, completion: false)
        installFactory(BabylonConstants.Selectors.downloadTaskWithURLCompletion, on: baseClass, completion: true)
    }

    func _swizzleURLSessionWebSocketTaskFactorySelector(baseClass: AnyClass) {
        installFactory(BabylonConstants.Selectors.webSocketTaskWithRequest, on: baseClass, completion: false)
        installFactory(BabylonConstants.Selectors.webSocketTaskWithURL, on: baseClass, completion: false)
        installWebSocketProtocolsFactory(on: baseClass)
    }

    private func installFactory(_ selectorName: String, on baseClass: AnyClass, completion: Bool) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(selectorName, on: baseClass) else { return }
        if completion {
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> AnyObject
            typealias Block = @convention(block) (AnyObject, AnyObject, AnyObject) -> AnyObject
            let replacement: Block = { [weak self] receiver, input, completionHandler in
                let prepared = self?.prepareFactoryInput(input) ?? (input, nil)
                let original = unsafeBitCast(implementation, to: Function.self)
                let task = original(receiver, selector, prepared.0, completionHandler)
                self?.reportCreatedTask(task, context: prepared.1)
                return task
            }
            RuntimeHook.install(replacement, on: method)
        } else {
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
            typealias Block = @convention(block) (AnyObject, AnyObject) -> AnyObject
            let replacement: Block = { [weak self] receiver, input in
                let prepared = self?.prepareFactoryInput(input) ?? (input, nil)
                let original = unsafeBitCast(implementation, to: Function.self)
                let task = original(receiver, selector, prepared.0)
                self?.reportCreatedTask(task, context: prepared.1)
                return task
            }
            RuntimeHook.install(replacement, on: method)
        }
    }

    private func installWebSocketProtocolsFactory(on baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(
            BabylonConstants.Selectors.webSocketTaskWithURLProtocols,
            on: baseClass
        ) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> AnyObject
        typealias Block = @convention(block) (AnyObject, AnyObject, AnyObject) -> AnyObject
        let replacement: Block = { [weak self] receiver, rawURL, protocols in
            let original = unsafeBitCast(implementation, to: Function.self)
            let task = original(receiver, selector, rawURL, protocols)
            let context = self?.correlationContext(for: rawURL)
            self?.reportCreatedTask(task, context: context)
            return task
        }
        RuntimeHook.install(replacement, on: method)
    }

    private func prepareFactoryInput(_ input: AnyObject) -> (AnyObject, CorrelationContext?) {
        if let request = input as? NSURLRequest {
            let result = delegate?.injectorSessionWillCreateTask(request: request as URLRequest)
            return ((result?.request as NSURLRequest?) ?? request, result?.correlationContext)
        }
        return (input, correlationContext(for: input))
    }

    private func correlationContext(for input: AnyObject) -> CorrelationContext? {
        guard let url = input as? URL else { return nil }
        return delegate?.injectorSessionWillCreateTask(request: URLRequest(url: url)).correlationContext
    }

    private func reportCreatedTask(_ rawTask: AnyObject, context: CorrelationContext?) {
        guard let task = rawTask as? URLSessionTask, !task.isBabylonInternal() else { return }
        delegate?.injectorSessionDidCreateTask(task: task, correlationContext: context)
    }

    private func sessionTask(ownedBy receiver: AnyObject) -> URLSessionTask? {
        let selector = NSSelectorFromString("task")
        return Runtime.object(from: receiver, selector: selector, as: URLSessionTask.self)
    }
}

extension NetworkInjector {
    func _swizzleURLSessionUploadSelector(baseClass: AnyClass) {
        installUploadFactory(
            BabylonConstants.Selectors.uploadFromFile,
            on: baseClass,
            completion: false,
            capturesData: false
        )
        installUploadFactory(
            BabylonConstants.Selectors.uploadFromFileCompletion,
            on: baseClass,
            completion: true,
            capturesData: false
        )
        installUploadFactory(
            BabylonConstants.Selectors.uploadFromData,
            on: baseClass,
            completion: false,
            capturesData: true
        )
        installUploadFactory(
            BabylonConstants.Selectors.uploadFromDataCompletion,
            on: baseClass,
            completion: true,
            capturesData: true
        )
    }

    private func installUploadFactory(
        _ selectorName: String,
        on baseClass: AnyClass,
        completion: Bool,
        capturesData: Bool
    ) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(selectorName, on: baseClass) else { return }
        if completion {
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, AnyObject) -> AnyObject
            typealias Block = @convention(block) (AnyObject, AnyObject, AnyObject?, AnyObject) -> AnyObject
            let replacement: Block = { [weak self] receiver, rawRequest, source, completionHandler in
                let prepared = self?.prepareFactoryInput(rawRequest) ?? (rawRequest, nil)
                let original = unsafeBitCast(implementation, to: Function.self)
                let rawTask = original(receiver, selector, prepared.0, source, completionHandler)
                self?.reportUpload(
                    rawTask,
                    request: rawRequest,
                    data: capturesData ? source as? Data : nil,
                    context: prepared.1
                )
                return rawTask
            }
            RuntimeHook.install(replacement, on: method)
        } else {
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?) -> AnyObject
            typealias Block = @convention(block) (AnyObject, AnyObject, AnyObject?) -> AnyObject
            let replacement: Block = { [weak self] receiver, rawRequest, source in
                let prepared = self?.prepareFactoryInput(rawRequest) ?? (rawRequest, nil)
                let original = unsafeBitCast(implementation, to: Function.self)
                let rawTask = original(receiver, selector, prepared.0, source)
                self?.reportUpload(
                    rawTask,
                    request: rawRequest,
                    data: capturesData ? source as? Data : nil,
                    context: prepared.1
                )
                return rawTask
            }
            RuntimeHook.install(replacement, on: method)
        }
    }

    private func reportUpload(
        _ rawTask: AnyObject,
        request rawRequest: AnyObject,
        data: Data?,
        context: CorrelationContext?
    ) {
        guard let task = rawTask as? URLSessionTask, let request = rawRequest as? NSURLRequest else { return }
        delegate?.injectorSessionDidCreateTask(task: task, correlationContext: context)
        delegate?.injectorSessionDidUpload(task: task, request: request, data: data)
    }
}

extension NetworkInjector {
    func _swizzleURLSessionWebsocketSelector() {
        guard let taskClass = NSClassFromString("__NSURLSessionWebSocketTask") else {
            runtimeHookLogger.error("WebSocket runtime class is unavailable")
            return
        }
        installWebSocketSend(on: taskClass)
        installWebSocketReceive(on: taskClass)
        installWebSocketPing(on: taskClass)
        installWebSocketCancel(on: taskClass)
    }

    private func installWebSocketSend(on baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(
            BabylonConstants.Selectors.webSocketSendMessage,
            on: baseClass
        ) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        typealias Block = @convention(block) (AnyObject, AnyObject, AnyObject) -> Void
        let replacement: Block = { [weak self] receiver, rawMessage, completion in
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector, rawMessage, completion)
            guard let task = receiver as? URLSessionTask,
                  let message = self?.wrapWebSocketMessage(object: rawMessage) else { return }
            self?.delegate?.injectorSessionWebSocketDidSendMessage(task: task, message: message)
        }
        RuntimeHook.install(replacement, on: method)
    }

    private func installWebSocketReceive(on baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(
            BabylonConstants.Selectors.webSocketReceiveMessage,
            on: baseClass
        ) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let replacement: @convention(block) (AnyObject, AnyObject) -> Void = { [weak self] receiver, completion in
            let intercepted = BabylonHelper.swizzleWebSocketReceiveMessage(
                withCompleteHandler: completion,
                responseHandler: { [weak self] text, data, _ in
                    guard let task = receiver as? URLSessionTask,
                          let message = self?.wrapWebSocketMessage(strValue: text, dataValue: data) else { return }
                    self?.delegate?.injectorSessionWebSocketDidReceive(task: task, message: message)
                }
            ) ?? completion
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector, intercepted)
        }
        RuntimeHook.install(replacement, on: method)
    }

    private func installWebSocketPing(on baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(
            BabylonConstants.Selectors.webSocketSendPing,
            on: baseClass
        ) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let replacement: @convention(block) (AnyObject, AnyObject) -> Void = { [weak self] receiver, completion in
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector, completion)
            guard let task = receiver as? URLSessionTask else { return }
            self?.delegate?.injectorSessionWebSocketDidSendPingPong(task: task)
        }
        RuntimeHook.install(replacement, on: method)
    }

    private func installWebSocketCancel(on baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolve(
            BabylonConstants.Selectors.webSocketCancelWithCloseCode,
            on: baseClass
        ) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, NSInteger, AnyObject?) -> Void
        typealias Block = @convention(block) (AnyObject, NSInteger, AnyObject?) -> Void
        let replacement: Block = { [weak self] receiver, rawCode, rawReason in
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector, rawCode, rawReason)
            guard let task = receiver as? URLSessionTask else { return }
            self?.delegate?.injectorSessionWebSocketDidSendCancelWithReason(
                task: task,
                closeCode: URLSessionWebSocketTask.CloseCode(rawValue: rawCode) ?? .invalid,
                reason: rawReason as? Data
            )
        }
        RuntimeHook.install(replacement, on: method)
    }

    func wrapWebSocketMessage(object: AnyObject) -> URLSessionWebSocketTask.Message? {
        guard let object = object as? NSObject else { return nil }
        return wrapWebSocketMessage(
            strValue: BabylonHelper.extractString(from: object),
            dataValue: BabylonHelper.extractData(from: object)
        )
    }

    func wrapWebSocketMessage(strValue: String?, dataValue: Data?) -> URLSessionWebSocketTask.Message? {
        if let strValue {
            return .string(strValue)
        }
        if let dataValue {
            return .data(dataValue)
        }
        return nil
    }
}
#endif
