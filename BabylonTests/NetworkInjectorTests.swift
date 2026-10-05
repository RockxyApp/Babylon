import Foundation
import Testing
@testable import Babylon

// MARK: - Private Class Discovery Tests

struct PrivateClassDiscoveryTests {
    @Test("__NSCFURLLocalSessionConnection class exists at runtime")
    func localSessionConnectionClassExists() {
        let cls = NSClassFromString("__NSCFURLLocalSessionConnection")
        #expect(cls != nil, "Expected __NSCFURLLocalSessionConnection to be registered with the ObjC runtime")
    }

    @Test("__NSURLSessionWebSocketTask class exists at runtime")
    func webSocketTaskClassExists() {
        let cls = NSClassFromString("__NSURLSessionWebSocketTask")
        #expect(cls != nil, "Expected __NSURLSessionWebSocketTask to be registered with the ObjC runtime")
    }
}

// MARK: - Selector Existence Tests

struct URLSessionSelectorTests {
    @Test("resume selector exists on URLSessionDataTask")
    func resumeSelectorExists() {
        let selector = NSSelectorFromString("resume")
        let responds = URLSessionDataTask.instancesRespond(to: selector)
        #expect(responds, "URLSessionDataTask should respond to 'resume'")
    }

    @Test("_didReceiveResponse:sniff: selector exists on session connection class (iOS 16+)")
    func didReceiveResponseSniffSelectorExists() {
        guard let cls = NSClassFromString("__NSCFURLLocalSessionConnection") else {
            Issue.record("__NSCFURLLocalSessionConnection class not found -- cannot verify selector")
            return
        }

        let selector = NSSelectorFromString("_didReceiveResponse:sniff:")
        let responds = cls.instancesRespond(to: selector)
        #expect(responds, "_didReceiveResponse:sniff: should exist on the session connection class")
    }

    @Test("_didReceiveData: selector exists on session connection class")
    func didReceiveDataSelectorExists() {
        guard let cls = NSClassFromString("__NSCFURLLocalSessionConnection") else {
            Issue.record("__NSCFURLLocalSessionConnection class not found -- cannot verify selector")
            return
        }

        let selector = NSSelectorFromString("_didReceiveData:")
        let responds = cls.instancesRespond(to: selector)
        #expect(responds, "_didReceiveData: should exist on the session connection class")
    }

    @Test("_didFinishWithError: selector exists on session connection class")
    func didFinishWithErrorSelectorExists() {
        guard let cls = NSClassFromString("__NSCFURLLocalSessionConnection") else {
            Issue.record("__NSCFURLLocalSessionConnection class not found -- cannot verify selector")
            return
        }

        let selector = NSSelectorFromString("_didFinishWithError:")
        let responds = cls.instancesRespond(to: selector)
        #expect(responds, "_didFinishWithError: should exist on the session connection class")
    }
}

// MARK: - NetworkInjector Instantiation Tests

struct NetworkInjectorInstantiationTests {
    @Test("NetworkInjector can be instantiated")
    func instantiation() {
        let injector = NetworkInjector()
        #expect(injector.delegate == nil, "A freshly created injector should have a nil delegate")
    }

    @Test("NetworkInjector conforms to Injector protocol")
    func conformsToInjector() {
        let injector = NetworkInjector()
        let asProtocol: (any Injector)? = injector
        #expect(asProtocol != nil, "NetworkInjector should conform to the Injector protocol")
    }
}

// MARK: - NetworkConfiguration Tests

struct NetworkConfigurationTests {
    @Test("Default configuration enables WebSocket capture")
    func defaultConfiguration() {
        let config = NetworkConfiguration()
        #expect(config.shouldCaptureWebSocketTraffic == true)
    }

    @Test("WebSocket capture can be disabled")
    func disableWebSocket() {
        let config = NetworkConfiguration(shouldCaptureWebSocketTraffic: false)
        #expect(config.shouldCaptureWebSocketTraffic == false)
    }

    @Test("WebSocket capture can be explicitly enabled")
    func enableWebSocket() {
        let config = NetworkConfiguration(shouldCaptureWebSocketTraffic: true)
        #expect(config.shouldCaptureWebSocketTraffic == true)
    }
}

// MARK: - Upload Task Selector Tests

struct UploadTaskSelectorTests {
    @Test("uploadTaskWithRequest:fromFile: selector exists on URLSession")
    func uploadFromFileSelectorExists() {
        let selector = NSSelectorFromString(BabylonConstants.Selectors.uploadFromFile)
        let responds = URLSession.instancesRespond(to: selector)
        #expect(responds, "URLSession should respond to uploadTaskWithRequest:fromFile:")
    }

    @Test("uploadTaskWithRequest:fromData: selector exists on URLSession")
    func uploadFromDataSelectorExists() {
        let selector = NSSelectorFromString(BabylonConstants.Selectors.uploadFromData)
        let responds = URLSession.instancesRespond(to: selector)
        #expect(responds, "URLSession should respond to uploadTaskWithRequest:fromData:")
    }

    @Test("WebSocket sendMessage:completionHandler: selector exists")
    func webSocketSendMessageSelectorExists() {
        guard let cls = NSClassFromString("__NSURLSessionWebSocketTask") else {
            Issue.record("__NSURLSessionWebSocketTask class not found")
            return
        }
        let selector = NSSelectorFromString(BabylonConstants.Selectors.webSocketSendMessage)
        let responds = cls.instancesRespond(to: selector)
        #expect(responds, "WebSocket task should respond to sendMessage:completionHandler:")
    }

    @Test("WebSocket receiveMessageWithCompletionHandler: selector exists")
    func webSocketReceiveMessageSelectorExists() {
        guard let cls = NSClassFromString("__NSURLSessionWebSocketTask") else {
            Issue.record("__NSURLSessionWebSocketTask class not found")
            return
        }
        let selector = NSSelectorFromString(BabylonConstants.Selectors.webSocketReceiveMessage)
        let responds = cls.instancesRespond(to: selector)
        #expect(responds, "WebSocket task should respond to receiveMessageWithCompletionHandler:")
    }
}

// MARK: - NetworkInjector Delegate Tests

struct NetworkInjectorDelegateTests {
    @Test("delegate can be set and read back")
    func delegateSetAndRead() {
        let injector = NetworkInjector()
        #expect(injector.delegate == nil)

        // Just verify the property is settable (we can't easily create a mock here
        // without the test helper, but setting nil should work)
        injector.delegate = nil
        #expect(injector.delegate == nil)
    }
}

// MARK: - BabylonHelper Tests

struct BabylonHelperTests {
    @Test("BabylonHelper is discoverable via NSClassFromString")
    func discoverableViaObjCRuntime() {
        let cls = NSClassFromString("BabylonHelper")
        #expect(cls != nil, "BabylonHelper should be registered with ObjC name 'BabylonHelper'")
    }

    @Test("Static selector constants are correct")
    func selectorConstants() {
        #expect(BabylonHelper.dataSelector == "data")
        #expect(BabylonHelper.stringSelector == "string")
    }
}

// MARK: - Connection Task Resolution Tests

/// iOS 27 and macOS 27 removed the loading connection's `task` getter but keep the task in its
/// `_task` instance variable. Without the fallback every response, body, and completion is dropped.
struct ConnectionTaskResolutionTests {
    @Test("A connection without a task getter resolves its task from the _task instance variable")
    func resolvesTaskFromInstanceVariable() throws {
        let connectionClass = try #require(Self.connectionLikeClass() as? NSObject.Type)
        let connection: AnyObject = connectionClass.init()
        let task = try URLSession(configuration: .ephemeral)
            .dataTask(with: #require(URL(string: "https://example.com/item")))
        let ivar = try #require(class_getInstanceVariable(connectionClass, "_task"))
        object_setIvarWithStrongDefault(connection, ivar, task)

        #expect(!connection.responds(to: NSSelectorFromString("task")))
        #expect(NetworkInjector().sessionTask(ownedBy: connection) === task)
        task.cancel()
    }

    @Test("Non-object instance variables are never read as objects")
    func ignoresNonObjectInstanceVariables() throws {
        let connectionClass = try #require(Self.connectionLikeClass() as? NSObject.Type)
        let connection: AnyObject = connectionClass.init()
        #expect(Runtime.ivarObject(from: connection, named: "_count", as: URLSessionTask.self) == nil)
        #expect(Runtime.ivarObject(from: connection, named: "_missing", as: URLSessionTask.self) == nil)
    }

    @Test("The system loading connection still exposes its task on this OS")
    func systemConnectionExposesTask() throws {
        // Canary for the next OS change: either the getter or the object-typed _task ivar must exist.
        let connectionClass = try #require(NSClassFromString("__NSCFURLLocalSessionConnection"))
        let hasGetter = connectionClass.instancesRespond(to: NSSelectorFromString("task"))
        let ivarEncoding = class_getInstanceVariable(connectionClass, "_task")
            .flatMap { ivar_getTypeEncoding($0) }
            .map { String(cString: $0) }
        #expect(hasGetter || ivarEncoding?.hasPrefix("@") == true)
    }

    private static func connectionLikeClass() -> AnyClass? {
        let name = "BabylonTestConnectionWithoutTaskGetter"
        if let existing = NSClassFromString(name) {
            return existing
        }
        guard let created = objc_allocateClassPair(NSObject.self, name, 0) else {
            return nil
        }
        _ = class_addIvar(
            created,
            "_task",
            MemoryLayout<AnyObject>.size,
            UInt8(log2(Double(MemoryLayout<AnyObject>.alignment))),
            "@"
        )
        _ = class_addIvar(
            created,
            "_count",
            MemoryLayout<Int>.size,
            UInt8(log2(Double(MemoryLayout<Int>.alignment))),
            "q"
        )
        objc_registerClassPair(created)
        return created
    }
}

// MARK: - Request Body Capture Tests

/// After `resume()` URLSession moves an `httpBody` into a stream on `currentRequest`; only
/// `originalRequest` still holds the data. A fake task models that state without resuming a real
/// task, which would reach the live hooks and other suites' delegates.
private final class ResumedBodyTask: URLSessionDataTask, @unchecked Sendable {
    let current: URLRequest
    let original: URLRequest

    init(current: URLRequest, original: URLRequest) {
        self.current = current
        self.original = original
        super.init()
    }

    override var currentRequest: URLRequest? {
        current
    }

    override var originalRequest: URLRequest? {
        original
    }
}

struct ResumedRequestBodyTests {
    @Test("A resumed data task still captures the body the app set")
    func resumedTaskKeepsRequestBody() throws {
        let body = Data(#"{"operationName":"GetUser"}"#.utf8)
        var original = try URLRequest(url: #require(URL(string: "https://api.example.com/graphql")))
        original.httpMethod = "POST"
        original.httpBody = body
        var current = original
        current.httpBodyStream = InputStream(data: body)

        let task = ResumedBodyTask(current: current, original: original)
        let package = try #require(TrafficPackage.buildRequest(sessionTask: task, id: "resumed-body"))
        #expect(package.request.body == body)
    }

    @Test("A request without a body stays without one")
    func requestWithoutBodyStaysEmpty() throws {
        let request = try URLRequest(url: #require(URL(string: "https://api.example.com/items")))
        let task = ResumedBodyTask(current: request, original: request)
        let package = try #require(TrafficPackage.buildRequest(sessionTask: task, id: "no-body"))
        #expect(package.request.body == nil)
    }
}
