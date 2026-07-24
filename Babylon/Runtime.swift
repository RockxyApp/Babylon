// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ObjectiveC

final class Atomic<Value> {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func mutate(_ operation: (inout Value) -> Void) {
        lock.withLock { operation(&storage) }
    }

    func exchange(_ replacement: Value) -> Value {
        lock.withLock {
            let previous = storage
            storage = replacement
            return previous
        }
    }
}

extension Atomic where Value: Equatable {
    func compareExchange(expected: Value, desired: Value) -> Bool {
        lock.withLock {
            guard storage == expected else { return false }
            storage = desired
            return true
        }
    }
}

enum Runtime {
    static func object<Value>(from object: AnyObject, selector: Selector, as _: Value.Type) -> Value? {
        guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(object, selector) as? Value
    }

    static func getAllClasses() -> [AnyClass] {
        let reportedCount = Int(objc_getClassList(nil, 0))
        guard reportedCount > 0 else { return [] }

        let storage = UnsafeMutablePointer<AnyClass?>.allocate(capacity: reportedCount)
        defer { storage.deallocate() }
        let classBuffer = AutoreleasingUnsafeMutablePointer<AnyClass>(storage)
        let populatedCount = min(reportedCount, Int(objc_getClassList(classBuffer, Int32(reportedCount))))
        return (0 ..< populatedCount).compactMap { storage[$0] }
    }

    static func getAllMethods(for anyClass: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(anyClass, &count) else { return [] }
        defer { free(methods) }

        return (0 ..< Int(count)).map { index in
            NSStringFromSelector(method_getName(methods[index]))
        }
    }
}

private enum InternalTaskMarker {
    static var key: UInt8 = 0
}

extension URLSessionTask {
    func markAsBabylonInternal() {
        objc_setAssociatedObject(self, &InternalTaskMarker.key, true, .OBJC_ASSOCIATION_RETAIN)
    }

    func isBabylonInternal() -> Bool {
        (objc_getAssociatedObject(self, &InternalTaskMarker.key) as? Bool) == true
    }
}

enum GRPCStatusCode: Int {
    case ok = 0
    case cancelled = 1
    case unknown = 2
    case invalidArgument = 3
    case deadlineExceeded = 4
    case notFound = 5
    case alreadyExists = 6
    case permissionDenied = 7
    case resourceExhausted = 8
    case failedPrecondition = 9
    case aborted = 10
    case outOfRange = 11
    case unimplemented = 12
    case internalError = 13
    case unavailable = 14
    case dataLoss = 15
    case unauthenticated = 16

    var description: String {
        "\(self) (code=\(rawValue))"
    }
}
