import Foundation
import Testing
@testable import Babylon

struct DataCompressionTests {
    // MARK: - Roundtrip Tests

    @Test("gzip and gunzip roundtrip preserves small data")
    func roundtripSmallData() {
        let original = Data("Hello, Babylon!".utf8)
        let compressed = original.gzip()
        #expect(compressed != nil)
        #expect(compressed != original)

        let decompressed = compressed?.gunzip()
        #expect(decompressed == original)
    }

    @Test("roundtrip preserves various data sizes", arguments: [1, 16, 256, 1024, 4096, 65536])
    func roundtripVariousSizes(size: Int) {
        var original = Data(count: size)
        for i in 0 ..< size {
            original[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7)
        }

        let compressed = original.gzip()
        #expect(compressed != nil)

        let decompressed = compressed?.gunzip()
        #expect(decompressed == original)
    }

    @Test("roundtrip with 1 MB of data")
    func roundtripLargeData() throws {
        let size = 1_048_576
        var original = Data(count: size)
        for i in 0 ..< size {
            original[i] = UInt8(truncatingIfNeeded: i &* 17 &+ 3)
        }

        let compressed = original.gzip()
        #expect(compressed != nil)
        #expect(try #require(compressed?.count) < original.count)

        let decompressed = compressed?.gunzip()
        #expect(decompressed == original)
    }

    @Test("roundtrip preserves exact byte content")
    func roundtripIntegrity() {
        let original = Data((0 ..< 256).map { UInt8($0) })
        let result = original.gzip()?.gunzip()
        #expect(result == original)
        #expect(result?.count == original.count)
    }

    @Test("roundtrip with repeated data achieves compression")
    func compressibleDataShrinks() throws {
        let repeated = Data(repeating: 0x42, count: 10000)
        let compressed = repeated.gzip()
        #expect(compressed != nil)
        #expect(try #require(compressed?.count) < repeated.count)
        #expect(compressed?.gunzip() == repeated)
    }

    // MARK: - Empty Data

    @Test("gzip returns nil for empty data")
    func gzipEmptyData() {
        let empty = Data()
        #expect(empty.gzip() == nil)
    }

    @Test("gunzip returns nil for empty data")
    func gunzipEmptyData() {
        let empty = Data()
        #expect(empty.gunzip() == nil)
    }

    // MARK: - Invalid Input

    @Test("gunzip returns nil for random invalid data")
    func gunzipInvalidData() {
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
        #expect(garbage.gunzip() == nil)
    }

    @Test("gunzip returns nil for truncated gzip data")
    func gunzipTruncatedData() {
        let original = Data("test data for truncation".utf8)
        guard let compressed = original.gzip() else {
            Issue.record("Failed to compress test data")
            return
        }
        // Remove the last 4 bytes (partial footer)
        let truncated = compressed.prefix(compressed.count - 4)
        #expect(truncated.gunzip() == nil)
    }

    @Test("gunzip returns nil for data shorter than minimum gzip size")
    func gunzipTooShort() {
        let tooShort = Data([0x1F, 0x8B, 0x08, 0x00, 0x00])
        #expect(tooShort.gunzip() == nil)
    }

    @Test("gunzip returns nil when magic bytes are wrong")
    func gunzipWrongMagic() {
        let original = Data("magic test".utf8)
        guard var compressed = original.gzip() else {
            Issue.record("Failed to compress test data")
            return
        }
        // Corrupt the first magic byte
        compressed[0] = 0x00
        #expect(compressed.gunzip() == nil)
    }

    @Test("gunzip returns nil when CRC32 is corrupted")
    func gunzipCorruptedChecksum() {
        let original = Data("checksum test".utf8)
        guard var compressed = original.gzip() else {
            Issue.record("Failed to compress test data")
            return
        }
        // Corrupt the CRC32 (4 bytes before the last 4 bytes)
        let crcOffset = compressed.count - 8
        compressed[crcOffset] ^= 0xFF
        #expect(compressed.gunzip() == nil)
    }

    // MARK: - GZIP Header Validation

    @Test("gzip output starts with correct magic bytes")
    func gzipHeaderMagicBytes() {
        let data = Data("header check".utf8)
        guard let compressed = data.gzip() else {
            Issue.record("Failed to compress test data")
            return
        }
        #expect(compressed[0] == 0x1F)
        #expect(compressed[1] == 0x8B)
        #expect(compressed[2] == 0x08) // deflate method
    }
}
