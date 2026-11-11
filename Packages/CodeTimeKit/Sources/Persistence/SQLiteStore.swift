import Foundation
import CSQLite
import SharedModels

public enum PersistenceError: LocalizedError, Sendable, Equatable {
    case openFailed(String)
    case statementFailed(String)
    case decodeFailed(String)
    case encodeFailed(String)
    case migrationFailed(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let detail): return "无法打开数据库：\(detail)"
        case .statementFailed(let detail): return "数据库语句失败：\(detail)"
        case .decodeFailed(let detail): return "数据库记录解析失败：\(detail)"
        case .encodeFailed(let detail): return "数据库记录编码失败：\(detail)"
        case .migrationFailed(let detail): return "数据库迁移失败：\(detail)"
        case .conflict(let detail): return "数据库记录已被修改：\(detail)"
        }
    }
}

enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null
}

/// SQLite-backed state store.
///
/// Concurrency rules (§6.1):
/// * Runtime state (status, timestamps, errors, access) is written with field-level
///   updates that re-read the current row inside the actor, so a struct captured
///   before an `await` can never resurrect stale user configuration.
/// * User configuration is written through `updateProjectConfig`, which validates a
///   revision, bumps it, and never touches runtime fields.
public actor SQLiteStore {
    public static let currentSchemaVersion = 4

    public let path: String
    private var db: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(path: String) throws {
        self.path = path
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw PersistenceError.openFailed(message)
        }
        self.db = handle
        do {
            try Self.execRaw(handle, "PRAGMA journal_mode=WAL;")
            try Self.execRaw(handle, "PRAGMA synchronous=NORMAL;")
            try Self.execRaw(handle, "PRAGMA foreign_keys=ON;")
            try Self.execRaw(handle, "PRAGMA busy_timeout=5000;")
            try Self.migrate(handle)
        } catch {
            sqlite3_close(handle)
            self.db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    /// Bounds WAL growth after bulk work (GC, migration, a large backup). The
    /// checkpoint is passive-safe and never blocks readers.
    public func checkpointWAL() throws {
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Migration

    /// Migrations run on the raw handle before the actor is fully initialized, so
    /// every helper here is static. Each step is additive and re-runnable: a crash
    /// between `ALTER TABLE` statements must not wedge the next launch.
    private static func migrate(_ db: OpaquePointer) throws {
        let version = try scalarInt(db, "PRAGMA user_version;")
        if version < 1 {
            try transaction(db) {
                try exec(db, """
                CREATE TABLE IF NOT EXISTS projects (
                    id TEXT PRIMARY KEY,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS policies (
                    project_id TEXT PRIMARY KEY,
                    payload BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS snapshots (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    status TEXT NOT NULL,
                    cloud_state TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_snapshots_project ON snapshots(project_id, created_at DESC);
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state, created_at);
                CREATE TABLE IF NOT EXISTS cloud_generations (
                    id TEXT PRIMARY KEY,
                    repository_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_generations_repo ON cloud_generations(repository_id, created_at DESC);
                CREATE TABLE IF NOT EXISTS cloud_objects (
                    hash TEXT PRIMARY KEY,
                    state TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    last_checked_at REAL,
                    payload BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS restore_jobs (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS verification_results (
                    id TEXT PRIMARY KEY,
                    generation_id TEXT,
                    checked_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS activities (
                    id TEXT PRIMARY KEY,
                    date REAL NOT NULL,
                    kind TEXT NOT NULL,
                    level TEXT NOT NULL,
                    project_id TEXT,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_activities_date ON activities(date DESC);
                CREATE TABLE IF NOT EXISTS repositories (
                    id TEXT PRIMARY KEY,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS kv (
                    key TEXT PRIMARY KEY,
                    payload BLOB NOT NULL
                );
                PRAGMA user_version=1;
                """)
            }
        }

        if version < 2 {
            try transaction(db) {
                // Job scheduling + lease ownership (§6.2, §10.1).
                try addColumnIfMissing(db, table: "jobs", column: "job_type", definition: "TEXT NOT NULL DEFAULT 'backup'")
                try addColumnIfMissing(db, table: "jobs", column: "repository_id", definition: "TEXT")
                try addColumnIfMissing(db, table: "jobs", column: "owner_pid", definition: "INTEGER")
                try addColumnIfMissing(db, table: "jobs", column: "owner_start_time", definition: "REAL")
                try addColumnIfMissing(db, table: "jobs", column: "owner_is_agent", definition: "INTEGER")
                try addColumnIfMissing(db, table: "jobs", column: "heartbeat_at", definition: "REAL")
                try addColumnIfMissing(db, table: "jobs", column: "lease_expires_at", definition: "REAL")
                try addColumnIfMissing(db, table: "jobs", column: "retry_count", definition: "INTEGER NOT NULL DEFAULT 0")
                try addColumnIfMissing(db, table: "jobs", column: "next_retry_at", definition: "REAL")
                try addColumnIfMissing(db, table: "jobs", column: "error_class", definition: "TEXT")
                try exec(db, """
                CREATE INDEX IF NOT EXISTS idx_jobs_lease ON jobs(state, lease_expires_at);
                CREATE INDEX IF NOT EXISTS idx_jobs_retry ON jobs(state, next_retry_at);
                """)

                // Project lifecycle is indexed so soft-deleted rows are never scheduled.
                try addColumnIfMissing(db, table: "projects", column: "lifecycle", definition: "TEXT NOT NULL DEFAULT 'active'")
                try addColumnIfMissing(db, table: "projects", column: "config_revision", definition: "INTEGER NOT NULL DEFAULT 0")
                try addColumnIfMissing(db, table: "snapshots", column: "updated_at", definition: "REAL")

                // Publish timestamp was only kept inside the payload in v1.
                try addColumnIfMissing(db, table: "cloud_generations", column: "published_at", definition: "REAL")

                // Restore state machine (§9).
                try addColumnIfMissing(db, table: "restore_jobs", column: "state", definition: "TEXT NOT NULL DEFAULT 'running'")
                try exec(db, """
                CREATE TABLE IF NOT EXISTS cloud_restore_jobs (
                    id TEXT PRIMARY KEY,
                    repository_id TEXT NOT NULL,
                    generation_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_cloud_restore_resumable ON cloud_restore_jobs(repository_id, generation_id, state);

                CREATE TABLE IF NOT EXISTS gc_journals (
                    id TEXT PRIMARY KEY,
                    repository_id TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_gc_repo ON gc_journals(repository_id, updated_at DESC);

                CREATE TABLE IF NOT EXISTS maintenance_state (
                    task TEXT PRIMARY KEY,
                    next_run_at REAL,
                    payload BLOB NOT NULL
                );

                CREATE TABLE IF NOT EXISTS object_hash_cache (
                    repository_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    verified_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY(repository_id, relative_path)
                );

                CREATE TABLE IF NOT EXISTS cloud_object_index (
                    repository_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY(repository_id, relative_path)
                );

                CREATE TABLE IF NOT EXISTS migration_jobs (
                    id TEXT PRIMARY KEY,
                    state TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                """)
                try exec(db, "PRAGMA user_version=2;")
            }
        }
        if version < 3 {
            // Cloud Format v3 local index (CT-152). Purely additive: v2 tables and
            // the Kopia repository stay untouched, so an upgraded user can still
            // restore every existing snapshot.
            try transaction(db) {
                try exec(db, """
                CREATE TABLE IF NOT EXISTS v3_file_index (
                    project_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    file_identity TEXT,
                    size INTEGER NOT NULL,
                    modified_at REAL,
                    changed_at REAL NOT NULL,
                    file_hash TEXT,
                    last_scanned_at REAL NOT NULL,
                    last_snapshot_id TEXT,
                    payload BLOB NOT NULL,
                    PRIMARY KEY(project_id, relative_path)
                );
                CREATE INDEX IF NOT EXISTS idx_v3_file_snapshot ON v3_file_index(project_id, last_snapshot_id);

                CREATE TABLE IF NOT EXISTS v3_chunk_index (
                    object_id TEXT PRIMARY KEY,
                    plaintext_size INTEGER NOT NULL,
                    stored_size INTEGER NOT NULL,
                    key_version INTEGER NOT NULL,
                    pack_id TEXT,
                    pack_offset INTEGER,
                    verified_at REAL,
                    payload BLOB NOT NULL
                );

                CREATE TABLE IF NOT EXISTS v3_snapshot_index (
                    snapshot_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    parent_snapshot_id TEXT,
                    created_at REAL NOT NULL,
                    root_node_id TEXT NOT NULL,
                    total_files INTEGER NOT NULL,
                    total_bytes INTEGER NOT NULL,
                    upload_state TEXT NOT NULL,
                    commit_state TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_v3_snapshot_project ON v3_snapshot_index(project_id, created_at DESC);

                CREATE TABLE IF NOT EXISTS v3_pending_uploads (
                    task_id TEXT PRIMARY KEY,
                    object_id TEXT NOT NULL,
                    file_size INTEGER NOT NULL,
                    upload_state TEXT NOT NULL,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_v3_pending_state ON v3_pending_uploads(upload_state, created_at);

                CREATE TABLE IF NOT EXISTS v3_cache_index (
                    cache_key TEXT PRIMARY KEY,
                    local_path TEXT NOT NULL,
                    cache_size INTEGER NOT NULL,
                    last_accessed_at REAL NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    payload BLOB NOT NULL
                );

                CREATE TABLE IF NOT EXISTS v3_migration_journal (
                    id TEXT PRIMARY KEY,
                    phase TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                """)
                try exec(db, "PRAGMA user_version=3;")
            }
        }
        if version < 4 {
            // Remote snapshot discovery cache and per-project migration records.
            // Both are additive: deleting them costs a re-discovery/rebaseline
            // check, never any backup data.
            try transaction(db) {
                try exec(db, """
                CREATE TABLE IF NOT EXISTS v3_remote_snapshot_index (
                    snapshot_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    format_version INTEGER NOT NULL,
                    commit_hash TEXT NOT NULL,
                    manifest_hash TEXT NOT NULL,
                    root_node_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    discovery_status TEXT NOT NULL,
                    last_verified_at REAL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_v3_remote_snapshot_project
                    ON v3_remote_snapshot_index(project_id, created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_v3_remote_snapshot_device
                    ON v3_remote_snapshot_index(device_id, project_id);

                CREATE TABLE IF NOT EXISTS v3_migration_records (
                    migration_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    source_repository_id TEXT NOT NULL,
                    baseline_snapshot_id TEXT,
                    state TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    UNIQUE(project_id, source_repository_id)
                );
                CREATE INDEX IF NOT EXISTS idx_v3_migration_project
                    ON v3_migration_records(project_id, updated_at DESC);
                """)
                try exec(db, "PRAGMA user_version=4;")
            }
        }
    }

    private static func columnExists(_ db: OpaquePointer, table: String, column: String) throws -> Bool {
        for row in try query(db, "PRAGMA table_info(\(table));", []) {
            if row.count >= 2, case .text(let name) = row[1], name == column { return true }
        }
        return false
    }

    private static func addColumnIfMissing(_ db: OpaquePointer, table: String, column: String, definition: String) throws {
        guard try !columnExists(db, table: table, column: column) else { return }
        try exec(db, "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    // MARK: - Projects

    /// Full-row write used only when creating a project or restoring from backup.
    /// Runtime updates go through `updateProjectRuntime`; user edits through
    /// `updateProjectConfig`.
    public func upsertProject(_ project: Project) throws {
        try transaction {
            try upsert(
                "INSERT INTO projects(id, created_at, payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                [.text(project.id.uuidString), .double(project.createdAt.timeIntervalSince1970), .blob(try encode(project))]
            )
            try upsert(
                "UPDATE projects SET lifecycle=?, config_revision=? WHERE id=?",
                [.text(project.lifecycle.rawValue), .int(Int64(project.configRevision)), .text(project.id.uuidString)]
            )
        }
    }

    public func projects() throws -> [Project] {
        try projects(includeDeleted: false)
    }

    public func projects(includeDeleted: Bool) throws -> [Project] {
        let all: [Project] = try query("SELECT payload FROM projects ORDER BY created_at ASC", []).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(Project.self, from: data)
        }
        return includeDeleted ? all : all.filter { $0.lifecycle != .deleted }
    }

    public func project(id: UUID) throws -> Project? {
        guard let row = try query("SELECT payload FROM projects WHERE id=?", [.text(id.uuidString)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(Project.self, from: data)
    }

    /// Field-level runtime update. Re-reads the row first so concurrent user edits
    /// (name, path, exclusions, policy, notes) are preserved.
    @discardableResult
    public func updateProjectRuntime(
        id: UUID,
        status: ProjectStatus? = nil,
        lastBackupAt: Date? = nil,
        clearLastBackupAt: Bool = false,
        lastSnapshotID: String? = nil,
        clearLastSnapshotID: Bool = false,
        lastError: String? = nil,
        clearLastError: Bool = false,
        accessState: SecurityAccessState? = nil
    ) throws -> Project? {
        try transactionResult {
            // A project in the deleting/deleted lifecycle must not be resurrected or
            // re-enabled by a late callback from a job that started before deletion.
            guard var project = try project(id: id), project.lifecycle == .active else { return nil }
            if let status { project.status = project.enabled ? status : .disabled }
            if clearLastBackupAt { project.lastBackupAt = nil } else if let lastBackupAt { project.lastBackupAt = lastBackupAt }
            if clearLastSnapshotID { project.lastSnapshotID = nil } else if let lastSnapshotID { project.lastSnapshotID = lastSnapshotID }
            if clearLastError { project.lastError = nil } else if let lastError { project.lastError = lastError }
            if let accessState { project.accessState = accessState }
            try writeProjectPayload(project)
            return project
        }
    }

    /// Compare-and-set edit of user configuration. `expectedRevision == nil` skips
    /// the check. Runtime fields are re-applied from the freshly read row so an
    /// editor can never roll them back.
    @discardableResult
    public func updateProjectConfig(
        id: UUID,
        expectedRevision: Int? = nil,
        mutate: (inout Project) -> Void
    ) throws -> Project {
        try transactionResult {
            guard let current = try project(id: id), current.lifecycle != .deleted else {
                throw PersistenceError.conflict("项目 \(id.uuidString) 不存在或已删除")
            }
            if let expectedRevision, current.configRevision != expectedRevision {
                throw PersistenceError.conflict("项目配置已被其他操作修改（期望 r\(expectedRevision)，当前 r\(current.configRevision)）")
            }
            var updated = current
            mutate(&updated)
            updated.id = current.id
            updated.createdAt = current.createdAt
            updated.status = updated.enabled
                ? (current.status == .disabled ? .idle : current.status)
                : .disabled
            updated.lastBackupAt = current.lastBackupAt
            updated.lastSnapshotID = current.lastSnapshotID
            updated.lastError = current.lastError
            updated.accessState = current.accessState
            updated.lifecycle = current.lifecycle
            updated.configRevision = current.configRevision + 1
            try writeProjectPayload(updated)
            return updated
        }
    }

    @discardableResult
    public func setProjectEnabled(id: UUID, enabled: Bool) throws -> Project {
        try updateProjectConfig(id: id) { project in
            project.enabled = enabled
            if enabled {
                if project.status == .disabled { project.status = .idle }
            } else {
                project.status = .disabled
            }
        }
    }

    public func markProjectDeleting(id: UUID) throws {
        try transaction {
            guard var project = try project(id: id), project.lifecycle != .deleted else { return }
            project.lifecycle = .deleting
            project.enabled = false
            project.status = .disabled
            project.configRevision += 1
            try writeProjectPayload(project)
        }
    }

    public func markProjectDeleted(id: UUID) throws {
        try transaction {
            guard var project = try project(id: id) else { return }
            project.lifecycle = .deleted
            project.enabled = false
            project.status = .disabled
            project.configRevision += 1
            try writeProjectPayload(project)
        }
    }

    private func writeProjectPayload(_ project: Project) throws {
        try upsert(
            "UPDATE projects SET lifecycle=?, config_revision=?, payload=? WHERE id=?",
            [
                .text(project.lifecycle.rawValue),
                .int(Int64(project.configRevision)),
                .blob(try encode(project)),
                .text(project.id.uuidString),
            ]
        )
    }

    public func deleteProject(id: UUID) throws {
        try transaction {
            try upsert("DELETE FROM policies WHERE project_id=?", [.text(id.uuidString)])
            try upsert("DELETE FROM snapshots WHERE project_id=?", [.text(id.uuidString)])
            try upsert("DELETE FROM jobs WHERE project_id=?", [.text(id.uuidString)])
            try upsert("DELETE FROM restore_jobs WHERE project_id=?", [.text(id.uuidString)])
            try upsert("DELETE FROM projects WHERE id=?", [.text(id.uuidString)])
        }
    }

    // MARK: - Policies

    public func upsertPolicy(_ policy: BackupPolicy) throws {
        try upsert(
            "INSERT INTO policies(project_id, payload) VALUES(?,?) ON CONFLICT(project_id) DO UPDATE SET payload=excluded.payload",
            [.text(policy.projectID.uuidString), .blob(try encode(policy))]
        )
    }

    public func policy(projectID: UUID) throws -> BackupPolicy? {
        guard let row = try query("SELECT payload FROM policies WHERE project_id=?", [.text(projectID.uuidString)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(BackupPolicy.self, from: data)
    }

    // MARK: - Snapshots

    public func upsertSnapshot(_ snapshot: Snapshot) throws {
        try upsert("""
        INSERT INTO snapshots(id, project_id, created_at, status, cloud_state, updated_at, payload)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET status=excluded.status, cloud_state=excluded.cloud_state,
            updated_at=excluded.updated_at, payload=excluded.payload
        """, [
            .text(snapshot.id),
            .text(snapshot.projectID.uuidString),
            .double(snapshot.createdAt.timeIntervalSince1970),
            .text(snapshot.status.rawValue),
            .text(snapshot.cloudState.rawValue),
            .double(Date().timeIntervalSince1970),
            .blob(try encode(snapshot)),
        ])
    }

    /// Field-level cloud state update so a background upload cannot clobber an
    /// edited snapshot record.
    @discardableResult
    public func updateSnapshotCloud(id: String, cloudState: CloudSyncState, cloudGenerationID: UUID? = nil) throws -> Snapshot? {
        guard var snapshot = try snapshot(id: id) else { return nil }
        snapshot.cloudState = cloudState
        if let cloudGenerationID { snapshot.cloudGenerationID = cloudGenerationID }
        try upsert(
            "UPDATE snapshots SET cloud_state=?, updated_at=?, payload=? WHERE id=?",
            [
                .text(cloudState.rawValue),
                .double(Date().timeIntervalSince1970),
                .blob(try encode(snapshot)),
                .text(id),
            ]
        )
        return snapshot
    }

    public func snapshots(projectID: UUID? = nil, limit: Int = 500) throws -> [Snapshot] {
        let sql: String
        let params: [SQLValue]
        if let projectID {
            sql = "SELECT payload FROM snapshots WHERE project_id=? ORDER BY created_at DESC LIMIT ?"
            params = [.text(projectID.uuidString), .int(Int64(limit))]
        } else {
            sql = "SELECT payload FROM snapshots ORDER BY created_at DESC LIMIT ?"
            params = [.int(Int64(limit))]
        }
        return try query(sql, params).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(Snapshot.self, from: data)
        }
    }

    public func snapshot(id: String) throws -> Snapshot? {
        guard let row = try query("SELECT payload FROM snapshots WHERE id=?", [.text(id)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(Snapshot.self, from: data)
    }

    public func deleteSnapshot(id: String) throws {
        try upsert("DELETE FROM snapshots WHERE id=?", [.text(id)])
    }

    public func snapshotCount() throws -> Int {
        Int(try scalarInt("SELECT COUNT(*) FROM snapshots;"))
    }

    // MARK: - Jobs

    public func upsertJob(_ job: BackupJob) throws {
        try upsert("""
        INSERT INTO jobs(id, project_id, state, created_at, job_type, repository_id,
                         owner_pid, owner_start_time, owner_is_agent, heartbeat_at, lease_expires_at,
                         retry_count, next_retry_at, error_class, payload)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            state=excluded.state, job_type=excluded.job_type, repository_id=excluded.repository_id,
            owner_pid=excluded.owner_pid, owner_start_time=excluded.owner_start_time,
            owner_is_agent=excluded.owner_is_agent, heartbeat_at=excluded.heartbeat_at,
            lease_expires_at=excluded.lease_expires_at, retry_count=excluded.retry_count,
            next_retry_at=excluded.next_retry_at, error_class=excluded.error_class,
            payload=excluded.payload
        """, try jobParams(job))
    }

    private func jobParams(_ job: BackupJob) throws -> [SQLValue] {
        [
            .text(job.id.uuidString),
            .text(job.projectID.uuidString),
            .text(job.state.rawValue),
            .double(job.createdAt.timeIntervalSince1970),
            .text(job.type.rawValue),
            job.repositoryID.map { .text($0.uuidString) } ?? .null,
            job.lease.map { .int(Int64($0.owner.pid)) } ?? .null,
            job.lease.map { .double($0.owner.startTime) } ?? .null,
            job.lease.map { .int($0.owner.isAgent ? 1 : 0) } ?? .null,
            job.lease.map { .double($0.heartbeatAt.timeIntervalSince1970) } ?? .null,
            job.lease.map { .double($0.leaseExpiresAt.timeIntervalSince1970) } ?? .null,
            .int(Int64(job.retryCount)),
            job.nextRetryAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            job.errorClass.map { .text($0.rawValue) } ?? .null,
            .blob(try encode(job)),
        ]
    }

    public func jobs(state: BackupJobState? = nil, limit: Int = 100) throws -> [BackupJob] {
        let sql: String
        let params: [SQLValue]
        if let state {
            sql = "SELECT payload FROM jobs WHERE state=? ORDER BY created_at DESC LIMIT ?"
            params = [.text(state.rawValue), .int(Int64(limit))]
        } else {
            sql = "SELECT payload FROM jobs ORDER BY created_at DESC LIMIT ?"
            params = [.int(Int64(limit))]
        }
        return try query(sql, params).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(BackupJob.self, from: data)
        }
    }

    public func job(id: UUID) throws -> BackupJob? {
        guard let row = try query("SELECT payload FROM jobs WHERE id=?", [.text(id.uuidString)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(BackupJob.self, from: data)
    }

    public func jobs(projectID: UUID, states: [BackupJobState], limit: Int = 50) throws -> [BackupJob] {
        guard !states.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: states.count).joined(separator: ",")
        let params: [SQLValue] = [.text(projectID.uuidString)]
            + states.map { .text($0.rawValue) }
            + [.int(Int64(limit))]
        return try query("""
        SELECT payload FROM jobs
        WHERE project_id=? AND state IN (\(placeholders))
        ORDER BY created_at DESC LIMIT ?
        """, params).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(BackupJob.self, from: data)
        }
    }

    /// Take the lease only when the job is not terminal and any existing lease is
    /// reclaimable (expired AND owner provably gone).
    public func acquireJobLease(id: UUID, owner: ProcessIdentity, expiresAt: Date) throws -> JobLease? {
        try transactionResult {
            guard var job = try job(id: id), !job.state.isTerminal else { return nil }
            if let existing = job.lease, !existing.isReclaimable() { return nil }
            let lease = JobLease(owner: owner, heartbeatAt: Date(), leaseExpiresAt: expiresAt)
            job.lease = lease
            job.state = .running
            if job.startedAt == nil { job.startedAt = Date() }
            try upsertJob(job)
            return lease
        }
    }

    /// CT-110: recomputes the project's runtime status in ONE write transaction:
    /// lifecycle check, live-job check, newest snapshot, cloud state and the
    /// status write are all inside the same `BEGIN IMMEDIATE`. Two competing
    /// services can never interleave a stale snapshot over a newer one.
    /// Returns the status written (nil when the project is gone/inactive).
    @discardableResult
    public func recomputeProjectRuntimeState(projectID: UUID) throws -> ProjectStatus? {
        try transactionResult { () -> ProjectStatus? in
            guard var project = try project(id: projectID), project.lifecycle == .active else {
                return nil
            }
            let running: [BackupJob] = try query(
                "SELECT payload FROM jobs WHERE project_id=? AND state='running'",
                [.text(projectID.uuidString)]
            ).compactMap { row -> BackupJob? in
                guard case .blob(let data) = row[0] else { return nil }
                return try decode(BackupJob.self, from: data)
            }
            let hasLiveBackup = running.contains {
                $0.type == .backup && $0.lease?.isReclaimable() == false
            }
            let status: ProjectStatus
            if hasLiveBackup {
                status = .backingUp
            } else if let latest = try snapshots(projectID: projectID, limit: 1).first {
                status = ProjectStatus.derived(
                    cloudState: latest.cloudState,
                    snapshotStatus: latest.status
                )
                // CT-131: persist the newest snapshot's cloud state so the UI can
                // distinguish local/uploading/synced/cloud-failed without guessing.
                project.lastCloudState = latest.cloudState
            } else {
                return project.status
            }
            project.status = project.enabled ? status : .disabled
            if status == .synced || status == .localOnly {
                project.lastError = nil
            }
            try writeProjectPayload(project)
            return project.status
        }
    }

    /// The live (running, lease not reclaimable) job for a project, if any.
    /// CT-091: used by the unified status recompute so a live backup pins the
    /// project status and a late upload callback cannot clobber it.
    public func liveRunningJob(projectID: UUID) throws -> BackupJob? {
        let rows = try query(
            "SELECT payload FROM jobs WHERE project_id=? AND state='running'",
            [.text(projectID.uuidString)]
        ).compactMap { row -> BackupJob? in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(BackupJob.self, from: data)
        }
        return rows.first { $0.lease?.isReclaimable() == false }
    }

    /// Atomically claim a backup job for a project: no live job may exist for the
    /// project, and the selected job's lease is taken in the same write transaction.
    public func claimBackupJob(
        projectID: UUID,
        retryJobID: UUID?,
        trigger: BackupTrigger,
        owner: ProcessIdentity,
        expiresAt: Date
    ) throws -> (job: BackupJob, lease: JobLease)? {
        try transactionResult { () -> (job: BackupJob, lease: JobLease)? in
            let running: [BackupJob] = try query(
                "SELECT payload FROM jobs WHERE project_id=? AND state='running'",
                [.text(projectID.uuidString)]
            ).compactMap { row -> BackupJob? in
                guard case .blob(let data) = row[0] else { return nil }
                return try decode(BackupJob.self, from: data)
            }
            for existing in running where existing.id != retryJobID {
                if let lease = existing.lease, !lease.isReclaimable() { return nil }
                if existing.lease == nil,
                   Date().timeIntervalSince(existing.startedAt ?? existing.createdAt) < 60 {
                    return nil
                }
                // Reclaimable: mark the old job interrupted in the same transaction
                // so it doesn't linger as "running" forever.
                var interrupted = existing
                interrupted.state = .failed
                interrupted.finishedAt = Date()
                interrupted.errorMessage = "被新任务回收"
                interrupted.lease = nil
                try upsertJob(interrupted)
            }

            var claimedJob: BackupJob
            if let retryJobID {
                // A retry claim must find a resumable backup-type job. Any other
                // outcome is a hard error, not a fallback to creating a new job.
                guard let existing = try self.job(id: retryJobID),
                      !existing.state.isTerminal,
                      existing.type == .backup,
                      existing.projectID == projectID else {
                    return nil
                }
                if let lease = existing.lease, !lease.isReclaimable() { return nil }
                claimedJob = existing
            } else {
                claimedJob = BackupJob(projectID: projectID, type: .backup, state: .queued, trigger: trigger)
            }
            let lease = JobLease(owner: owner, heartbeatAt: Date(), leaseExpiresAt: expiresAt)
            claimedJob.state = .running
            claimedJob.startedAt = claimedJob.startedAt ?? Date()
            claimedJob.lease = lease
            try upsertJob(claimedJob)
            return (claimedJob, lease)
        }
    }

    /// Owner-checked terminal update in one transaction. A stale worker can never
    /// overwrite the state of a job that another process has since claimed.
    public func finishJob(
        id: UUID,
        state: BackupJobState,
        owner: ProcessIdentity,
        errorMessage: String? = nil
    ) throws {
        try transaction {
            guard var job = try job(id: id), let lease = job.lease,
                  lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return }
            job.state = state
            job.finishedAt = Date()
            job.errorMessage = errorMessage
            job.lease = nil
            if state == .succeeded {
                job.nextRetryAt = nil
                job.errorClass = nil
                job.attempt = 0
            }
            try upsertJob(job)
        }
    }

    /// Owner-checked retry scheduling using the current row, not a stale copy.
    public func scheduleRetry(
        id: UUID,
        owner: ProcessIdentity,
        after delay: TimeInterval,
        errorClass: RetryErrorClass,
        message: String
    ) throws -> Bool {
        try transactionResult {
            guard var job = try job(id: id), let lease = job.lease,
                  lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return false }
            job.state = .queued
            job.retryCount += 1
            job.attempt = job.retryCount + 1
            job.nextRetryAt = Date().addingTimeInterval(delay)
            job.errorClass = errorClass
            job.errorMessage = message
            job.finishedAt = nil
            job.lease = nil
            try upsertJob(job)
            return true
        }
    }

    public func renewJobLease(id: UUID, owner: ProcessIdentity, expiresAt: Date) throws -> Bool {
        try transactionResult {
            guard var job = try job(id: id), let lease = job.lease else { return false }
            guard lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return false }
            job.lease = JobLease(owner: owner, heartbeatAt: Date(), leaseExpiresAt: expiresAt)
            try upsertJob(job)
            return true
        }
    }

    public func releaseJobLease(id: UUID, owner: ProcessIdentity) throws {
        try transaction {
            guard var job = try job(id: id), let lease = job.lease else { return }
            guard lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return }
            job.lease = nil
            try upsertJob(job)
        }
    }

    /// Marks leftovers as `.interrupted`. A running job is only reclaimed when its
    /// lease is provably dead; unleased legacy rows wait out a grace period so a
    /// live v1.0.0-beta.1 process is not killed from under itself.
    @discardableResult
    public func recoverInterruptedJobs(now: Date = Date(), legacyGrace: TimeInterval = 0) throws -> [UUID] {
        var recovered: [UUID] = []
        for var job in try jobs(state: .running, limit: 1000) {
            let reclaimable: Bool
            if let lease = job.lease {
                reclaimable = lease.isReclaimable(now: now)
            } else {
                let started = job.startedAt ?? job.createdAt
                reclaimable = now.timeIntervalSince(started) >= legacyGrace
            }
            guard reclaimable else { continue }
            job.state = .interrupted
            job.finishedAt = now
            job.lease = nil
            job.errorMessage = "进程在任务完成前退出，已标记为中断"
            try upsertJob(job)
            recovered.append(job.id)
        }
        return recovered
    }

    /// Queued jobs that are due now (never retried, or past `nextRetryAt`).
    public func dueRetryJobs(now: Date = Date(), limit: Int = 50) throws -> [BackupJob] {
        try query("""
        SELECT payload FROM jobs
        WHERE state='queued' AND (next_retry_at IS NULL OR next_retry_at <= ?)
        ORDER BY created_at ASC LIMIT ?
        """, [.double(now.timeIntervalSince1970), .int(Int64(limit))]).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(BackupJob.self, from: data)
        }
    }

    public func scheduleRetry(_ job: BackupJob, after delay: TimeInterval, errorClass: RetryErrorClass, message: String) throws {
        var updated = job
        updated.state = .queued
        updated.retryCount += 1
        updated.attempt = updated.retryCount + 1
        updated.nextRetryAt = Date().addingTimeInterval(delay)
        updated.errorClass = errorClass
        updated.errorMessage = message
        updated.finishedAt = nil
        updated.lease = nil
        try upsertJob(updated)
    }

    // MARK: - Cloud generations

    public func upsertGeneration(_ generation: CloudGeneration) throws {
        try upsert("""
        INSERT INTO cloud_generations(id, repository_id, state, created_at, published_at, payload)
        VALUES(?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET state=excluded.state, published_at=excluded.published_at, payload=excluded.payload
        """, [
            .text(generation.id.uuidString),
            .text(generation.repositoryID.uuidString),
            .text(generation.state.rawValue),
            .double(generation.createdAt.timeIntervalSince1970),
            generation.publishedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .blob(try encode(generation)),
        ])
    }

    public func generations(repositoryID: UUID, limit: Int = 200) throws -> [CloudGeneration] {
        try query(
            "SELECT payload FROM cloud_generations WHERE repository_id=? ORDER BY created_at DESC LIMIT ?",
            [.text(repositoryID.uuidString), .int(Int64(limit))]
        ).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(CloudGeneration.self, from: data)
        }
    }

    /// Generations that never reached a terminal published/verified state and must
    /// be resumed or reconciled before a new generation is started (§4.4).
    public func unfinishedGenerations(repositoryID: UUID) throws -> [CloudGeneration] {
        try query("""
        SELECT payload FROM cloud_generations
        WHERE repository_id=? AND state IN ('staging','uploading')
        ORDER BY created_at ASC
        """, [.text(repositoryID.uuidString)]).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(CloudGeneration.self, from: data)
        }
    }

    public func generation(id: UUID) throws -> CloudGeneration? {
        guard let row = try query("SELECT payload FROM cloud_generations WHERE id=?", [.text(id.uuidString)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(CloudGeneration.self, from: data)
    }

    // MARK: - Cloud objects

    public func upsertCloudObject(_ object: CloudObject) throws {
        try upsert("""
        INSERT INTO cloud_objects(hash, state, size, last_checked_at, payload) VALUES(?,?,?,?,?)
        ON CONFLICT(hash) DO UPDATE SET state=excluded.state, last_checked_at=excluded.last_checked_at, payload=excluded.payload
        """, [
            .text(object.hash),
            .text(object.uploadState.rawValue),
            .int(object.size),
            object.lastCheckedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .blob(try encode(object)),
        ])
    }

    public func cloudObjects(limit: Int = 20_000) throws -> [CloudObject] {
        try query("SELECT payload FROM cloud_objects LIMIT ?", [.int(Int64(limit))]).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(CloudObject.self, from: data)
        }
    }

    // MARK: - Restore jobs (local, Kopia)

    public func upsertRestoreJob(_ job: RestoreJob) throws {
        try upsert("""
        INSERT INTO restore_jobs(id, project_id, created_at, state, payload) VALUES(?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET state=excluded.state, payload=excluded.payload
        """, [
            .text(job.id.uuidString),
            .text(job.projectID.uuidString),
            .double(job.createdAt.timeIntervalSince1970),
            .text(job.status.rawValue),
            .blob(try encode(job)),
        ])
    }

    public func restoreJob(id: UUID) throws -> RestoreJob? {
        guard let row = try query("SELECT payload FROM restore_jobs WHERE id=?", [.text(id.uuidString)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(RestoreJob.self, from: data)
    }

    public func restoreJobs(limit: Int = 100) throws -> [RestoreJob] {
        try query("SELECT payload FROM restore_jobs ORDER BY created_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(RestoreJob.self, from: data)
        }
    }

    @discardableResult
    /// CT-112: a running restore job is reclaimed ONLY when its original owner is
    /// provably gone (lease expired AND the process dead) — or, for legacy rows
    /// without a lease, after a grace period. A job owned by a live UI/Agent
    /// process is never touched just because another service bootstrapped.
    public func recoverInterruptedRestoreJobs(
        now: Date = Date(), legacyGrace: TimeInterval = 600
    ) throws -> [UUID] {
        let running = try query("SELECT payload FROM restore_jobs WHERE state='running'", []).compactMap { row -> RestoreJob? in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(RestoreJob.self, from: data)
        }
        var recovered: [UUID] = []
        for var job in running {
            guard job.status == .running else { continue }
            if let lease = job.lease {
                guard lease.isReclaimable(now: now) else { continue }
            } else if now.timeIntervalSince(job.createdAt) < legacyGrace {
                // Legacy unleased row: a peer process may still be running it.
                continue
            }
            job.status = .failed
            job.finishedAt = now
            job.errorMessage = "恢复任务在完成前被中断，请重试"
            job.lease = nil
            try upsertRestoreJob(job)
            recovered.append(job.id)
        }
        return recovered
    }

    // MARK: - Cloud restore jobs (resumable, §9)

    public func upsertCloudRestoreJob(_ job: CloudRestoreJob) throws {
        try upsert("""
        INSERT INTO cloud_restore_jobs(id, repository_id, generation_id, state, updated_at, payload)
        VALUES(?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET state=excluded.state, updated_at=excluded.updated_at, payload=excluded.payload
        """, [
            .text(job.id.uuidString),
            .text(job.repositoryID.uuidString),
            .text(job.generationID.uuidString),
            .text(job.state.rawValue),
            .double(job.updatedAt.timeIntervalSince1970),
            .blob(try encode(job)),
        ])
    }

    public func cloudRestoreJob(id: UUID) throws -> CloudRestoreJob? {
        guard let row = try query("SELECT payload FROM cloud_restore_jobs WHERE id=?", [.text(id.uuidString)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(CloudRestoreJob.self, from: data)
    }

    public func cloudRestoreJobs(limit: Int = 100) throws -> [CloudRestoreJob] {
        try query("SELECT payload FROM cloud_restore_jobs ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(CloudRestoreJob.self, from: data)
        }
    }

    /// Finds a resumable job for the same generation so a restart continues instead
    /// of starting over against a partially staged directory.
    public func resumableCloudRestore(repositoryID: UUID, generationID: UUID) throws -> CloudRestoreJob? {
        let rows = try query("""
        SELECT payload FROM cloud_restore_jobs
        WHERE repository_id=? AND generation_id=?
          AND state IN ('preparing','downloading','verifying','committing','interrupted','failed','retryableFailed')
        ORDER BY updated_at DESC LIMIT 1
        """, [.text(repositoryID.uuidString), .text(generationID.uuidString)])
        guard let row = rows.first, case .blob(let data) = row[0] else { return nil }
        return try decode(CloudRestoreJob.self, from: data)
    }

    public func deleteCloudRestoreJob(id: UUID) throws {
        try upsert("DELETE FROM cloud_restore_jobs WHERE id=?", [.text(id.uuidString)])
    }

    // MARK: Local restore lease (CT-111)

    /// Atomically claims a local restore job. Terminal jobs and jobs whose lease
    /// is still held by a live owner cannot be claimed.
    public func claimRestoreJob(
        id: UUID, owner: ProcessIdentity, expiresAt: Date
    ) throws -> RestoreJob? {
        try transactionResult {
            guard var job = try self.restoreJob(id: id),
                  job.status == .running else { return nil }
            if let existing = job.lease, !existing.isReclaimable() { return nil }
            job.lease = JobLease(owner: owner, heartbeatAt: Date(), leaseExpiresAt: expiresAt)
            try self.upsertRestoreJob(job)
            return job
        }
    }

    public func renewRestoreLease(id: UUID, owner: ProcessIdentity, expiresAt: Date) throws -> Bool {
        try transactionResult {
            guard var job = try self.restoreJob(id: id), let lease = job.lease else { return false }
            guard lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return false }
            job.lease = JobLease(owner: owner, heartbeatAt: Date(), leaseExpiresAt: expiresAt)
            try self.upsertRestoreJob(job)
            return true
        }
    }

    /// Owner-checked write; the row's current lease is preserved.
    @discardableResult
    public func upsertRestoreJob(_ job: RestoreJob, owner: ProcessIdentity) throws -> Bool {
        try transactionResult {
            guard let current = try self.restoreJob(id: job.id), let lease = current.lease else {
                return false
            }
            guard lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return false }
            var payload = job
            payload.lease = lease
            try self.upsertRestoreJob(payload)
            return true
        }
    }

    public func releaseRestoreLease(id: UUID, owner: ProcessIdentity) throws {
        try transaction {
            guard var job = try self.restoreJob(id: id), let lease = job.lease else { return }
            guard lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return }
            job.lease = nil
            try self.upsertRestoreJob(job)
        }
    }

    /// Whether another live restore is already writing to the same target path.
    public func liveRestoreForTarget(_ targetPath: String, excluding id: UUID) throws -> RestoreJob? {
        let running: [RestoreJob] = try query(
            "SELECT payload FROM restore_jobs WHERE state='running'", []
        ).compactMap { row -> RestoreJob? in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(RestoreJob.self, from: data)
        }
        let standardized = URL(fileURLWithPath: targetPath).standardizedFileURL.path
        return running.first {
            $0.id != id
                && URL(fileURLWithPath: $0.targetPath).standardizedFileURL.path == standardized
                && $0.lease?.isReclaimable() == false
        }
    }

    // MARK: Cloud restore lease (CT-087, Goal §3.2)

    /// Atomically takes the exclusive lease on a cloud restore job. Refuses
    /// terminal jobs and jobs whose lease is still held by a live owner. Two
    /// processes racing on the same job produce exactly one winner.
    public func claimCloudRestoreJob(
        id: UUID, owner: ProcessIdentity, expiresAt: Date
    ) throws -> CloudRestoreJob? {
        try transactionResult {
            guard var job = try self.cloudRestoreJob(id: id), !job.state.isTerminal else { return nil }
            if let existing = job.lease, !existing.isReclaimable() { return nil }
            job.lease = JobLease(owner: owner, heartbeatAt: Date(), leaseExpiresAt: expiresAt)
            job.updatedAt = Date()
            try self.upsertCloudRestoreJob(job)
            return job
        }
    }

    /// Heartbeat: renews the lease only for the current owner.
    public func renewCloudRestoreLease(
        id: UUID, owner: ProcessIdentity, expiresAt: Date
    ) throws -> Bool {
        try transactionResult {
            guard var job = try self.cloudRestoreJob(id: id), let lease = job.lease else { return false }
            guard lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return false }
            job.lease = JobLease(owner: owner, heartbeatAt: Date(), leaseExpiresAt: expiresAt)
            try self.upsertCloudRestoreJob(job)
            return true
        }
    }

    /// Owner-checked write. A stale worker whose lease was taken over can no
    /// longer persist progress or state. The row's CURRENT lease is preserved in
    /// the written payload — callers pass possibly-stale copies (lease absent or
    /// outdated), and only the store may touch lease state. Returns false when
    /// the write was refused.
    @discardableResult
    public func upsertCloudRestoreJob(_ job: CloudRestoreJob, owner: ProcessIdentity) throws -> Bool {
        try transactionResult {
            guard let current = try self.cloudRestoreJob(id: job.id), let lease = current.lease else {
                return false
            }
            guard lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return false }
            var payload = job
            payload.lease = lease
            try self.upsertCloudRestoreJob(payload)
            return true
        }
    }

    /// Owner-checked lease release (completion / cancellation).
    public func releaseCloudRestoreLease(id: UUID, owner: ProcessIdentity) throws {
        try transaction {
            guard var job = try self.cloudRestoreJob(id: id), let lease = job.lease else { return }
            guard lease.owner.pid == owner.pid,
                  abs(lease.owner.startTime - owner.startTime) < 0.001 else { return }
            job.lease = nil
            try self.upsertCloudRestoreJob(job)
        }
    }

    // MARK: - Garbage collection journals (§4.5)

    public func upsertGCJournal(_ journal: GCJournal) throws {
        try upsert("""
        INSERT INTO gc_journals(id, repository_id, phase, updated_at, payload) VALUES(?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET phase=excluded.phase, updated_at=excluded.updated_at, payload=excluded.payload
        """, [
            .text(journal.id.uuidString),
            .text(journal.repositoryID.uuidString),
            .text(journal.phase.rawValue),
            .double(journal.updatedAt.timeIntervalSince1970),
            .blob(try encode(journal)),
        ])
    }

    public func gcJournals(repositoryID: UUID? = nil, limit: Int = 50) throws -> [GCJournal] {
        let sql: String
        let params: [SQLValue]
        if let repositoryID {
            sql = "SELECT payload FROM gc_journals WHERE repository_id=? ORDER BY updated_at DESC LIMIT ?"
            params = [.text(repositoryID.uuidString), .int(Int64(limit))]
        } else {
            sql = "SELECT payload FROM gc_journals ORDER BY updated_at DESC LIMIT ?"
            params = [.int(Int64(limit))]
        }
        return try query(sql, params).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(GCJournal.self, from: data)
        }
    }

    /// An unfinished journal must block new cleanup and drive recovery on launch.
    public func latestUnfinishedGCJournal(repositoryID: UUID) throws -> GCJournal? {
        let rows = try query("""
        SELECT payload FROM gc_journals
        WHERE repository_id=? AND phase != 'completed'
        ORDER BY updated_at DESC LIMIT 1
        """, [.text(repositoryID.uuidString)])
        guard let row = rows.first, case .blob(let data) = row[0] else { return nil }
        return try decode(GCJournal.self, from: data)
    }

    public func deleteGCJournal(id: UUID) throws {
        try upsert("DELETE FROM gc_journals WHERE id=?", [.text(id.uuidString)])
    }

    // MARK: - Verification

    public func insertVerification(_ result: VerificationResult) throws {
        try upsert(
            "INSERT INTO verification_results(id, generation_id, checked_at, payload) VALUES(?,?,?,?)",
            [
                .text(result.id.uuidString),
                result.generationID.map { .text($0.uuidString) } ?? .null,
                .double(result.checkedAt.timeIntervalSince1970),
                .blob(try encode(result)),
            ]
        )
    }

    public func verifications(limit: Int = 100) throws -> [VerificationResult] {
        try query("SELECT payload FROM verification_results ORDER BY checked_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(VerificationResult.self, from: data)
        }
    }

    public func latestVerification(generationID: UUID) throws -> VerificationResult? {
        let rows = try query("""
        SELECT payload FROM verification_results WHERE generation_id=?
        ORDER BY checked_at DESC LIMIT 1
        """, [.text(generationID.uuidString)])
        guard let row = rows.first, case .blob(let data) = row[0] else { return nil }
        return try decode(VerificationResult.self, from: data)
    }

    public func latestVerification(projectID: UUID) throws -> VerificationResult? {
        let results: [VerificationResult] = try query(
            "SELECT payload FROM verification_results ORDER BY checked_at DESC LIMIT 200", []
        ).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(VerificationResult.self, from: data)
        }
        return results.first { $0.projectID == projectID }
    }

    // MARK: - Activity

    public func appendActivity(_ event: ActivityEvent) throws {
        try upsert(
            "INSERT INTO activities(id, date, kind, level, project_id, payload) VALUES(?,?,?,?,?,?)",
            [
                .text(event.id.uuidString),
                .double(event.date.timeIntervalSince1970),
                .text(event.kind.rawValue),
                .text(event.level.rawValue),
                event.projectID.map { .text($0.uuidString) } ?? .null,
                .blob(try encode(event)),
            ]
        )
    }

    public func activities(limit: Int = 200, projectID: UUID? = nil) throws -> [ActivityEvent] {
        let sql: String
        let params: [SQLValue]
        if let projectID {
            sql = "SELECT payload FROM activities WHERE project_id=? ORDER BY date DESC LIMIT ?"
            params = [.text(projectID.uuidString), .int(Int64(limit))]
        } else {
            sql = "SELECT payload FROM activities ORDER BY date DESC LIMIT ?"
            params = [.int(Int64(limit))]
        }
        return try query(sql, params).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(ActivityEvent.self, from: data)
        }
    }

    public func trimActivities(keep: Int = 5000) throws {
        try upsert("""
        DELETE FROM activities WHERE id NOT IN (
            SELECT id FROM activities ORDER BY date DESC LIMIT ?
        )
        """, [.int(Int64(keep))])
    }

    // MARK: - Repositories

    public func upsertRepository(_ repository: RepositoryRecord) throws {
        try upsert(
            "INSERT INTO repositories(id, created_at, payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
            [.text(repository.id.uuidString), .double(repository.createdAt.timeIntervalSince1970), .blob(try encode(repository))]
        )
    }

    public func repositories() throws -> [RepositoryRecord] {
        try query("SELECT payload FROM repositories ORDER BY created_at ASC", []).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(RepositoryRecord.self, from: data)
        }
    }

    // MARK: - Maintenance state (§10.3)

    public func maintenanceState(_ task: CodeTimeJobType) throws -> MaintenanceTaskState? {
        guard let row = try query("SELECT payload FROM maintenance_state WHERE task=?", [.text(task.rawValue)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(MaintenanceTaskState.self, from: data)
    }

    public func saveMaintenanceState(_ state: MaintenanceTaskState) throws {
        try upsert("""
        INSERT INTO maintenance_state(task, next_run_at, payload) VALUES(?,?,?)
        ON CONFLICT(task) DO UPDATE SET next_run_at=excluded.next_run_at, payload=excluded.payload
        """, [
            .text(state.task.rawValue),
            state.nextRunAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            .blob(try encode(state)),
        ])
    }

    public func allMaintenanceStates() throws -> [MaintenanceTaskState] {
        try query("SELECT payload FROM maintenance_state", []).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(MaintenanceTaskState.self, from: data)
        }
    }

    // MARK: - Object hash cache (§3.3)

    /// Cache entries are only trusted when file identity, size and modification date
    /// all match; publishes still re-hash before committing.
    public func hashCacheEntry(repositoryID: UUID, relativePath: String) throws -> ObjectHashCacheEntry? {
        let rows = try query(
            "SELECT payload FROM object_hash_cache WHERE repository_id=? AND relative_path=?",
            [.text(repositoryID.uuidString), .text(relativePath)]
        )
        guard let row = rows.first, case .blob(let data) = row[0] else { return nil }
        return try decode(ObjectHashCacheEntry.self, from: data)
    }

    public func saveHashCacheEntry(_ entry: ObjectHashCacheEntry, repositoryID: UUID) throws {
        try upsert("""
        INSERT INTO object_hash_cache(repository_id, relative_path, verified_at, payload) VALUES(?,?,?,?)
        ON CONFLICT(repository_id, relative_path) DO UPDATE SET verified_at=excluded.verified_at, payload=excluded.payload
        """, [
            .text(repositoryID.uuidString),
            .text(entry.relativePath),
            .double(entry.verifiedAt.timeIntervalSince1970),
            .blob(try encode(entry)),
        ])
    }

    public func saveHashCacheEntries(_ entries: [ObjectHashCacheEntry], repositoryID: UUID) throws {
        guard !entries.isEmpty else { return }
        try transaction {
            for entry in entries {
                try saveHashCacheEntry(entry, repositoryID: repositoryID)
            }
        }
    }

    public func pruneObjectHashCache(repositoryID: UUID, keepPaths: Set<String>) throws {
        guard !keepPaths.isEmpty else {
            try upsert("DELETE FROM object_hash_cache WHERE repository_id=?", [.text(repositoryID.uuidString)])
            return
        }
        let existing = try query(
            "SELECT relative_path FROM object_hash_cache WHERE repository_id=?",
            [.text(repositoryID.uuidString)]
        ).compactMap { row -> String? in
            guard case .text(let value) = row[0] else { return nil }
            return value
        }
        try transaction {
            for path in existing where !keepPaths.contains(path) {
                try upsert(
                    "DELETE FROM object_hash_cache WHERE repository_id=? AND relative_path=?",
                    [.text(repositoryID.uuidString), .text(path)]
                )
            }
        }
    }

    // MARK: - Cloud object index (§3.8)

    public func saveObjectIndexEntry(_ entry: CloudObjectIndexEntry, repositoryID: UUID) throws {
        try upsert("""
        INSERT INTO cloud_object_index(repository_id, relative_path, payload) VALUES(?,?,?)
        ON CONFLICT(repository_id, relative_path) DO UPDATE SET payload=excluded.payload
        """, [
            .text(repositoryID.uuidString),
            .text(entry.relativePath),
            .blob(try encode(entry)),
        ])
    }

    public func saveObjectIndexEntries(_ entries: [CloudObjectIndexEntry], repositoryID: UUID) throws {
        guard !entries.isEmpty else { return }
        try transaction {
            for entry in entries {
                try saveObjectIndexEntry(entry, repositoryID: repositoryID)
            }
        }
    }

    public func objectIndex(repositoryID: UUID) throws -> [CloudObjectIndexEntry] {
        try query(
            "SELECT payload FROM cloud_object_index WHERE repository_id=?",
            [.text(repositoryID.uuidString)]
        ).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(CloudObjectIndexEntry.self, from: data)
        }
    }

    // MARK: - Migration jobs (§8.1)

    public func upsertMigrationJob(_ job: MigrationJob) throws {
        try upsert("""
        INSERT INTO migration_jobs(id, state, updated_at, payload) VALUES(?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET state=excluded.state, updated_at=excluded.updated_at, payload=excluded.payload
        """, [
            .text(job.id.uuidString),
            .text(job.state.rawValue),
            .double(job.updatedAt.timeIntervalSince1970),
            .blob(try encode(job)),
        ])
    }

    public func migrationJobs(limit: Int = 20) throws -> [MigrationJob] {
        try query("SELECT payload FROM migration_jobs ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(MigrationJob.self, from: data)
        }
    }

    public func unfinishedMigrationJob() throws -> MigrationJob? {
        let rows = try query("""
        SELECT payload FROM migration_jobs
        WHERE state NOT IN ('completed','failed','notNeeded')
        ORDER BY updated_at DESC LIMIT 1
        """, [])
        guard let row = rows.first, case .blob(let data) = row[0] else { return nil }
        return try decode(MigrationJob.self, from: data)
    }

    // MARK: - Settings with CAS (§6.3)

    public func saveSettingsCAS(_ settings: AppSettings, expectedRevision: Int?) throws -> AppSettings {
        try transactionResult {
            let stored = try codable(AppSettings.self, forKey: Keys.settings)
            if let expectedRevision, let stored, stored.configRevision != expectedRevision {
                throw PersistenceError.conflict("设置已被其他进程修改（期望 r\(expectedRevision)，当前 r\(stored.configRevision)）")
            }
            var updated = settings
            updated.configRevision = (stored?.configRevision ?? 0) + 1
            try setCodable(updated, forKey: Keys.settings)
            return updated
        }
    }

    public func settingsRevision() throws -> Int {
        try codable(AppSettings.self, forKey: Keys.settings)?.configRevision ?? 0
    }

    // MARK: - Key-value

    public func setCodable<T: Encodable>(_ value: T, forKey key: String) throws {
        try upsert(
            "INSERT INTO kv(key, payload) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload",
            [.text(key), .blob(try encode(value))]
        )
    }

    public func codable<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let row = try query("SELECT payload FROM kv WHERE key=?", [.text(key)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(type, from: data)
    }

    public func removeValue(forKey key: String) throws {
        try upsert("DELETE FROM kv WHERE key=?", [.text(key)])
    }

    // MARK: - SQL helpers

    func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw PersistenceError.encodeFailed(String(describing: error)) }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw PersistenceError.decodeFailed(String(describing: error)) }
    }

    func scalarInt(_ sql: String) throws -> Int {
        guard let row = try query(sql, []).first, case .int(let value) = row[0] else { return 0 }
        return Int(value)
    }

    func transaction(_ body: () throws -> Void) throws {
        try transactionResult(body)
    }

    /// Read-check-write operations must hold a write transaction for their whole
    /// duration. The actor only serializes this process; UI and Agent use separate
    /// SQLite connections and would otherwise both pass a stale check.
    func transactionResult<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func exec(_ sql: String) throws {
        guard let db else { throw PersistenceError.statementFailed("database closed") }
        try Self.execRaw(db, sql, errorCase: .statementFailed)
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        try execRaw(db, sql, errorCase: .migrationFailed)
    }

    private enum RawErrorCase { case openFailed, statementFailed, migrationFailed }

    private static func execRaw(_ db: OpaquePointer, _ sql: String, errorCase: RawErrorCase = .openFailed) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            switch errorCase {
            case .openFailed: throw PersistenceError.openFailed(message)
            case .statementFailed: throw PersistenceError.statementFailed(message)
            case .migrationFailed: throw PersistenceError.migrationFailed(message)
            }
        }
    }

    static func transaction(_ db: OpaquePointer, _ body: () throws -> Void) throws {
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            try body()
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        guard let row = try query(db, sql, []).first, case .int(let value) = row[0] else { return 0 }
        return Int(value)
    }

    func upsert(_ sql: String, _ params: [SQLValue]) throws {
        _ = try query(sql, params)
    }

    @discardableResult
    func query(_ sql: String, _ params: [SQLValue]) throws -> [[SQLValue]] {
        guard let db else { throw PersistenceError.statementFailed("database closed") }
        return try Self.query(db, sql, params)
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ params: [SQLValue]) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PersistenceError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in params.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case .int(let number):
                sqlite3_bind_int64(statement, position, number)
            case .double(let number):
                sqlite3_bind_double(statement, position, number)
            case .blob(let data):
                data.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(statement, position, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }

        var result: [[SQLValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw PersistenceError.statementFailed(String(cString: sqlite3_errmsg(db)))
            }
            let count = sqlite3_column_count(statement)
            var row: [SQLValue] = []
            row.reserveCapacity(Int(count))
            for index in 0..<count {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT:
                    row.append(.double(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    if let cString = sqlite3_column_text(statement, index) {
                        row.append(.text(String(cString: cString)))
                    } else {
                        row.append(.null)
                    }
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(statement, index)
                    let length = sqlite3_column_bytes(statement, index)
                    if let bytes, length > 0 {
                        row.append(.blob(Data(bytes: bytes, count: Int(length))))
                    } else {
                        row.append(.blob(Data()))
                    }
                default:
                    row.append(.null)
                }
            }
            result.append(row)
        }
        return result
    }
}

private enum StoreKeys {
    static let settings = "app.settings"
    static let device = "device.identity"
    static let repository = "repository.record"
    static let lastVerification = "verification.lastRun"
    static let lastCleanup = "cleanup.lastRun"
    static let cloudRecoveryAttempted = "cloud.recovery.attempted"
}

private typealias Keys = StoreKeys

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
