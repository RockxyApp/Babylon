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
}
