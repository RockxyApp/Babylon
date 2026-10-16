// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Central constants for the Babylon framework.
///
/// Grouped here to break circular dependencies between the transport,
/// model, and configuration layers.
enum BabylonConstants {
    /// Maximum body size before truncation (50 MB).
    static let maximumBodySize = 52_428_800

    /// Shared ceiling for capture data retained across capture, encoding, and transport stages.
    static let maximumCaptureMemoryBytes = 536_870_912

    /// Maximum encoded UTF-8 bytes retained for any one captured string.
    static let maximumCaptureStringBytes = 16384

    /// Maximum headers retained on a captured request or response.
    static let maximumCaptureHeaderCount = 128

    /// Maximum aggregate UTF-8 bytes retained in captured headers.
    static let maximumCaptureHeaderBytes = 65536

    /// Maximum encoded application icon retained in a connection capture.
    static let maximumCaptureIconBytes = 1_048_576

    /// Current framework version sent in wire protocol messages.
    static let buildVersion = "1.0.0"

    /// Maximum number of unsent packages held in the pending queue.
    static let maxPendingItems = 50

    /// Maximum estimated bytes held by unsent network deliveries.
    static let maximumPendingBytes = 75_497_472

    /// Maximum time an unsent package remains eligible for delivery.
    static let maximumPendingLifetime: TimeInterval = 60

    /// Grace period for acknowledging final runtime packages after Babylon.stop().
    static let gracefulTransportDrainDeadline: TimeInterval = 8

    /// Maximum accepted encrypted protocol frame before any payload allocation.
    static let maximumFrameSize = 75_497_472

    /// Maximum encrypted frames retained while awaiting acknowledgements.
    static let maxOutstandingFrames = 50

    /// Aggregate memory cap for encrypted frames awaiting acknowledgements.
    static let maximumOutstandingBytes = 75_497_472

    /// Bonjour service type for discovering the Rockxy desktop app.
    static let serviceType = "_Rockxy._tcp"

    /// Direct TCP port for simulator connections.
    static let directConnectionPort: UInt16 = 10909

    /// Private URLSession selector names used for method swizzling.
    ///
    /// These are Apple implementation details and may change between
    /// iOS versions. Each swizzle site handles the method-not-found
    /// case gracefully by logging and returning early.
    enum Selectors {
        static let resume = "resume"
        static let didReceiveResponseSniff = "_didReceiveResponse:sniff:"
        static let didReceiveData = "_didReceiveData:"
        static let didFinishWithError = "_didFinishWithError:"
        static let dataTaskWithRequest = "dataTaskWithRequest:"
        static let dataTaskWithRequestCompletion = "dataTaskWithRequest:completionHandler:"
        static let dataTaskWithURL = "dataTaskWithURL:"
        static let dataTaskWithURLCompletion = "dataTaskWithURL:completionHandler:"
        static let downloadTaskWithRequest = "downloadTaskWithRequest:"
        static let downloadTaskWithRequestCompletion = "downloadTaskWithRequest:completionHandler:"
        static let downloadTaskWithURL = "downloadTaskWithURL:"
        static let downloadTaskWithURLCompletion = "downloadTaskWithURL:completionHandler:"
        static let uploadFromFile = "uploadTaskWithRequest:fromFile:"
        static let uploadFromFileCompletion = "uploadTaskWithRequest:fromFile:completionHandler:"
        static let uploadFromData = "uploadTaskWithRequest:fromData:"
        static let uploadFromDataCompletion = "uploadTaskWithRequest:fromData:completionHandler:"
        static let webSocketTaskWithRequest = "webSocketTaskWithRequest:"
        static let webSocketTaskWithURL = "webSocketTaskWithURL:"
        static let webSocketTaskWithURLProtocols = "webSocketTaskWithURL:protocols:"
        static let webSocketSendMessage = "sendMessage:completionHandler:"
        static let webSocketReceiveMessage = "receiveMessageWithCompletionHandler:"
        static let webSocketSendPing = "sendPingWithPongReceiveHandler:"
        static let webSocketCancelWithCloseCode = "cancelWithCloseCode:reason:"
    }
}
