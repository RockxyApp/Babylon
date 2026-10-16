// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Accounts for memory retained by Babylon's capture pipeline.
///
/// Estimates include headroom for JSON/base64 encoding, protocol wrapping, and
/// encrypted-frame copies. Leases follow retained objects and release on drop.
final class CaptureMemoryBudget {
    static let shared = CaptureMemoryBudget(limit: BabylonConstants.maximumCaptureMemoryBytes)

    private let lock = NSLock()
    private let limit: Int
    private var used = 0
    private var highWater = 0
    private var drops = 0

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func reserve(_ bytes: Int) -> CaptureMemoryLease? {
        let amount = max(1, bytes)
        lock.lock()
        defer { lock.unlock() }
        guard amount <= limit - used else {
            drops += 1
            return nil
        }
        used += amount
        highWater = max(highWater, used)
        return CaptureMemoryLease(budget: self, bytes: amount)
    }

    fileprivate func resize(_ lease: CaptureMemoryLease, to requested: Int) -> Bool {
        let amount = max(1, requested)
        lock.lock()
        defer { lock.unlock() }
        let growth = amount - lease.bytes
        guard growth <= 0 || growth <= limit - used else {
            drops += 1
            return false
        }
        used += growth
        lease.bytes = amount
        highWater = max(highWater, used)
        return true
    }

    fileprivate func release(_ bytes: Int) {
        lock.lock()
        used = max(0, used - bytes)
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(limitBytes: limit, usedBytes: used, highWaterBytes: highWater, droppedReservations: drops)
    }

    struct Snapshot: Equatable {
        let limitBytes: Int
        let usedBytes: Int
        let highWaterBytes: Int
        let droppedReservations: Int
    }
}

final class CaptureMemoryLease {
    private let budget: CaptureMemoryBudget
    fileprivate var bytes: Int

    fileprivate init(budget: CaptureMemoryBudget, bytes: Int) {
        self.budget = budget
        self.bytes = bytes
    }

    func resize(to bytes: Int) -> Bool {
        budget.resize(self, to: bytes)
    }

    deinit {
        budget.release(bytes)
    }
}

final class BoundedCaptureWorkQueue {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let maximumItems: Int
    private var pending: [() -> Void] = []
    private var draining = false
    private var dropped = 0

    init(label: String, maximumItems: Int = BabylonConstants.maxPendingItems) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.maximumItems = maximumItems
    }

    @discardableResult
    func enqueue(_ work: @escaping () -> Void) -> Bool {
        lock.lock()
        guard pending.count < maximumItems else {
            dropped += 1
            lock.unlock()
            return false
        }
        pending.append(work)
        let shouldStart = !draining
        if shouldStart {
            draining = true
        }
        lock.unlock()
        if shouldStart {
            queue.async { [weak self] in self?.drain() }
        }
        return true
    }

    func clear() {
        lock.lock()
        dropped += pending.count
        pending.removeAll()
        lock.unlock()
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    var droppedWorkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                draining = false
                lock.unlock()
                return
            }
            let work = pending.removeFirst()
            lock.unlock()
            work()
        }
    }
}

enum CaptureMemoryEstimate {
    /// Budget several simultaneous representations of captured bytes.
    static func retained(bodyBytes: Int, stringBytes: Int) -> Int {
        let (body, bodyOverflow) = max(0, bodyBytes).multipliedReportingOverflow(by: 2)
        let (strings, stringOverflow) = max(0, stringBytes).multipliedReportingOverflow(by: 6)
        guard !bodyOverflow, !stringOverflow else { return Int.max }
        let (total, overflow) = body.addingReportingOverflow(strings)
        return overflow ? Int.max : max(4096, total)
    }
}
