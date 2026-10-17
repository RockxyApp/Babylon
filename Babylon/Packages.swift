// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

#if os(macOS)
import AppKit

typealias Image = NSImage
#elseif os(iOS) || targetEnvironment(macCatalyst) || os(tvOS) || os(visionOS)
import UIKit

typealias Image = UIImage
#elseif os(watchOS)
import UIKit
import WatchKit

typealias Image = UIImage
#endif

protocol Serializable {
    func toData() -> Data?
}

protocol CaptureMemoryEstimating {
    var captureMemoryEstimate: Int { get }
}

extension CaptureMemoryEstimating {
    var captureMemoryEstimate: Int {
        4096
    }
}

enum CaptureString {
    static func bounded(_ value: String, maximumBytes: Int = BabylonConstants.maximumCaptureStringBytes) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            guard byteCount + scalarBytes <= maximumBytes else { break }
            result.append(scalar)
            byteCount += scalarBytes
        }
        return String(result)
    }

    static func headers(_ headers: [Header]) -> [Header] {
        var result: [Header] = []
        var byteCount = 0
        let ordered = headers.sorted {
            let left = $0.key.lowercased()
            let right = $1.key.lowercased()
            return left == right ? $0.key < $1.key : left < right
        }
        for header in ordered.prefix(BabylonConstants.maximumCaptureHeaderCount) {
            let key = bounded(header.key, maximumBytes: 256)
            let remaining = BabylonConstants.maximumCaptureHeaderBytes - byteCount - key.utf8.count
            guard remaining > 0 else { break }
            let value = bounded(header.value, maximumBytes: min(4096, remaining))
            byteCount += key.utf8.count + value.utf8.count
            result.append(Header(key: key, value: value))
            guard byteCount < BabylonConstants.maximumCaptureHeaderBytes else { break }
        }
        return result
    }
}

private enum PackageEncoding {
    static let logger = Logger(subsystem: "com.amunx.Babylon", category: "CaptureModels")
    static let omittedBody = Data("<Skip Large Body>".utf8)
    static let omittedText = "<Skip Large Body>"

    static func encode(_ value: some Encodable, label: String) -> Data? {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            logger.error("Could not encode \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func capturedSize(_ data: Data?) -> Int {
        guard let data, data != omittedBody else { return 0 }
        return data.count
    }

    static func bounded(_ data: Data?, limit: Int) -> Data? {
        guard let data else { return nil }
        return data.count <= max(0, limit) ? data : omittedBody
    }
}

private enum CaptureRedaction {
    static let replacement = "[REDACTED]"

    static func headers(_ headers: [Header]) -> [Header] {
        let names = Babylon.shared.redactedHeaderKeysSnapshot
        return headers.map { header in
            names.contains(header.key.lowercased())
                ? Header(key: header.key, value: replacement)
                : header
        }
    }

    static func url(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue),
              let items = components.queryItems else { return rawValue }
        let names = Babylon.shared.redactedQueryKeysSnapshot
        components.queryItems = items.map { item in
            names.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: replacement)
                : item
        }
        return components.string ?? rawValue
    }
}

struct ConnectionPackage: Codable, Serializable, CaptureMemoryEstimating {
    let device: Device
    let project: Project
    let icon: Data?
    let capabilities: ProducerCapabilities

    init(config: Configuration) {
        let detectedDevice = Device.current
        let detectedProject = Project.current
        device = Device(name: config.deviceName, model: detectedDevice.model)
        project = Project(name: config.projectName, bundleIdentifier: detectedProject.bundleIdentifier)
        icon = PackageEncoding.bounded(Image.appIcon?.getPNGData(), limit: BabylonConstants.maximumCaptureIconBytes)
        capabilities = ProducerCapabilities.current
    }

    func toData() -> Data? {
        PackageEncoding.encode(self, label: "connection package")
    }

    var captureMemoryEstimate: Int {
        let stringBytes = device.name.utf8.count + device.model.utf8.count + project.name.utf8.count +
            project.bundleIdentifier.utf8.count + capabilities.captureMemoryEstimate
        return CaptureMemoryEstimate.retained(bodyBytes: icon?.count ?? 0, stringBytes: stringBytes)
    }
}

public final class TrafficPackage: Codable, CustomDebugStringConvertible, Serializable, CaptureMemoryEstimating {
    public enum PackageType: String, Codable {
        case http
        case websocket
        case grpc
    }

    public let id: String
    public private(set) var startAt: TimeInterval
    public let request: Request
    public private(set) var response: Response?
    public private(set) var error: CustomError?
    public private(set) var responseBodyData: Data
    public private(set) var endAt: TimeInterval?
    public private(set) var lastData: Data?
    public let packageType: PackageType
    public private(set) var correlationContext: CorrelationContext?
    private(set) var urlSessionTiming: URLSessionTiming?
    private(set) var websocketMessagePackage: WebsocketMessagePackage?
    private(set) var grpcCapture: GRPCCapture?
    // The runtime lease is excluded from CodingKeys; decoding must restore an unleased package.
    // swiftlint:disable:next implicit_optional_initialization
    private var captureMemoryLease: CaptureMemoryLease? = nil
    private var basePayloadCache = TrafficPackageBasePayloadCache()
    private var maximumRequestBodyBytes = BabylonConstants.maximumBodySize
    private var maximumResponseBodyBytes = BabylonConstants.maximumBodySize
    private var metadataOnlyCapture = false
    private var capturePolicy = CapturePolicy()
    private var captureRequest: URLRequest?
    public private(set) var requestBodyOmission: CaptureOmission?
    public private(set) var responseBodyOmission: CaptureOmission?
    var basePayloadEncodingCount: Int {
        basePayloadCache.encodingCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, startAt, request, response, error, responseBodyData, endAt, lastData
        case packageType, correlationContext, urlSessionTiming, websocketMessagePackage, grpcCapture
        case requestBodyOmission, responseBodyOmission
    }

    var captureMemoryEstimate: Int {
        CaptureMemoryEstimate.retained(bodyBytes: capturedBodySize, stringBytes: capturedStringSize)
    }

    private var capturedBodySize: Int {
        PackageEncoding.capturedSize(request.body) + PackageEncoding.capturedSize(responseBodyData) +
            (websocketMessagePackage?.capturedBodySize ?? 0) + (grpcCapture?.capturedBodySize ?? 0)
    }

    private var capturedStringSize: Int {
        var byteCount = id.utf8.count
        byteCount += request.url.utf8.count
        byteCount += request.method.utf8.count
        byteCount += request.headers.reduce(0) { partial, header in
            partial + header.key.utf8.count + header.value.utf8.count
        }
        if let response {
            byteCount += response.headers.reduce(0) { partial, header in
                partial + header.key.utf8.count + header.value.utf8.count
            }
        }
        byteCount += error?.message.utf8.count ?? 0
        if let correlationContext {
            byteCount += correlationContext.sessionId.utf8.count
            byteCount += correlationContext.traceId.utf8.count
            byteCount += correlationContext.stepId.utf8.count
        }
        byteCount += urlSessionTiming?.retainedByteCount ?? 0
        byteCount += websocketMessagePackage?.captureMemoryStringSize ?? 0
        byteCount += grpcCapture?.captureMemoryStringSize ?? 0
        return byteCount
    }

    public var debugDescription: String {
        "Package: id=\(id), type=\(packageType.rawValue), hasResponse=\(response != nil)"
    }

    init(
        id: String,
        request: Request,
        response: Response? = nil,
        responseBodyData: Data? = nil,
        packageType: PackageType = .http,
        startAt: TimeInterval = Date().timeIntervalSince1970,
        endAt: TimeInterval? = nil,
        correlationContext: CorrelationContext? = nil
    ) {
        self.id = CaptureString.bounded(id, maximumBytes: 512)
        self.startAt = startAt
        self.request = request
        self.response = response
        self.packageType = packageType
        self.endAt = endAt
        self.correlationContext = correlationContext
        let responseLimit = BabylonConstants.maximumBodySize - PackageEncoding.capturedSize(request.body)
        self.responseBodyData = PackageEncoding.bounded(
            responseBodyData ?? Data(),
            limit: min(responseLimit, maximumResponseBodyBytes)
        ) ?? Data()
    }

    static func buildRequest(
        sessionTask: URLSessionTask,
        id: String,
        maximumRequestBodyBytes: Int = BabylonConstants.maximumBodySize,
        metadataOnly: Bool = false
    ) -> TrafficPackage? {
        guard let sourceRequest = sessionTask.currentRequestSafe,
              let request = Request(
                  sourceRequest,
                  maximumBodyBytes: maximumRequestBodyBytes,
                  metadataOnly: metadataOnly
              ) else {
            return nil
        }
        if !metadataOnly, request.body == nil, let body = sessionTask.originalRequestBodySafe, !body.isEmpty {
            request.appendBody(
                body,
                maximumBodySize: min(max(0, maximumRequestBodyBytes), BabylonConstants.maximumBodySize)
            )
        }
        let type: PackageType = if let webSocketTaskClass = NSClassFromString("__NSURLSessionWebSocketTask"),
                                   sessionTask.isKind(of: webSocketTaskClass) {
            .websocket
        } else {
            .http
        }
        return TrafficPackage(id: id, request: request, packageType: type)
    }

    static func buildRequest(request: NSURLRequest, id: String) -> TrafficPackage? {
        Request(request as URLRequest).map { TrafficPackage(id: id, request: $0) }
    }

    static func buildRequest(urlRequest: URLRequest, urlResponse: URLResponse, bodyData: Data?) -> TrafficPackage? {
        guard let request = Request(urlRequest) else { return nil }
        return TrafficPackage(
            id: UUID().uuidString,
            request: request,
            response: Response(urlResponse),
            responseBodyData: bodyData
        )
    }

    static func buildRequest(urlRequest: URLRequest, error: Error) -> TrafficPackage? {
        guard let request = Request(urlRequest) else { return nil }
        let result = TrafficPackage(id: UUID().uuidString, request: request)
        result.updateDidComplete(error)
        return result
    }

    func updateResponse(_ response: URLResponse) {
        invalidateBasePayload()
        self.response = Response(response)
        if let captureRequest,
           !capturePolicy.responseDecision(for: response, request: captureRequest).included {
            let observed = PackageEncoding.capturedSize(responseBodyData)
            responseBodyOmission = CaptureOmission(reason: .rule, observedBytes: observed)
            responseBodyData = Data()
        }
        guard resizeCaptureLease(toBodyBytes: capturedBodySize, estimatedBytes: captureMemoryEstimate) else {
            self.response = nil
            if let captureMemoryLease {
                _ = captureMemoryLease.resize(to: captureMemoryEstimate)
            }
            return
        }
    }

    func updateDidComplete(_ error: Error?) {
        invalidateBasePayload()
        endAt = Date().timeIntervalSince1970
        self.error = error.map(CustomError.init)
        if let omission = requestBodyOmission {
            requestBodyOmission = CaptureOmission(
                reason: omission.reason,
                observedBytes: omission.observedBytes,
                originalBytes: omission.observedBytes
            )
        }
        if let omission = responseBodyOmission {
            responseBodyOmission = CaptureOmission(
                reason: omission.reason,
                observedBytes: omission.observedBytes,
                originalBytes: omission.observedBytes
            )
        }
        guard resizeCaptureLease(toBodyBytes: capturedBodySize, estimatedBytes: captureMemoryEstimate) else {
            self.error = nil
            if let captureMemoryLease {
                _ = captureMemoryLease.resize(to: captureMemoryEstimate)
            }
            return
        }
    }

    func appendRequestData(_ data: Data) {
        invalidateBasePayload()
        if let omission = requestBodyOmission {
            requestBodyOmission = CaptureOmission(
                reason: CapturePolicyDecision.OmissionReason(rawValue: omission.reason) ?? .bodyLimit,
                observedBytes: min(omission.observedBytes + data.count, BabylonConstants.maximumBodySize * 1024)
            )
            request.resetBody()
            return
        }
        guard !metadataOnlyCapture else {
            recordRequestOmission(observedBytes: min(
                (request.body?.count ?? 0) + data.count,
                BabylonConstants.maximumBodySize * 1024
            ))
            request.resetBody()
            return
        }
        guard data.count <= max(0, maximumRequestBodyBytes - (request.body?.count ?? 0)) else {
            recordRequestOmission(observedBytes: min(
                (request.body?.count ?? 0) + data.count,
                BabylonConstants.maximumBodySize * 1024
            ))
            request.resetBody()
            return
        }
        guard resizeCaptureLease(forAdditionalBodyBytes: data.count, omittingRequestOnFailure: true) else { return }
        request.appendBody(
            data,
            maximumBodySize: min(maximumRequestBodyBytes, remainingBodyCapacity(excluding: .request))
        )
        if let captureMemoryLease {
            _ = captureMemoryLease.resize(to: captureMemoryEstimate)
        }
    }

    func updateStartTime(_ startTime: TimeInterval) {
        invalidateBasePayload()
        startAt = startTime
    }

    func appendResponseData(_ data: Data) {
        if let omission = responseBodyOmission,
           omission.reason == CapturePolicyDecision.OmissionReason.bodyLimit.rawValue {
            invalidateBasePayload()
            responseBodyOmission = CaptureOmission(
                reason: .bodyLimit,
                observedBytes: min(omission.observedBytes + data.count, BabylonConstants.maximumBodySize * 1024),
                originalBytes: omission.originalBytes
            )
            return
        }
        if let omission = responseBodyOmission,
           omission.reason == CapturePolicyDecision.OmissionReason.rule.rawValue {
            invalidateBasePayload()
            responseBodyOmission = CaptureOmission(
                reason: .rule,
                observedBytes: min(omission.observedBytes + data.count, BabylonConstants.maximumBodySize * 1024),
                originalBytes: omission.originalBytes
            )
            return
        }
        guard responseBodyData != PackageEncoding.omittedBody else { return }
        guard !metadataOnlyCapture else {
            recordResponseOmission(observedBytes: min(
                PackageEncoding.capturedSize(responseBodyData) + data.count,
                BabylonConstants.maximumBodySize * 1024
            ))
            invalidateBasePayload()
            responseBodyData = Data()
            lastData = nil
            return
        }
        guard data.count <= max(0, maximumResponseBodyBytes - PackageEncoding.capturedSize(responseBodyData)) else {
            recordResponseOmission(observedBytes: min(
                PackageEncoding.capturedSize(responseBodyData) + data.count,
                BabylonConstants.maximumBodySize * 1024
            ))
            invalidateBasePayload()
            responseBodyData = PackageEncoding.omittedBody
            lastData = nil
            return
        }
        guard resizeCaptureLease(forAdditionalBodyBytes: data.count, omittingRequestOnFailure: false) else {
            invalidateBasePayload()
            responseBodyData = PackageEncoding.omittedBody
            lastData = nil
            return
        }
        let limit = remainingBodyCapacity(excluding: .response)
        guard data.count <= limit - min(limit, responseBodyData.count) else {
            invalidateBasePayload()
            responseBodyData = PackageEncoding.omittedBody
            lastData = nil
            if let captureMemoryLease {
                _ = captureMemoryLease.resize(to: captureMemoryEstimate)
            }
            return
        }
        invalidateBasePayload()
        responseBodyData.append(data)
    }

    func setWebsocketMessagePackage(package: WebsocketMessagePackage) {
        let bounded = package.bounded(maximumBodySize: remainingBodyCapacity(excluding: .webSocket))
        guard resizeCaptureLease(toBodyBytes: capturedBodySize - (websocketMessagePackage?.capturedBodySize ?? 0) +
            bounded.capturedBodySize) else {
            websocketMessagePackage = package.bounded(maximumBodySize: 0)
            if let captureMemoryLease {
                _ = captureMemoryLease.resize(to: captureMemoryEstimate)
            }
            return
        }
        websocketMessagePackage = bounded
    }

    func setCorrelationContext(_ context: CorrelationContext?) {
        if let context {
            invalidateBasePayload()
            correlationContext = context
            guard resizeCaptureLease(toBodyBytes: capturedBodySize, estimatedBytes: captureMemoryEstimate) else {
                correlationContext = nil
                if let captureMemoryLease {
                    _ = captureMemoryLease.resize(to: captureMemoryEstimate)
                }
                return
            }
        }
    }

    func setURLSessionTiming(_ timing: URLSessionTiming) {
        invalidateBasePayload()
        let previous = urlSessionTiming
        urlSessionTiming = timing
        guard resizeCaptureLease(toBodyBytes: capturedBodySize, estimatedBytes: captureMemoryEstimate) else {
            urlSessionTiming = previous
            if let captureMemoryLease {
                _ = captureMemoryLease.resize(to: captureMemoryEstimate)
            }
            return
        }
    }

    func toData() -> Data? {
        lastData = nil
        if responseBodyData.count > BabylonConstants.maximumBodySize {
            invalidateBasePayload()
            responseBodyData = PackageEncoding.omittedBody
        }
        if let body = request.body,
           body == PackageEncoding.omittedBody || body.count > BabylonConstants.maximumBodySize {
            invalidateBasePayload()
            request.resetBody()
        }
        guard let cachedBasePayload = basePayloadCache.payload(encode: {
            let base = TrafficPackageBase(
                id: id,
                startAt: startAt,
                request: request,
                response: response,
                error: error,
                responseBodyData: responseBodyData,
                endAt: endAt,
                lastData: lastData,
                packageType: packageType,
                correlationContext: correlationContext,
                urlSessionTiming: urlSessionTiming,
                requestBodyOmission: requestBodyOmission,
                responseBodyOmission: responseBodyOmission
            )
            return PackageEncoding.encode(base, label: "traffic package base")
        }) else { return nil }
        var result = cachedBasePayload
        if let websocketMessagePackage,
           let encodedFrame = PackageEncoding.encode(websocketMessagePackage, label: "WebSocket package"),
           result.last == UInt8(ascii: "}"), result.count > 2 {
            result.removeLast()
            result.append(contentsOf: ",\"websocketMessagePackage\":".utf8)
            result.append(encodedFrame)
            result.append(UInt8(ascii: "}"))
        }
        if let grpcCapture,
           let encodedGRPC = PackageEncoding.encode(grpcCapture, label: "gRPC capture"),
           result.last == UInt8(ascii: "}"), result.count > 2 {
            result.removeLast()
            result.append(contentsOf: ",\"grpcCapture\":".utf8)
            result.append(encodedGRPC)
            result.append(UInt8(ascii: "}"))
        }
        return result
    }

    func configureCaptureLimits(
        requestBytes: Int,
        responseBytes: Int,
        metadataOnly: Bool,
        policy: CapturePolicy,
        request: URLRequest,
        observedRequestBodyBytes: Int? = nil
    ) {
        maximumRequestBodyBytes = min(max(0, requestBytes), BabylonConstants.maximumBodySize)
        maximumResponseBodyBytes = min(max(0, responseBytes), BabylonConstants.maximumBodySize)
        metadataOnlyCapture = metadataOnly
        capturePolicy = policy
        captureRequest = request
        let requestSize = PackageEncoding.capturedSize(self.request.body)
        if let observedRequestBodyBytes,
           metadataOnly || observedRequestBodyBytes > maximumRequestBodyBytes {
            recordRequestOmission(observedBytes: min(observedRequestBodyBytes, BabylonConstants.maximumBodySize * 1024))
            self.request.resetBody()
        }
        if metadataOnly || requestSize > maximumRequestBodyBytes {
            if observedRequestBodyBytes == nil {
                recordRequestOmission(observedBytes: min(requestSize, BabylonConstants.maximumBodySize * 1024))
            }
            self.request.resetBody()
        }
        let responseSize = PackageEncoding.capturedSize(responseBodyData)
        if metadataOnly || responseSize > maximumResponseBodyBytes {
            recordResponseOmission(observedBytes: min(responseSize, BabylonConstants.maximumBodySize * 1024))
            responseBodyData = Data()
        }
        invalidateBasePayload()
    }

    private func recordRequestOmission(observedBytes: Int) {
        requestBodyOmission = CaptureOmission(reason: .bodyLimit, observedBytes: observedBytes)
    }

    private func recordResponseOmission(observedBytes: Int) {
        responseBodyOmission = CaptureOmission(reason: .bodyLimit, observedBytes: observedBytes)
    }

    func makeSnapshot() -> TrafficPackage? {
        guard let lease = CaptureMemoryBudget.shared.reserve(captureMemoryEstimate) else { return nil }
        let copy = TrafficPackage(
            id: id,
            request: Request(url: request.url, method: request.method, headers: request.headers, body: request.body),
            response: response,
            responseBodyData: responseBodyData,
            packageType: packageType,
            startAt: startAt,
            endAt: endAt,
            correlationContext: correlationContext
        )
        copy.error = error
        copy.websocketMessagePackage = websocketMessagePackage
        copy.grpcCapture = grpcCapture
        copy.urlSessionTiming = urlSessionTiming
        copy.requestBodyOmission = requestBodyOmission
        copy.responseBodyOmission = responseBodyOmission
        copy.captureMemoryLease = lease
        copy.basePayloadCache = basePayloadCache
        return copy
    }

    private func invalidateBasePayload() {
        basePayloadCache = TrafficPackageBasePayloadCache()
    }

    @discardableResult
    func admitCapture(using budget: CaptureMemoryBudget = .shared) -> Bool {
        guard captureMemoryLease == nil else { return true }
        guard let lease = budget.reserve(captureMemoryEstimate) else { return false }
        captureMemoryLease = lease
        return true
    }

    private func resizeCaptureLease(forAdditionalBodyBytes count: Int, omittingRequestOnFailure: Bool) -> Bool {
        let additional = max(0, count)
        let projectedBodySize = capturedBodySize + additional
        let (projectedEstimate, estimateOverflow) = CaptureMemoryEstimate.retained(
            bodyBytes: projectedBodySize,
            stringBytes: capturedStringSize
        ).addingReportingOverflow(additional)
        let target = estimateOverflow ? Int.max : projectedEstimate
        guard resizeCaptureLease(toBodyBytes: capturedBodySize + max(0, count), estimatedBytes: target) else {
            if omittingRequestOnFailure {
                request.resetBody()
            } else {
                responseBodyData = PackageEncoding.omittedBody
            }
            if let captureMemoryLease {
                _ = captureMemoryLease.resize(to: captureMemoryEstimate)
            }
            return false
        }
        return true
    }

    private func resizeCaptureLease(toBodyBytes bodyBytes: Int, estimatedBytes: Int? = nil) -> Bool {
        guard let captureMemoryLease else { return true }
        let estimate = estimatedBytes ?? CaptureMemoryEstimate.retained(
            bodyBytes: bodyBytes,
            stringBytes: capturedStringSize
        )
        return captureMemoryLease.resize(to: estimate)
    }

    private enum BodySection {
        case request
        case response
        case webSocket
    }

    private func remainingBodyCapacity(excluding section: BodySection) -> Int {
        var used = 0
        if section != .request {
            used += PackageEncoding.capturedSize(request.body)
        }
        if section != .response {
            used += PackageEncoding.capturedSize(responseBodyData)
        }
        if section != .webSocket {
            used += websocketMessagePackage?.capturedBodySize ?? 0
        }
        used += grpcCapture?.capturedBodySize ?? 0
        return max(0, BabylonConstants.maximumBodySize - used)
    }

    func setGRPCCapture(_ capture: GRPCCapture) {
        let bounded = capture.bounded(maximumBodySize: remainingBodyCapacity(excluding: .webSocket))
        let previous = grpcCapture?.capturedBodySize ?? 0
        let target = capturedBodySize - previous + bounded.capturedBodySize
        guard resizeCaptureLease(toBodyBytes: target) else {
            grpcCapture = capture.bounded(maximumBodySize: 0)
            if let captureMemoryLease {
                _ = captureMemoryLease.resize(to: captureMemoryEstimate)
            }
            invalidateBasePayload()
            return
        }
        grpcCapture = bounded
        invalidateBasePayload()
    }
}

private struct TrafficPackageBase: Encodable {
    let id: String
    let startAt: TimeInterval
    let request: Request
    let response: Response?
    let error: CustomError?
    let responseBodyData: Data
    let endAt: TimeInterval?
    let lastData: Data?
    let packageType: TrafficPackage.PackageType
    let correlationContext: CorrelationContext?
    let urlSessionTiming: URLSessionTiming?
    let requestBodyOmission: CaptureOmission?
    let responseBodyOmission: CaptureOmission?
}

struct ProducerCapabilities: Codable, CaptureMemoryEstimating {
    let sdkVersion: String
    let platform: String
    let payloadSchemaVersions: [String: Int]
    let supportedMessageTypes: [String]
    let supportedTrafficTypes: [String]
    let maximumBodyBytes: Int
    let maximumWebSocketFrameBytes: Int
    let maximumCaptureMemoryBytes: Int

    static var current: ProducerCapabilities {
        ProducerCapabilities(
            sdkVersion: BabylonConstants.buildVersion,
            platform: platformName,
            payloadSchemaVersions: [
                "connection": 1,
                "traffic": 1,
                "grpcCapture": 1,
                "runtime": 1,
                "urlSessionTiming": URLSessionTiming.currentSchemaVersion
            ],
            supportedMessageTypes: ["connection", "traffic", "runtime", "ack", "rejection"],
            supportedTrafficTypes: ["http", "websocket", "grpc"],
            maximumBodyBytes: BabylonConstants.maximumBodySize,
            maximumWebSocketFrameBytes: BabylonConstants.maximumWebSocketFrameSize,
            maximumCaptureMemoryBytes: BabylonConstants.maximumCaptureMemoryBytes
        )
    }

    var captureMemoryEstimate: Int {
        let stringBytes = sdkVersion.utf8.count + platform.utf8.count +
            payloadSchemaVersions.keys.reduce(0) { $0 + $1.utf8.count } +
            supportedMessageTypes.reduce(0) { $0 + $1.utf8.count } +
            supportedTrafficTypes.reduce(0) { $0 + $1.utf8.count }
        return CaptureMemoryEstimate.retained(bodyBytes: 0, stringBytes: stringBytes)
    }

    private static var platformName: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(watchOS)
        "watchOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "unknown"
        #endif
    }
}

private final class TrafficPackageBasePayloadCache {
    private let lock = NSLock()
    private var cachedPayload: Data?
    private var encodeCount = 0

    var encodingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return encodeCount
    }

    func payload(encode: () -> Data?) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPayload {
            return cachedPayload
        }
        guard let payload = encode() else { return nil }
        cachedPayload = payload
        encodeCount += 1
        return payload
    }
}

struct Device: Codable {
    var name: String
    let model: String

    static var current: Device {
        Device()
    }

    init(name: String, model: String) {
        self.name = CaptureString.bounded(name, maximumBytes: 4096)
        self.model = CaptureString.bounded(model, maximumBytes: 4096)
    }

    init() {
        #if os(macOS)
        let computerName = Host.current().localizedName ?? Host.current().name ?? "Unknown Mac Device"
        self.init(
            name: computerName,
            model: "\(computerName) \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        #elseif os(iOS) || targetEnvironment(macCatalyst) || os(tvOS) || os(visionOS)
        let platformDevice = UIDevice.current
        self.init(
            name: platformDevice.name,
            model: "\(platformDevice.name) (\(platformDevice.systemName) \(platformDevice.systemVersion))"
        )
        #elseif os(watchOS)
        let platformDevice = WKInterfaceDevice.current()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        self.init(
            name: platformDevice.name,
            model: "\(platformDevice.name) (watchOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion))"
        )
        #endif
    }
}

struct Project: Codable {
    var name: String
    let bundleIdentifier: String

    static var current: Project {
        Project()
    }

    init(name: String, bundleIdentifier: String) {
        self.name = CaptureString.bounded(name, maximumBytes: 4096)
        self.bundleIdentifier = CaptureString.bounded(bundleIdentifier, maximumBytes: 512)
    }

    init() {
        let localized = Bundle.main.localizedInfoDictionary
        let standard = Bundle.main.infoDictionary
        let resolvedName = localized?["CFBundleDisplayName"] as? String
            ?? standard?["CFBundleDisplayName"] as? String
            ?? localized?[kCFBundleNameKey as String] as? String
            ?? standard?[kCFBundleNameKey as String] as? String
            ?? "Untitled"
        self.init(name: resolvedName, bundleIdentifier: Bundle.main.bundleIdentifier ?? "No bundle identifier")
    }
}

public struct Header: Codable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = CaptureString.bounded(key, maximumBytes: 256)
        self.value = CaptureString.bounded(value, maximumBytes: 4096)
    }
}

public final class Request: Codable {
    public let url: String
    public let method: String
    public let headers: [Header]
    public private(set) var body: Data?

    public init(url: String, method: String, headers: [Header], body: Data?) {
        self.url = CaptureString.bounded(CaptureRedaction.url(CaptureString.bounded(url)))
        self.method = CaptureString.bounded(method, maximumBytes: 256)
        self.headers = CaptureString.headers(CaptureRedaction.headers(CaptureString.headers(headers)))
        self.body = PackageEncoding.bounded(body, limit: BabylonConstants.maximumBodySize)
    }

    init?(
        _ source: URLRequest?,
        maximumBodyBytes: Int = BabylonConstants.maximumBodySize,
        metadataOnly: Bool = false
    ) {
        guard let source else { return nil }
        let sourceURL = CaptureString.bounded(source.url?.absoluteString ?? "-")
        url = CaptureString.bounded(CaptureRedaction.url(sourceURL))
        method = CaptureString.bounded(source.httpMethod ?? "-", maximumBytes: 256)
        headers = CaptureString
            .headers(CaptureRedaction
                .headers(CaptureString.headers((source.allHTTPHeaderFields ?? [:]).map { name, value in
                    Header(key: name, value: value)
                })))
        let sourceBody = metadataOnly || source.httpBodyStream != nil ? nil : source.httpBody
        let policyLimit = min(max(0, maximumBodyBytes), BabylonConstants.maximumBodySize)
        body = PackageEncoding.bounded(sourceBody, limit: policyLimit)
    }

    func appendBody(_ data: Data, maximumBodySize: Int = BabylonConstants.maximumBodySize) {
        guard body != PackageEncoding.omittedBody else { return }
        let existing = body ?? Data()
        guard data.count <= max(0, maximumBodySize - existing.count) else {
            body = PackageEncoding.omittedBody
            return
        }
        body = existing + data
    }

    func resetBody() {
        body = nil
    }
}

public struct Response: Codable {
    public let statusCode: Int
    public let headers: [Header]

    public init(statusCode: Int, headers: [Header]) {
        self.statusCode = statusCode
        self.headers = CaptureString.headers(CaptureRedaction.headers(headers))
    }

    init?(_ source: URLResponse) {
        if let http = source as? HTTPURLResponse {
            self.init(
                statusCode: http.statusCode,
                headers: http.allHeaderFields.map { Header(
                    key: String(describing: $0.key),
                    value: String(describing: $0.value)
                ) }
            )
        } else {
            self.init(statusCode: 200, headers: [
                Header(key: "Content-Length", value: String(source.expectedContentLength)),
                Header(key: "Content-Type", value: source.mimeType ?? "plain/text")
            ])
        }
    }
}

public struct CustomError: Codable {
    public let code: Int
    public let message: String

    init(_ error: Error) {
        self.init(error as NSError)
    }

    init(_ error: NSError) {
        code = error.code
        message = CaptureString.bounded(error.localizedDescription, maximumBytes: 4096)
    }
}

public struct WebsocketMessagePackage: Codable, Serializable, CaptureMemoryEstimating {
    public enum MessageType: String, Codable {
        case pingPong
        case ping
        case pong
        case send
        case receive
        case sendCloseMessage
        case receiveCloseMessage
        case abnormalTermination
    }

    public enum Message {
        case data(Data)
        case string(String)

        init?(message: URLSessionWebSocketTask.Message) {
            switch message {
            case let .data(value): self = .data(value)
            case let .string(value): self = .string(value)
            @unknown default: return nil
            }
        }
    }

    private let id: String
    private let createdAt: TimeInterval
    private let messageType: MessageType
    private let stringValue: String?
    private let dataValue: Data?
    private let closeCode: Int?
    private let closeReason: String?
    private let closeOrigin: String?
    private let abnormal: Bool?

    var capturedBodySize: Int {
        if messageType == .sendCloseMessage {
            return 0
        }
        if let dataValue, dataValue != PackageEncoding.omittedBody {
            return dataValue.count
        }
        if let stringValue, stringValue != PackageEncoding.omittedText {
            return stringValue.utf8.count
        }
        return 0
    }

    var captureMemoryStringSize: Int {
        id.utf8.count + (stringValue?.utf8.count ?? 0) + (closeReason?.utf8.count ?? 0)
    }

    var captureMemoryEstimate: Int {
        let strings = captureMemoryStringSize + (closeOrigin?.utf8.count ?? 0)
        return CaptureMemoryEstimate.retained(bodyBytes: capturedBodySize, stringBytes: strings)
    }

    init(id: String, message: Message, messageType: MessageType) {
        self.id = CaptureString.bounded(id, maximumBytes: 512)
        createdAt = Date().timeIntervalSince1970
        self.messageType = messageType
        closeCode = nil
        closeReason = nil
        closeOrigin = nil
        abnormal = nil
        switch message {
        case let .data(value):
            dataValue = PackageEncoding.bounded(value, limit: BabylonConstants.maximumWebSocketFrameSize)
            stringValue = nil
        case let .string(value):
            stringValue = value.utf8.count <= BabylonConstants.maximumWebSocketFrameSize
                ? value
                : PackageEncoding.omittedText
            dataValue = nil
        }
    }

    init(id: String, closeCode: Int, reason: Data?) {
        self.id = CaptureString.bounded(id, maximumBytes: 512)
        createdAt = Date().timeIntervalSince1970
        messageType = .sendCloseMessage
        stringValue = String(closeCode)
        dataValue = PackageEncoding.bounded(reason, limit: BabylonConstants.maximumWebSocketFrameSize)
        self.closeCode = closeCode
        closeReason = reason.map { String(decoding: $0.prefix(123), as: UTF8.self) }
        closeOrigin = "local"
        abnormal = nil
    }

    init(id: String, closeCode: Int?, reason: Data?, origin: String, abnormal: Bool) {
        self.id = CaptureString.bounded(id, maximumBytes: 512)
        createdAt = Date().timeIntervalSince1970
        messageType = abnormal ? .abnormalTermination : .receiveCloseMessage
        stringValue = closeCode.map(String.init)
        dataValue = PackageEncoding.bounded(reason, limit: BabylonConstants.maximumWebSocketFrameSize)
        self.closeCode = closeCode
        closeReason = reason.map { String(decoding: $0.prefix(123), as: UTF8.self) }
        closeOrigin = origin
        self.abnormal = abnormal
    }

    func bounded(maximumBodySize: Int) -> WebsocketMessagePackage {
        let limit = min(maximumBodySize, BabylonConstants.maximumWebSocketFrameSize)
        guard capturedBodySize <= limit else {
            return WebsocketMessagePackage(
                id: id,
                createdAt: createdAt,
                messageType: messageType,
                stringValue: dataValue == nil ? PackageEncoding.omittedText : stringValue,
                dataValue: dataValue == nil ? nil : PackageEncoding.omittedBody,
                closeCode: closeCode,
                closeReason: closeReason,
                closeOrigin: closeOrigin,
                abnormal: abnormal
            )
        }
        return self
    }

    func toData() -> Data? {
        PackageEncoding.encode(self, label: "WebSocket package")
    }

    private init(
        id: String,
        createdAt: TimeInterval,
        messageType: MessageType,
        stringValue: String?,
        dataValue: Data?,
        closeCode: Int? = nil,
        closeReason: String? = nil,
        closeOrigin: String? = nil,
        abnormal: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.messageType = messageType
        self.stringValue = stringValue
        self.dataValue = dataValue
        self.closeCode = closeCode
        self.closeReason = closeReason
        self.closeOrigin = closeOrigin
        self.abnormal = abnormal
    }
}

extension Image {
    static var appIcon: Image? {
        #if os(macOS)
        return Thread.isMainThread
            ? NSApplication.shared.applicationIconImage
            : DispatchQueue.main.sync { NSApplication.shared.applicationIconImage }
        #elseif targetEnvironment(macCatalyst)
        guard let name = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String else { return nil }
        return Image(named: name)
        #elseif os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { return nil }
        if let files = primary["CFBundleIconFiles"] as? [String], let name = files.last {
            return Image(named: name)
        }
        if let name = primary["CFBundleIconName"] as? String {
            return Image(named: "\(name)60x60")
        }
        return nil
        #endif
    }

    func getPNGData() -> Data? {
        #if os(macOS)
        guard let source = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let representation = NSBitmapImageRep(cgImage: source)
        representation.size = CGSize(width: 64, height: 64)
        return representation.representation(using: .png, properties: [:])
        #else
        return pngData()
        #endif
    }
}
