import Foundation
import Testing
@testable import Babylon

// MARK: - Configuration Tests

struct ConfigurationExpandedTests {
    @Test("Default config with nil hostname has nil hostName")
    func defaultNilHostname() {
        let config = Configuration.default()
        #expect(config.hostName == nil)
    }

    @Test("Default config with hostname preserves it")
    func defaultWithHostname() {
        let config = Configuration.default(hostName: "my-macbook")
        #expect(config.hostName == "my-macbook")
    }

    @Test("Config ID is an opaque UUID")
    func idIsOpaqueUUID() {
        let config = Configuration.default()
        #expect(UUID(uuidString: config.id) != nil)
        #expect(!config.id.contains(Project.current.bundleIdentifier))
        #expect(!config.id.contains(Device.current.name))
    }

    @Test("Config ID is fresh across calls")
    func idIsFresh() {
        let config1 = Configuration.default()
        let config2 = Configuration.default()
        #expect(config1.id != config2.id)
    }

    @Test("Default config with authToken preserves it")
    func defaultWithAuthToken() {
        let config = Configuration.default(authToken: testPairingToken)
        #expect(config.authToken == testPairingToken)
        #expect(config.hasValidAuthentication)
    }

    @Test("Default config with nil authToken has nil authToken")
    func defaultNilAuthToken() {
        let config = Configuration.default()
        #expect(config.authToken == nil)
    }

    @Test("Authentication rejects malformed pairing tokens")
    func malformedAuthenticationToken() {
        #expect(!Configuration.default(authToken: "short-token").hasValidAuthentication)
        #expect(!Configuration.default(authToken: String(repeating: "A", count: 64)).hasValidAuthentication)
        #expect(!Configuration.default(authToken: String(repeating: "z", count: 64)).hasValidAuthentication)
    }
}

// MARK: - Device Tests

struct DeviceExpandedTests {
    @Test("Device.current has non-empty name")
    func deviceHasNonEmptyName() {
        let device = Device.current
        #expect(!device.name.isEmpty, "Device name should not be empty")
    }

    @Test("Device.current has non-empty model")
    func deviceHasNonEmptyModel() {
        let device = Device.current
        #expect(!device.model.isEmpty, "Device model should not be empty")
    }
}

// MARK: - Project Tests

struct ProjectExpandedTests {
    @Test("Project.current has non-empty bundleIdentifier")
    func projectHasNonEmptyBundleIdentifier() {
        let project = Project.current
        #expect(!project.bundleIdentifier.isEmpty, "Project bundleIdentifier should not be empty")
    }
}
