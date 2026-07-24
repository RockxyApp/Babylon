// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import zlib

extension Data {
    func gzip() -> Data? {
        GzipCodec.encode(self)
    }

    func gunzip() -> Data? {
        GzipCodec.decode(self)
    }
}

private enum GzipCodec {
    private static let chunkSize = 32 * 1024

    static func encode(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        var stream = z_stream()
        guard deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        return process(input, stream: &stream, operation: .encode)
    }

    static func decode(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        return process(input, stream: &stream, operation: .decode)
    }

    private enum Operation {
        case encode
        case decode
    }

    private static func process(_ input: Data, stream: inout z_stream, operation: Operation) -> Data? {
        input.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer(mutating: source)
            stream.avail_in = uInt(input.count)

            var result = Data()
            var output = [UInt8](repeating: 0, count: chunkSize)
            while true {
                let status = output.withUnsafeMutableBytes { destinationBuffer -> Int32 in
                    stream.next_out = destinationBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    switch operation {
                    case .encode:
                        return zlib.deflate(&stream, Z_FINISH)
                    case .decode:
                        return zlib.inflate(&stream, Z_NO_FLUSH)
                    }
                }
                let written = chunkSize - Int(stream.avail_out)
                result.append(contentsOf: output.prefix(written))
                if status == Z_STREAM_END {
                    return result
                }
                guard status == Z_OK else { return nil }
            }
        }
    }
}
