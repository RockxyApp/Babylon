// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

@objc(BabylonHelper)
final class BabylonHelper: NSObject {
    static let dataSelector = "data"
    static let stringSelector = "string"

    private static let logger = Logger(subsystem: "com.amunx.Babylon", category: "WebSocketBridge")

    static func extractData(from message: NSObject) -> Data? {
        value(from: message, selectorName: dataSelector, as: Data.self)
    }

    static func extractString(from message: NSObject) -> String? {
        value(from: message, selectorName: stringSelector, as: String.self)
    }

    @objc
    static func swizzleWebSocketReceiveMessage(
        withCompleteHandler handler: AnyObject,
        responseHandler: ((String?, Data?, Error?) -> Void)?
    ) -> AnyObject? {
        typealias Completion = @convention(block) (NSObject?, NSError?) -> Void
        guard NSStringFromClass(type(of: handler)).contains("Block") else {
            logger.error("Unsupported WebSocket completion handler representation")
            return nil
        }

        let original = unsafeBitCast(handler, to: Completion.self)
        let intercepted: Completion = { message, error in
            if let message, NSStringFromClass(type(of: message)) == "NSURLSessionWebSocketMessage" {
                responseHandler?(extractString(from: message), extractData(from: message), error)
            }
            original(message, error)
        }
        return intercepted as AnyObject
    }

    private static func value<Value>(from object: NSObject, selectorName: String, as _: Value.Type) -> Value? {
        Runtime.object(from: object, selector: Selector(selectorName), as: Value.self)
    }
}
