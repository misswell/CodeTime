import Foundation
import Compression
import CryptoKit
import CodeTimeSecurity

/// Cloud Format v3 object envelope.
///
/// Layout (all integers big-endian):
///
///     "CTO3" | formatVersion u8 | compression u8 | keyVersion u16
///     | originalSize u64 | plaintextSHA256 32 | nonce 12 | ciphertext | tag 16
///
/// The header is fed to AES-GCM as associated data (together with the object ID),
/// so an object cannot be re-labelled, re-compressed or replayed as a different
/// object: any change to the header invalidates the tag.
///
/// Compression is only kept when it actually shrinks the chunk; the flag records
/// which path was taken so decoding never guesses.
public enum ObjectEnvelope {
    public static let magic = Data("CTO3".utf8)
    public static let formatVersion: UInt8 = 1
    public static let headerSize = 4 + 1 + 1 + 2 + 8 + 32 + 12

    public enum CompressionKind: UInt8, Sendable, CaseIterable {
        case none = 0
        case lzfse = 1
    }
}

public enum ObjectCodecError: Error, Sendable, Equatable {
    case tooShort(Int)
    case badMagic
    case unsupportedFormat(UInt8)
    case unsupportedCompression(UInt8)
    case plaintextHashMismatch
    case sizeMismatch(expected: Int, actual: Int)
    case decryptionFailed
    case compressionFailed
    case decompressionFailed

    public var diagnosticCode: String {
        switch self {
        case .tooShort, .badMagic, .unsupportedFormat, .unsupportedCompression:
            return "ICLOUD_OBJECT_CORRUPTED"
        case .plaintextHashMismatch, .sizeMismatch:
            return "ICLOUD_OBJECT_CORRUPTED"
        case .decryptionFailed:
            return "ICLOUD_OBJECT_CORRUPTED"
        case .compressionFailed, .decompressionFailed:
            return "ICLOUD_OBJECT_CORRUPTED"
        }
    }
}

public struct EncodedObject: Sendable, Equatable {
    public let objectID: String
    public let payload: Data
    public let originalSize: Int
    public let storedSize: Int
    public let compression: ObjectEnvelope.CompressionKind
    public let keyVersion: UInt16

    public var savedBytes: Int { max(0, originalSize - storedSize) }
    /// A chunk that got bigger through compression keeps its original bytes.
    public var wasCompressed: Bool { compression != .none }
}

public struct ObjectEncoder: Sendable {
    private let objectKey: SymmetricKey
    private let hasher: ContentHasher
    public let keyVersion: UInt16
    /// Chunks below this size are not worth compressing (header/FSE overhead).
    public let compressionThreshold: Int

    public init(masterKey: Data, keyVersion: UInt16 = 1, compressionThreshold: Int = 1024) {
        self.objectKey = CryptoBox.deriveKey(
            masterKey: masterKey,
            salt: Data("codetime.v3.object".utf8),
            info: "codetime.v3.object.v1"
        )
        self.hasher = ContentHasher(masterKey: masterKey)
        self.keyVersion = keyVersion
        self.compressionThreshold = compressionThreshold
    }

    public func objectID(for chunk: Data) -> String {
        hasher.objectID(forChunk: chunk)
    }

    public func encode(chunk: Data) throws -> EncodedObject {
        let objectID = hasher.objectID(forChunk: chunk)
        let originalSize = chunk.count

        var body = chunk
        var compression = ObjectEnvelope.CompressionKind.none
        if originalSize >= compressionThreshold, let squeezed = Self.lzfseCompress(chunk), squeezed.count < chunk.count {
            body = squeezed
            compression = .lzfse
        }

        let nonce = try AES.GCM.Nonce()
        let nonceBytes = Data(nonce)
        let header = Self.header(
            compression: compression,
            keyVersion: keyVersion,
            originalSize: originalSize,
            plaintextHash: Data(SHA256.hash(data: chunk)),
            nonce: nonceBytes
        )
        let sealed = try AES.GCM.seal(
            body,
            using: objectKey,
            nonce: nonce,
            authenticating: header + Data(objectID.utf8)
        )
        var payload = header
        payload.append(sealed.ciphertext)
        payload.append(sealed.tag)

        return EncodedObject(
            objectID: objectID,
            payload: payload,
            originalSize: originalSize,
            storedSize: payload.count,
            compression: compression,
            keyVersion: keyVersion
        )
    }

    /// Decodes and proves the object is the one we asked for.
    /// `expectingSize` is optional; when supplied a mismatch is an error.
    public func decode(_ payload: Data, objectID: String, expectingSize: Int? = nil) throws -> Data {
        guard payload.count >= ObjectEnvelope.headerSize + 16 else {
            throw ObjectCodecError.tooShort(payload.count)
        }
        guard payload.prefix(4) == ObjectEnvelope.magic else {
            throw ObjectCodecError.badMagic
        }
        let base = payload.startIndex
        let formatVersion = payload[base + 4]
        guard formatVersion == ObjectEnvelope.formatVersion else {
            throw ObjectCodecError.unsupportedFormat(formatVersion)
        }
        guard let compression = ObjectEnvelope.CompressionKind(rawValue: payload[base + 5]) else {
            throw ObjectCodecError.unsupportedCompression(payload[base + 5])
        }
        let storedKeyVersion = UInt16(payload[base + 6]) << 8 | UInt16(payload[base + 7])
        guard storedKeyVersion == keyVersion else {
            throw ObjectCodecError.unsupportedFormat(UInt8(truncatingIfNeeded: storedKeyVersion))
        }
        let originalSize = Self.readUInt64(payload, at: base + 8)
        let expectedHash = payload.subdata(in: (base + 16)..<(base + 48))
        let nonce = payload.subdata(in: (base + 48)..<(base + 60))
        let header = payload.subdata(in: base..<(base + ObjectEnvelope.headerSize))
        let ciphertext = payload.subdata(in: (base + ObjectEnvelope.headerSize)..<(payload.endIndex - 16))
        let tag = payload.subdata(in: (payload.endIndex - 16)..<payload.endIndex)

        let sealed = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        let body: Data
        do {
            body = try AES.GCM.open(
                sealed,
                using: objectKey,
                authenticating: header + Data(objectID.utf8)
            )
        } catch {
            throw ObjectCodecError.decryptionFailed
        }

        let chunk: Data
        switch compression {
        case .none:
            chunk = body
        case .lzfse:
            guard let inflated = Self.lzfseDecompress(body, originalSize: Int(originalSize)) else {
                throw ObjectCodecError.decompressionFailed
            }
            chunk = inflated
        }

        guard chunk.count == Int(originalSize) else {
            throw ObjectCodecError.sizeMismatch(expected: Int(originalSize), actual: chunk.count)
        }
        guard Data(SHA256.hash(data: chunk)) == expectedHash else {
            throw ObjectCodecError.plaintextHashMismatch
        }
        if let expectingSize, expectingSize != chunk.count {
            throw ObjectCodecError.sizeMismatch(expected: expectingSize, actual: chunk.count)
        }
        // The name must match the content — otherwise a swapped-but-valid object
        // would be accepted under the wrong identity.
        guard hasher.objectID(forChunk: chunk) == objectID else {
            throw ObjectCodecError.plaintextHashMismatch
        }
        return chunk
    }

    // MARK: - Header

    static func header(
        compression: ObjectEnvelope.CompressionKind,
        keyVersion: UInt16,
        originalSize: Int,
        plaintextHash: Data,
        nonce: Data
    ) -> Data {
        var header = Data()
        header.append(ObjectEnvelope.magic)
        header.append(ObjectEnvelope.formatVersion)
        header.append(compression.rawValue)
        header.append(UInt8(keyVersion >> 8))
        header.append(UInt8(keyVersion & 0xFF))
        for shift in stride(from: 56, through: 0, by: -8) {
            header.append(UInt8((UInt64(originalSize) >> UInt64(shift)) & 0xFF))
        }
        header.append(plaintextHash.prefix(32))
        header.append(nonce.prefix(12))
        return header
    }

    static func readUInt64(_ data: Data, at index: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value = (value << 8) | UInt64(data[index + offset])
        }
        return value
    }

    // MARK: - LZFSE

    /// Returns nil when the API cannot fit the output or fails; callers then store
    /// the chunk uncompressed rather than losing data.
    static func lzfseCompress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + max(64 * 1024, input.count / 8)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBase, capacity,
                    sourceBase, input.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }

    static func lzfseDecompress(_ input: Data, originalSize: Int) -> Data? {
        guard originalSize > 0, input.count > 0 else { return nil }
        var output = Data(count: originalSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, originalSize,
                    sourceBase, input.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard written == originalSize else { return nil }
        return output
    }
}
