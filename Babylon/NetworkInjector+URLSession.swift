// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

#if DEBUG
private let runtimeHookLogger = Logger(subsystem: "com.amunx.Babylon", category: "RuntimeHooks")
private let sessionConnectionFinalizationKey = "com.amunx.Babylon.session-connection-finalization"

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

    static func resolveDirect(_ selectorName: String, on baseClass: AnyClass) -> (Selector, Method, IMP)? {
        let selector = NSSelectorFromString(selectorName)
        var methodCount: UInt32 = 0
        guard let methods = class_copyMethodList(baseClass, &methodCount) else { return nil }
        defer { free(methods) }
        guard let method = (0 ..< Int(methodCount))
            .map({ methods[$0] })
            .first(where: { method_getName($0) == selector }) else {
            return nil
        }
        return (selector, method, method_getImplementation(method))
    }

    static func directlyImplements(_ selectorName: String, on baseClass: AnyClass) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        var methodCount: UInt32 = 0
        guard let methods = class_copyMethodList(baseClass, &methodCount) else { return false }
        defer { free(methods) }
        return (0 ..< Int(methodCount)).contains { method_getName(methods[$0]) == selector }
    }

    static func isVoidNoArgumentInstanceMethod(_ method: Method) -> Bool {
        guard method_getNumberOfArguments(method) == 2 else { return false }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        return String(cString: returnType) == "v"
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
            guard Thread.current.threadDictionary[sessionConnectionFinalizationKey] as? Bool != true else { return }
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
            let threadDictionary = Thread.current.threadDictionary
            let previousFinalization = threadDictionary[sessionConnectionFinalizationKey]
            threadDictionary[sessionConnectionFinalizationKey] = true
            defer {
                if let previousFinalization {
                    threadDictionary[sessionConnectionFinalizationKey] = previousFinalization
                } else {
                    threadDictionary.removeObject(forKey: sessionConnectionFinalizationKey)
                }
            }
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector, rawError)
            guard let self, let task = sessionTask(ownedBy: receiver) else { return }
            delegate?.injectorSessionDidComplete(task: task, error: rawError as? Error)
        }
        RuntimeHook.install(replacement, on: method)
    }

    /// Observes Foundation's metrics-ready notification without replacing the task's delegate.
    /// Both selectors are private and optional; when either is absent, URLSession continues
    /// normally and Babylon omits timing data.
    func _swizzleURLSessionTaskMetrics(baseClass: AnyClass) {
        guard let (selector, method, implementation) = RuntimeHook.resolveDirect(
            BabylonConstants.Selectors.didSendMetrics,
            on: baseClass
        ), RuntimeHook.isVoidNoArgumentInstanceMethod(method) else { return }
        let metricsSelector = NSSelectorFromString(BabylonConstants.Selectors.metrics)
        guard class_getInstanceMethod(baseClass, metricsSelector) != nil else { return }

        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let replacement: @convention(block) (AnyObject) -> Void = { [weak self] receiver in
            let metrics = Runtime.object(from: receiver, selector: metricsSelector, as: URLSessionTaskMetrics.self)
            if let self,
               let task = receiver as? URLSessionTask,
               !task.isBabylonInternal(),
               let metrics {
                // Preserve timing on the in-flight package before Foundation can advance task
                // completion and retire it. The original method still always runs unchanged.
                delegate?.injectorSessionDidCollectMetrics(task: task, metrics: metrics)
            }
            let original = unsafeBitCast(implementation, to: Function.self)
            original(receiver, selector)
        }
        RuntimeHook.install(replacement, on: method)
    }

    func _swizzleURLSessionTaskMetricsForKnownTaskKinds() {
        // Probe unstarted tasks before URLSession factories are hooked, then hook the most-specific
        // class that directly implements _didSendMetrics for each task family.
        let session = URLSession(configuration: .ephemeral)
        let httpURL = URL(string: "http://127.0.0.1/")!
        let httpRequest = URLRequest(url: httpURL)
        let tasks: [URLSessionTask] = [
            session.dataTask(with: httpURL),
            session.downloadTask(with: httpURL),
            session.uploadTask(with: httpRequest, from: Data()),
            session.webSocketTask(with: URL(string: "ws://127.0.0.1/")!)
        ]
        var installedOwners = Set<ObjectIdentifier>()
        for task in tasks {
            var candidate: AnyClass? = type(of: task)
            while let taskClass = candidate {
                if RuntimeHook.directlyImplements(BabylonConstants.Selectors.didSendMetrics, on: taskClass) {
                    if installedOwners.insert(ObjectIdentifier(taskClass)).inserted {
                        _swizzleURLSessionTaskMetrics(baseClass: taskClass)
                    }
                    break
                }
                if taskClass === URLSessionTask.self {
                    break
                }
                candidate = class_getSuperclass(taskClass)
            }
            task.markAsBabylonInternal()
            task.cancel()
        }
        session.invalidateAndCancel()
        if installedOwners.isEmpty {
            runtimeHookLogger.error("Hook unavailable: _didSendMetrics on URLSession task classes")
        }
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
                let prepared = self?.prepareFactoryInput(input) ?? PreparedTaskInput(
                    object: input,
                    correlationContext: nil,
                    capturePolicyDecision: .included
                )
                let original = unsafeBitCast(implementation, to: Function.self)
                let task = original(receiver, selector, prepared.object, completionHandler)
                self?.reportCreatedTask(
                    task,
                    context: prepared.correlationContext,
                    decision: prepared.capturePolicyDecision
                )
                return task
            }
            RuntimeHook.install(replacement, on: method)
        } else {
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
            typealias Block = @convention(block) (AnyObject, AnyObject) -> AnyObject
            let replacement: Block = { [weak self] receiver, input in
                let prepared = self?.prepareFactoryInput(input) ?? PreparedTaskInput(
                    object: input,
                    correlationContext: nil,
                    capturePolicyDecision: .included
                )
                let original = unsafeBitCast(implementation, to: Function.self)
                let task = original(receiver, selector, prepared.object)
                self?.reportCreatedTask(
                    task,
                    context: prepared.correlationContext,
                    decision: prepared.capturePolicyDecision
                )
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
            let prepared = self?.prepareFactoryInput(rawURL) ?? PreparedTaskInput(
                object: rawURL,
                correlationContext: nil,
                capturePolicyDecision: .included
            )
            self?.reportCreatedTask(
                task,
                context: prepared.correlationContext,
                decision: prepared.capturePolicyDecision
            )
            return task
        }
        RuntimeHook.install(replacement, on: method)
    }

    private func prepareFactoryInput(_ input: AnyObject) -> PreparedTaskInput {
        if let request = input as? NSURLRequest {
            let result = delegate?.injectorSessionWillCreateTask(request: request as URLRequest)
            return PreparedTaskInput(
                object: (result?.request as NSURLRequest?) ?? request,
                correlationContext: result?.correlationContext,
                capturePolicyDecision: result?.capturePolicyDecision ?? .included
            )
        }
        let result = (input as? URL).map { url in
            delegate?.injectorSessionWillCreateTask(request: URLRequest(url: url))
        } ?? nil
        return PreparedTaskInput(
            object: input,
            correlationContext: result?.correlationContext,
            capturePolicyDecision: result?.capturePolicyDecision ?? .included
        )
    }

    private func correlationContext(for input: AnyObject) -> CorrelationContext? {
        guard let url = input as? URL else { return nil }
        return delegate?.injectorSessionWillCreateTask(request: URLRequest(url: url)).correlationContext
    }

    private func reportCreatedTask(
        _ rawTask: AnyObject,
        context: CorrelationContext?,
        decision: CapturePolicyDecision = .included
    ) {
        guard let task = rawTask as? URLSessionTask, !task.isBabylonInternal() else { return }
        delegate?.injectorSessionDidCreateTask(
            task: task,
            correlationContext: context,
            capturePolicyDecision: decision
        )
    }

    /// The loading connection's task. iOS 27 and macOS 27 dropped the connection's `task` getter
    /// but still keep the task in its `_task` instance variable, so read that when the getter is gone;
    /// otherwise every response, body, and completion would be dropped.
    func sessionTask(ownedBy receiver: AnyObject) -> URLSessionTask? {
        if let task = Runtime.object(from: receiver, selector: NSSelectorFromString("task"), as: URLSessionTask.self) {
            return task
        }
        return Runtime.ivarObject(from: receiver, named: "_task", as: URLSessionTask.self)
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
                let prepared = self?.prepareFactoryInput(rawRequest) ?? PreparedTaskInput(
                    object: rawRequest,
                    correlationContext: nil,
                    capturePolicyDecision: .included
                )
                let original = unsafeBitCast(implementation, to: Function.self)
                let rawTask = original(receiver, selector, prepared.object, source, completionHandler)
                self?.reportUpload(
                    rawTask,
                    request: rawRequest,
                    data: capturesData ? source as? Data : nil,
                    context: prepared.correlationContext,
                    decision: prepared.capturePolicyDecision
                )
                return rawTask
            }
            RuntimeHook.install(replacement, on: method)
        } else {
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?) -> AnyObject
            typealias Block = @convention(block) (AnyObject, AnyObject, AnyObject?) -> AnyObject
            let replacement: Block = { [weak self] receiver, rawRequest, source in
                let prepared = self?.prepareFactoryInput(rawRequest) ?? PreparedTaskInput(
                    object: rawRequest,
                    correlationContext: nil,
                    capturePolicyDecision: .included
                )
                let original = unsafeBitCast(implementation, to: Function.self)
                let rawTask = original(receiver, selector, prepared.object, source)
                self?.reportUpload(
                    rawTask,
                    request: rawRequest,
                    data: capturesData ? source as? Data : nil,
                    context: prepared.correlationContext,
                    decision: prepared.capturePolicyDecision
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
        context: CorrelationContext?,
        decision: CapturePolicyDecision
    ) {
        guard let task = rawTask as? URLSessionTask, let request = rawRequest as? NSURLRequest else { return }
        delegate?.injectorSessionDidCreateTask(
            task: task,
            correlationContext: context,
            capturePolicyDecision: decision
        )
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
                  self?.isWebSocketCaptureEnabled == true,
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
                receiveCompletionHandler: { [weak self] error in
                    guard let task = receiver as? URLSessionWebSocketTask,
                          self?.isWebSocketCaptureEnabled == true else { return }
                    self?.delegate?.injectorSessionWebSocketDidCompleteReceive(task: task, error: error)
                },
                responseHandler: { [weak self] text, data, error in
                    guard let task = receiver as? URLSessionTask,
                          self?.isWebSocketCaptureEnabled == true else { return }
                    if let message = self?.wrapWebSocketMessage(strValue: text, dataValue: data) {
                        self?.delegate?.injectorSessionWebSocketDidReceive(task: task, message: message)
                    } else if let error, let task = task as? URLSessionWebSocketTask {
                        self?.delegate?.injectorSessionWebSocketDidReceiveClose(task: task, error: error)
                    }
                }
            ) ?? completion
            if let task = receiver as? URLSessionWebSocketTask, self?.isWebSocketCaptureEnabled == true {
                self?.delegate?.injectorSessionWebSocketWillReceive(task: task)
            }
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
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        typealias PongHandler = @convention(block) (NSError?) -> Void
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { [weak self] receiver, completion in
            let original = unsafeBitCast(implementation, to: Function.self)
            if let task = receiver as? URLSessionTask,
               self?.isWebSocketCaptureEnabled == true {
                self?.delegate?.injectorSessionWebSocketDidSendPingPong(task: task)
            }
            let wrappedCompletion: AnyObject? = completion.map { originalCompletion in
                let wrapped: PongHandler = { [weak self, weak task = receiver as? URLSessionTask] error in
                    if error == nil,
                       let task,
                       self?.isWebSocketCaptureEnabled == true {
                        self?.delegate?.injectorSessionWebSocketDidReceivePong(task: task)
                    }
                    unsafeBitCast(originalCompletion, to: PongHandler.self)(error)
                }
                return wrapped as AnyObject
            }
            original(receiver, selector, wrappedCompletion)
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
            guard let task = receiver as? URLSessionTask,
                  self?.isWebSocketCaptureEnabled == true else { return }
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
