// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct Configuration {
    let projectName: String
    let deviceName: String
    let clientID: String
    let sessionID: String
    let hostName: String?
    let authToken: String?

    var id: String {
        clientID
    }

    var normalizedAuthToken: String {
        authToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var hasValidAuthentication: Bool {
        normalizedAuthToken.utf8.count == 64 && normalizedAuthToken.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }

    static func `default`(hostName: String? = nil, authToken: String? = nil) -> Configuration {
        let project = Project.current
        let device = Device.current
        return Configuration(
            projectName: project.name,
            deviceName: device.name,
            clientID: UUID().uuidString,
            sessionID: UUID().uuidString,
            hostName: hostName,
            authToken: authToken
        )
    }

    func withAuthToken(_ authToken: String?) -> Configuration {
        var replacement = self
        replacement = Configuration(
            projectName: replacement.projectName,
            deviceName: replacement.deviceName,
            clientID: replacement.clientID,
            sessionID: replacement.sessionID,
            hostName: replacement.hostName,
            authToken: authToken
        )
        return replacement
    }
}
