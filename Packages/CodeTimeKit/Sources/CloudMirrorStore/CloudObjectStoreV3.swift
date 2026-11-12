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
    /// Existing bytes are not the object they claim to be. Never overwrite
    /// silently; the caller must report corruption or run an explicit repair.
    case objectCorrupted(String)

    public var diagnosticCode: String {
        switch self {
        case .objectMissing, .nodeMissing:
            return "ICLOUD_OBJECT_CORRUPTED"
        case .manifestMissing, .manifestHashMismatch, .commitBeforeManifest:
            return "ICLOUD_MANIFEST_UNREADABLE"
        case .deviceMismatch, .notConfirmed:
            return "ICLOUD_UPLOAD_FAILED"
        case .objectCorrupted:
            return "ICLOUD_OBJECT_CORRUPTED"
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

        public var deviceRecordURL: URL {
            deviceRoot.appendingPathComponent("device.json")
        }

        /// GC epochs and acks live at the container root, not inside one device
        /// namespace: every device must be able to see the plan it has to confirm.
        public var gcDir: URL { root.appendingPathComponent("gc", isDirectory: true) }
        public var epochsDir: URL { gcDir.appendingPathComponent("epochs", isDirectory: true) }
        public func epochURL(_ id: String) -> URL {
            epochsDir.appendingPathComponent("\(id).json")
        }
        public func acksDir(epochID: String) -> URL {
            epochsDir.appendingPathComponent(epochID, isDirectory: true)
                .appendingPathComponent("acks", isDirectory: true)
        }
        public func ackURL(epochID: String, deviceID: String) -> URL {
            acksDir(epochID: epochID).appendingPathComponent("\(deviceID).json")
        }
        public func hiddenAckURL(epochID: String, deviceID: String) -> URL {
            epochsDir.appendingPathComponent(epochID, isDirectory: true)
                .appendingPathComponent("hidden-acks", isDirectory: true)
                .appendingPathComponent("\(deviceID).json")
        }
        public var barriersDir: URL { gcDir.appendingPathComponent("barriers", isDirectory: true) }
        public func barrierURL(epochID: String, deviceID: String) -> URL {
            barriersDir.appendingPathComponent(epochID, isDirectory: true)
                .appendingPathComponent("\(deviceID).json")
        }
        public func hiddenCommitsDir(epochID: String) -> URL {
            gcDir.appendingPathComponent("hidden", isDirectory: true)
                .appendingPathComponent(epochID, isDirectory: true)
        }
        public func hiddenCommitURL(projectID: UUID, snapshotID: String, epochID: String) -> URL {
            hiddenCommitsDir(epochID: epochID)
                .appendingPathComponent(projectID.uuidString, isDirectory: true)
                .appendingPathComponent("\(snapshotID).commit")
        }
    }

    public struct FormatFile: Codable, Sendable, Equatable {
        public var format: Int
        public var createdAt: Date
        public var createdBy: String
        public var deviceName: String
    }

    public let layout: Layout
    private let cloudAccess: CloudAccessCoordinator
    /// Optional plaintext validation for existing objects. Production passes
    /// `ObjectEncoder.decode`; without it, an existing upload-confirmed object is
    /// reused by identity (never by comparing two random AEAD ciphertexts).
    private let objectValidator: (@Sendable (Data, String) -> Bool)?
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
        evictionObserver: (@Sendable (EvictionOutcome) -> Void)? = nil,
        objectValidator: (@Sendable (Data, String) -> Bool)? = nil,
        leaseManager: LocalCopyLeaseManager = LocalCopyLeaseManager()
    ) {
        self.layout = Layout(root: root, deviceID: deviceID)
        self.masterKey = masterKey
        self.objectValidator = objectValidator
        self.cloudAccess = CloudAccessCoordinator(
            access: access,
            tracker: tracker,
            eviction: eviction,
            uploadTimeout: uploadTimeout,
            evictionObserver: evictionObserver,
            leaseManager: leaseManager,
            expectsUbiquitous: eviction != nil
        )
    }

    static func nodeContext(_ nodeID: String) -> String {
        "v3:node:\(nodeID)"
    }

    /// Confirms the upload and, when configured, releases the local iCloud copy.
    /// A failed eviction is reported to the observer — never silently treated as
    /// released space.
    private func confirmAndRelease(_ url: URL, expectedHash: String? = nil) async throws {
        try await cloudAccess.confirmAndRelease(url: url, expectedHash: expectedHash)
    }

    // MARK: - Format / device

    /// Creates the format file only when absent. An existing format.json is never
    /// rewritten: a transiently empty container must not re-initialise the store.
    @discardableResult
    public func prepare(deviceName: String, createdAt: Date = Date()) async throws -> FormatFile {
        try await cloudAccess.ensureDirectory(layout.deviceRoot)
        try await cloudAccess.ensureDirectory(
            layout.deviceRoot.appendingPathComponent("objects", isDirectory: true)
        )
        try await cloudAccess.ensureDirectory(
            layout.deviceRoot.appendingPathComponent("packs", isDirectory: true)
        )
        try await cloudAccess.ensureDirectory(
            layout.deviceRoot.appendingPathComponent("nodes", isDirectory: true)
        )
        try await cloudAccess.ensureDirectory(layout.tombstonesDir)

        let formatExists = cloudAccess.exists(layout.formatFile)
        if formatExists {
            guard let existing = try? await cloudAccess.read(layout.formatFile) else {
                // Exists but unreadable (network/placeholder/corruption): never
                // re-initialise over it.
                throw CloudObjectStoreV3Error.notConfirmed("format.json 暂时不可读")
            }
            guard let decoded = try? JSONDecoder().decode(FormatFile.self, from: existing) else {
                // A present but unreadable format marker is corruption, not an
                // invitation to re-initialise the store over it.
                throw CloudObjectStoreV3Error.notConfirmed("format.json 不可解析")
            }
            try await registerDeviceIfNeeded(name: deviceName, at: createdAt)
            return decoded
        }
        let created = FormatFile(
            format: CloudFormatV3.version,
            createdAt: createdAt,
            createdBy: deviceName,
            deviceName: deviceName
        )
        let data = try JSONEncoder().encode(created)
        try await cloudAccess.writeAtomically(data, to: layout.formatFile)
        try await registerDeviceIfNeeded(name: deviceName, at: createdAt)
        return created
    }

    public func readFormat() async throws -> FormatFile? {
        guard let data = try? await cloudAccess.read(layout.formatFile) else { return nil }
        return try JSONDecoder().decode(FormatFile.self, from: data)
    }

    // MARK: - Objects

    public func hasObject(_ objectID: String) async throws -> Bool {
        try existsStrict(layout.objectURL(objectID))
    }

    /// Uploads one object and waits for confirmation. Returns true when the object
    /// was actually written (false when it already existed).
    @discardableResult
    public func putObject(_ payload: Data, objectID: String) async throws -> Bool {
        let destination = layout.objectURL(objectID)
        if try existsStrict(destination) {
            // AES-GCM uses a random nonce: the same plaintext/object ID produces
            // different valid ciphertext bytes. Reuse by identity + upload
            // confirmation, never by comparing two ciphertexts.
            _ = try await ensureObjectReady(
                objectID,
                payload: payload,
                storedSize: payload.count
            )
            return false
        }
        try await cloudAccess.ensureDirectory(destination.deletingLastPathComponent())
        try await cloudAccess.writeAtomically(payload, to: destination)
        try await confirmAndRelease(destination)
        return true
    }

    public func readObject(_ objectID: String) async throws -> Data {
        let url = layout.objectURL(objectID)
        guard try existsStrict(url) else {
            throw CloudObjectStoreV3Error.objectMissing(objectID)
        }
        return try await readStrict(url)
    }

    public func readObjectIfPresent(_ objectID: String) async throws -> Data? {
        let url = layout.objectURL(objectID)
        guard try existsStrict(url) else { return nil }
        return try await readStrict(url)
    }

    // MARK: - Nodes

    @discardableResult
    public func putNode(_ node: DirectoryNode) async throws -> Bool {
        let destination = layout.nodeURL(node.nodeID)
        if let data = try await readExistingStrict(destination) {
            // Same identity must mean same bytes; otherwise the tree is not
            // content addressed and we refuse to continue silently. Sealed bytes
            // are randomized per nonce, so compare the decrypted node.
            let plaintext = try? CryptoBox.open(
                data,
                masterKey: masterKey,
                context: Self.nodeContext(node.nodeID)
            )
            let existing = plaintext.flatMap { try? JSONDecoder().decode(DirectoryNode.self, from: $0) }
            if existing == node {
                // An existing node may still be in the provider's upload queue.
                try await cloudAccess.waitForUpload(destination)
                return false
            }
            throw CloudObjectStoreV3Error.nodeMissing(node.nodeID)
        }
        let plaintext = try JSONEncoder().encode(node)
        let sealed = try CryptoBox.seal(
            plaintext,
            masterKey: masterKey,
            context: Self.nodeContext(node.nodeID)
        )
        try await cloudAccess.ensureDirectory(destination.deletingLastPathComponent())
        try await cloudAccess.writeAtomically(sealed, to: destination)
        try await confirmAndRelease(
            destination,
            expectedHash: CanonicalHashing.sha256Hex(sealed)
        )
        return true
    }

    public func readNode(_ nodeID: String) async throws -> DirectoryNode {
        let url = layout.nodeURL(nodeID)
        guard try existsStrict(url) else {
            throw CloudObjectStoreV3Error.nodeMissing(nodeID)
        }
        let data = try await readStrict(url)
        let plaintext: Data
        do {
            plaintext = try CryptoBox.open(
                data,
                masterKey: masterKey,
                context: Self.nodeContext(nodeID)
            )
        } catch {
            throw CloudObjectStoreV3Error.notConfirmed("节点解密失败：\(nodeID)")
        }
        return try JSONDecoder().decode(DirectoryNode.self, from: plaintext)
    }

    public func hasNode(_ nodeID: String) async throws -> Bool {
        try existsStrict(layout.nodeURL(nodeID))
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
        if let existing = try await readExistingStrict(destination) {
            guard existing == payload else {
                // A published manifest is immutable; rewriting it would
                // invalidate the commit hash that points at it.
                throw CloudObjectStoreV3Error.manifestHashMismatch
            }
            // Reuse confirmed bytes; never rewrite an identical manifest.
            try await cloudAccess.waitForUpload(destination)
            return CanonicalHashing.sha256Hex(payload)
        }
        try await cloudAccess.ensureDirectory(destination.deletingLastPathComponent())
        try await cloudAccess.writeAtomically(payload, to: destination)
        try await confirmAndRelease(
            destination,
            expectedHash: CanonicalHashing.sha256Hex(payload)
        )
        return CanonicalHashing.sha256Hex(payload)
    }

    public func readManifestPayload(projectID: UUID, snapshotID: String) async throws -> Data {
        let url = layout.manifestURL(projectID: projectID, snapshotID: snapshotID)
        guard try existsStrict(url) else {
            throw CloudObjectStoreV3Error.manifestMissing(snapshotID)
        }
        return try await readStrict(url)
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
        if let existing = try await readExistingStrict(destination) {
            let decoded = try? JSONDecoder().decode(SnapshotCommit.self, from: existing)
            guard decoded == commit else {
                // A version marker is immutable; a different commit for the same
                // snapshot ID is a conflict, not an update.
                throw CloudObjectStoreV3Error.deviceMismatch(
                    expected: commit.snapshotID,
                    found: "existing commit"
                )
            }
            try await cloudAccess.waitForUpload(destination)
            return
        }
        try await cloudAccess.ensureDirectory(destination.deletingLastPathComponent())
        let data = try JSONEncoder().encode(commit)
        try await cloudAccess.writeAtomically(data, to: destination)
        try await confirmAndRelease(
            destination,
            expectedHash: CanonicalHashing.sha256Hex(data)
        )
    }

    /// Commits are the ONLY thing a reader may enumerate to discover versions:
    /// a snapshot that died before its commit does not exist.
    public func commits(projectID: UUID) async throws -> [SnapshotCommit] {
        let directory = layout.projectDir(projectID).appendingPathComponent("snapshots", isDirectory: true)
        guard let entries = try? await cloudAccess.list(directory, keys: [.isRegularFileKey]) else {
            return []
        }
        var result: [SnapshotCommit] = []
        for entry in entries where entry.pathExtension == "commit" {
            let data = try await readStrict(entry)
            guard let commit = try? JSONDecoder().decode(SnapshotCommit.self, from: data) else {
                throw CloudObjectStoreV3Error.notConfirmed("提交标记损坏：\(entry.lastPathComponent)")
            }
            result.append(commit)
        }
        return result.sorted { $0.committedAt < $1.committedAt }
    }

    public func readCommit(projectID: UUID, snapshotID: String) async throws -> SnapshotCommit? {
        let url = layout.commitURL(projectID: projectID, snapshotID: snapshotID)
        guard try existsStrict(url) else { return nil }
        let data = try await readStrict(url)
        do {
            return try JSONDecoder().decode(SnapshotCommit.self, from: data)
        } catch {
            throw CloudObjectStoreV3Error.notConfirmed("提交标记损坏：\(snapshotID)")
        }
    }

    // MARK: - Packs

    @discardableResult
    public func putPack(_ payload: Data, packID: String) async throws -> Bool {
        let destination = layout.packURL(packID)
        switch try await packState(packID) {
        case .absent, .staged:
            break
        case .uploaded, .verified, .packed:
            // Existence is not enough; the pack must be upload-confirmed and the
            // existing bytes must match before it can be reused.
            let existing = try await readStrict(destination)
            guard existing == payload else {
                throw CloudObjectStoreV3Error.objectMissing(packID)
            }
            return false
        case .uploading:
            do {
                try await cloudAccess.waitForUpload(destination)
            } catch {
                throw CloudObjectLifecycleError.uploadNotConfirmed(
                    objectID: packID,
                    detail: error.localizedDescription
                )
            }
            let existing = try await readStrict(destination)
            guard existing == payload else {
                throw CloudObjectStoreV3Error.objectMissing(packID)
            }
            return false
        case .failed(let detail):
            throw CloudObjectLifecycleError.uploadNotConfirmed(objectID: packID, detail: detail)
        case .inaccessible(let detail):
            throw CloudObjectLifecycleError.stateUnavailable(objectID: packID, detail: detail)
        }
        try await cloudAccess.ensureDirectory(destination.deletingLastPathComponent())
        try await cloudAccess.writeAtomically(payload, to: destination)
        try await confirmAndRelease(destination)
        return true
    }

    public func readPack(_ packID: String) async throws -> Data {
        let url = layout.packURL(packID)
        guard try existsStrict(url) else {
            throw CloudObjectStoreV3Error.objectMissing(packID)
        }
        return try await readStrict(url)
    }

    public func readPackIfPresent(_ packID: String) async throws -> Data? {
        let url = layout.packURL(packID)
        guard try existsStrict(url) else { return nil }
        return try await readStrict(url)
    }

    public func hasPack(_ packID: String) async throws -> Bool {
        try existsStrict(layout.packURL(packID))
    }
}

extension CloudObjectStoreV3: CloudObjectSink {}

extension CloudObjectStoreV3: CloudObjectSource {}

extension CloudObjectStoreV3: CloudGarbageCollectible {
    // MARK: - Strict filesystem enumeration

    /// Distinguishes a genuinely missing path from an unreadable one. `stat`
    /// errors other than ENOENT are surfaced, never treated as absence.
    private func existsStrict(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
                return false
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
                return false
            }
            throw CloudObjectStoreV3Error.notConfirmed("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private func listStrict(_ directory: URL, keys: [URLResourceKey]) async throws -> DirectoryEnumerationResult {
        guard try existsStrict(directory) else { return .notFound }
        do {
            return .exists(try await cloudAccess.list(directory, keys: keys))
        } catch {
            throw CloudObjectStoreV3Error.notConfirmed("无法枚举 \(directory.lastPathComponent)：\(error)")
        }
    }

    private func namesStrict(in directory: URL) async throws -> [String] {
        switch try await listStrict(directory, keys: [.isRegularFileKey]) {
        case .notFound:
            return []
        case .exists(let entries):
            return entries
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .map(\.lastPathComponent)
        }
    }

    private func readStrict(_ url: URL) async throws -> Data {
        do { return try await cloudAccess.readLeased(url) }
        catch { throw CloudObjectStoreV3Error.notConfirmed("无法读取 \(url.lastPathComponent)：\(error)") }
    }

    /// Strict optional read: a genuinely absent file is nil, while an existing
    /// but unreadable file throws. `try? read` would silently turn the second
    /// case into "missing" and permit overwriting immutable metadata.
    private func readExistingStrict(_ url: URL) async throws -> Data? {
        guard try existsStrict(url) else { return nil }
        return try await readStrict(url)
    }

    // MARK: - Device registry

    public func deviceRecordsStrict() async throws -> [GCDeviceRecord] {
        let result = try await listStrict(layout.root.appendingPathComponent("devices", isDirectory: true),
                                          keys: [.isDirectoryKey])
        let entries: [URL]
        switch result {
        case .notFound:
            // A format file without any device directory is an incomplete sync,
            // not an empty repository.
            if try existsStrict(layout.formatFile) {
                throw CloudObjectStoreV3Error.notConfirmed("format.json 存在但 devices 目录缺失")
            }
            return []
        case .exists(let value):
            entries = value
        }
        var records: [GCDeviceRecord] = []
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            let deviceID = entry.lastPathComponent
            let recordURL = entry.appendingPathComponent("device.json")
            if try existsStrict(recordURL) {
                let data = try await readStrict(recordURL)
                do {
                    var record = try JSONDecoder().decode(GCDeviceRecord.self, from: data)
                    if record.deviceID != deviceID {
                        throw CloudObjectStoreV3Error.notConfirmed("设备记录 ID 不匹配：\(deviceID)")
                    }
                    record.lastSeenAt = max(record.lastSeenAt, Date(timeIntervalSince1970: 0))
                    records.append(record)
                } catch let error as CloudObjectStoreV3Error {
                    throw error
                } catch {
                    throw CloudObjectStoreV3Error.notConfirmed("设备记录损坏：\(deviceID)")
                }
            } else {
                // Legacy namespace without a record: conservatively active.
                let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path)
                let created = (attrs?[.creationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                records.append(GCDeviceRecord(
                    deviceID: deviceID,
                    name: deviceID,
                    createdAt: created,
                    lastSeenAt: created,
                    state: .active
                ))
            }
        }
        return records
    }

    public func writeDeviceRecord(_ record: GCDeviceRecord) async throws {
        try await cloudAccess.ensureDirectory(layout.deviceRoot)
        let data = try JSONEncoder.canonical.encode(record)
        try await cloudAccess.writeAtomically(data, to: layout.deviceRecordURL)
    }

    func registerDeviceIfNeeded(name: String, at date: Date) async throws {
        let recordURL = layout.deviceRecordURL
        if try existsStrict(recordURL) {
            let data = try await readStrict(recordURL)
            guard var record = try? JSONDecoder().decode(GCDeviceRecord.self, from: data) else {
                throw CloudObjectStoreV3Error.notConfirmed("device.json 不可解析")
            }
            if record.state == .retired { return }
            if date.timeIntervalSince(record.lastSeenAt) > 3600 {
                record.lastSeenAt = date
                try await writeDeviceRecord(record)
            }
            return
        }
        try await writeDeviceRecord(GCDeviceRecord(
            deviceID: layout.deviceID,
            name: name,
            createdAt: date,
            lastSeenAt: date,
            state: .active
        ))
    }

    // MARK: - GC epochs / acks

    public func writeEpoch(_ epoch: GCEpoch) async throws {
        try await cloudAccess.ensureDirectory(layout.epochsDir)
        let data = try JSONEncoder.canonical.encode(epoch)
        let url = layout.epochURL(epoch.id)
        if try existsStrict(url) {
            let existingData = try await readStrict(url)
            guard let existing = try? JSONDecoder().decode(GCEpoch.self, from: existingData) else {
                throw CloudObjectStoreV3Error.notConfirmed("GC Epoch 不可解析：\(epoch.id)")
            }
            // Only progress fields may change. The frozen plan and the required
            // device set can never be rewritten by a later run.
            guard existing.initiatorDeviceID == epoch.initiatorDeviceID,
                  existing.candidates == epoch.candidates,
                  existing.planDigest == epoch.planDigest,
                  existing.retainedSnapshots == epoch.retainedSnapshots,
                  existing.requiredDeviceIDs == epoch.requiredDeviceIDs,
                  (existing.protocolVersion ?? 1) == (epoch.protocolVersion ?? 1) else {
                throw CloudObjectStoreV3Error.notConfirmed("GC Epoch 计划被改写：\(epoch.id)")
            }
        }
        try await cloudAccess.writeAtomically(data, to: url)
    }

    public func epochsStrict() async throws -> [GCEpoch] {
        let names = try await namesStrict(in: layout.epochsDir)
        var epochs: [GCEpoch] = []
        for name in names where name.hasSuffix(".json") {
            let data = try await readStrict(layout.epochsDir.appendingPathComponent(name))
            do { epochs.append(try JSONDecoder().decode(GCEpoch.self, from: data)) }
            catch { throw CloudObjectStoreV3Error.notConfirmed("GC Epoch 损坏：\(name)") }
        }
        return epochs
    }

    public func writeEpochAck(_ ack: GCEpochAck) async throws {
        let directory = layout.acksDir(epochID: ack.epochID)
        try await cloudAccess.ensureDirectory(directory)
        let url = layout.ackURL(epochID: ack.epochID, deviceID: ack.deviceID)
        if try existsStrict(url) { return }
        let data = try JSONEncoder.canonical.encode(ack)
        try await cloudAccess.writeAtomically(data, to: url)
    }

    public func epochAcks(epochID: String) async throws -> [String: Date] {
        let result = try await listStrict(layout.acksDir(epochID: epochID), keys: [.isRegularFileKey])
        guard case .exists(let entries) = result else { return [:] }
        var acks: [String: Date] = [:]
        for entry in entries where entry.pathExtension == "json" {
            let data = try await readStrict(entry)
            do {
                let ack = try JSONDecoder().decode(GCEpochAck.self, from: data)
                acks[ack.deviceID] = ack.acknowledgedAt
            } catch {
                throw CloudObjectStoreV3Error.notConfirmed("GC 确认记录损坏：\(entry.lastPathComponent)")
            }
        }
        return acks
    }

    // MARK: - Strict namespace enumeration

    public func strictProjectIDs() async throws -> [UUID] {
        let directory = layout.deviceRoot.appendingPathComponent("projects", isDirectory: true)
        let result = try await listStrict(directory, keys: [.isDirectoryKey])
        guard case .exists(let entries) = result else { return [] }
        var ids: [UUID] = []
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            guard let id = UUID(uuidString: entry.lastPathComponent) else {
                throw CloudObjectStoreV3Error.notConfirmed("无法识别的项目目录：\(entry.lastPathComponent)")
            }
            ids.append(id)
        }
        return ids
    }

    public func strictCommits(projectID: UUID) async throws -> [SnapshotCommit] {
        let directory = layout.projectDir(projectID)
            .appendingPathComponent("snapshots", isDirectory: true)
        let result = try await listStrict(directory, keys: [.isRegularFileKey])
        guard case .exists(let entries) = result else {
            // Manifests without commits mean a half-published/sync-incomplete
            // version; that is never "no history".
            let manifests = layout.projectDir(projectID)
                .appendingPathComponent("manifests", isDirectory: true)
            if case .exists(let files) = try await listStrict(manifests, keys: [.isRegularFileKey]),
               files.contains(where: { !$0.lastPathComponent.hasPrefix(".") }) {
                throw CloudObjectStoreV3Error.notConfirmed(
                    "项目 \(projectID.uuidString) 有清单但没有提交标记，可能仍在发布或同步不完整"
                )
            }
            return []
        }
        var commits: [SnapshotCommit] = []
        for entry in entries where entry.pathExtension == "commit" {
            let data = try await readStrict(entry)
            do { commits.append(try JSONDecoder().decode(SnapshotCommit.self, from: data)) }
            catch { throw CloudObjectStoreV3Error.notConfirmed("提交标记损坏：\(entry.lastPathComponent)") }
        }
        return commits
    }

    public func strictStandaloneObjectIDs() async throws -> [String] {
        let root = layout.deviceRoot.appendingPathComponent("objects", isDirectory: true)
        let result = try await listStrict(root, keys: [.isDirectoryKey])
        guard case .exists(let prefixes) = result else { return [] }
        var ids: [String] = []
        for prefix in prefixes where !prefix.lastPathComponent.hasPrefix(".") {
            guard prefix.lastPathComponent.count == 2 else {
                throw CloudObjectStoreV3Error.notConfirmed("无法识别的对象前缀：\(prefix.lastPathComponent)")
            }
            for name in try await namesStrict(in: prefix) {
                guard name.count == 64, name.allSatisfy({ $0.isHexDigit }) else {
                    throw CloudObjectStoreV3Error.notConfirmed("无法识别的对象名：\(name)")
                }
                ids.append(name)
            }
        }
        return ids
    }

    public func strictPackIDs() async throws -> [String] {
        let names = try await namesStrict(in: layout.deviceRoot.appendingPathComponent("packs", isDirectory: true))
        for name in names where !(name.count == 64 && name.allSatisfy({ $0.isHexDigit })) {
            throw CloudObjectStoreV3Error.notConfirmed("无法识别的 Pack 名：\(name)")
        }
        return names
    }

    public func strictNodeIDs() async throws -> [String] {
        let names = try await namesStrict(in: layout.deviceRoot.appendingPathComponent("nodes", isDirectory: true))
        for name in names where !(name.count == 64 && name.allSatisfy({ $0.isHexDigit })) {
            throw CloudObjectStoreV3Error.notConfirmed("无法识别的目录节点名：\(name)")
        }
        return names
    }

    public func strictTombstonePayloads() async throws -> [Data] {
        let names = try await namesStrict(in: layout.tombstonesDir)
        var payloads: [Data] = []
        for name in names {
            payloads.append(try await readStrict(layout.tombstonesDir.appendingPathComponent(name)))
        }
        return payloads
    }

    // MARK: - Deletion / hiding

    public func deleteObject(_ objectID: String) async throws {
        try await removeIfExists(layout.objectURL(objectID))
    }

    public func deletePack(_ packID: String) async throws {
        try await removeIfExists(layout.packURL(packID))
    }

    public func deleteNode(_ nodeID: String) async throws {
        try await removeIfExists(layout.nodeURL(nodeID))
    }

    public func deleteManifest(projectID: UUID, snapshotID: String) async throws {
        try await removeIfExists(layout.manifestURL(projectID: projectID, snapshotID: snapshotID))
    }

    public func deleteCommit(projectID: UUID, snapshotID: String) async throws {
        try await removeIfExists(layout.commitURL(projectID: projectID, snapshotID: snapshotID))
    }

    private func removeIfExists(_ url: URL) async throws {
        guard try existsStrict(url) else { return }
        do { try await cloudAccess.remove(url) }
        catch { throw CloudObjectStoreV3Error.notConfirmed("无法删除 \(url.lastPathComponent)：\(error)") }
    }

    public func putTombstone(_ payload: Data, id: String) async throws {
        try await cloudAccess.ensureDirectory(layout.tombstonesDir)
        try await cloudAccess.writeAtomically(
            payload,
            to: layout.tombstonesDir.appendingPathComponent("\(id).json")
        )
    }

    public func deleteTombstone(id: String) async throws {
        try await removeIfExists(layout.tombstonesDir.appendingPathComponent("\(id).json"))
    }

    public func hideCommit(projectID: UUID, snapshotID: String, epochID: String) async throws {
        let source = layout.commitURL(projectID: projectID, snapshotID: snapshotID)
        let destination = layout.hiddenCommitURL(projectID: projectID, snapshotID: snapshotID, epochID: epochID)
        let sourceExists = try existsStrict(source)
        let hiddenExists = try existsStrict(destination)
        if !sourceExists {
            if hiddenExists { return }
            throw CloudObjectStoreV3Error.notConfirmed("提交标记缺失：\(snapshotID)")
        }
        try await cloudAccess.ensureDirectory(destination.deletingLastPathComponent())
        try await cloudAccess.move(source, to: destination)
    }

    public func hiddenCommitIDs(epochID: String) async throws -> [String] {
        let root = layout.hiddenCommitsDir(epochID: epochID)
        let result = try await listStrict(root, keys: [.isDirectoryKey])
        guard case .exists(let projects) = result else { return [] }
        var ids: [String] = []
        for project in projects where !project.lastPathComponent.hasPrefix(".") {
            for name in try await namesStrict(in: project) where name.hasSuffix(".commit") {
                ids.append(String(name.dropLast(".commit".count)))
            }
        }
        return ids
    }

    public func deleteHiddenCommit(projectID: UUID, snapshotID: String, epochID: String) async throws {
        try await removeIfExists(layout.hiddenCommitURL(
            projectID: projectID, snapshotID: snapshotID, epochID: epochID
        ))
    }
}

// MARK: - Object lifecycle

extension CloudObjectStoreV3 {
    /// Distinguishes a local file name from a cloud-confirmed object.
    public func objectState(_ objectID: String) async throws -> CloudObjectState {
        let url = layout.objectURL(objectID)
        guard try existsStrict(url) else { return .absent }
        switch await cloudAccess.uploadDisposition(url) {
        case .missing:
            return .absent
        case .localDurable, .uploaded:
            return .uploaded(storedSize: fileSize(url))
        case .uploading:
            return .uploading
        case .failed(let detail):
            return .failed(detail)
        case .metadataUnavailable(let detail):
            return .inaccessible(detail)
        }
    }

    /// Ensures an object is durable before another file references it.
    public func ensureObjectReady(
        _ objectID: String,
        payload: Data,
        storedSize: Int
    ) async throws -> StoredObjectLocation {
        let url = layout.objectURL(objectID)
        guard try existsStrict(url) else {
            try await cloudAccess.ensureDirectory(url.deletingLastPathComponent())
            try await cloudAccess.writeAtomically(payload, to: url)
            try await confirmAndRelease(url)
            return StoredObjectLocation(storedSize: payload.count)
        }

        switch await cloudAccess.uploadDisposition(url) {
        case .missing:
            // Raced with deletion after the existence check: write once, then
            // confirm. This is still a single-writer operation under UploadQueue.
            try await cloudAccess.ensureDirectory(url.deletingLastPathComponent())
            try await cloudAccess.writeAtomically(payload, to: url)
            try await confirmAndRelease(url)
            return StoredObjectLocation(storedSize: payload.count)
        case .uploading:
            do {
                try await cloudAccess.waitForUpload(url)
            } catch {
                throw CloudObjectLifecycleError.uploadNotConfirmed(
                    objectID: objectID,
                    detail: error.localizedDescription
                )
            }
        case .failed(let detail):
            throw CloudObjectLifecycleError.uploadNotConfirmed(objectID: objectID, detail: detail)
        case .metadataUnavailable(let detail):
            throw CloudObjectLifecycleError.stateUnavailable(objectID: objectID, detail: detail)
        case .localDurable, .uploaded:
            break
        }

        let existing = try await readStrict(url)
        if let objectValidator, !objectValidator(existing, objectID) {
            throw CloudObjectStoreV3Error.objectCorrupted(objectID)
        }
        return StoredObjectLocation(storedSize: existing.count)
    }

    private func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}

extension CloudObjectStoreV3 {
    public func packState(_ packID: String) async throws -> CloudObjectState {
        let url = layout.packURL(packID)
        guard try existsStrict(url) else { return .absent }
        switch await cloudAccess.uploadDisposition(url) {
        case .missing:
            return .absent
        case .localDurable, .uploaded:
            return .uploaded(storedSize: fileSize(url))
        case .uploading:
            return .uploading
        case .failed(let detail):
            return .failed(detail)
        case .metadataUnavailable(let detail):
            return .inaccessible(detail)
        }
    }
}

// MARK: - GC device barriers / hidden acknowledgements

extension CloudObjectStoreV3 {
    public func writeHiddenEpochAck(epochID: String, deviceID: String, at date: Date) async throws {
        let record: [String: String] = [
            "epochID": epochID,
            "deviceID": deviceID,
            "acknowledgedAt": ISO8601DateFormatter().string(from: date),
        ]
        let data = try JSONEncoder().encode(record)
        let url = layout.hiddenAckURL(epochID: epochID, deviceID: deviceID)
        try await cloudAccess.ensureDirectory(url.deletingLastPathComponent())
        try await cloudAccess.writeAtomically(data, to: url)
        try await confirmAndRelease(url, expectedHash: CanonicalHashing.sha256Hex(data))
    }

    public func hiddenEpochAcks(epochID: String) async throws -> [String: Date] {
        let directory = layout.hiddenAckURL(epochID: epochID, deviceID: "x").deletingLastPathComponent()
        switch try await listStrict(directory, keys: [.isRegularFileKey]) {
        case .notFound:
            return [:]
        case .exists(let entries):
            var result: [String: Date] = [:]
            let decoder = JSONDecoder()
            for entry in entries where entry.pathExtension == "json" {
                let data = try await readStrict(entry)
                let object = try decoder.decode([String: String].self, from: data)
                guard let device = object["deviceID"],
                      let raw = object["acknowledgedAt"],
                      let date = ISO8601DateFormatter().date(from: raw) else { continue }
                result[device] = date
            }
            return result
        }
    }

    public func writeDeviceBarrier(_ barrier: GCDeviceBarrier) async throws {
        let data = try JSONEncoder.canonical.encode(barrier)
        let url = layout.barrierURL(epochID: barrier.epochID, deviceID: barrier.deviceID)
        try await cloudAccess.ensureDirectory(url.deletingLastPathComponent())
        try await cloudAccess.writeAtomically(data, to: url)
        try await confirmAndRelease(url, expectedHash: CanonicalHashing.sha256Hex(data))
    }

    public func deviceBarrier(epochID: String, deviceID: String) async throws -> GCDeviceBarrier? {
        let url = layout.barrierURL(epochID: epochID, deviceID: deviceID)
        guard try existsStrict(url) else { return nil }
        let data = try await readStrict(url)
        do {
            return try JSONDecoder().decode(GCDeviceBarrier.self, from: data)
        } catch {
            throw CloudObjectStoreV3Error.notConfirmed("GC Barrier 损坏：\(epochID)/\(deviceID)")
        }
    }

    public func deviceBarriers(epochID: String) async throws -> [GCDeviceBarrier] {
        let directory = layout.barriersDir.appendingPathComponent(epochID, isDirectory: true)
        switch try await listStrict(directory, keys: [.isRegularFileKey]) {
        case .notFound:
            return []
        case .exists(let entries):
            var barriers: [GCDeviceBarrier] = []
            for entry in entries where entry.pathExtension == "json" {
                let data = try await readStrict(entry)
                do {
                    barriers.append(try JSONDecoder().decode(GCDeviceBarrier.self, from: data))
                } catch {
                    throw CloudObjectStoreV3Error.notConfirmed("GC Barrier 损坏：\(entry.lastPathComponent)")
                }
            }
            return barriers
        }
    }

    public func deleteDeviceBarrier(epochID: String, deviceID: String) async throws {
        let url = layout.barrierURL(epochID: epochID, deviceID: deviceID)
        guard try existsStrict(url) else { return }
        try await cloudAccess.remove(url)
    }

    /// Enumerates every active barrier and returns the snapshots it protects.
    /// Used by the restore entry point; an enumeration failure aborts restore.
    public func blockedSnapshotIDs() async throws -> Set<String> {
        let result = try await listStrict(layout.barriersDir, keys: [.isDirectoryKey])
        guard case .exists(let epochs) = result else { return [] }
        var blocked = Set<String>()
        for epochDir in epochs {
            let entries = try await listStrict(epochDir, keys: [.isRegularFileKey])
            guard case .exists(let files) = entries else { continue }
            for file in files where file.pathExtension == "json" {
                let data = try await readStrict(file)
                let barrier = try JSONDecoder().decode(GCDeviceBarrier.self, from: data)
                if barrier.phase != .released {
                    blocked.formUnion(barrier.candidateSnapshotIDs)
                }
            }
        }
        return blocked
    }
}
