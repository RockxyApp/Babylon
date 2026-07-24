// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct TraceStartResult {
    let traceId: String?
    let packages: [RuntimePackage]
}

struct TraceStepResult {
    let packages: [RuntimePackage]
}

struct TraceFinishResult {
    let packages: [RuntimePackage]
}

final class TraceContextStore {
    private struct TraceRecord {
        let traceId: String
        let name: String
        let rootStepId: String
        let startedAt: TimeInterval
        var activeStepId: String
        var activeStepName: String
        var activeStepStartedAt: TimeInterval
        var finishedAt: TimeInterval?

        var isFinished: Bool {
            finishedAt != nil
        }
    }

    private var sessionId: String?
    private var sessionStartedAt: TimeInterval?
    private var traces: [String: TraceRecord] = [:]
    private var activeTraceId: String?
    private var packageCorrelationContexts: [String: CorrelationContext] = [:]

    var currentSessionId: String? {
        sessionId
    }

    func startSession(name: String, metadata: [String: String]) -> RuntimePackage {
        let newSessionId = UUID().uuidString
        let now = Date().timeIntervalSince1970

        sessionId = newSessionId
        sessionStartedAt = now
        traces.removeAll()
        activeTraceId = nil
        packageCorrelationContexts.removeAll()

        return RuntimePackage(
            kind: .sessionStarted,
            sessionId: newSessionId,
            name: name,
            createdAt: now,
            startedAt: now,
            metadata: metadata
        )
    }

    func finishSession(name: String, metadata: [String: String]) -> [RuntimePackage] {
        guard let sessionId else { return [] }
        let now = Date().timeIntervalSince1970
        var packages: [RuntimePackage] = []

        for traceId in traces.keys.sorted() {
            packages.append(contentsOf: finishTrace(traceId: traceId, metadata: [:], endedAt: now).packages)
        }

        packages.append(RuntimePackage(
            kind: .sessionFinished,
            sessionId: sessionId,
            name: name,
            createdAt: now,
            startedAt: sessionStartedAt,
            endedAt: now,
            duration: sessionStartedAt.map { now - $0 },
            metadata: metadata
        ))

        clear()
        return packages
    }

    func clear() {
        sessionId = nil
        sessionStartedAt = nil
        traces.removeAll()
        activeTraceId = nil
        packageCorrelationContexts.removeAll()
    }

    func startTrace(name: String, metadata: [String: String]) -> TraceStartResult {
        guard let sessionId else {
            return TraceStartResult(traceId: nil, packages: [])
        }

        let now = Date().timeIntervalSince1970
        let traceId = UUID().uuidString
        let rootStepId = UUID().uuidString
        traces[traceId] = TraceRecord(
            traceId: traceId,
            name: name,
            rootStepId: rootStepId,
            startedAt: now,
            activeStepId: rootStepId,
            activeStepName: name,
            activeStepStartedAt: now
        )
        activeTraceId = traceId

        let package = RuntimePackage(
            kind: .traceStarted,
            sessionId: sessionId,
            traceId: traceId,
            stepId: rootStepId,
            name: name,
            createdAt: now,
            startedAt: now,
            metadata: metadata
        )
        return TraceStartResult(traceId: traceId, packages: [package])
    }

    func step(traceId: String?, name: String, metadata: [String: String]) -> TraceStepResult {
        guard let traceId,
              let sessionId,
              var trace = traces[traceId],
              !trace.isFinished else {
            return TraceStepResult(packages: [])
        }

        let now = Date().timeIntervalSince1970
        let previousStepId = trace.activeStepId
        let previousStepName = trace.activeStepName
        let previousStepStartedAt = trace.activeStepStartedAt
        let nextStepId = UUID().uuidString

        trace.activeStepId = nextStepId
        trace.activeStepName = name
        trace.activeStepStartedAt = now
        traces[traceId] = trace
        activeTraceId = traceId

        let finished = RuntimePackage(
            kind: .stepFinished,
            sessionId: sessionId,
            traceId: traceId,
            stepId: previousStepId,
            name: previousStepName,
            createdAt: now,
            startedAt: previousStepStartedAt,
            endedAt: now,
            duration: now - previousStepStartedAt
        )
        let started = RuntimePackage(
            kind: .stepStarted,
            sessionId: sessionId,
            traceId: traceId,
            stepId: nextStepId,
            parentStepId: trace.rootStepId,
            name: name,
            createdAt: now,
            startedAt: now,
            metadata: metadata
        )

        return TraceStepResult(packages: [finished, started])
    }

    func finishTrace(traceId: String?, metadata: [String: String]) -> TraceFinishResult {
        guard let traceId else {
            return TraceFinishResult(packages: [])
        }
        return finishTrace(traceId: traceId, metadata: metadata, endedAt: Date().timeIntervalSince1970)
    }

    func mark(name: String, metadata: [String: String]) -> RuntimePackage? {
        buildInstantPackage(kind: .mark, name: name, metadata: metadata, error: nil)
    }

    func event(name: String, metadata: [String: String]) -> RuntimePackage? {
        buildInstantPackage(kind: .event, name: name, metadata: metadata, error: nil)
    }

    func error(name: String, error: Error, metadata: [String: String]) -> RuntimePackage? {
        buildInstantPackage(kind: .error, name: name, metadata: metadata, error: CustomError(error))
    }

    func activeCorrelationContext() -> CorrelationContext? {
        guard let sessionId,
              let traceId = activeTraceId,
              let trace = traces[traceId],
              !trace.isFinished else {
            return nil
        }

        return CorrelationContext(
            sessionId: sessionId,
            traceId: trace.traceId,
            stepId: trace.activeStepId
        )
    }

    func setCorrelationContext(_ context: CorrelationContext?, forPackageId packageId: String) {
        guard let context else { return }
        packageCorrelationContexts[packageId] = context
    }

    func correlationContext(forPackageId packageId: String) -> CorrelationContext? {
        packageCorrelationContexts[packageId]
    }

    func removeCorrelationContext(forPackageId packageId: String) {
        packageCorrelationContexts.removeValue(forKey: packageId)
    }

    private func finishTrace(
        traceId: String,
        metadata: [String: String],
        endedAt: TimeInterval
    ) -> TraceFinishResult {
        guard let sessionId,
              var trace = traces[traceId],
              !trace.isFinished else {
            return TraceFinishResult(packages: [])
        }

        trace.finishedAt = endedAt
        traces[traceId] = trace
        if activeTraceId == traceId {
            activeTraceId = traces.values
                .filter { !$0.isFinished }
                .max { $0.activeStepStartedAt < $1.activeStepStartedAt }?
                .traceId
        }

        let stepFinished = RuntimePackage(
            kind: .stepFinished,
            sessionId: sessionId,
            traceId: traceId,
            stepId: trace.activeStepId,
            name: trace.activeStepName,
            createdAt: endedAt,
            startedAt: trace.activeStepStartedAt,
            endedAt: endedAt,
            duration: endedAt - trace.activeStepStartedAt
        )
        let traceFinished = RuntimePackage(
            kind: .traceFinished,
            sessionId: sessionId,
            traceId: traceId,
            stepId: trace.rootStepId,
            name: trace.name,
            createdAt: endedAt,
            startedAt: trace.startedAt,
            endedAt: endedAt,
            duration: endedAt - trace.startedAt,
            metadata: metadata
        )

        return TraceFinishResult(packages: [stepFinished, traceFinished])
    }

    private func buildInstantPackage(
        kind: RuntimePackage.Kind,
        name: String,
        metadata: [String: String],
        error: CustomError?
    ) -> RuntimePackage? {
        guard let sessionId else { return nil }
        let now = Date().timeIntervalSince1970
        let trace = activeTraceId.flatMap { traces[$0] }

        return RuntimePackage(
            kind: kind,
            sessionId: sessionId,
            traceId: trace?.traceId,
            stepId: trace?.activeStepId,
            name: name,
            createdAt: now,
            metadata: metadata,
            error: error
        )
    }
}
