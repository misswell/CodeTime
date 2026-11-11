import Foundation
import SharedModels

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

    public init(
        root: URL,
        deviceID: String,
        access: CloudFileAccess = LocalFileAccess(),
        tracker: CloudUploadTracking = NoopUploadTracker(),
        uploadTimeout: TimeInterval = 120
    ) {
        self.layout = Layout(root: root, deviceID: deviceID)
        self.access = access
        self.tracker = tracker
        self.uploadTimeout = uploadTimeout
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
        try await tracker.waitForUpload(destination, timeout: uploadTimeout)
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
            // content addressed and we refuse to continue silently.
            if data == (try JSONEncoder().encode(node)) { return false }
            throw CloudObjectStoreV3Error.nodeMissing(node.nodeID)
        }
        let data = try JSONEncoder().encode(node)
        try await access.ensureDirectory(destination.deletingLastPathComponent())
        try await access.writeAtomically(data, to: destination)
        try await tracker.waitForUpload(destination, timeout: uploadTimeout)
        return true
    }

    public func readNode(_ nodeID: String) async throws -> DirectoryNode {
        guard let data = try? await access.read(layout.nodeURL(nodeID)) else {
            throw CloudObjectStoreV3Error.nodeMissing(nodeID)
        }
        return try JSONDecoder().decode(DirectoryNode.self, from: data)
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
        try await tracker.waitForUpload(destination, timeout: uploadTimeout)
        return true
    }

    public func readPack(_ packID: String) async throws -> Data {
        guard let data = try? await access.read(layout.packURL(packID)) else {
            throw CloudObjectStoreV3Error.objectMissing(packID)
        }
        return data
    }
}
