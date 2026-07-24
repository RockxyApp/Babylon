import Foundation
import Testing
@testable import Babylon

// MARK: - Mock WebSocket Message

/// A mock NSObject subclass that exposes `data` and `string` properties
/// via `@objc dynamic`, mimicking the layout of Apple's private
/// `NSURLSessionWebSocketMessage` class for testing purposes.
private class MockWebSocketMessage: NSObject {
    @objc dynamic var data: Data?
    @objc dynamic var string: String?

    init(data: Data? = nil, string: String? = nil) {
        self.data = data
        self.string = string
        super.init()
    }
}

/// A minimal NSObject subclass that does NOT have `data` or `string` properties.
/// Used to safely test that extractData/extractString return nil for objects
/// that lack those selectors. Using a plain NSObject is unsafe because
/// NSObject.responds(to:) may return true for common selectors like "data"
/// in certain runtime contexts.
private class EmptyMockObject: NSObject {
    @objc dynamic var unrelated = 0
}

// MARK: - BabylonHelper extractData Tests

struct BabylonHelperExtractDataTests {
    @Test("extractData returns Data from object with 'data' property")
    func extractDataReturnsData() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let mock = MockWebSocketMessage(data: payload)

        let result = BabylonHelper.extractData(from: mock)
        #expect(result == payload)
    }

    @Test("extractData returns nil from plain NSObject without 'data' property")
    func extractDataReturnsNilForPlainObject() {
        let plainObject = NSObject()
        let result = BabylonHelper.extractData(from: plainObject)
        #expect(result == nil)
    }

    @Test("extractData returns nil when data property is nil")
    func extractDataReturnsNilForNilData() {
        let mock = MockWebSocketMessage(data: nil)
        let result = BabylonHelper.extractData(from: mock)
        #expect(result == nil)
    }
}

// MARK: - BabylonHelper extractString Tests

struct BabylonHelperExtractStringTests {
    @Test("extractString returns String from object with 'string' property")
    func extractStringReturnsString() {
        let mock = MockWebSocketMessage(string: "hello websocket")

        let result = BabylonHelper.extractString(from: mock)
        #expect(result == "hello websocket")
    }

    @Test("extractString returns nil from plain NSObject without 'string' property")
    func extractStringReturnsNilForPlainObject() {
        let plainObject = NSObject()
        let result = BabylonHelper.extractString(from: plainObject)
        #expect(result == nil)
    }

    @Test("extractString returns nil when string property is nil")
    func extractStringReturnsNilForNilString() {
        let mock = MockWebSocketMessage(string: nil)
        let result = BabylonHelper.extractString(from: mock)
        #expect(result == nil)
    }
}

// MARK: - NetworkInjector wrapWebSocketMessage(object:) Tests

struct WrapWebSocketMessageObjectTests {
    @Test("Extracts string message from object with string property")
    func extractsStringFromObject() {
        let injector = NetworkInjector()
        let mock = MockWebSocketMessage(string: "ws-text-message")

        let result = injector.wrapWebSocketMessage(object: mock)

        if case let .string(value) = result {
            #expect(value == "ws-text-message")
        } else {
            Issue.record("Expected .string message, got \(String(describing: result))")
        }
    }

    @Test("Extracts data message from object with data property")
    func extractsDataFromObject() {
        let injector = NetworkInjector()
        let payload = Data([0x01, 0x02, 0x03])
        let mock = MockWebSocketMessage(data: payload)

        let result = injector.wrapWebSocketMessage(object: mock)

        if case let .data(value) = result {
            #expect(value == payload)
        } else {
            Issue.record("Expected .data message, got \(String(describing: result))")
        }
    }

    @Test("Returns nil from plain NSObject with no string or data")
    func returnsNilForPlainObject() {
        let injector = NetworkInjector()
        let plainObject = NSObject()

        let result = injector.wrapWebSocketMessage(object: plainObject)
        #expect(result == nil)
    }
}

// MARK: - NetworkInjector wrapWebSocketMessage(strValue:dataValue:) Tests

struct WrapWebSocketMessageValueTests {
    @Test("Prefers string over data when both are provided")
    func prefersStringOverData() {
        let injector = NetworkInjector()
        let result = injector.wrapWebSocketMessage(
            strValue: "preferred",
            dataValue: Data([0xFF])
        )

        if case let .string(value) = result {
            #expect(value == "preferred")
        } else {
            Issue.record("Expected .string message, got \(String(describing: result))")
        }
    }

    @Test("Falls back to data when string is nil")
    func fallsBackToData() {
        let injector = NetworkInjector()
        let payload = Data([0xCA, 0xFE])
        let result = injector.wrapWebSocketMessage(strValue: nil, dataValue: payload)

        if case let .data(value) = result {
            #expect(value == payload)
        } else {
            Issue.record("Expected .data message, got \(String(describing: result))")
        }
    }

    @Test("Returns nil when both string and data are nil")
    func returnsNilWhenBothNil() {
        let injector = NetworkInjector()
        let result = injector.wrapWebSocketMessage(strValue: nil, dataValue: nil)
        #expect(result == nil)
    }
}
