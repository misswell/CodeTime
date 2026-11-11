import Foundation
import Compression
import CryptoKit
import CodeTimeSecurity

/// Cloud Format v3 object envelope.
///
/// Version 2 (current write format), all integers big-endian:
///
///     "CTO3" | formatVersion u8 | compression u8 | keyVersion u16
///     | originalSize u64 | nonce 12 | ciphertext | tag 16
///
/// The plaintext SHA-256 is *inside* the AEAD payload, never in the public
/// header. The header (including the object ID as additional data) is
/// authenticated, so an object cannot be re-labelled, re-compressed or replayed
/// as a different object.
///
/// Version 1 (legacy, decode-only) carried the plaintext SHA-256 in the header.
/// It is still accepted so existing v3 backups remain readable.
public enum ObjectEnvelope {
    public static let magic = Data("CTO3".utf8)
    public static let formatVersion: UInt8 = 2
    public static let legacyFormatVersion: UInt8 = 1
    /// magic + version + compression + keyVersion + originalSize + nonce
    public static let headerSize: Int = 4 + 1 + 1 + 2 + 8 + 12
    /// magic + version + compression + keyVersion + originalSize + plaintextHash + nonce
    public static let legacyHeaderSize: Int = 4 + 1 + 1 + 2 + 8 + 32 + 12

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

    public var diagnosticCode: String { "ICLOUD_OBJECT_CORRUPTED" }
}

public struct EncodedObject: Sendable, Equatable {
    public let objectID: String
    public let payload: Data
    public let originalSize: Int
    public let storedSize: Int
    public let compression: ObjectEnvelope.CompressionKind
    public let keyVersion: UInt16
    public let formatVersion: UInt8

    public var savedBytes: Int { max(0, originalSize - storedSize) }
    /// A chunk that got bigger through compression keeps its original bytes.
    public var wasCompressed: Bool { compression != .none }
}

public struct ObjectEncoder: Sendable {
    private let masterKey: Data
    private let hasher: ContentHasher
    /// Key version used for new objects.
    public let keyVersion: UInt16
    /// Chunks below this size are not worth compressing (header/FSE overhead).
    public let compressionThreshold: Int

    public init(masterKey: Data, keyVersion: UInt16 = 1, compressionThreshold: Int = 1024) {
        self.masterKey = masterKey
        self.hasher = ContentHasher(masterKey: masterKey)
        self.keyVersion = keyVersion
        self.compressionThreshold = compressionThreshold
    }

    public func objectID(for chunk: Data) -> String {
        hasher.objectID(forChunk: chunk)
    }

    /// The object key is derived per key version. Key version therefore actually
    /// participates in HKDF instead of being a decorative header field.
    private func objectKey(for version: UInt16) -> SymmetricKey {
        CryptoBox.deriveKey(
            masterKey: masterKey,
            salt: Data("codetime.v3.object".utf8),
            info: "codetime.v3.object.v\(version)"
        )
    }

    public func encode(chunk: Data) throws -> EncodedObject {
        try encode(chunk: chunk, formatVersion: ObjectEnvelope.formatVersion)
    }

    /// `formatVersion: 1` exists only for compatibility tests/migration fixtures;
    /// production always writes version 2.
    func encode(chunk: Data, formatVersion: UInt8) throws -> EncodedObject {
        guard formatVersion == 1 || formatVersion == 2 else {
            throw ObjectCodecError.unsupportedFormat(formatVersion)
        }
        let objectID = hasher.objectID(forChunk: chunk)
        let originalSize = chunk.count

        var body = chunk
        var compression = ObjectEnvelope.CompressionKind.none
        if originalSize >= compressionThreshold,
           let squeezed = Self.lzfseCompress(chunk),
           squeezed.count < chunk.count {
            body = squeezed
            compression = .lzfse
        }

        let nonce = try AES.GCM.Nonce()
        let nonceBytes = Data(nonce)
        let plaintextHash = Data(SHA256.hash(data: chunk))
        let header: Data
        let authenticatedBody: Data
        if formatVersion == 1 {
            header = Self.legacyHeader(
                compression: compression,
                keyVersion: keyVersion,
                originalSize: originalSize,
                plaintextHash: plaintextHash,
                nonce: nonceBytes
            )
            authenticatedBody = body
        } else {
            header = Self.header(
                compression: compression,
                keyVersion: keyVersion,
                originalSize: originalSize,
                nonce: nonceBytes
            )
            var inner = Data()
            inner.append(plaintextHash)
            inner.append(body)
            authenticatedBody = inner
        }
        let sealed = try AES.GCM.seal(
            authenticatedBody,
            using: objectKey(for: keyVersion),
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
            keyVersion: keyVersion,
            formatVersion: formatVersion
        )
    }

    /// Decodes and proves the object is the one we asked for.
    /// `expectingSize` is optional; when supplied a mismatch is an error.
    public func decode(_ payload: Data, objectID: String, expectingSize: Int? = nil) throws -> Data {
        guard payload.count >= 4 + 1 + 1 + 2 + 8 + 12 + 16 else {
            throw ObjectCodecError.tooShort(payload.count)
        }
        guard payload.prefix(4) == ObjectEnvelope.magic else {
            throw ObjectCodecError.badMagic
        }
        let base = payload.startIndex
        let formatVersion = payload[base + 4]
        guard formatVersion == 1 || formatVersion == 2 else {
            throw ObjectCodecError.unsupportedFormat(formatVersion)
        }
        guard let compression = ObjectEnvelope.CompressionKind(rawValue: payload[base + 5]) else {
            throw ObjectCodecError.unsupportedCompression(payload[base + 5])
        }
        let storedKeyVersion = UInt16(payload[base + 6]) << 8 | UInt16(payload[base + 7])
        let originalSize = Self.readUInt64(payload, at: base + 8)
        let headerSize = formatVersion == 1
            ? ObjectEnvelope.legacyHeaderSize
            : ObjectEnvelope.headerSize
        guard payload.count >= headerSize + 16 else {
            throw ObjectCodecError.tooShort(payload.count)
        }
        let nonceOffset = formatVersion == 1 ? 48 : 16
        let nonce = payload.subdata(in: (base + nonceOffset)..<(base + nonceOffset + 12))
        let header = payload.subdata(in: base..<(base + headerSize))
        let ciphertext = payload.subdata(in: (base + headerSize)..<(payload.endIndex - 16))
        let tag = payload.subdata(in: (payload.endIndex - 16)..<payload.endIndex)

        let sealed = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        let opened: Data
        do {
            opened = try AES.GCM.open(
                sealed,
                using: objectKey(for: formatVersion == 1 ? 1 : storedKeyVersion),
                authenticating: header + Data(objectID.utf8)
            )
        } catch {
            throw ObjectCodecError.decryptionFailed
        }

        let expectedHash: Data
        let body: Data
        if formatVersion == 1 {
            expectedHash = payload.subdata(in: (base + 16)..<(base + 48))
            body = opened
        } else {
            guard opened.count >= 32 else {
                throw ObjectCodecError.tooShort(opened.count)
            }
            expectedHash = opened.prefix(32)
            body = opened.subdata(in: 32..<opened.count)
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
        header.append(nonce.prefix(12))
        return header
    }

    static func legacyHeader(
        compression: ObjectEnvelope.CompressionKind,
        keyVersion: UInt16,
        originalSize: Int,
        plaintextHash: Data,
        nonce: Data
    ) -> Data {
        var header = Data()
        header.append(ObjectEnvelope.magic)
        header.append(ObjectEnvelope.legacyFormatVersion)
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
