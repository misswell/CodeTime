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
    public enum UploadDisposition: Sendable, Equatable {
        case missing
        /// A plain local mirror file has no iCloud upload step; once written it is
        /// the durable backing store.
        case localDurable
        case uploaded
        case uploading
        case failed(String)
        case metadataUnavailable(String)
    }

    public let access: CloudFileAccess
    public let leaseManager: LocalCopyLeaseManager
    private let tracker: CloudUploadTracking
    private let eviction: ICloudEvictionManager?
    private let uploadTimeout: TimeInterval
    private let observer: (@Sendable (EvictionOutcome) -> Void)?
    /// True for real iCloud containers: a brand-new file can briefly lack
    /// ubiquitous metadata before the provider adopts it. In that window it is
    /// still uploading, not a durable local mirror.
    private let expectsUbiquitous: Bool

    public init(
        access: CloudFileAccess,
        tracker: CloudUploadTracking,
        eviction: ICloudEvictionManager?,
        uploadTimeout: TimeInterval = 120,
        evictionObserver: (@Sendable (EvictionOutcome) -> Void)? = nil,
        leaseManager: LocalCopyLeaseManager = LocalCopyLeaseManager(),
        expectsUbiquitous: Bool = false
    ) {
        self.access = access
        self.leaseManager = leaseManager
        self.tracker = tracker
        self.eviction = eviction
        self.uploadTimeout = uploadTimeout
        self.observer = evictionObserver
        self.expectsUbiquitous = expectsUbiquitous
    }

    // MARK: - Coordinated file operations

    public func read(_ url: URL) async throws -> Data {
        await leaseManager.acquireRead(url)
        do {
            let data = try await access.read(url)
            await leaseManager.releaseRead(url)
            await evictIfSafe(url)
            return data
        } catch {
            await leaseManager.releaseRead(url)
            throw error
        }
    }

    /// Reads under a local-copy lease and evicts only when this was the last
    /// reader. A different process is handled by the eviction manager's provider
    /// checks; an in-process restore cannot lose its file mid-read.
    public func readLeased(_ url: URL) async throws -> Data {
        try await read(url)
    }

    public func evictIfSafe(_ url: URL) async {
        guard let eviction else { return }
        guard await leaseManager.beginEviction(url) else { return }
        let outcome = await eviction.evictLocalCopies(of: [url])
        observer?(outcome)
        await leaseManager.endEviction(url)
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

    /// Waits for provider upload confirmation without evicting.
    public func waitForUpload(_ url: URL) async throws {
        try await tracker.waitForUpload(url, timeout: uploadTimeout)
    }

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
        await leaseManager.acquireWrite(url)
        do {
            try await tracker.waitForUpload(url, timeout: uploadTimeout)
            if let expectedHash {
                let actual = try await access.hash(url)
                guard actual == expectedHash else {
                    throw CloudStoreError.uploadIncomplete(
                        "\(url.lastPathComponent)：上传后的内容哈希不一致"
                    )
                }
            }
            if let eviction {
                let outcome = await eviction.evictLocalCopies(of: [url])
                observer?(outcome)
            }
            await leaseManager.releaseWrite(url)
        } catch {
            await leaseManager.releaseWrite(url)
            throw error
        }
    }

    /// Inspects the provider's upload state without downloading the object. This
    /// is the only cheap way to distinguish "file exists locally" from "iCloud
    /// accepted the bytes".
    public func uploadDisposition(_ url: URL) async -> UploadDisposition {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemUploadingErrorKey,
        ]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                return .missing
            }
            return .metadataUnavailable(error.localizedDescription)
        }
        if values.isUbiquitousItem != true {
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            // In an iCloud-backed namespace a non-ubiquitous regular file is in
            // the adoption window; do not report it as a durable local file.
            return expectsUbiquitous ? .uploading : .localDurable
        }
        if let error = values.ubiquitousItemUploadingError {
            return .failed(error.localizedDescription)
        }
        if values.ubiquitousItemIsUploaded == true {
            return .uploaded
        }
        return .uploading
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
