// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A handle for an active Babylon workflow trace.
public final class BabylonTrace: Sendable {
    private let traceId: String?

    init(traceId: String?) {
        self.traceId = traceId
    }

    /// A snapshot of this trace's current session and step, suitable for explicit propagation.
    /// The value remains stable when the trace advances to another step.
    public var correlationContext: CorrelationContext? {
        guard let traceId, Babylon.isEnabled.value else { return nil }
        return Babylon.shared.correlationContextSnapshot(forTraceId: traceId)
    }

    /// Finishes the current step and starts a new step within this trace.
    ///
    /// Calls after ``finish(metadata:)`` are no-ops.
    ///
    /// - Parameters:
    ///   - name: Human-readable step name shown in Rockxy.
    ///   - metadata: Optional debugging metadata. Values are capped before transmission.
    public func step(_ name: String, metadata: [String: String] = [:]) {
        Babylon.shared.stepTrace(traceId: traceId, name: name, metadata: metadata)
    }

    /// Finishes the current step and the trace.
    ///
    /// This method is idempotent.
    ///
    /// - Parameter metadata: Optional debugging metadata. Values are capped before transmission.
    public func finish(metadata: [String: String] = [:]) {
        Babylon.shared.finishTrace(traceId: traceId, metadata: metadata)
    }

    /// Starts a step and runs asynchronous work with that step's scoped correlation context.
    public func withStep<T>(
        _ name: String,
        metadata: [String: String] = [:],
        operation: () async throws -> T
    ) async rethrows -> T {
        step(name, metadata: metadata)
        return try await Babylon.withTrace(self, operation: operation)
    }

    /// Starts a step and runs synchronous callback work with that step's scoped context.
    public func withStep<T>(
        _ name: String,
        metadata: [String: String] = [:],
        operation: () throws -> T
    ) rethrows -> T {
        step(name, metadata: metadata)
        return try Babylon.withTrace(self, operation: operation)
    }
}

public extension Babylon {
    /// The scoped correlation context for the current task, or the legacy context when exactly
    /// one trace is active. Returns `nil` when concurrent traces make inference ambiguous.
    class var currentCorrelationContext: CorrelationContext? {
        Babylon.shared.activeCorrelationContextSnapshot(scope: BabylonTraceScope.current)
    }

    #if compiler(>=6.2)
    /// Runs asynchronous work with a trace context. Structured child tasks inherit the scope.
    class func withTrace<T>(
        _ trace: BabylonTrace,
        operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await BabylonTraceScope.$current.withValue(
            CorrelationScope(context: trace.correlationContext),
            operation: operation
        )
    }
    #else
    /// Runs asynchronous work with a trace context. Structured child tasks inherit the scope.
    class func withTrace<T>(
        _ trace: BabylonTrace,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await BabylonTraceScope.$current.withValue(
            CorrelationScope(context: trace.correlationContext),
            operation: operation
        )
    }
    #endif

    /// Runs synchronous callback work with a trace context.
    class func withTrace<T>(
        _ trace: BabylonTrace,
        operation: () throws -> T
    ) rethrows -> T {
        try BabylonTraceScope.$current.withValue(
            CorrelationScope(context: trace.correlationContext),
            operation: operation
        )
    }

    #if compiler(>=6.2)
    /// Runs asynchronous work with an explicitly captured context, including detached tasks.
    class func withTraceContext<T>(
        _ context: CorrelationContext,
        operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await BabylonTraceScope.$current.withValue(CorrelationScope(context: context), operation: operation)
    }
    #else
    /// Runs asynchronous work with an explicitly captured context, including detached tasks.
    class func withTraceContext<T>(
        _ context: CorrelationContext,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await BabylonTraceScope.$current.withValue(CorrelationScope(context: context), operation: operation)
    }
    #endif

    /// Runs callback or queue work with an explicitly captured context.
    class func withTraceContext<T>(
        _ context: CorrelationContext,
        operation: () throws -> T
    ) rethrows -> T {
        try BabylonTraceScope.$current.withValue(CorrelationScope(context: context), operation: operation)
    }

    /// Starts a workflow trace that can correlate application execution with network traffic.
    ///
    /// - Parameters:
    ///   - name: Human-readable trace name shown in Rockxy.
    ///   - metadata: Optional debugging metadata. Values are capped before transmission.
    /// - Returns: A trace handle. If Babylon is stopped, the returned handle is inert.
    class func startTrace(_ name: String, metadata: [String: String] = [:]) -> BabylonTrace {
        guard isEnabled.value else {
            return BabylonTrace(traceId: nil)
        }

        var result: TraceStartResult?
        Babylon.shared.queue.sync {
            result = Babylon.shared.traceContextStore.startTrace(name: name, metadata: metadata)
        }

        if let result {
            Babylon.shared.startSendingRuntimeMessages(packages: result.packages)
            return BabylonTrace(traceId: result.traceId)
        }

        return BabylonTrace(traceId: nil)
    }

    /// Adds an instant timeline mark to the current Babylon session.
    ///
    /// - Parameters:
    ///   - name: Human-readable mark name shown in Rockxy.
    ///   - metadata: Optional debugging metadata. Values are capped before transmission.
    class func mark(_ name: String, metadata: [String: String] = [:]) {
        Babylon.shared.sendInstantRuntime(kind: .mark, name: name, metadata: metadata)
    }

    /// Adds an application event to the current Babylon session.
    ///
    /// - Parameters:
    ///   - name: Human-readable event name shown in Rockxy.
    ///   - metadata: Optional debugging metadata. Values are capped before transmission.
    class func event(_ name: String, metadata: [String: String] = [:]) {
        Babylon.shared.sendInstantRuntime(kind: .event, name: name, metadata: metadata)
    }

    /// Adds an application error to the current Babylon session.
    ///
    /// The error is simplified to code and localized message before transmission.
    ///
    /// - Parameters:
    ///   - name: Human-readable error name shown in Rockxy.
    ///   - error: The error that occurred.
    ///   - metadata: Optional debugging metadata. Values are capped before transmission.
    class func error(_ name: String, error: Error, metadata: [String: String] = [:]) {
        guard isEnabled.value else { return }

        let scope = BabylonTraceScope.current
        var package: RuntimePackage?
        Babylon.shared.queue.sync {
            package = Babylon.shared.traceContextStore.error(name: name, error: error, metadata: metadata, scope: scope)
        }
        Babylon.shared.startSendingRuntimeMessages(packages: package.map { [$0] } ?? [])
    }
}

extension Babylon {
    func activeCorrelationContextSnapshot(scope: CorrelationScope?) -> CorrelationContext? {
        queue.sync {
            traceContextStore.activeCorrelationContext(scope: scope)
        }
    }

    func correlationContextSnapshot(forTraceId traceId: String) -> CorrelationContext? {
        queue.sync { traceContextStore.correlationContext(forTraceId: traceId) }
    }

    func stepTrace(traceId: String?, name: String, metadata: [String: String]) {
        guard Babylon.isEnabled.value else { return }

        var result: TraceStepResult?
        queue.sync {
            result = traceContextStore.step(traceId: traceId, name: name, metadata: metadata)
        }
        startSendingRuntimeMessages(packages: result?.packages ?? [])
    }

    func finishTrace(traceId: String?, metadata: [String: String]) {
        guard Babylon.isEnabled.value else { return }

        var result: TraceFinishResult?
        queue.sync {
            result = traceContextStore.finishTrace(traceId: traceId, metadata: metadata)
        }
        startSendingRuntimeMessages(packages: result?.packages ?? [])
    }

    func sendInstantRuntime(kind: RuntimePackage.Kind, name: String, metadata: [String: String]) {
        guard Babylon.isEnabled.value else { return }

        let scope = BabylonTraceScope.current
        var package: RuntimePackage?
        queue.sync {
            switch kind {
            case .mark:
                package = traceContextStore.mark(name: name, metadata: metadata, scope: scope)
            case .event:
                package = traceContextStore.event(name: name, metadata: metadata, scope: scope)
            case .error,
                 .sessionStarted,
                 .sessionFinished,
                 .traceStarted,
                 .stepStarted,
                 .stepFinished,
                 .traceFinished:
                package = nil
            }
        }
        startSendingRuntimeMessages(packages: package.map { [$0] } ?? [])
    }
}
