import Foundation
import SharedModels
import BackupEngine
import CloudMirrorStore

/// Remembers which v3 snapshots were created as migration baselines, so the
/// verification step proves exactly those versions instead of guessing.
public actor MigrationBaselineRegistry {
    private var ids: [String] = []
    public init() {}
    public func record(_ snapshotID: String) { ids.append(snapshotID) }
    public func all() -> [String] { ids }
    public func reset() { ids.removeAll() }
}

/// Read-only compatibility layer for the legacy Kopia world (§14).
///
/// Everything that still touches the v2 repository — listing old versions,
/// publishing the old repository to the v2 cloud format, verifying it, and
/// finally releasing the local copy — is isolated here. The cloud-first engine
/// never calls into this type.
///
/// The safety ordering lives in `BackupMigrationCoordinator`; this type only
/// performs the individual steps and reports facts.
public struct LegacyKopiaCoordinator: Sendable, MigrationProbing {
    private let engine: KopiaBackupEngine
    private let store: CloudStore
    private let repositoryID: UUID
    private let deviceID: UUID
    private let repositoriesRoot: URL
    private let legacyRoot: URL
    private let snapshotIDs: @Sendable () async -> [String]
    private let activeProjects: @Sendable () async -> [Project]
    /// Creates (or resumes) a v3 baseline for one project; the snapshot ID is
    /// recorded so verification later proves the exact same versions.
    private let makeNativeBaseline: @Sendable (Project) async throws -> String?
    private let verifyNativeSnapshot: @Sendable (String) async throws -> Bool
    private let baselines: MigrationBaselineRegistry
    private let makeEngineAtRoot: @Sendable (URL) async throws -> KopiaBackupEngine
    private let clock: @Sendable () -> Date

    public init(
        engine: KopiaBackupEngine,
        store: CloudStore,
        repositoryID: UUID,
        deviceID: UUID,
        repositoriesRoot: URL,
        legacyRoot: URL,
        snapshotIDs: @escaping @Sendable () async -> [String],
        activeProjects: @escaping @Sendable () async -> [Project],
        makeNativeBaseline: @escaping @Sendable (Project) async throws -> String?,
        verifyNativeSnapshot: @escaping @Sendable (String) async throws -> Bool,
        makeEngineAtRoot: @escaping @Sendable (URL) async throws -> KopiaBackupEngine,
        baselines: MigrationBaselineRegistry = MigrationBaselineRegistry(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.store = store
        self.repositoryID = repositoryID
        self.deviceID = deviceID
        self.repositoriesRoot = repositoriesRoot
        self.legacyRoot = legacyRoot
        self.snapshotIDs = snapshotIDs
        self.activeProjects = activeProjects
        self.makeNativeBaseline = makeNativeBaseline
        self.verifyNativeSnapshot = verifyNativeSnapshot
        self.baselines = baselines
        self.makeEngineAtRoot = makeEngineAtRoot
        self.clock = clock
    }

    // MARK: - Legacy access

    /// Old versions are still listed and restored through the Kopia engine; the
    /// v3 switch never deletes them.
    public func listLegacySnapshots(project: Project) async throws -> [Snapshot] {
        try await engine.listSnapshots(project: project)
    }

    public func legacyEngine() -> KopiaBackupEngine { engine }

    /// A read-only legacy engine plus the temporary directory it needs, if any.
    ///
    /// When the local repository is present the existing engine is returned. When
    /// it was released (or never existed on this Mac), the newest Cloud Format v2
    /// generation that contains the old snapshots is downloaded to a temporary
    /// directory and connected with the same password. The caller owns the
    /// temporary directory and must remove it when done.
    public func legacyEngineForRead(
        snapshotIDs: [String] = []
    ) async throws -> (engine: KopiaBackupEngine, temporaryRoot: URL?) {
        if await engine.repositoryState() == .ready {
            return (engine, nil)
        }
        let generations = try await store.listGenerations(repositoryId: repositoryID)
        let candidates = generations.filter {
            $0.state == .published || $0.state == .verified
        }
        guard let generation = snapshotIDs.isEmpty
            ? candidates.max(by: { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) })
            : candidates
                .filter({ generation in
                    snapshotIDs.contains(where: { generation.snapshotIDs.contains($0) })
                })
                .max(by: { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) })
        else {
            throw CodeTimeError.restoreSourceUnavailable("云端没有包含所选旧版本的 v2 备份")
        }

        let fm = FileManager.default
        let temporaryRoot = fm.temporaryDirectory
            .appendingPathComponent("CodeTimeLegacy-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = temporaryRoot
            .appendingPathComponent(repositoryID.uuidString, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        do {
            try fm.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
            try await store.restoreRepository(
                generationId: generation.id,
                destination: repositoryURL
            )
            let temporaryEngine = try await makeEngineAtRoot(temporaryRoot)
            try await temporaryEngine.ensureRepository()
            return (temporaryEngine, temporaryRoot)
        } catch {
            try? fm.removeItem(at: temporaryRoot)
            throw error
        }
    }

    /// Bytes currently occupied by local Kopia repositories. A fresh v3 install
    /// has none; a legacy install reports the real number the user may reclaim.
    public func localRepositoryBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: repositoriesRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - Migration steps

    public func inspectLegacy() async throws -> LegacyRepositoryState {
        let generations = try await store.listGenerations(repositoryId: repositoryID)
        let localBytes = localRepositoryBytes()
        return LegacyRepositoryState(
            localPresent: localBytes > 0,
            localBytes: localBytes,
            cloudV2Present: !generations.isEmpty,
            cloudV2Verified: generations.contains {
                $0.state == .verified || $0.verifiedAt != nil
            }
        )
    }

    /// Publishes every legacy snapshot as one new v2 generation. If an existing
    /// generation already covers the full snapshot set, it is reused instead of
    /// re-uploading the same repository.
    public func publishLegacyToCloud() async throws {
        let ids = await snapshotIDs()
        let generations = try await store.listGenerations(repositoryId: repositoryID)
        if generations.contains(where: { generation in
            (generation.state == .published || generation.state == .verified)
                && Set(ids).isSubset(of: Set(generation.snapshotIDs))
        }) {
            return
        }
        var generation = CloudGeneration(
            repositoryID: repositoryID,
            deviceID: deviceID,
            state: .staging,
            snapshotIDs: ids
        )
        try await store.publish(repositoryId: repositoryID, generation: generation)
        generation.state = .published
        generation.publishedAt = clock()
    }

    /// Verification is against the newest published generation that contains the
    /// complete legacy snapshot set. An older, partial generation never counts.
    public func verifyLegacyCloud() async throws -> Bool {
        let ids = Set(await snapshotIDs())
        let generations = try await store.listGenerations(repositoryId: repositoryID)
        guard let newest = generations
            .filter({ $0.state == .published || $0.state == .verified })
            .filter({ ids.isSubset(of: Set($0.snapshotIDs)) })
            .max(by: { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) })
        else {
            return false
        }
        let result = try await store.verifyGeneration(newest.id)
        return result.outcome == .passed
    }

    /// Creates a v3 baseline for every active project. Any project that cannot
    /// produce a verified baseline blocks the migration as a whole.
    public func createNativeBaseline() async throws -> Bool {
        let projects = await activeProjects()
        guard !projects.isEmpty else { return true }
        for project in projects {
            guard let snapshotID = try await makeNativeBaseline(project) else { return false }
            await baselines.record(snapshotID)
        }
        return true
    }

    /// Proves the new format is restorable by verifying each baseline snapshot's
    /// manifest and every chunk it references.
    public func verifyNativeBaseline() async throws -> Bool {
        let ids = await baselines.all()
        let projects = await activeProjects()
        guard !ids.isEmpty || projects.isEmpty else { return false }
        for id in ids {
            guard try await verifyNativeSnapshot(id) else { return false }
        }
        return true
    }

    /// Releases the local Kopia repository after explicit consent. The data is
    /// moved into `legacy/kopia` first, so a failure leaves a recoverable copy
    /// rather than a half-deleted repository; only a successful move is followed
    /// by removal.
    public func cleanupLegacyLocal() async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: repositoriesRoot.path) else { return }
        let contents = try fm.contentsOfDirectory(atPath: repositoriesRoot.path)
        guard !contents.isEmpty else { return }

        try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let staging = legacyRoot.appendingPathComponent("kopia-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try fm.moveItem(at: repositoriesRoot, to: staging)
        try fm.removeItem(at: staging)
        try fm.createDirectory(at: repositoriesRoot, withIntermediateDirectories: true)
    }
}
