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

    @available(
        *,
        deprecated,
        message: "Use addGRPCCall with endpoint, call type, metadata, trailers, status, compression, and ordered messages."
    )
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
        let (service, method) = grpcOperation(from: path)
        addGRPCCall(
            endpoint: path,
            service: service,
            method: method,
            callType: .unary,
            requestMetadata: HPACKHeadersRequest,
            responseMetadata: HPACKHeadersResponse,
            trailers: grpcTrailers(statusCode: statusCode, statusMessage: statusMessage),
            statusCode: statusCode,
            statusMessage: statusMessage,
            messages: [
                GRPCCapture.Message(sequence: 0, direction: .request, data: requestObject),
                GRPCCapture.Message(sequence: 0, direction: .response, data: responseObject)
            ].filter { $0.data != nil },
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    /// Records one bounded gRPC call while keeping its RPC identity separate from its network endpoint.
    ///
    /// Protobuf message bytes remain opaque. The SDK preserves message boundaries and direction, and applies
    /// its configured capture bounds before retaining or serializing the messages.
    /// - Parameters:
    ///   - endpoint: Absolute URL or endpoint string used for the network request.
    ///   - service: Fully qualified gRPC service name, such as `example.Greeter`.
    ///   - method: RPC method name, such as `SayHello`.
    ///   - authority: Optional HTTP/2 authority used by the call.
    ///   - callType: Unary, client-streaming, server-streaming, or bidirectional-streaming.
    ///   - messages: Request and response messages in their capture order.
    class func addGRPCCall(
        id: UUID? = nil,
        endpoint: String,
        service: String,
        method: String,
        authority: String? = nil,
        callType: GRPCCapture.CallType,
        requestMetadata: [Header] = [],
        responseMetadata: [Header] = [],
        trailers: [Header] = [],
        statusCode: Int? = nil,
        statusMessage: String? = nil,
        requestCompression: String? = nil,
        responseCompression: String? = nil,
        messages: [GRPCCapture.Message],
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        enqueueManualCapture { context in
            let package = TrafficPackage(
                id: id?.uuidString ?? UUID().uuidString,
                request: Request(
                    url: endpoint,
                    method: "POST",
                    headers: requestMetadata,
                    body: messages.first(where: { $0.direction == .request })?.data
                ),
                response: statusCode.map { _ in Response(statusCode: 200, headers: responseMetadata + trailers) },
                responseBodyData: messages.first(where: { $0.direction == .response })?.data,
                packageType: .grpc,
                startAt: startedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
                endAt: endedAt?.timeIntervalSince1970,
                correlationContext: context
            )
            package.setGRPCCapture(GRPCCapture(
                endpoint: endpoint,
                authority: authority,
                service: service,
                method: method,
                callType: callType,
                requestMetadata: requestMetadata,
                responseMetadata: responseMetadata,
                trailers: trailers,
                statusCode: statusCode,
                statusMessage: statusMessage,
                requestCompression: requestCompression,
                responseCompression: responseCompression,
                messages: messages
            ))
            Babylon.shared.startSendingMessage(package: package)
        }
    }

    @available(
        *,
        deprecated,
        message: "Use addGRPCCall with endpoint, call type, metadata, trailers, status, compression, and ordered messages."
    )
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
        let callType: GRPCCapture.CallType = switch streamingType {
        case .client: .clientStreaming
        case .server: .serverStreaming
        case .bidirectional: .bidirectionalStreaming
        }
        let direction: GRPCCapture.Direction = type == .send ? .request : .response
        let payload: Data? = switch message {
        case let .data(data): data
        case let .string(value): Data(value.utf8)
        }
        let (service, method) = grpcOperation(from: path)
        addGRPCCall(
            id: id,
            endpoint: path,
            service: service,
            method: method,
            callType: callType,
            requestMetadata: HPACKHeadersRequest,
            responseMetadata: HPACKHeadersResponse,
            trailers: grpcTrailers(statusCode: statusCode, statusMessage: statusMessage),
            statusCode: statusCode,
            statusMessage: statusMessage,
            messages: [GRPCCapture.Message(
                sequence: 0,
                direction: direction,
                data: payload
            )],
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private class func grpcTrailers(statusCode: Int, statusMessage: String?) -> [Header] {
        var result = [Header(key: "grpc-status", value: String(statusCode))]
        if let statusMessage {
            result.append(Header(key: "grpc-message", value: statusMessage))
        }
        return result
    }

    private class func grpcOperation(from endpoint: String) -> (service: String, method: String) {
        let path = URLComponents(string: endpoint)?.path ?? endpoint
        let parts = path.split(separator: "/")
        guard let method = parts.last else { return ("", endpoint) }
        return (parts.dropLast().joined(separator: "/"), String(method))
    }

    private class func enqueueManualCapture(_ operation: @escaping (CorrelationContext?) -> Void) {
        Babylon.shared.scheduleManualCapture(operation)
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
