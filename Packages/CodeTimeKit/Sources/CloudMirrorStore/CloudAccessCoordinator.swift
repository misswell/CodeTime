import Foundation
import SharedModels
import CodeTimeSecurity

/// The single path for reading/writing iCloud-backed files.
///
/// Every write follows the same lifecycle: write atomically → wait until the
/// provider confirms the upload → optionally re-read and hash the bytes → release
/// the local copy only when it is safe. Nodes, manifests, commits, objects and
/// packs all use this type; a provider state is never inferred from "the file
/// exists in the container".
public struct CloudAccessCoordinator: Sendable {
    public let access: CloudFileAccess
    private let tracker: CloudUploadTracking
    private let eviction: ICloudEvictionManager?
    private let uploadTimeout: TimeInterval
    private let observer: (@Sendable (EvictionOutcome) -> Void)?

    public init(
        access: CloudFileAccess,
        tracker: CloudUploadTracking,
        eviction: ICloudEvictionManager?,
        uploadTimeout: TimeInterval = 120,
        evictionObserver: (@Sendable (EvictionOutcome) -> Void)? = nil
    ) {
        self.access = access
        self.tracker = tracker
        self.eviction = eviction
        self.uploadTimeout = uploadTimeout
        self.observer = evictionObserver
    }

    // MARK: - Coordinated file operations

    public func read(_ url: URL) async throws -> Data {
        try await access.read(url)
    }

    public func writeAtomically(_ data: Data, to url: URL) async throws {
        try await access.writeAtomically(data, to: url)
    }

    public func move(_ source: URL, to destination: URL) async throws {
        try await access.move(source, to: destination)
    }

    public func copy(_ source: URL, to destination: URL) async throws {
        try await access.copy(source, to: destination)
    }

    public func remove(_ url: URL) async throws {
        try await access.remove(url)
    }

    public func list(_ directory: URL, keys: [URLResourceKey]) async throws -> [URL] {
        try await access.list(directory, keys: keys)
    }

    public func ensureDirectory(_ directory: URL) async throws {
        try await access.ensureDirectory(directory)
    }

    public func download(_ url: URL, timeout: TimeInterval = 300) async throws {
        try await access.download(url, timeout: timeout)
    }

    // MARK: - Upload confirmation

    /// Confirms that the provider accepted the bytes and, when configured,
    /// releases the local copy.
    ///
    /// - Parameter expectedHash: SHA-256 of the exact bytes that must be visible
    ///   at `url` after confirmation. Metadata files (nodes, manifests, commits)
    ///   are always checked; a nil value is used only for large encrypted data
    ///   whose content is independently verified by `RemoteIntegrityVerifier`
    ///   before a restore reads it.
    public func confirmAndRelease(
        url: URL,
        expectedHash: String? = nil
    ) async throws {
        try await tracker.waitForUpload(url, timeout: uploadTimeout)
        if let expectedHash {
            let actual = try await access.hash(url)
            guard actual == expectedHash else {
                throw CloudStoreError.uploadIncomplete(
                    "\(url.lastPathComponent)：上传后的内容哈希不一致"
                )
            }
        }
        guard let eviction else { return }
        let outcome = await eviction.evictLocalCopies(of: [url])
        observer?(outcome)
    }

    /// File existence is only a hint; callers that need correctness use
    /// `readIfPresent` / strict enumeration instead.
    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func hash(_ url: URL) async throws -> String {
        try await access.hash(url)
    }
}
