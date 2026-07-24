// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

private final class OnceRegistry: @unchecked Sendable {
    static let shared = OnceRegistry()

    private var claimedTokens: Set<String> = []
    private let lock = NSLock()

    func claim(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimedTokens.insert(token).inserted
    }
}

extension DispatchQueue {
    class func once(
        file: String = #fileID,
        function: String = #function,
        line: Int = #line,
        block: () -> Void
    ) {
        once(token: "\(file)|\(function)|\(line)", block: block)
    }

    class func once(token: String, block: () -> Void) {
        guard OnceRegistry.shared.claim(token) else { return }
        block()
    }
}
