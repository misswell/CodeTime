import Foundation
import CSQLite
import SharedModels

public enum PersistenceError: LocalizedError, Sendable {
    case openFailed(String)
    case statementFailed(String)
    case decodeFailed(String)
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let detail): return "无法打开数据库：\(detail)"
        case .statementFailed(let detail): return "数据库语句失败：\(detail)"
        case .decodeFailed(let detail): return "数据库记录解析失败：\(detail)"
        case .encodeFailed(let detail): return "数据库记录编码失败：\(detail)"
        }
    }
}

private enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null
}

public actor SQLiteStore {
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
        try Self.execRaw(handle, "PRAGMA journal_mode=WAL;")
        try Self.execRaw(handle, "PRAGMA synchronous=NORMAL;")
        try Self.execRaw(handle, "PRAGMA foreign_keys=ON;")
        try Self.execRaw(handle, "PRAGMA busy_timeout=5000;")
        try migrate()
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

    // MARK: - Migration

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version;")
        if version < 1 {
            try transaction {
                try exec("""
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
    }

    // MARK: - Projects

    public func upsertProject(_ project: Project) throws {
        try upsert(
            "INSERT INTO projects(id, created_at, payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
            [.text(project.id.uuidString), .double(project.createdAt.timeIntervalSince1970), .blob(try encode(project))]
        )
    }

    public func projects() throws -> [Project] {
        try query("SELECT payload FROM projects ORDER BY created_at ASC", []).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(Project.self, from: data)
        }
    }

    public func project(id: UUID) throws -> Project? {
        guard let row = try query("SELECT payload FROM projects WHERE id=?", [.text(id.uuidString)]).first,
              case .blob(let data) = row[0] else { return nil }
        return try decode(Project.self, from: data)
    }

    public func deleteProject(id: UUID) throws {
        try transaction {
            try upsert("DELETE FROM policies WHERE project_id=?", [.text(id.uuidString)])
            try upsert("DELETE FROM snapshots WHERE project_id=?", [.text(id.uuidString)])
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
        INSERT INTO snapshots(id, project_id, created_at, status, cloud_state, payload)
        VALUES(?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET status=excluded.status, cloud_state=excluded.cloud_state, payload=excluded.payload
        """, [
            .text(snapshot.id),
            .text(snapshot.projectID.uuidString),
            .double(snapshot.createdAt.timeIntervalSince1970),
            .text(snapshot.status.rawValue),
            .text(snapshot.cloudState.rawValue),
            .blob(try encode(snapshot)),
        ])
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
        INSERT INTO jobs(id, project_id, state, created_at, payload) VALUES(?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET state=excluded.state, payload=excluded.payload
        """, [
            .text(job.id.uuidString),
            .text(job.projectID.uuidString),
            .text(job.state.rawValue),
            .double(job.createdAt.timeIntervalSince1970),
            .blob(try encode(job)),
        ])
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

    public func recoverInterruptedJobs() throws -> Int {
        let running = try jobs(state: .running, limit: 1000)
        for var job in running {
            job.state = .failed
            job.finishedAt = Date()
            job.errorMessage = "进程在任务完成前退出，已标记为未完成"
            try upsertJob(job)
        }
        return running.count
    }

    // MARK: - Cloud generations

    public func upsertGeneration(_ generation: CloudGeneration) throws {
        try upsert("""
        INSERT INTO cloud_generations(id, repository_id, state, created_at, payload) VALUES(?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET state=excluded.state, payload=excluded.payload
        """, [
            .text(generation.id.uuidString),
            .text(generation.repositoryID.uuidString),
            .text(generation.state.rawValue),
            .double(generation.createdAt.timeIntervalSince1970),
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

    // MARK: - Restore jobs

    public func upsertRestoreJob(_ job: RestoreJob) throws {
        try upsert("""
        INSERT INTO restore_jobs(id, project_id, created_at, payload) VALUES(?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET payload=excluded.payload
        """, [
            .text(job.id.uuidString),
            .text(job.projectID.uuidString),
            .double(job.createdAt.timeIntervalSince1970),
            .blob(try encode(job)),
        ])
    }

    public func restoreJobs(limit: Int = 100) throws -> [RestoreJob] {
        try query("SELECT payload FROM restore_jobs ORDER BY created_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(RestoreJob.self, from: data)
        }
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

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw PersistenceError.encodeFailed(String(describing: error)) }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw PersistenceError.decodeFailed(String(describing: error)) }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        guard let row = try query(sql, []).first, case .int(let value) = row[0] else { return 0 }
        return Int(value)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw PersistenceError.statementFailed("database closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw PersistenceError.statementFailed(message)
        }
    }

    private static func execRaw(_ db: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw PersistenceError.openFailed(message)
        }
    }

    private func upsert(_ sql: String, _ params: [SQLValue]) throws {
        guard let db else { throw PersistenceError.statementFailed("database closed") }
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

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersistenceError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, _ params: [SQLValue]) throws -> [[SQLValue]] {
        guard let db else { throw PersistenceError.statementFailed("database closed") }
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
                let type = sqlite3_column_type(statement, index)
                switch type {
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

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
