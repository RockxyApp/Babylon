// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Bounded, versioned timing data copied from URLSession's documented task metrics.
///
/// The payload deliberately contains no request URLs or headers. A missing duration means the
/// operating system did not report both endpoints for that phase; a reported `0` remains measured.
struct URLSessionTiming: Codable, Equatable, CaptureMemoryEstimating {
    static let currentSchemaVersion = 1
    static let maximumTransactions = 8
    static let maximumEncodedBytes = 8192
    private static let maximumProtocolNameBytes = 128

    let schemaVersion: Int
    let taskDuration: TimeInterval?
    let redirectCount: Int
    let reportedTransactionCount: Int
    let omittedTransactionCount: Int
    let transactions: [Transaction]

    struct Transaction: Codable, Equatable {
        let index: Int
        let fetchDuration: TimeInterval?
        let dnsDuration: TimeInterval?
        let connectDuration: TimeInterval?
        let secureConnectDuration: TimeInterval?
        let requestDuration: TimeInterval?
        let serverWaitDuration: TimeInterval?
        let responseTransferDuration: TimeInterval?
        let networkProtocolName: String?
        let reusedConnection: Bool
        let proxyConnection: Bool
        let resourceFetchType: String
    }

    static func capture(_ metrics: URLSessionTaskMetrics) -> URLSessionTiming? {
        let allTransactions = metrics.transactionMetrics
        let transactions = allTransactions.prefix(maximumTransactions).enumerated().map { index, metric in
            Transaction(
                index: index,
                fetchDuration: metric.fetchStartDate.flatMap { start in
                    metric.responseEndDate.flatMap { end in duration(start, end) }
                },
                dnsDuration: metric.domainLookupStartDate.flatMap { start in
                    metric.domainLookupEndDate.flatMap { end in duration(start, end) }
                },
                connectDuration: metric.connectStartDate.flatMap { start in
                    metric.connectEndDate.flatMap { end in duration(start, end) }
                },
                secureConnectDuration: metric.secureConnectionStartDate.flatMap { start in
                    metric.secureConnectionEndDate.flatMap { end in duration(start, end) }
                },
                requestDuration: metric.requestStartDate.flatMap { start in
                    metric.requestEndDate.flatMap { end in duration(start, end) }
                },
                serverWaitDuration: metric.requestEndDate.flatMap { start in
                    metric.responseStartDate.flatMap { end in duration(start, end) }
                },
                responseTransferDuration: metric.responseStartDate.flatMap { start in
                    metric.responseEndDate.flatMap { end in duration(start, end) }
                },
                networkProtocolName: metric.networkProtocolName.map {
                    CaptureString.bounded($0, maximumBytes: maximumProtocolNameBytes)
                },
                reusedConnection: metric.isReusedConnection,
                proxyConnection: metric.isProxyConnection,
                resourceFetchType: resourceFetchType(metric.resourceFetchType)
            )
        }
        return bounded(
            taskDuration: duration(metrics.taskInterval.start, metrics.taskInterval.end),
            redirectCount: metrics.redirectCount,
            reportedTransactionCount: allTransactions.count,
            transactions: transactions
        )
    }

    static func bounded(
        taskDuration: TimeInterval?,
        redirectCount: Int,
        reportedTransactionCount: Int,
        transactions: [Transaction]
    ) -> URLSessionTiming? {
        let transactionLimit = Array(transactions.prefix(maximumTransactions))
        let reportedCount = min(max(reportedTransactionCount, transactions.count), 1_000_000)
        var result = URLSessionTiming(
            schemaVersion: currentSchemaVersion,
            taskDuration: boundedDuration(taskDuration),
            redirectCount: min(max(0, redirectCount), 1_000_000),
            reportedTransactionCount: reportedCount,
            omittedTransactionCount: max(0, reportedCount - transactionLimit.count),
            transactions: transactionLimit.map { transaction in
                Transaction(
                    index: max(0, transaction.index),
                    fetchDuration: boundedDuration(transaction.fetchDuration),
                    dnsDuration: boundedDuration(transaction.dnsDuration),
                    connectDuration: boundedDuration(transaction.connectDuration),
                    secureConnectDuration: boundedDuration(transaction.secureConnectDuration),
                    requestDuration: boundedDuration(transaction.requestDuration),
                    serverWaitDuration: boundedDuration(transaction.serverWaitDuration),
                    responseTransferDuration: boundedDuration(transaction.responseTransferDuration),
                    networkProtocolName: transaction.networkProtocolName.map {
                        CaptureString.bounded($0, maximumBytes: maximumProtocolNameBytes)
                    },
                    reusedConnection: transaction.reusedConnection,
                    proxyConnection: transaction.proxyConnection,
                    resourceFetchType: CaptureString.bounded(transaction.resourceFetchType, maximumBytes: 32)
                )
            }
        )

        while !result.transactions.isEmpty, result.encodedByteCount > maximumEncodedBytes {
            result = result.omittingLastTransaction()
        }
        guard result.encodedByteCount <= maximumEncodedBytes else { return nil }
        return result
    }

    var captureMemoryEstimate: Int {
        CaptureMemoryEstimate.retained(bodyBytes: encodedByteCount, stringBytes: 0)
    }

    var retainedByteCount: Int {
        encodedByteCount
    }

    var encodedByteCount: Int {
        (try? JSONEncoder().encode(self).count) ?? Self.maximumEncodedBytes + 1
    }

    private func omittingLastTransaction() -> URLSessionTiming {
        URLSessionTiming(
            schemaVersion: schemaVersion,
            taskDuration: taskDuration,
            redirectCount: redirectCount,
            reportedTransactionCount: reportedTransactionCount,
            omittedTransactionCount: omittedTransactionCount + 1,
            transactions: Array(transactions.dropLast())
        )
    }

    private static func duration(_ start: Date, _ end: Date) -> TimeInterval? {
        let value = end.timeIntervalSince(start)
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func boundedDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func resourceFetchType(_ value: URLSessionTaskMetrics.ResourceFetchType) -> String {
        switch value {
        case .networkLoad:
            "networkLoad"
        case .serverPush:
            "serverPush"
        case .localCache:
            "localCache"
        case .unknown:
            "unknown"
        @unknown default:
            "unknown"
        }
    }
}
