import Foundation
import Testing
@testable import Babylon

@Suite("URLSession Timing Payload")
struct URLSessionTimingTests {
    @Test("Unavailable phases stay absent while a measured zero remains encoded")
    func unavailableAndMeasuredZeroAreDistinct() throws {
        let transaction = URLSessionTiming.Transaction(
            index: 0,
            fetchDuration: 0,
            dnsDuration: nil,
            connectDuration: 0,
            secureConnectDuration: nil,
            requestDuration: nil,
            serverWaitDuration: 0,
            responseTransferDuration: nil,
            networkProtocolName: "http/1.1",
            reusedConnection: false,
            proxyConnection: false,
            resourceFetchType: "networkLoad"
        )
        let timing = try #require(URLSessionTiming.bounded(
            taskDuration: 0,
            redirectCount: 0,
            reportedTransactionCount: 1,
            transactions: [transaction]
        ))
        let package = TrafficPackage(
            id: "metrics-zero",
            request: Request(url: "http://127.0.0.1/zero", method: "GET", headers: [], body: nil)
        )
        package.setURLSessionTiming(timing)

        let data = try #require(package.toData())
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let timingJSON = try #require(root["urlSessionTiming"] as? [String: Any])
        let transactions = try #require(timingJSON["transactions"] as? [[String: Any]])
        let first = try #require(transactions.first)

        #expect(timingJSON["schemaVersion"] as? Int == 1)
        #expect(first["fetchDuration"] as? Double == 0)
        #expect(first["connectDuration"] as? Double == 0)
        #expect(first["serverWaitDuration"] as? Double == 0)
        #expect(first["dnsDuration"] == nil)
        #expect(first["secureConnectDuration"] == nil)
    }

    @Test("Redirect transactions retain original order and bounded payload size")
    func redirectsAreOrderedAndBounded() throws {
        let transactions = (0 ..< 32).map { index in
            URLSessionTiming.Transaction(
                index: index,
                fetchDuration: 0.25,
                dnsDuration: nil,
                connectDuration: nil,
                secureConnectDuration: nil,
                requestDuration: 0,
                serverWaitDuration: nil,
                responseTransferDuration: nil,
                networkProtocolName: String(repeating: "h", count: 10000),
                reusedConnection: index > 0,
                proxyConnection: false,
                resourceFetchType: "networkLoad"
            )
        }

        let timing = try #require(URLSessionTiming.bounded(
            taskDuration: 1,
            redirectCount: 31,
            reportedTransactionCount: transactions.count,
            transactions: transactions
        ))

        #expect(timing.transactions.count <= URLSessionTiming.maximumTransactions)
        #expect(timing.transactions.map(\.index) == Array(0 ..< timing.transactions.count))
        #expect(timing.omittedTransactionCount == transactions.count - timing.transactions.count)
        #expect(timing.encodedByteCount <= URLSessionTiming.maximumEncodedBytes)
        #expect(timing.transactions.first?.networkProtocolName?.utf8.count == 128)
    }

    @Test("Missing metrics and failed requests remain valid without fabricated timing")
    func missingMetricsRemainAbsent() throws {
        let package = TrafficPackage(
            id: "metrics-missing",
            request: Request(url: "http://127.0.0.1/failure", method: "GET", headers: [], body: nil)
        )
        package.updateDidComplete(URLError(.cannotConnectToHost))

        let data = try #require(package.toData())
        let decoded = try JSONDecoder().decode(TrafficPackage.self, from: data)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded.error?.code == URLError.cannotConnectToHost.rawValue)
        #expect(decoded.urlSessionTiming == nil)
        #expect(root["urlSessionTiming"] == nil)
    }
}
