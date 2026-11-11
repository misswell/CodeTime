import Foundation
import SharedModels

/// Resolves how a snapshot is stored using remote metadata.
///
/// The rule this type enforces: **a local SQLite row can never decide that a
/// snapshot is legacy**. If this device recorded a v3 publication for the ID, the
/// remote commit marker is required; its absence is an error, not a reason to
/// fall back to Kopia. Only when there is neither a remote commit nor a local v3
/// publication row is the legacy probe consulted.
public struct SnapshotFormatResolver: Sendable {
    public typealias LocalSnapshotProbe = @Sendable (String) async -> SnapshotRecordV3?
    public typealias LegacyProbe = @Sendable (String, UUID) async throws -> ResolvedSnapshot?

    private let masterKey: Data
    private let source: CloudObjectSource
    private let localSnapshotProbe: LocalSnapshotProbe
    private let legacyProbe: LegacyProbe
    private let clock: @Sendable () -> Date

    public init(
        masterKey: Data,
        source: CloudObjectSource,
        localSnapshotProbe: @escaping LocalSnapshotProbe = { _ in nil },
        legacyProbe: @escaping LegacyProbe = { _, _ in nil },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.masterKey = masterKey
        self.source = source
        self.localSnapshotProbe = localSnapshotProbe
        self.legacyProbe = legacyProbe
        self.clock = clock
    }

    public func resolve(snapshotID: String, projectID: UUID) async throws -> ResolvedSnapshot {
        let commit: SnapshotCommit?
        do {
            commit = try await source.readCommit(projectID: projectID, snapshotID: snapshotID)
        } catch {
            // Inaccessibility must never be interpreted as "no v3 commit, so it
            // must be a Kopia snapshot".
            throw SnapshotFormatError.remoteNamespaceInaccessible(
                snapshotID: snapshotID,
                reason: error.localizedDescription
            )
        }

        if let commit {
            guard commit.projectID == projectID else {
                throw SnapshotFormatError.manifestInvalid(
                    snapshotID: snapshotID,
                    reason: "提交标记属于另一个项目"
                )
            }
            guard commit.formatVersion == CloudFormatV3.version else {
                let format: SnapshotFormat = commit.formatVersion == 2 ? .v2 : .unknown
                return ResolvedSnapshot(
                    snapshotID: snapshotID,
                    projectID: projectID,
                    deviceID: commit.deviceID,
                    formatVersion: commit.formatVersion,
                    rootNodeID: nil,
                    createdAt: commit.committedAt,
                    format: format,
                    commitHash: SnapshotCommitHashing.hash(commit),
                    manifestHash: commit.manifestPayloadHash,
                    discoveryStatus: format == .unknown ? .corrupted : .discovered,
                    lastVerifiedAt: nil
                )
            }
            let now = clock()
            let manifest: SnapshotManifest
            do {
                manifest = try await CloudRestoreEngine(masterKey: masterKey, source: source)
                    .loadManifest(projectID: projectID, snapshotID: snapshotID)
            } catch {
                // The commit is authoritative for existence; a bad manifest is
                // reported as corruption and the caller must refuse to restore,
                // not choose a different engine.
                return ResolvedSnapshot(
                    snapshotID: snapshotID,
                    projectID: projectID,
                    deviceID: commit.deviceID,
                    formatVersion: commit.formatVersion,
                    rootNodeID: nil,
                    createdAt: commit.committedAt,
                    format: .v3,
                    commitHash: SnapshotCommitHashing.hash(commit),
                    manifestHash: commit.manifestPayloadHash,
                    discoveryStatus: .corrupted,
                    lastVerifiedAt: nil
                )
            }
            return ResolvedSnapshot(
                snapshotID: snapshotID,
                projectID: projectID,
                deviceID: commit.deviceID,
                formatVersion: commit.formatVersion,
                rootNodeID: manifest.rootNodeID,
                createdAt: commit.committedAt,
                format: .v3,
                commitHash: SnapshotCommitHashing.hash(commit),
                manifestHash: commit.manifestPayloadHash,
                discoveryStatus: .verified,
                lastVerifiedAt: now
            )
        }

        // No remote v3 commit. A local v3 publication row means the version was
        // being published but never committed; it is invisible in the cloud and
        // must not be turned into a legacy snapshot.
        if let local = await localSnapshotProbe(snapshotID) {
            throw SnapshotFormatError.commitMissing(snapshotID: snapshotID)
        }

        if let legacy = try await legacyProbe(snapshotID, projectID) {
            return legacy
        }
        throw SnapshotFormatError.snapshotNotFound(snapshotID: snapshotID)
    }

    /// Refreshes the persistent discovery cache from every remote commit. The
    /// cache is rebuildable; errors from one device are recorded as
    /// `inaccessible` instead of deleting existing rows.
    @discardableResult
    public func refreshRemoteIndex(
        projectID: UUID,
        index: RemoteSnapshotIndexing
    ) async throws -> [RemoteSnapshotRecord] {
        let commits = try await source.commits(projectID: projectID)
        var existingByID: [String: RemoteSnapshotRecord] = [:]
        for record in try await index.remoteSnapshots(projectID: projectID, limit: 5000) {
            existingByID[record.snapshotID] = record
        }
        var records: [RemoteSnapshotRecord] = []
        for commit in commits {
            guard commit.formatVersion == CloudFormatV3.version else { continue }
            let existing = existingByID[commit.snapshotID]
            let commitHash = SnapshotCommitHashing.hash(commit)
            if let existing, existing.commitHash == commitHash,
               existing.discoveryStatus == .verified {
                // The commit has not moved since the manifest was validated. The
                // cache may skip a re-download; the commit read above is still the
                // authority for existence.
                records.append(existing)
                continue
            }
            var status: RemoteSnapshotDiscoveryStatus = .discovered
            var rootNodeID = existing?.rootNodeID ?? ""
            do {
                let manifest = try await CloudRestoreEngine(masterKey: masterKey, source: source)
                    .loadManifest(projectID: projectID, snapshotID: commit.snapshotID)
                rootNodeID = manifest.rootNodeID
                status = .verified
            } catch {
                status = .corrupted
            }
            records.append(RemoteSnapshotRecord(
                projectID: projectID,
                snapshotID: commit.snapshotID,
                deviceID: commit.deviceID,
                formatVersion: commit.formatVersion,
                commitHash: commitHash,
                manifestHash: commit.manifestPayloadHash,
                rootNodeID: rootNodeID,
                createdAt: commit.committedAt,
                discoveryStatus: status,
                lastVerifiedAt: status == .verified ? clock() : existing?.lastVerifiedAt
            ))
        }
        try await index.upsertRemoteSnapshots(records)
        return records
    }
}
