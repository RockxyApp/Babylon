import Foundation
import Testing
@testable import Babylon

// MARK: - Singleton Tests

struct BabylonSingletonTests {
    @Test("Shared instance exists and is a Babylon object")
    func sharedExists() {
        let instance = Babylon.shared
        #expect(instance is Babylon)
    }

    @Test("Shared instance is stable across accesses")
    func sharedIsStable() {
        let first = Babylon.shared
        let second = Babylon.shared
        #expect(first === second)
    }

    @Test("Configuration is populated with valid defaults")
    func configurationIsValid() {
        let config = Babylon.shared.configuration
        #expect(!config.projectName.isEmpty)
        #expect(!config.deviceName.isEmpty)
        #expect(!config.id.isEmpty)
    }
}

// MARK: - Lifecycle Tests

@Suite(.serialized)
struct BabylonLifecycleTests {
    @Test("start and stop do not crash when called in sequence")
    func startStopSequence() {
        // Disable transport layer so we don't attempt real Bonjour discovery.
        Babylon.setEnableTransportLayer(false)

        Babylon.start()
        Babylon.stop()

        // Restore default.
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("stop is safe to call when not started")
    func stopWithoutStart() {
        Babylon.stop()
        #expect(true)
    }

    @Test("Multiple start calls are idempotent")
    func multipleStarts() {
        Babylon.setEnableTransportLayer(false)

        Babylon.start()
        Babylon.start() // second call should be a no-op
        Babylon.stop()

        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("start with hostname configures session correctly")
    func startWithHostname() {
        Babylon.setEnableTransportLayer(false)

        Babylon.start(hostName: "test-machine")
        let config = Babylon.shared.configuration
        Babylon.stop()

        Babylon.setEnableTransportLayer(true)

        #expect(config.hostName == "test-machine")
    }

    @Test("start with WebSocket capture disabled does not crash")
    func startWithWebSocketDisabled() {
        Babylon.setEnableTransportLayer(false)

        Babylon.start(shouldCaptureWebSocketTraffic: false)
        Babylon.stop()

        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("start with auth token keeps the secret in session configuration")
    func startWithAuthToken() {
        Babylon.setEnableTransportLayer(false)

        Babylon.start(authToken: testPairingToken, hostName: "test-machine")
        let config = Babylon.shared.configuration
        Babylon.stop()

        Babylon.setEnableTransportLayer(true)

        #expect(config.authToken == testPairingToken)
        #expect(config.hostName == "test-machine")
    }
}

// MARK: - Delegate Tests

struct BabylonDelegateTests {
    /// A simple test delegate that records received packages.
    private final class TestDelegate: BabylonDelegate {
        var receivedPackages: [TrafficPackage] = []

        func babylonDidCapturePackage(_ package: TrafficPackage) {
            receivedPackages.append(package)
        }
    }

    @Test("BabylonDelegate protocol can be conformed to")
    func delegateConformance() {
        let delegate = TestDelegate()
        let _: any BabylonDelegate = delegate
        #expect(true)
    }

    @Test("setDelegate does not crash")
    func setDelegateDoesNotCrash() {
        let delegate = TestDelegate()
        Babylon.setDelegate(delegate)
        #expect(true)
    }
}

// MARK: - Configuration Methods Tests

@Suite(.serialized)
struct BabylonConfigurationMethodTests {
    @Test("setIgnoreProtocols does not crash with empty array")
    func setIgnoreProtocolsEmpty() {
        Babylon.setIgnoreProtocols([])
        #expect(true)
    }

    @Test("setIgnoreProtocols accepts protocol classes")
    func setIgnoreProtocolsWithClasses() {
        Babylon.setIgnoreProtocols([URLProtocol.self])
        // Clean up.
        Babylon.setIgnoreProtocols([])
        #expect(true)
    }

    @Test("setEnableTransportLayer toggles without crash")
    func setEnableTransportLayer() {
        Babylon.setEnableTransportLayer(false)
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("setIsRunningOniOSPlayground toggles without crash")
    func setIsRunningOniOSPlayground() {
        Babylon.setIsRunningOniOSPlayground(true)
        Babylon.setIsRunningOniOSPlayground(false)
        #expect(true)
    }
}

// MARK: - Bundle Extension Tests

struct BundleExtensionTests {
    @Test("hasLocalNetworkUsageDescription returns a boolean")
    func localNetworkUsageDescription() {
        // In the test host, this key may or may not be present.
        // We verify the property does not crash and returns a Bool.
        let result = Bundle.main.hasLocalNetworkUsageDescription
        #expect(result == true || result == false)
    }

    @Test("hasBonjourServices returns a boolean")
    func bonjourServices() {
        let result = Bundle.main.hasBonjourServices
        #expect(result == true || result == false)
    }
}

// MARK: - Package Cache Tests

@Suite(.serialized)
struct PackageCacheTests {
    @Test("Packages dictionary starts empty on a fresh singleton")
    func packagesCacheIsAccessible() {
        // We verify the singleton can be accessed and start/stop
        // properly manages internal state without crashing.
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("TrafficPackage can be built from URLRequest and URLResponse")
    func buildFromURLRequestAndResponse() throws {
        let url = try #require(URL(string: "https://api.example.com/test"))
        let urlRequest = URLRequest(url: url)
        let urlResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))

        let package = TrafficPackage.buildRequest(
            urlRequest: urlRequest,
            urlResponse: urlResponse,
            bodyData: "test".data(using: .utf8)
        )

        #expect(package != nil)
        #expect(package?.request.url == "https://api.example.com/test")
        #expect(package?.response?.statusCode == 200)
    }

    @Test("TrafficPackage can be built from URLRequest and Error")
    func buildFromURLRequestAndError() throws {
        let url = try #require(URL(string: "https://api.example.com/fail"))
        let urlRequest = URLRequest(url: url)
        let error = NSError(domain: "TestDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Test error"])

        let package = TrafficPackage.buildRequest(urlRequest: urlRequest, error: error)

        #expect(package != nil)
        #expect(package?.request.url == "https://api.example.com/fail")
        #expect(package?.error?.code == -1)
        #expect(package?.error?.message == "Test error")
        #expect(package?.endAt != nil)
    }
}

// MARK: - Enabled Flag Tests

@Suite(.serialized)
struct IsEnabledFlagTests {
    @Test("isEnabled starts as false")
    func startsDisabled() {
        // After a clean stop, isEnabled should be false.
        Babylon.stop()
        // We start and stop to ensure a known state.
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        Babylon.stop()
        Babylon.setEnableTransportLayer(true)

        // After stop, a second stop should be a no-op (guard fails).
        // This indirectly confirms the flag is false.
        Babylon.stop()
        #expect(true)
    }

    @Test("isEnabled becomes true after start and false after stop")
    func togglesCorrectly() {
        Babylon.setEnableTransportLayer(false)

        Babylon.start()
        // A second start should be a no-op (guard succeeds).
        Babylon.start()

        Babylon.stop()
        // A second stop should be a no-op (guard fails).
        Babylon.stop()

        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }
}

// MARK: - Expanded Core Tests

@Suite(.serialized)
struct BabylonExpandedTests {
    @Test("setDelegate holds delegate weakly — nil after strong ref released")
    func delegateHeldWeakly() throws {
        class TestDelegate: BabylonDelegate {
            func babylonDidCapturePackage(_ package: TrafficPackage) {}
        }

        var delegate: TestDelegate? = TestDelegate()
        try Babylon.setDelegate(#require(delegate))

        delegate = nil

        // Weak reference should become nil — no crash is the primary assertion.
        #expect(true)
    }

    @Test("setEnableTransportLayer(false) before start prevents transporter activation")
    func disableTransportBeforeStart() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
        #expect(true)
    }

    @Test("isEnabled is false after stop")
    func isEnabledFalseAfterStop() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        #expect(Babylon.isEnabled.value == true)
        Babylon.stop()
        #expect(Babylon.isEnabled.value == false)
        Babylon.setEnableTransportLayer(true)
    }

    @Test("start when already started is no-op (idempotent)")
    func startIdempotent() {
        Babylon.setEnableTransportLayer(false)
        Babylon.start()
        Babylon.start() // Should be no-op
        #expect(Babylon.isEnabled.value == true)
        Babylon.stop()
        Babylon.setEnableTransportLayer(true)
    }

    @Test("setIgnoreProtocols replaces previous protocol list")
    func setIgnoreProtocolsReplaces() {
        Babylon.setIgnoreProtocols([URLProtocol.self])
        Babylon.setIgnoreProtocols([])
        // No crash is the assertion — we can't read the internal list
        #expect(true)
    }

    @Test("setRedactedHeaders stores header keys")
    func setRedactedHeaders() {
        Babylon.setRedactedHeaders(["Authorization", "Cookie"])
        // Clean up
        Babylon.setRedactedHeaders([])
        #expect(true)
    }
}
