import Foundation
import SharedModels
import CodeTimeSecurity
import CryptoKit

/// Content addressing for Cloud Format v3.
///
/// Two separate identities exist for a chunk and they must not be confused:
///
/// * `plaintextHash` — SHA-256 of the chunk bytes. Used to prove the bytes we
///   reassemble are the bytes we read, and to detect corruption.
/// * `objectID` — HMAC-SHA256(dedupKey, plaintextHash). This is what names the
///   object in iCloud. The HMAC keeps the cloud filename from disclosing the
///   content hash (a plain SHA-256 name would let anyone with read access to the
///   container confirm whether a known file is backed up).
///
/// Same chunk + same repository key ⇒ same objectID, so identical content is
/// stored exactly once and never re-uploaded.
public struct ContentHasher: Sendable {
    private let dedupKey: SymmetricKey

    /// Derives the repository-scoped dedup key from the master key via HKDF.
    public init(masterKey: Data) {
        self.dedupKey = CryptoBox.deriveKey(
            masterKey: masterKey,
            salt: Data("codetime.v3.objectid".utf8),
            info: "codetime.v3.objectid.v1"
        )
    }

    /// 64 hex characters, namespaced under the first two characters by the store.
    public func objectID(forChunk data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(digest), using: dedupKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    public func plaintextHash(forChunk data: Data) -> String {
        Hashing.sha256Hex(data)
    }

    public func plaintextHash(ofFile url: URL, chunkSize: Int = 1 << 20) throws -> String {
        try Hashing.sha256Hex(fileURL: url, chunkSize: chunkSize)
    }
}
