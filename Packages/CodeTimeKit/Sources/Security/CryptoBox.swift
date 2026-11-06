import Foundation
import CryptoKit
import Security

public enum SecurityError: LocalizedError, Sendable {
    case keychain(OSStatus)
    case invalidRecoveryKey
    case corruptCiphertext
    case missingSecret(String)
    case randomGenerationFailed(OSStatus)
    case bookmarkFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain 操作失败（\(status)）"
        case .invalidRecoveryKey:
            return "恢复密钥格式不正确"
        case .corruptCiphertext:
            return "加密数据损坏或密钥不匹配"
        case .missingSecret(let name):
            return "缺少密钥：\(name)"
        case .randomGenerationFailed(let status):
            return "系统随机数生成失败（\(status)）"
        case .bookmarkFailed(let detail):
            return "无法创建目录访问书签：\(detail)"
        }
    }
}

public struct CryptoBox: Sendable {
    private static let magic = Data("CTM1".utf8)

    static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw SecurityError.randomGenerationFailed(status)
        }
        return data
    }

    public static func deriveKey(masterKey: Data, salt: Data, info: String) -> SymmetricKey {
        let input = SymmetricKey(data: masterKey)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// Binary layout: "CTM1" | 16-byte salt | AES.GCM combined (nonce|ciphertext|tag).
    /// The associated data binds the ciphertext to its generation identifier.
    public static func seal(_ plaintext: Data, masterKey: Data, context: String) throws -> Data {
        let salt = try randomBytes(count: 16)
        let key = deriveKey(masterKey: masterKey, salt: salt, info: "codetime.cloud.manifest.v1")
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Data(context.utf8))
        guard let combined = sealed.combined else {
            throw SecurityError.corruptCiphertext
        }
        var output = Data()
        output.append(magic)
        output.append(salt)
        output.append(combined)
        return output
    }

    public static func open(_ sealedData: Data, masterKey: Data, context: String) throws -> Data {
        guard sealedData.count > 4 + 16 + 12 + 16,
              sealedData.prefix(4) == magic else {
            throw SecurityError.corruptCiphertext
        }
        let salt = sealedData.subdata(in: 4..<20)
        let combined = sealedData.subdata(in: 20..<sealedData.count)
        let key = deriveKey(masterKey: masterKey, salt: salt, info: "codetime.cloud.manifest.v1")
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch {
            throw SecurityError.corruptCiphertext
        }
    }
}

public enum RecoveryKey {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate() throws -> Data {
        try CryptoBox.randomBytes(count: 32)
    }

    public static func format(_ key: Data) -> String {
        let encoded = base32Encode(key)
        var groups: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 5, limitedBy: encoded.endIndex) ?? encoded.endIndex
            groups.append(String(encoded[index..<end]))
            index = end
        }
        return "CT1-" + groups.joined(separator: "-")
    }

    public static func parse(_ text: String) throws -> Data {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("CT1") {
            cleaned.removeFirst(3)
        }
        let filtered = cleaned.filter { character in
            character.isLetter || character.isNumber
        }
        var normalized = ""
        for character in filtered {
            switch character {
            case "O": normalized.append("0")
            case "I", "L": normalized.append("1")
            default: normalized.append(character)
            }
        }
        guard let data = base32Decode(normalized), data.count == 32 else {
            throw SecurityError.invalidRecoveryKey
        }
        return data
    }

    private static func base32Encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var output = ""
        output.reserveCapacity((data.count * 8 + 4) / 5)
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(value >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            output.append(alphabet[(value << (5 - bits)) & 0x1F])
        }
        return output
    }

    private static func base32Decode(_ text: String) -> Data? {
        var bits = 0
        var value = 0
        var bytes: [UInt8] = []
        for character in text {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return Data(bytes)
    }
}

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(fileURL: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct SecurityScopedAccess {
    public let url: URL
    private let started: Bool

    public init(url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
    }

    public func stop() {
        if started { url.stopAccessingSecurityScopedResource() }
    }
}

public enum SecurityScopedBookmarks {
    public static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            do {
                return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                throw SecurityError.bookmarkFailed(error.localizedDescription)
            }
        }
    }

    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url, stale)
        } catch {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url, stale)
        }
    }
}
