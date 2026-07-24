// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

private let manualCaptureLogger = Logger(subsystem: "com.amunx.Babylon", category: "ManualCapture")

public extension Babylon {
    class func add(request: URLRequest, response: URLResponse, responseBody: Data?) {
        enqueueManualCapture { context in
            guard let package = TrafficPackage.buildRequest(
                urlRequest: request,
                urlResponse: response,
                bodyData: responseBody
            ) else {
                manualCaptureLogger.error("Manual request/response could not be converted")
                return
            }
            package.setCorrelationContext(context)
            Babylon.shared.startSendingMessage(package: package)
        }
    }

    class func add(request: URLRequest, error: Error) {
        enqueueManualCapture { context in
            guard let package = TrafficPackage.buildRequest(urlRequest: request, error: error) else {
                manualCaptureLogger.error("Manual failed request could not be converted")
                return
            }
            package.setCorrelationContext(context)
            Babylon.shared.startSendingMessage(package: package)
        }
    }

    class func add(request: Request, response: Response, responseBody: Data?) {
        enqueueManualCapture { context in
            Babylon.shared.startSendingMessage(package: TrafficPackage(
                id: UUID().uuidString,
                request: request,
                response: response,
                responseBodyData: responseBody,
                correlationContext: context
            ))
        }
    }

    enum GRPCStreamingType {
        case client
        case server
        case bidirectional
    }

    class func addGRPCUnary(
        path: String,
        requestObject: Data?,
        responseObject: Data?,
        success: Bool,
        statusCode: Int,
        statusMessage: String?,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        HPACKHeadersRequest: [Header] = [],
        HPACKHeadersResponse: [Header] = []
    ) {
        enqueueManualCapture { context in
            let package = TrafficPackage(
                id: UUID().uuidString,
                request: Request(url: path, method: "GRPC", headers: HPACKHeadersRequest, body: requestObject),
                response: grpcResponse(
                    success: success,
                    statusCode: statusCode,
                    statusMessage: statusMessage,
                    metadata: HPACKHeadersResponse
                ),
                responseBodyData: responseObject,
                startAt: startedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                endAt: endedAt?.timeIntervalSince1970,
                correlationContext: context
            )
            Babylon.shared.startSendingMessage(package: package)
        }
    }

    class func addGRPCStreaming(
        id: UUID,
        path: String,
        message: WebsocketMessagePackage.Message,
        success: Bool,
        statusCode: Int,
        statusMessage: String?,
        streamingType: GRPCStreamingType,
        type: WebsocketMessagePackage.MessageType,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        HPACKHeadersRequest: [Header] = [],
        HPACKHeadersResponse: [Header] = []
    ) {
        enqueueManualCapture { context in
            let identifier = id.uuidString
            let outgoingBody: Data? = streamingType == .server ? message.optionalData : nil
            let responseBody: Data? = streamingType == .client ? message.optionalData : nil
            let package = TrafficPackage(
                id: identifier,
                request: Request(url: path, method: "GRPC", headers: HPACKHeadersRequest, body: outgoingBody),
                response: grpcResponse(
                    success: success,
                    statusCode: statusCode,
                    statusMessage: statusMessage,
                    metadata: HPACKHeadersResponse
                ),
                responseBodyData: responseBody,
                packageType: .websocket,
                startAt: startedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                endAt: endedAt?.timeIntervalSince1970,
                correlationContext: context
            )

            let shouldAttachFrame = type != .send || streamingType != .server
            if shouldAttachFrame {
                package.setWebsocketMessagePackage(package: WebsocketMessagePackage(
                    id: identifier,
                    message: message,
                    messageType: type
                ))
            }
            Babylon.shared.startSendingWebsocketMessage(package)
        }
    }

    private class func enqueueManualCapture(_ operation: @escaping (CorrelationContext?) -> Void) {
        Babylon.shared.scheduleManualCapture(operation)
    }

    private class func grpcResponse(
        success: Bool,
        statusCode: Int,
        statusMessage: String?,
        metadata: [Header]
    ) -> Response {
        let statusDescription = GRPCStatusCode(rawValue: statusCode)?.description ?? "Unknown status Code \(statusCode)"
        let diagnosticHeaders = [
            Header(key: "success", value: String(success)),
            Header(key: "statusCode", value: statusDescription),
            Header(key: "statusMessage", value: statusMessage ?? "nil")
        ]
        return Response(statusCode: success ? 200 : 503, headers: diagnosticHeaders + metadata)
    }
}

extension WebsocketMessagePackage.Message {
    var optionalData: Data? {
        switch self {
        case let .data(value): value
        case let .string(value): Data(value.utf8)
        }
    }
}
