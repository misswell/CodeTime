import Foundation
import CSQLite
import SharedModels

/// Cloud Format v3 local index.
///
/// Everything here is rebuildable from iCloud (commits → manifest → nodes), so it
/// is a cache of knowledge, never the only copy of a backup. What it must not do
/// is claim more than it knows: a chunk is `verified` only after it was actually
/// downloaded and decrypted, and a snapshot is `committed` only after the commit
/// marker was confirmed.
extension SQLiteStore {

    // MARK: - File index

    /// Replaces the index for a project in one transaction: rows for paths that no
    /// longer exist are removed, changed rows are rewritten. Callers pass the
    /// complete scan result, so a file that disappeared cannot stay "known".
    public func replaceFileIndex(projectID: UUID, files: [FileNode], snapshotID: String, at date: Date = Date()) throws {
        let projectKey = projectID.uuidString
        try transaction {
            try upsert("DELETE FROM v3_file_index WHERE project_id = ?", [.text(projectKey)])
            for node in files where node.kind != .directory {
                let payload = try encode(node)
                try upsert(
                    """
                    INSERT INTO v3_file_index
                        (project_id, relative_path, file_identity, size, modified_at, changed_at,
                         file_hash, last_scanned_at, last_snapshot_id, payload)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """,
                    [
                        .text(projectKey),
                        .text(node.path),
                        .text(node.contentHash ?? ""),
                        .int(Int64(node.size)),
                        node.modifiedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                        .double(date.timeIntervalSince1970),
                        node.contentHash.map { .text($0) } ?? .null,
                        .double(date.timeIntervalSince1970),
                        .text(snapshotID),
                        .blob(payload),
                    ]
                )
            }
        }
    }

    public func fileIndex(projectID: UUID) throws -> [FileNode] {
        let rows = try query(
            "SELECT payload FROM v3_file_index WHERE project_id = ? ORDER BY relative_path",
            [.text(projectID.uuidString)]
        )
        return try rows.compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(FileNode.self, from: data)
        }
    }

    public func fileNode(projectID: UUID, path: String) throws -> FileNode? {
        let rows = try query(
            "SELECT payload FROM v3_file_index WHERE project_id = ? AND relative_path = ?",
            [.text(projectID.uuidString), .text(path)]
        )
        guard case .blob(let data)? = rows.first?.first else { return nil }
        return try decode(FileNode.self, from: data)
    }

    public func fileIndexCount(projectID: UUID) throws -> Int {
        try scalarInt(
            "SELECT COUNT(*) FROM v3_file_index WHERE project_id = '\(projectID.uuidString.replacingOccurrences(of: "'", with: "''"))';"
        )
    }

    // MARK: - Chunk index

    public func upsertChunks(_ chunks: [ChunkRecordV3]) throws {
        guard !chunks.isEmpty else { return }
        try transaction {
            for chunk in chunks {
                let payload = try encode(chunk)
                try upsert(
                    """
                    INSERT INTO v3_chunk_index
                        (object_id, plaintext_size, stored_size, key_version, pack_id, pack_offset, verified_at, payload)
                    VALUES (?,?,?,?,?,?,?,?)
                    ON CONFLICT(object_id) DO UPDATE SET
                        plaintext_size=excluded.plaintext_size,
                        stored_size=excluded.stored_size,
                        verified_at=COALESCE(excluded.verified_at, v3_chunk_index.verified_at),
                        payload=excluded.payload
                    """,
                    [
                        .text(chunk.objectID),
                        .int(Int64(chunk.plaintextSize)),
                        .int(Int64(chunk.storedSize)),
                        .int(Int64(chunk.keyVersion)),
                        chunk.packID.map { .text($0) } ?? .null,
                        chunk.packOffset.map { .int($0) } ?? .null,
                        chunk.verifiedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                        .blob(payload),
                    ]
                )
            }
        }
    }

    /// Which of these objects does the local index already know? Used to avoid
    /// re-encoding and re-uploading unchanged chunks.
    public func knownObjectIDs(_ objectIDs: [String]) throws -> Set<String> {
        guard !objectIDs.isEmpty else { return [] }
        var found: Set<String> = []
        // Chunked to stay well below SQLite's variable limit.
        for slice in stride(from: 0, to: objectIDs.count, by: 400) {
            let batch = Array(objectIDs[slice..<min(slice + 400, objectIDs.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try query(
                "SELECT object_id FROM v3_chunk_index WHERE object_id IN (\(placeholders))",
                batch.map { .text($0) }
            )
            for row in rows {
                if case .text(let id) = row[0] { found.insert(id) }
            }
        }
        return found
    }

    public func chunkRecord(_ objectID: String) throws -> ChunkRecordV3? {
        let rows = try query("SELECT payload FROM v3_chunk_index WHERE object_id = ?", [.text(objectID)])
        guard case .blob(let data)? = rows.first?.first else { return nil }
        return try decode(ChunkRecordV3.self, from: data)
    }

    public func markChunkVerified(_ objectID: String, at date: Date = Date()) throws {
        // Rewrite the whole record: the column and the JSON payload must agree,
        // otherwise a decode of the payload reports the chunk as unverified.
        guard var record = try chunkRecord(objectID) else { return }
        record.verifiedAt = date
        try upsertChunks([record])
    }

    public func removeChunkRecord(_ objectID: String) throws {
        try upsert("DELETE FROM v3_chunk_index WHERE object_id = ?", [.text(objectID)])
    }

    public func chunkCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM v3_chunk_index;")
    }

    public func chunkBytes() throws -> Int64 {
        let rows = try query("SELECT COALESCE(SUM(stored_size),0) FROM v3_chunk_index;", [])
        if case .int(let value)? = rows.first?.first { return value }
        if case .double(let value)? = rows.first?.first { return Int64(value) }
        return 0
    }

    // MARK: - Snapshot index

    public func upsertSnapshotRecord(_ record: SnapshotRecordV3) throws {
        let payload = try encode(record)
        try upsert(
            """
            INSERT INTO v3_snapshot_index
                (snapshot_id, project_id, parent_snapshot_id, created_at, root_node_id,
                 total_files, total_bytes, upload_state, commit_state, payload)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(snapshot_id) DO UPDATE SET
                parent_snapshot_id=excluded.parent_snapshot_id,
                total_files=excluded.total_files,
                total_bytes=excluded.total_bytes,
                upload_state=excluded.upload_state,
                commit_state=excluded.commit_state,
                payload=excluded.payload
            """,
            [
                .text(record.snapshotID),
                .text(record.projectID.uuidString),
                record.parentSnapshotID.map { .text($0) } ?? .null,
                .double(record.createdAt.timeIntervalSince1970),
                .text(record.rootNodeID),
                .int(Int64(record.fileCount)),
                .int(record.totalBytes),
                .text(record.uploadState.rawValue),
                .text(record.commitState.rawValue),
                .blob(payload),
            ]
        )
    }

    public func snapshotRecord(_ snapshotID: String) throws -> SnapshotRecordV3? {
        let rows = try query("SELECT payload FROM v3_snapshot_index WHERE snapshot_id = ?", [.text(snapshotID)])
        guard case .blob(let data)? = rows.first?.first else { return nil }
        return try decode(SnapshotRecordV3.self, from: data)
    }

    public func snapshotRecords(projectID: UUID, limit: Int = 100) throws -> [SnapshotRecordV3] {
        let rows = try query(
            "SELECT payload FROM v3_snapshot_index WHERE project_id = ? ORDER BY created_at DESC LIMIT ?",
            [.text(projectID.uuidString), .int(Int64(limit))]
        )
        return try rows.compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(SnapshotRecordV3.self, from: data)
        }
    }

    public func latestSnapshotRecord(projectID: UUID) throws -> SnapshotRecordV3? {
        try snapshotRecords(projectID: projectID, limit: 1).first
    }

    public func updateSnapshotRecord(
        _ snapshotID: String,
        uploadState: SnapshotUploadState? = nil,
        commitState: SnapshotCommitState? = nil,
        manifestPayloadHash: String? = nil
    ) throws {
        guard let existing = try snapshotRecord(snapshotID) else { return }
        var updated = existing
        if let uploadState { updated.uploadState = uploadState }
        if let commitState { updated.commitState = commitState }
        if let manifestPayloadHash { updated.manifestPayloadHash = manifestPayloadHash }
        try upsertSnapshotRecord(updated)
    }

    // MARK: - Pending uploads

    public func enqueueUploads(_ uploads: [PendingUploadV3]) throws {
        guard !uploads.isEmpty else { return }
        try transaction {
            for upload in uploads {
                let payload = try encode(upload)
                try upsert(
                    """
                    INSERT INTO v3_pending_uploads
                        (task_id, object_id, file_size, upload_state, retry_count, created_at, payload)
                    VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(task_id) DO UPDATE SET payload=excluded.payload
                    """,
                    [
                        .text(upload.taskID),
                        .text(upload.objectID),
                        .int(upload.fileSize),
                        .text(upload.state.rawValue),
                        .int(Int64(upload.retryCount)),
                        .double(upload.createdAt.timeIntervalSince1970),
                        .blob(payload),
                    ]
                )
            }
        }
    }

    public func pendingUploads(state: UploadTaskState? = nil, limit: Int = 500) throws -> [PendingUploadV3] {
        let sql: String
        let params: [SQLValue]
        if let state {
            sql = """
            SELECT payload FROM v3_pending_uploads WHERE upload_state = ?
            ORDER BY created_at ASC LIMIT ?
            """
            params = [.text(state.rawValue), .int(Int64(limit))]
        } else {
            sql = "SELECT payload FROM v3_pending_uploads ORDER BY created_at ASC LIMIT ?"
            params = [.int(Int64(limit))]
        }
        let rows = try query(sql, params)
        return try rows.compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(PendingUploadV3.self, from: data)
        }
    }

    /// Marks a task failed and bumps its retry counter in one statement, so a
    /// crash cannot lose the count and turn a poison task into an infinite retry.
    public func updateUploadState(_ taskID: String, state: UploadTaskState, bumpRetry: Bool = false) throws {
        if bumpRetry {
            try upsert(
                """
                UPDATE v3_pending_uploads
                SET upload_state = ?, retry_count = retry_count + 1
                WHERE task_id = ?
                """,
                [.text(state.rawValue), .text(taskID)]
            )
            if let record = try pendingUploads(limit: 5000).first(where: { $0.taskID == taskID }) {
                var updated = record
                updated.state = state
                updated.retryCount += 1
                if let payload = try? encode(updated) {
                    try? upsert("UPDATE v3_pending_uploads SET payload = ? WHERE task_id = ?", [.blob(payload), .text(taskID)])
                }
            }
        } else {
            try upsert(
                "UPDATE v3_pending_uploads SET upload_state = ? WHERE task_id = ?",
                [.text(state.rawValue), .text(taskID)]
            )
            if var record = try pendingUploads(limit: 5000).first(where: { $0.taskID == taskID }) {
                record.state = state
                if let payload = try? encode(record) {
                    try? upsert("UPDATE v3_pending_uploads SET payload = ? WHERE task_id = ?", [.blob(payload), .text(taskID)])
                }
            }
        }
    }

    public func removeUpload(_ taskID: String) throws {
        try upsert("DELETE FROM v3_pending_uploads WHERE task_id = ?", [.text(taskID)])
    }

    public func pendingUploadCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM v3_pending_uploads;")
    }

    public func pendingUploadBytes() throws -> Int64 {
        let rows = try query("SELECT COALESCE(SUM(file_size),0) FROM v3_pending_uploads;", [])
        if case .int(let value)? = rows.first?.first { return value }
        if case .double(let value)? = rows.first?.first { return Int64(value) }
        return 0
    }

    // MARK: - Cache index

    public func upsertCacheEntry(_ entry: CacheEntryV3) throws {
        let payload = try encode(entry)
        try upsert(
            """
            INSERT INTO v3_cache_index
                (cache_key, local_path, cache_size, last_accessed_at, pinned, payload)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(cache_key) DO UPDATE SET
                local_path=excluded.local_path,
                cache_size=excluded.cache_size,
                last_accessed_at=excluded.last_accessed_at,
                pinned=excluded.pinned,
                payload=excluded.payload
            """,
            [
                .text(entry.key),
                .text(entry.localPath),
                .int(entry.size),
                .double(entry.lastAccessedAt.timeIntervalSince1970),
                .int(entry.pinned ? 1 : 0),
                .blob(payload),
            ]
        )
    }

    public func cacheEntry(_ key: String) throws -> CacheEntryV3? {
        let rows = try query("SELECT payload FROM v3_cache_index WHERE cache_key = ?", [.text(key)])
        guard case .blob(let data)? = rows.first?.first else { return nil }
        return try decode(CacheEntryV3.self, from: data)
    }

    public func cacheEntries(pinned: Bool? = nil, limit: Int = 1000) throws -> [CacheEntryV3] {
        let sql: String
        let params: [SQLValue]
        if let pinned {
            sql = "SELECT payload FROM v3_cache_index WHERE pinned = ? ORDER BY last_accessed_at ASC LIMIT ?"
            params = [.int(pinned ? 1 : 0), .int(Int64(limit))]
        } else {
            sql = "SELECT payload FROM v3_cache_index ORDER BY last_accessed_at ASC LIMIT ?"
            params = [.int(Int64(limit))]
        }
        let rows = try query(sql, params)
        return try rows.compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(CacheEntryV3.self, from: data)
        }
    }

    public func removeCacheEntry(_ key: String) throws {
        try upsert("DELETE FROM v3_cache_index WHERE cache_key = ?", [.text(key)])
    }

    public func cacheBytes() throws -> Int64 {
        let rows = try query("SELECT COALESCE(SUM(cache_size),0) FROM v3_cache_index;", [])
        if case .int(let value)? = rows.first?.first { return value }
        if case .double(let value)? = rows.first?.first { return Int64(value) }
        return 0
    }

    // MARK: - Migration journal

    public func appendMigrationEvent(_ entry: MigrationJournalEntryV3) throws {
        let payload = try encode(entry)
        try upsert(
            """
            INSERT INTO v3_migration_journal (id, phase, updated_at, payload)
            VALUES (?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                phase=excluded.phase, updated_at=excluded.updated_at, payload=excluded.payload
            """,
            [
                .text(entry.id),
                .text(entry.phase),
                .double(entry.updatedAt.timeIntervalSince1970),
                .blob(payload),
            ]
        )
    }

    public func migrationEvents(limit: Int = 50) throws -> [MigrationJournalEntryV3] {
        let rows = try query(
            "SELECT payload FROM v3_migration_journal ORDER BY updated_at DESC LIMIT ?",
            [.int(Int64(limit))]
        )
        return try rows.compactMap { row in
            guard case .blob(let data) = row[0] else { return nil }
            return try decode(MigrationJournalEntryV3.self, from: data)
        }
    }

    public func latestMigrationPhase() throws -> String? {
        try migrationEvents(limit: 1).first?.phase
    }
}

// MARK: - Engine seam

extension SQLiteStore: CloudSnapshotIndex {
    public func fileNodes(projectID: UUID) async throws -> [FileNode] {
        try fileIndex(projectID: projectID)
    }

    public func replaceFileIndex(projectID: UUID, files: [FileNode], snapshotID: String) async throws {
        try replaceFileIndex(projectID: projectID, files: files, snapshotID: snapshotID, at: Date())
    }

    public func upsertSnapshot(_ record: SnapshotRecordV3) async throws {
        try upsertSnapshotRecord(record)
    }

    public func updateSnapshot(
        _ snapshotID: String,
        uploadState: SnapshotUploadState?,
        commitState: SnapshotCommitState?,
        manifestPayloadHash: String?
    ) async throws {
        try updateSnapshotRecord(
            snapshotID,
            uploadState: uploadState,
            commitState: commitState,
            manifestPayloadHash: manifestPayloadHash
        )
    }
}

extension SQLiteStore: ChunkCacheIndex {}
