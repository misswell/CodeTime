import Foundation
import SharedModels
import CodeTimeSecurity

public enum CloudObjectStoreV3Error: Error, Sendable, Equatable {
    case objectMissing(String)
    case nodeMissing(String)
    case manifestMissing(String)
    case manifestHashMismatch
    case commitBeforeManifest
    case deviceMismatch(expected: String, found: String)
    case notConfirmed(String)

    public var diagnosticCode: String {
        switch self {
        case .objectMissing, .nodeMissing:
            return "ICLOUD_OBJECT_CORRUPTED"
        case .manifestMissing, .manifestHashMismatch, .commitBeforeManifest:
            return "ICLOUD_MANIFEST_UNREADABLE"
        case .deviceMismatch, .notConfirmed:
            return "ICLOUD_UPLOAD_FAILED"
        }
    }
}

/// Cloud Format v3 object storage.
///
/// Layout (`<root>` = `iCloud Drive/CodeTime/v3`):
///
///     format.json
///     devices/<deviceID>/objects/<ab>/<objectID>
///     devices/<deviceID>/packs/<packID>
///     devices/<deviceID>/nodes/<nodeID>
///     devices/<deviceID>/projects/<projectID>/manifests/<snapshotID>.enc
///     devices/<deviceID>/projects/<projectID>/snapshots/<snapshotID>.commit
///     devices/<deviceID>/tombstones/
///     devices/<deviceID>/recovery-info.enc
///
/// Publish order is enforced here, not by convention: a commit marker can only be
/// written when the manifest it names already exists AND its bytes still hash to
/// the value recorded in the marker. Everything before the commit is idempotent —
/// re-running a backup never rewrites an existing object.
///
/// Object names are `objectID` (HMAC of the content), so nothing in iCloud
/// discloses the plaintext hash or the project path.
public struct CloudObjectStoreV3: Sendable {
    public struct Layout: Sendable {
        public let root: URL
        public let deviceID: String

        public init(root: URL, deviceID: String) {
            self.root = root
            self.deviceID = deviceID
        }

        public var deviceRoot: URL {
            root.appendingPathComponent("devices", isDirectory: true)
                .appendingPathComponent(deviceID, isDirectory: true)
        }

        public var formatFile: URL { root.appendingPathComponent(CloudFormatV3.formatFile) }

        public func objectURL(_ objectID: String) -> URL {
            let prefix = String(objectID.prefix(2))
            return deviceRoot.appendingPathComponent("objects", isDirectory: true)
                .appendingPathComponent(prefix, isDirectory: true)
                .appendingPathComponent(objectID)
        }

        public func packURL(_ packID: String) -> URL {
            deviceRoot.appendingPathComponent("packs", isDirectory: true)
                .appendingPathComponent(packID)
        }

        public func nodeURL(_ nodeID: String) -> URL {
            deviceRoot.appendingPathComponent("nodes", isDirectory: true)
                .appendingPathComponent(nodeID)
        }

        public func projectDir(_ projectID: UUID) -> URL {
            deviceRoot.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectID.uuidString, isDirectory: true)
        }

        public func manifestURL(projectID: UUID, snapshotID: String) -> URL {
            projectDir(projectID).appendingPathComponent("manifests", isDirectory: true)
                .appendingPathComponent("\(snapshotID).enc")
        }

        public func commitURL(projectID: UUID, snapshotID: String) -> URL {
            projectDir(projectID).appendingPathComponent("snapshots", isDirectory: true)
                .appendingPathComponent("\(snapshotID).commit")
        }

        public var tombstonesDir: URL {
            deviceRoot.appendingPathComponent("tombstones", isDirectory: true)
        }

        public var recoveryInfoURL: URL {
            deviceRoot.appendingPathComponent("recovery-info.enc")
        }
    }

    public struct FormatFile: Codable, Sendable, Equatable {
        public var format: Int
        public var createdAt: Date
        public var createdBy: String
        public var deviceName: String
    }

    public let layout: Layout
    private let access: CloudFileAccess
    private let tracker: CloudUploadTracking
    private let uploadTimeout: TimeInterval
    private let eviction: ICloudEvictionManager?
    private let evictionObserver: (@Sendable (EvictionOutcome) -> Void)?
    /// Nodes are plaintext file trees, so they are sealed like manifests: an
    /// iCloud file name alone must never reveal project structure.
    private let masterKey: Data

    public init(
        root: URL,
        deviceID: String,
        masterKey: Data,
        access: CloudFileAccess = LocalFileAccess(),
        tracker: CloudUploadTracking = NoopUploadTracker(),
        uploadTimeout: TimeInterval = 120,
        eviction: ICloudEvictionManager? = nil,
        evictionObserver: (@Sendable (EvictionOutcome) -> Void)? = nil
    ) {
        self.layout = Layout(root: root, deviceID: deviceID)
        self.masterKey = masterKey
        self.access = access
        self.tracker = tracker
        self.uploadTimeout = uploadTimeout
        self.eviction = eviction
        self.evictionObserver = evictionObserver
    }

    static func nodeContext(_ nodeID: String) -> String {
        "v3:node:\(nodeID)"
    }

    /// Confirms the upload and, when configured, releases the local iCloud copy.
    /// A failed eviction is reported to the observer — never silently treated as
    /// released space.
    private func confirmAndRelease(_ url: URL) async throws {
        try await tracker.waitForUpload(url, timeout: uploadTimeout)
        guard let eviction else { return }
        let outcome = await eviction.evictLocalCopies(of: [url])
        evictionObserver?(outcome)
    }

    // MARK: - Format / device

    /// Creates the format file only when absent. An existing format.json is never
    /// rewritten: a transiently empty container must not re-initialise the store.
    @discardableResult
    public func prepare(deviceName: String, createdAt: Date = Date()) async throws -> FormatFile {
        try await access.ensureDirectory(layout.deviceRoot)
        try await access.ensureDirectory(
            layout.deviceRoot.appendingPathComponent("objects", isDirectory: true)
        )
        try await access.ensureDirectory(
            layout.deviceRoot.appendingPathComponent("packs", isDirectory: true)
        )
        try await access.ensureDirectory(
            layout.deviceRoot.appendingPathComponent("nodes", isDirectory: true)
        )
        try await access.ensureDirectory(layout.tombstonesDir)

        if let existing = try? await access.read(layout.formatFile),
           let decoded = try? JSONDecoder().decode(FormatFile.self, from: existing) {
            return decoded
        }
        let created = FormatFile(
            format: CloudFormatV3.version,
            createdAt: createdAt,
            createdBy: deviceName,
            deviceName: deviceName
        )
        let data = try JSONEncoder().encode(created)
        try await access.writeAtomically(data, to: layout.formatFile)
        return created
    }

    public func readFormat() async throws -> FormatFile? {
        guard let data = try? await access.read(layout.formatFile) else { return nil }
        return try JSONDecoder().decode(FormatFile.self, from: data)
    }

    // MARK: - Objects

    public func hasObject(_ objectID: String) async throws -> Bool {
        let parent = layout.objectURL(objectID).deletingLastPathComponent()
        guard let entries = try? await access.list(parent, keys: [.isRegularFileKey]) else {
            return false
        }
        return entries.contains { $0.lastPathComponent == objectID }
    }

    /// Uploads one object and waits for confirmation. Returns true when the object
    /// was actually written (false when it already existed).
    @discardableResult
    public func putObject(_ payload: Data, objectID: String) async throws -> Bool {
        if try await hasObject(objectID) { return false }
        let destination = layout.objectURL(objectID)
        try await access.ensureDirectory(destination.deletingLastPathComponent())
        try await access.writeAtomically(payload, to: destination)
        try await confirmAndRelease(destination)
        return true
    }

    public func readObject(_ objectID: String) async throws -> Data {
        guard let data = try? await access.read(layout.objectURL(objectID)) else {
            throw CloudObjectStoreV3Error.objectMissing(objectID)
        }
        return data
    }

    // MARK: - Nodes

    @discardableResult
    public func putNode(_ node: DirectoryNode) async throws -> Bool {
        let destination = layout.nodeURL(node.nodeID)
        if let data = try? await access.read(destination) {
            // Same identity must mean same bytes; otherwise the tree is not
            // content addressed and we refuse to continue silently. Sealed bytes
            // are randomized per nonce, so compare the decrypted node.
            let plaintext = try? CryptoBox.open(
                data,
                masterKey: masterKey,
                context: Self.nodeContext(node.nodeID)
            )
            let existing = plaintext.flatMap { try? JSONDecoder().decode(DirectoryNode.self, from: $0) }
            if existing == node { return false }
            throw CloudObjectStoreV3Error.nodeMissing(node.nodeID)
        }
        let plaintext = try JSONEncoder().encode(node)
        let sealed = try CryptoBox.seal(
            plaintext,
            masterKey: masterKey,
            context: Self.nodeContext(node.nodeID)
        )
        try await access.ensureDirectory(destination.deletingLastPathComponent())
        try await access.writeAtomically(sealed, to: destination)
        try await tracker.waitForUpload(destination, timeout: uploadTimeout)
        return true
    }

    public func readNode(_ nodeID: String) async throws -> DirectoryNode {
        guard let data = try? await access.read(layout.nodeURL(nodeID)) else {
            throw CloudObjectStoreV3Error.nodeMissing(nodeID)
        }
        let plaintext = try CryptoBox.open(
            data,
            masterKey: masterKey,
            context: Self.nodeContext(nodeID)
        )
        return try JSONDecoder().decode(DirectoryNode.self, from: plaintext)
    }

    public func hasNode(_ nodeID: String) async throws -> Bool {
        (try? await access.read(layout.nodeURL(nodeID))) != nil
    }

    // MARK: - Manifest / Commit

    /// Uploads the encrypted manifest payload and returns its SHA-256, which the
    /// commit marker binds to.
    @discardableResult
    public func putManifest(
        _ payload: Data,
        projectID: UUID,
        snapshotID: String
    ) async throws -> String {
        let destination = layout.manifestURL(projectID: projectID, snapshotID: snapshotID)
        try await access.ensureDirectory(destination.deletingLastPathComponent())
        try await access.writeAtomically(payload, to: destination)
        try await tracker.waitForUpload(destination, timeout: uploadTimeout)
        return CanonicalHashing.sha256Hex(payload)
    }

    public func readManifestPayload(projectID: UUID, snapshotID: String) async throws -> Data {
        guard let data = try? await access.read(
            layout.manifestURL(projectID: projectID, snapshotID: snapshotID)
        ) else {
            throw CloudObjectStoreV3Error.manifestMissing(snapshotID)
        }
        return data
    }

    /// Publishes the snapshot: objects and nodes must already be uploaded.
    /// Refuses when the manifest is missing or its bytes changed since hashing,
    /// so a commit can never point at a payload that is not there.
    public func putCommit(_ commit: SnapshotCommit) async throws {
        guard commit.deviceID == layout.deviceID else {
            throw CloudObjectStoreV3Error.deviceMismatch(expected: layout.deviceID, found: commit.deviceID)
        }
        let manifest = try await readManifestPayload(
            projectID: commit.projectID,
            snapshotID: commit.snapshotID
        )
        guard CanonicalHashing.sha256Hex(manifest) == commit.manifestPayloadHash else {
            throw CloudObjectStoreV3Error.manifestHashMismatch
        }
        let destination = layout.commitURL(projectID: commit.projectID, snapshotID: commit.snapshotID)
        try await access.ensureDirectory(destination.deletingLastPathComponent())
        let data = try JSONEncoder().encode(commit)
        try await access.writeAtomically(data, to: destination)
        try await tracker.waitForUpload(destination, timeout: uploadTimeout)
    }

    /// Commits are the ONLY thing a reader may enumerate to discover versions:
    /// a snapshot that died before its commit does not exist.
    public func commits(projectID: UUID) async throws -> [SnapshotCommit] {
        let directory = layout.projectDir(projectID).appendingPathComponent("snapshots", isDirectory: true)
        guard let entries = try? await access.list(directory, keys: [.isRegularFileKey]) else {
            return []
        }
        var result: [SnapshotCommit] = []
        for entry in entries where entry.pathExtension == "commit" {
            guard let data = try? await access.read(entry) else { continue }
            if let commit = try? JSONDecoder().decode(SnapshotCommit.self, from: data) {
                result.append(commit)
            }
        }
        return result.sorted { $0.committedAt < $1.committedAt }
    }

    public func readCommit(projectID: UUID, snapshotID: String) async throws -> SnapshotCommit? {
        guard let data = try? await access.read(
            layout.commitURL(projectID: projectID, snapshotID: snapshotID)
        ) else { return nil }
        return try JSONDecoder().decode(SnapshotCommit.self, from: data)
    }

    // MARK: - Packs

    @discardableResult
    public func putPack(_ payload: Data, packID: String) async throws -> Bool {
        let destination = layout.packURL(packID)
        if (try? await access.read(destination)) != nil { return false }
        try await access.ensureDirectory(destination.deletingLastPathComponent())
        try await access.writeAtomically(payload, to: destination)
        try await confirmAndRelease(destination)
        return true
    }

    public func readPack(_ packID: String) async throws -> Data {
        guard let data = try? await access.read(layout.packURL(packID)) else {
            throw CloudObjectStoreV3Error.objectMissing(packID)
        }
        return data
    }

    public func hasPack(_ packID: String) async throws -> Bool {
        guard let entries = try? await access.list(
            layout.packURL(packID).deletingLastPathComponent(),
            keys: [.isRegularFileKey]
        ) else {
            return false
        }
        return entries.contains { $0.lastPathComponent == packID }
    }
}

extension CloudObjectStoreV3: CloudObjectSink {}

extension CloudObjectStoreV3: CloudObjectSource {}

extension CloudObjectStoreV3: CloudGarbageCollectible {
    private func fileNames(in directory: URL) async -> [String] {
        guard let entries = try? await access.list(directory, keys: [.isRegularFileKey]) else {
            return []
        }
        return entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent)
    }

    public func projectIDs() async throws -> [UUID] {
        let directory = layout.deviceRoot.appendingPathComponent("projects", isDirectory: true)
        guard let entries = try? await access.list(directory, keys: [.isDirectoryKey]) else {
            return []
        }
        return entries.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    /// Unlike `commits`, a directory that exists but cannot be listed is an error:
    /// GC must never read an I/O failure as "this device has no versions".
    public func strictCommits(projectID: UUID) async throws -> [SnapshotCommit] {
        let directory = layout.projectDir(projectID)
            .appendingPathComponent("snapshots", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let entries: [URL]
        do {
            entries = try await access.list(directory, keys: [.isRegularFileKey])
        } catch {
            throw CloudObjectStoreV3Error.notConfirmed("无法枚举 \(projectID.uuidString) 的提交标记：\(error)")
        }
        var commits: [SnapshotCommit] = []
        for entry in entries where entry.pathExtension == "commit" {
            let data: Data
            do {
                data = try await access.read(entry)
            } catch {
                throw CloudObjectStoreV3Error.notConfirmed("提交标记不可读：\(entry.lastPathComponent)")
            }
            do {
                commits.append(try JSONDecoder().decode(SnapshotCommit.self, from: data))
            } catch {
                throw CloudObjectStoreV3Error.notConfirmed("提交标记损坏：\(entry.lastPathComponent)")
            }
        }
        return commits
    }

    public func standaloneObjectIDs() async throws -> [String] {
        let root = layout.deviceRoot.appendingPathComponent("objects", isDirectory: true)
        guard let prefixes = try? await access.list(root, keys: [.isDirectoryKey]) else {
            return []
        }
        var ids: [String] = []
        for prefix in prefixes {
            ids.append(contentsOf: await fileNames(in: prefix))
        }
        return ids
    }

    public func packIDs() async throws -> [String] {
        await fileNames(in: layout.deviceRoot.appendingPathComponent("packs", isDirectory: true))
    }

    public func nodeIDs() async throws -> [String] {
        await fileNames(in: layout.deviceRoot.appendingPathComponent("nodes", isDirectory: true))
    }

    public func deleteObject(_ objectID: String) async throws {
        try await access.remove(layout.objectURL(objectID))
    }

    public func deletePack(_ packID: String) async throws {
        try await access.remove(layout.packURL(packID))
    }

    public func deleteNode(_ nodeID: String) async throws {
        try await access.remove(layout.nodeURL(nodeID))
    }

    public func deleteManifest(projectID: UUID, snapshotID: String) async throws {
        try await access.remove(layout.manifestURL(projectID: projectID, snapshotID: snapshotID))
    }

    public func deleteCommit(projectID: UUID, snapshotID: String) async throws {
        try await access.remove(layout.commitURL(projectID: projectID, snapshotID: snapshotID))
    }

    public func tombstonePayloads() async throws -> [Data] {
        let names = await fileNames(in: layout.tombstonesDir)
        var payloads: [Data] = []
        for name in names {
            if let data = try? await access.read(layout.tombstonesDir.appendingPathComponent(name)) {
                payloads.append(data)
            }
        }
        return payloads
    }

    public func putTombstone(_ payload: Data, id: String) async throws {
        try await access.ensureDirectory(layout.tombstonesDir)
        try await access.writeAtomically(
            payload,
            to: layout.tombstonesDir.appendingPathComponent("\(id).json")
        )
    }

    public func deleteTombstone(id: String) async throws {
        try await access.remove(layout.tombstonesDir.appendingPathComponent("\(id).json"))
    }
}
