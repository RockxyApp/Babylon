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
