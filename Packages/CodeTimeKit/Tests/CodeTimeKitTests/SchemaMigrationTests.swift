import XCTest
import Foundation
import CSQLite
@testable import SharedModels
@testable import Persistence

/// MIG-001 / MIG-002: v1 → v2 is additive, transactional and re-runnable.
final class SchemaMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MIG-001: a v1 database keeps its data and gains every v2 table/column;
    // opening it again is a no-op.
    func testMIG001_V1DatabaseUpgradesAdditivelyAndIdempotently() async throws {
        let url = directory.appendingPathComponent("v1.sqlite")
        try createVersionOneDatabase(at: url)
        XCTAssertEqual(try userVersion(at: url), 1)

        let store = try SQLiteStore(path: url.path)
        let settings = try await store.saveSettingsCAS(AppSettings(), expectedRevision: nil)
        XCTAssertEqual(settings.configRevision, 1)
        await store.close()

        XCTAssertEqual(try userVersion(at: url), 4)
        let tables = try tableNames(at: url)
        for table in [
            "cloud_restore_jobs", "gc_journals", "maintenance_state",
            "object_hash_cache", "cloud_object_index", "migration_jobs",
        ] {
            XCTAssertTrue(tables.contains(table), "缺少 v2 表 \(table)")
        }
        let jobColumns = try columnNames(at: url, table: "jobs")
        for column in [
            "job_type", "repository_id", "owner_pid", "owner_start_time",
            "owner_is_agent", "heartbeat_at", "lease_expires_at", "retry_count",
            "next_retry_at", "error_class",
        ] {
            XCTAssertTrue(jobColumns.contains(column), "jobs 缺少 v2 列 \(column)")
        }

        // Re-opening an already migrated database must not re-run destructive steps.
        let reopened = try SQLiteStore(path: url.path)
        let revision = try await reopened.settingsRevision()
        XCTAssertEqual(revision, 1)
        let project = Project(name: "Migrated", rootPath: directory.path)
        try await reopened.upsertProject(project)
        let loaded = try await reopened.project(id: project.id)
        XCTAssertEqual(loaded?.lifecycle, .active)
        XCTAssertEqual(loaded?.configRevision, 0)
        await reopened.close()
        XCTAssertEqual(try userVersion(at: url), 4)
    }

    // MIG-002: a crash after some ALTER TABLE statements leaves user_version at 1;
    // the next launch must fill in only the missing columns.
    func testMIG002_PartialV2MigrationIsRepaired() async throws {
        let url = directory.appendingPathComponent("partial.sqlite")
        try createVersionOneDatabase(at: url)
        try execute("ALTER TABLE projects ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active';", at: url)
        XCTAssertEqual(try userVersion(at: url), 1)

        let store = try SQLiteStore(path: url.path)
        let project = Project(name: "Partial", rootPath: directory.path)
        try await store.upsertProject(project)
        let loaded = try await store.project(id: project.id)
        XCTAssertEqual(loaded?.lifecycle, .active)
        await store.close()

        XCTAssertEqual(try userVersion(at: url), 4)
        let columns = try columnNames(at: url, table: "jobs")
        XCTAssertTrue(columns.contains("owner_pid"))
        XCTAssertTrue(columns.contains("next_retry_at"))
        let tables = try tableNames(at: url)
        XCTAssertTrue(tables.contains("cloud_restore_jobs"))
    }

    // MARK: - Raw v1 fixture

    private func createVersionOneDatabase(at url: URL) throws {
        try execute("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE projects (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE TABLE policies (
            project_id TEXT PRIMARY KEY,
            payload BLOB NOT NULL
        );
        CREATE TABLE snapshots (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            status TEXT NOT NULL,
            cloud_state TEXT NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX idx_snapshots_project ON snapshots(project_id, created_at DESC);
        CREATE TABLE jobs (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX idx_jobs_state ON jobs(state, created_at);
        CREATE TABLE cloud_generations (
            id TEXT PRIMARY KEY,
            repository_id TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX idx_generations_repo ON cloud_generations(repository_id, created_at DESC);
        CREATE TABLE cloud_objects (
            hash TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            size INTEGER NOT NULL,
            last_checked_at REAL,
            payload BLOB NOT NULL
        );
        CREATE TABLE restore_jobs (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE TABLE verification_results (
            id TEXT PRIMARY KEY,
            generation_id TEXT,
            checked_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE TABLE activities (
            id TEXT PRIMARY KEY,
            date REAL NOT NULL,
            kind TEXT NOT NULL,
            level TEXT NOT NULL,
            project_id TEXT,
            payload BLOB NOT NULL
        );
        CREATE INDEX idx_activities_date ON activities(date DESC);
        CREATE TABLE repositories (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE TABLE kv (
            key TEXT PRIMARY KEY,
            payload BLOB NOT NULL
        );
        PRAGMA user_version=1;
        """, at: url)
    }

    // MARK: - SQLite helpers

    private func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw PersistenceError.openFailed("无法打开测试数据库")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func execute(_ sql: String, at url: URL) throws {
        try withDatabase(at: url) { db in
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
                let detail = message.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(message)
                throw PersistenceError.statementFailed(detail)
            }
        }
    }

    private func userVersion(at url: URL) throws -> Int {
        try withDatabase(at: url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw PersistenceError.statementFailed("无法读取 user_version")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw PersistenceError.statementFailed("user_version 查询失败")
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func tableNames(at url: URL) throws -> Set<String> {
        try queryStrings(
            "SELECT name FROM sqlite_master WHERE type='table';",
            at: url
        )
    }

    private func columnNames(at url: URL, table: String) throws -> Set<String> {
        try queryStrings("PRAGMA table_info(\(table));", at: url, column: 1)
    }

    private func queryStrings(_ sql: String, at url: URL, column: Int32 = 0) throws -> Set<String> {
        try withDatabase(at: url) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw PersistenceError.statementFailed("无法执行查询")
            }
            defer { sqlite3_finalize(statement) }
            var result: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, column) {
                    result.insert(String(cString: text))
                }
            }
            return result
        }
    }
}
