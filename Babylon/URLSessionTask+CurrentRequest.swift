// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
#if os(iOS) || os(macOS)
import class AVFoundation.AVAggregateAssetDownloadTask
#endif

extension URLSessionTask {
    var currentRequestSafe: URLRequest? {
        #if os(iOS) || os(macOS)
        guard !(self is AVAggregateAssetDownloadTask) else { return nil }
        #endif
        return currentRequest
    }

    /// The body the app set on the request. URLSession moves an `httpBody` into a stream on
    /// `currentRequest`, which cannot be read without consuming it; `originalRequest` keeps the data.
    var originalRequestBodySafe: Data? {
        #if os(iOS) || os(macOS)
        guard !(self is AVAggregateAssetDownloadTask) else { return nil }
        #endif
        return originalRequest?.httpBody
    }
}
