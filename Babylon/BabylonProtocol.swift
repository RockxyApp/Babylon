// Copyright 2026 Rockxy.
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import zlib

enum BabylonProtocol {
    static let version = 1
    static let keySalt = Data("rockxy-babylon-v1".utf8)
    static let maximumInboundPlaintextSize = 1_048_576
    static let maximumMessageIDSize = 128
    static let maximumSessionIDSize = 128
    static let maximumClientIDSize = 512
    static let maximumProtocolErrorBytes = 4096

    enum MessageType: String, Codable, CaseIterable {
        case connection
        case traffic
        case websocket
        case runtime
        case heartbeat
        case ack
        case error
    }

    enum Compression: String, Codable {
        case gzip
    }

    struct PayloadEnvelope: Codable {
        let messageType: MessageType
        let sentAt: TimeInterval
        let content: Data
    }

    struct SecureFrame: Codable {
        let protocolVersion: Int
        let messageID: String
        let sessionID: String
        let clientID: String
        let sequence: UInt64
        let compression: Compression
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    struct Ack: Codable, Equatable {
        let messageID: String
    }

    struct Heartbeat: Codable, Equatable {
        let uptime: TimeInterval
    }

    struct ProtocolError: Codable, Equatable {
        let code: String
        let message: String

        init(code: String, message: String) {
            self.code = CaptureString.bounded(code, maximumBytes: 128)
            self.message = CaptureString.bounded(message, maximumBytes: Self.maximumMessageBytes)
        }

        private static let maximumMessageBytes = BabylonProtocol.maximumProtocolErrorBytes
    }

    struct DecodedMessage {
        let frame: SecureFrame
        let payload: PayloadEnvelope
    }

    struct EncodedFrame {
        let messageID: String
        let header: Data
        let payload: Data
        var captureMemoryLease: CaptureMemoryLease?

        var data: Data {
            var result = Data(capacity: header.count + payload.count)
            result.append(header)
            result.append(payload)
            return result
        }
    }

    enum CodecError: Error, Equatable {
        case authenticationRequired
        case invalidNonce
        case invalidProtocolVersion
        case identityMismatch
        case unsupportedCompression
        case payloadTooLarge
        case malformedFrame
        case compressionFailed
    }

    static func encode(
        message: Message,
        configuration: Configuration,
        sequence: UInt64,
        messageID: String = UUID().uuidString,
        sentAt: TimeInterval = Date().timeIntervalSince1970,
        nonce: Data? = nil
    ) throws -> EncodedFrame {
        guard configuration.hasValidAuthentication else {
            throw CodecError.authenticationRequired
        }
        guard let content = message.payloadData else {
            throw CodecError.compressionFailed
        }
        let payload = PayloadEnvelope(messageType: message.payloadType, sentAt: sentAt, content: content)
        var frame = try encode(
            payload: payload,
            configuration: configuration,
            sequence: sequence,
            messageID: messageID,
            nonce: nonce
        )
        frame.captureMemoryLease = message.captureMemoryLease
        return frame
    }

    static func encode(
        payload: PayloadEnvelope,
        configuration: Configuration,
        sequence: UInt64,
        messageID: String = UUID().uuidString,
        nonce: Data? = nil
    ) throws -> EncodedFrame {
        guard configuration.hasValidAuthentication else {
            throw CodecError.authenticationRequired
        }
        guard isValidIdentifier(messageID, maximumSize: maximumMessageIDSize),
              isValidIdentifier(configuration.sessionID, maximumSize: maximumSessionIDSize),
              isValidIdentifier(configuration.clientID, maximumSize: maximumClientIDSize) else {
            throw CodecError.identityMismatch
        }

        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys]
        let plaintext = try payloadEncoder.encode(payload)
        let compressed = try deterministicGzip(plaintext)

        let nonceValue: AES.GCM.Nonce
        if let nonce {
            guard nonce.count == 12, let value = try? AES.GCM.Nonce(data: nonce) else {
                throw CodecError.invalidNonce
            }
            nonceValue = value
        } else {
            nonceValue = AES.GCM.Nonce()
        }

        let aad = authenticatedData(
            clientID: configuration.clientID,
            sessionID: configuration.sessionID,
            messageID: messageID,
            sequence: sequence
        )
        let sealed = try AES.GCM.seal(
            compressed,
            using: encryptionKey(configuration: configuration),
            nonce: nonceValue,
            authenticating: aad
        )
        let secureFrame = SecureFrame(
            protocolVersion: version,
            messageID: messageID,
            sessionID: configuration.sessionID,
            clientID: configuration.clientID,
            sequence: sequence,
            compression: .gzip,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        let frameEncoder = JSONEncoder()
        frameEncoder.outputFormatting = [.sortedKeys]
        let encoded = try frameEncoder.encode(secureFrame)
        guard encoded.count <= BabylonConstants.maximumFrameSize else {
            throw CodecError.payloadTooLarge
        }
        return EncodedFrame(messageID: messageID, header: lengthHeader(for: encoded.count), payload: encoded)
    }

    static func decode(frameData: Data, configuration: Configuration) throws -> DecodedMessage {
        guard frameData.count <= BabylonConstants.maximumFrameSize else {
            throw CodecError.payloadTooLarge
        }
        guard configuration.hasValidAuthentication,
              let frame = try? JSONDecoder().decode(SecureFrame.self, from: frameData) else {
            throw configuration.hasValidAuthentication ? CodecError.malformedFrame : CodecError.authenticationRequired
        }
        guard frame.protocolVersion == version else {
            throw CodecError.invalidProtocolVersion
        }
        guard frame.clientID == configuration.clientID,
              frame.sessionID == configuration.sessionID,
              isValidIdentifier(frame.messageID, maximumSize: maximumMessageIDSize),
              isValidIdentifier(frame.sessionID, maximumSize: maximumSessionIDSize),
              isValidIdentifier(frame.clientID, maximumSize: maximumClientIDSize) else {
            throw CodecError.identityMismatch
        }
        guard frame.compression == .gzip else {
            throw CodecError.unsupportedCompression
        }
        guard frame.nonce.count == 12,
              let nonce = try? AES.GCM.Nonce(data: frame.nonce),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: frame.ciphertext, tag: frame.tag) else {
            throw CodecError.invalidNonce
        }
        let aad = authenticatedData(
            clientID: frame.clientID,
            sessionID: frame.sessionID,
            messageID: frame.messageID,
            sequence: frame.sequence
        )
        let compressed = try AES.GCM.open(
            sealed,
            using: encryptionKey(configuration: configuration),
            authenticating: aad
        )
        let plaintext = try boundedGunzip(compressed, maximumOutputSize: maximumInboundPlaintextSize)
        guard let payload = try? JSONDecoder().decode(PayloadEnvelope.self, from: plaintext) else {
            throw CodecError.malformedFrame
        }
        return DecodedMessage(frame: frame, payload: payload)
    }

    static func lengthHeader(for count: Int) -> Data {
        var length = UInt64(count).bigEndian
        return Data(bytes: &length, count: MemoryLayout<UInt64>.size)
    }

    static func encryptionKey(configuration: Configuration) -> SymmetricKey {
        let tokenKey = SymmetricKey(data: Data(configuration.normalizedAuthToken.utf8))
        let info = Data("\(configuration.clientID):\(configuration.sessionID)".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: tokenKey,
            salt: keySalt,
            info: info,
            outputByteCount: 32
        )
    }

    private static func authenticatedData(
        clientID: String,
        sessionID: String,
        messageID: String,
        sequence: UInt64
    ) -> Data {
        Data("1:\(clientID):\(sessionID):\(messageID):\(sequence)".utf8)
    }

    private static func isValidIdentifier(_ value: String, maximumSize: Int) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= maximumSize && bytes.allSatisfy { byte in
            byte >= 0x20 && byte != 0x3A && byte != 0x7F
        }
    }

    private static func boundedGunzip(_ data: Data, maximumOutputSize: Int) throws -> Data {
        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw CodecError.compressionFailed
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 32768
        let status = data.withUnsafeBytes { inputBuffer -> Int32 in
            guard let inputAddress = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputAddress)
            stream.avail_in = uInt(data.count)

            var inflateStatus = Z_OK
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                let produced = chunk.withUnsafeMutableBytes { outputBuffer -> Int in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    inflateStatus = zlib.inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                guard output.count + produced <= maximumOutputSize else {
                    return Z_MEM_ERROR
                }
                output.append(contentsOf: chunk.prefix(produced))
            } while inflateStatus == Z_OK
            return inflateStatus
        }

        guard status == Z_STREAM_END else {
            if status == Z_MEM_ERROR {
                throw CodecError.payloadTooLarge
            }
            throw CodecError.compressionFailed
        }
        return output
    }

    private static func deterministicGzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initialization = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw CodecError.compressionFailed
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 32768
        let status = data.withUnsafeBytes { inputBuffer -> Int32 in
            guard let inputAddress = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputAddress)
            stream.avail_in = uInt(data.count)

            var deflateStatus = Z_OK
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                let produced = chunk.withUnsafeMutableBytes { outputBuffer -> Int in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    deflateStatus = zlib.deflate(&stream, Z_FINISH)
                    return chunkSize - Int(stream.avail_out)
                }
                output.append(contentsOf: chunk.prefix(produced))
                guard output.count <= BabylonConstants.maximumFrameSize else {
                    return Z_MEM_ERROR
                }
            } while deflateStatus == Z_OK
            return deflateStatus
        }

        guard status == Z_STREAM_END else {
            if status == Z_MEM_ERROR {
                throw CodecError.payloadTooLarge
            }
            throw CodecError.compressionFailed
        }
        return output
    }
}

struct ProtocolFrameAccumulator {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= MemoryLayout<UInt64>.size {
            let length = buffer.prefix(MemoryLayout<UInt64>.size).reduce(UInt64(0)) { partial, byte in
                (partial << 8) | UInt64(byte)
            }
            guard length <= UInt64(BabylonConstants.maximumFrameSize) else {
                buffer.removeAll(keepingCapacity: false)
                throw BabylonProtocol.CodecError.payloadTooLarge
            }
            guard length > 0 else {
                buffer.removeAll(keepingCapacity: false)
                throw BabylonProtocol.CodecError.malformedFrame
            }
            let totalLength = MemoryLayout<UInt64>.size + Int(length)
            guard buffer.count >= totalLength else { break }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: MemoryLayout<UInt64>.size)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: totalLength)
            frames.append(Data(buffer[payloadStart ..< payloadEnd]))
            buffer.removeFirst(totalLength)
        }

        return frames
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}

struct ProtocolMessageDeduplicator {
    private let capacity: Int
    private var orderedIDs: [String] = []
    private var IDs: Set<String> = []

    init(capacity: Int = 1024) {
        self.capacity = max(capacity, 1)
    }

    mutating func insert(_ messageID: String) -> Bool {
        guard IDs.insert(messageID).inserted else { return false }
        orderedIDs.append(messageID)
        if orderedIDs.count > capacity {
            IDs.remove(orderedIDs.removeFirst())
        }
        return true
    }

    mutating func reset() {
        orderedIDs.removeAll(keepingCapacity: false)
        IDs.removeAll(keepingCapacity: false)
    }
}
