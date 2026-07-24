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

struct ConnectionPackage: Codable, Serializable {
    let device: Device
    let project: Project
    let icon: Data?

    init(config: Configuration) {
        let detectedDevice = Device.current
        let detectedProject = Project.current
        device = Device(name: config.deviceName, model: detectedDevice.model)
        project = Project(name: config.projectName, bundleIdentifier: detectedProject.bundleIdentifier)
        icon = Image.appIcon?.getPNGData()
    }

    func toData() -> Data? {
        PackageEncoding.encode(self, label: "connection package")
    }
}

public final class TrafficPackage: Codable, CustomDebugStringConvertible, Serializable {
    public enum PackageType: String, Codable {
        case http
        case websocket
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
    private(set) var websocketMessagePackage: WebsocketMessagePackage?

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
        self.id = id
        self.startAt = startAt
        self.request = request
        self.response = response
        self.packageType = packageType
        self.endAt = endAt
        self.correlationContext = correlationContext
        let responseLimit = BabylonConstants.maximumBodySize - PackageEncoding.capturedSize(request.body)
        self.responseBodyData = PackageEncoding.bounded(responseBodyData ?? Data(), limit: responseLimit) ?? Data()
    }

    static func buildRequest(sessionTask: URLSessionTask, id: String) -> TrafficPackage? {
        guard let request = Request(sessionTask.currentRequestSafe) else { return nil }
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
        self.response = Response(response)
    }

    func updateDidComplete(_ error: Error?) {
        endAt = Date().timeIntervalSince1970
        self.error = error.map(CustomError.init)
    }

    func appendRequestData(_ data: Data) {
        request.appendBody(data, maximumBodySize: remainingBodyCapacity(excluding: .request))
    }

    func updateStartTime(_ startTime: TimeInterval) {
        startAt = startTime
    }

    func appendResponseData(_ data: Data) {
        guard responseBodyData != PackageEncoding.omittedBody else { return }
        let limit = remainingBodyCapacity(excluding: .response)
        guard data.count <= limit - min(limit, responseBodyData.count) else {
            responseBodyData = PackageEncoding.omittedBody
            lastData = nil
            return
        }
        responseBodyData.append(data)
    }

    func setWebsocketMessagePackage(package: WebsocketMessagePackage) {
        websocketMessagePackage = package.bounded(maximumBodySize: remainingBodyCapacity(excluding: .webSocket))
    }

    func setCorrelationContext(_ context: CorrelationContext?) {
        if let context {
            correlationContext = context
        }
    }

    func toData() -> Data? {
        lastData = nil
        if responseBodyData.count > BabylonConstants.maximumBodySize {
            responseBodyData = PackageEncoding.omittedBody
        }
        if let body = request.body,
           body == PackageEncoding.omittedBody || body.count > BabylonConstants.maximumBodySize {
            request.resetBody()
        }
        return PackageEncoding.encode(self, label: "traffic package")
    }

    func makeSnapshot() -> TrafficPackage {
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
        return copy
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
        return max(0, BabylonConstants.maximumBodySize - used)
    }
}

struct Device: Codable {
    var name: String
    let model: String

    static var current: Device {
        Device()
    }

    init(name: String, model: String) {
        self.name = name
        self.model = model
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
        self.name = name
        self.bundleIdentifier = bundleIdentifier
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

public struct Header: Codable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public final class Request: Codable {
    public let url: String
    public let method: String
    public let headers: [Header]
    public private(set) var body: Data?

    public init(url: String, method: String, headers: [Header], body: Data?) {
        self.url = CaptureRedaction.url(url)
        self.method = method
        self.headers = CaptureRedaction.headers(headers)
        self.body = PackageEncoding.bounded(body, limit: BabylonConstants.maximumBodySize)
    }

    init?(_ source: URLRequest?) {
        guard let source else { return nil }
        url = CaptureRedaction.url(source.url?.absoluteString ?? "-")
        method = source.httpMethod ?? "-"
        headers = CaptureRedaction.headers((source.allHTTPHeaderFields ?? [:]).map { name, value in
            Header(key: name, value: value)
        })
        body = source.httpBodyStream == nil
            ? PackageEncoding.bounded(source.httpBody, limit: BabylonConstants.maximumBodySize)
            : nil
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
        self.headers = CaptureRedaction.headers(headers)
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
        message = error.localizedDescription
    }
}

public struct WebsocketMessagePackage: Codable, Serializable {
    public enum MessageType: String, Codable {
        case pingPong
        case send
        case receive
        case sendCloseMessage
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

    init(id: String, message: Message, messageType: MessageType) {
        self.id = id
        createdAt = Date().timeIntervalSince1970
        self.messageType = messageType
        switch message {
        case let .data(value):
            dataValue = PackageEncoding.bounded(value, limit: BabylonConstants.maximumBodySize)
            stringValue = nil
        case let .string(value):
            stringValue = value.utf8.count <= BabylonConstants.maximumBodySize ? value : PackageEncoding.omittedText
            dataValue = nil
        }
    }

    init(id: String, closeCode: Int, reason: Data?) {
        self.id = id
        createdAt = Date().timeIntervalSince1970
        messageType = .sendCloseMessage
        stringValue = String(closeCode)
        dataValue = PackageEncoding.bounded(reason, limit: BabylonConstants.maximumBodySize)
    }

    func bounded(maximumBodySize: Int) -> WebsocketMessagePackage {
        guard capturedBodySize <= maximumBodySize else {
            return WebsocketMessagePackage(
                id: id,
                createdAt: createdAt,
                messageType: messageType,
                stringValue: dataValue == nil ? PackageEncoding.omittedText : stringValue,
                dataValue: dataValue == nil ? nil : PackageEncoding.omittedBody
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
        dataValue: Data?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.messageType = messageType
        self.stringValue = stringValue
        self.dataValue = dataValue
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
