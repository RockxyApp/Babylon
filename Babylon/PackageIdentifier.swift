// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ObjectiveC

enum PackageIdentifier {
    private static var associationKey: UInt8 = 0
    private static let lock = NSLock()

    static func getID(for object: AnyObject) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let identifier = objc_getAssociatedObject(object, &associationKey) as? String {
            return identifier
        }

        let identifier = UUID().uuidString
        objc_setAssociatedObject(object, &associationKey, identifier, .OBJC_ASSOCIATION_RETAIN)
        return identifier
    }
}
