import Foundation
import SharedModels

public enum UploadQueueError: Error, Sendable, Equatable {
    /// The spool soft limit would be exceeded. New chunks must not be generated;
    /// everything already spooled stays exactly where it is.
    case spoolFull(pendingBytes: Int64, limitBytes: Int64)
    case spoolWriteFailed(String)
    case spoolReadFailed(String)
    case invalidTask(String)

    public var diagnosticCode: String {
        switch self {
        case .spoolFull: return "ICLOUD_UPLOAD_TIMEOUT"
        case .spoolWriteFailed, .spoolReadFailed, .invalidTask: return "ICLOUD_UPLOAD_FAILED"
        }
    }
}

public struct UploadQueueConfiguration: Sendable, Equatable {
    /// `AppPaths.spool/pending`. Never inside the download cache.
    public var spoolRoot: URL
    /// Soft ceiling for not-yet-uploaded encrypted data (2GB by default).
    public var softLimitBytes: Int64
    /// Uploads in flight during a drain (2 default, 4 for balanced).
    public var uploadConcurrency: Int
    /// A task that keeps failing is kept (never deleted) but no longer retried
    /// automatically after this many attempts. The UI still lists it.
    public var maxRetries: Int

    public init(
        spoolRoot: URL,
        softLimitBytes: Int64 = 2 * 1024 * 1024 * 1024,
        uploadConcurrency: Int = 2,
        maxRetries: Int = 5
    ) {
        self.spoolRoot = spoolRoot
        self.softLimitBytes = max(0, softLimitBytes)
        self.uploadConcurrency = max(1, uploadConcurrency)
        self.maxRetries = max(0, maxRetries)
    }
}

public struct SpoolStatus: Sendable, Equatable {
    public var pendingTasks: Int
    public var pendingBytes: Int64
    public var spoolFileBytes: Int64
    public var softLimitBytes: Int64
    public var oldestPendingAt: Date?
    public var oversized: Bool

    public init(
        pendingTasks: Int = 0,
        pendingBytes: Int64 = 0,
        spoolFileBytes: Int64 = 0,
        softLimitBytes: Int64 = 0,
        oldestPendingAt: Date? = nil,
        oversized: Bool = false
    ) {
        self.pendingTasks = pendingTasks
        self.pendingBytes = pendingBytes
        self.spoolFileBytes = spoolFileBytes
        self.softLimitBytes = softLimitBytes
        self.oldestPendingAt = oldestPendingAt
        self.oversized = oversized
    }
}

public struct UploadDrainReport: Sendable, Equatable {
    public var attempted: Int
    public var uploaded: Int
    public var alreadyPresent: Int
    public var failed: Int
    public var bytesUploaded: Int64
    public var errors: [String]
    public var skippedRetryExhausted: Int
    public var stoppedReason: String?

    public init(
        attempted: Int = 0,
        uploaded: Int = 0,
        alreadyPresent: Int = 0,
        failed: Int = 0,
        bytesUploaded: Int64 = 0,
        errors: [String] = [],
        skippedRetryExhausted: Int = 0,
        stoppedReason: String? = nil
    ) {
        self.attempted = attempted
        self.uploaded = uploaded
        self.alreadyPresent = alreadyPresent
        self.failed = failed
        self.bytesUploaded = bytesUploaded
        self.errors = errors
        self.skippedRetryExhausted = skippedRetryExhausted
        self.stoppedReason = stoppedReason
    }
}

/// Durable upload queue for Cloud Format v3.
///
/// Encrypted objects are written to `spool/pending/` *before* any network call and
/// only removed after the cloud store confirmed the upload. That gives three
/// properties the task book requires:
///
/// 1. An interrupted upload never loses the only encrypted copy — the file is
///    still in the spool, and the task is still in `pending_uploads`.
/// 2. The spool is never touched by cache eviction (different root, different
///    policy) and no task is ever deleted to make room.
/// 3. When the soft limit is reached new chunks are refused, so the backup pauses
///    instead of quietly discarding un-uploaded data.
///
/// It is also a `CloudObjectSink`: wrapping the real store means the backup engine
/// gets all of this without knowing about the queue.
public actor UploadQueue: CloudObjectSink {
    public static let objectKind = "object"
    public static let packKind = "pack"

    private let base: CloudObjectSink
    private let index: CloudSnapshotIndex
    private let configuration: UploadQueueConfiguration
    private let fileManager: FileManager
    private var spoolBytes: Int64?

    public init(
        base: CloudObjectSink,
        index: CloudSnapshotIndex,
        configuration: UploadQueueConfiguration,
        fileManager: FileManager = .default
    ) {
        self.base = base
        self.index = index
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public var spoolRoot: URL { configuration.spoolRoot }
    public var softLimitBytes: Int64 { configuration.softLimitBytes }

    // MARK: - CloudObjectSink

    public func hasObject(_ objectID: String) async throws -> Bool {
        try await base.hasObject(objectID)
    }

    public func hasPack(_ packID: String) async throws -> Bool {
        try await base.hasPack(packID)
    }

    @discardableResult
    public func putObject(_ payload: Data, objectID: String) async throws -> Bool {
        if try await base.hasObject(objectID) { return false }
        let taskID = Self.taskID(kind: Self.objectKind, id: objectID)
        try await stage(taskID: taskID, kind: Self.objectKind, id: objectID, payload: payload)
        return try await upload(
            taskID: taskID,
            kind: Self.objectKind,
            id: objectID,
            payload: payload
        )
    }

    @discardableResult
    public func putPack(_ payload: Data, packID: String) async throws -> Bool {
        if try await base.hasPack(packID) { return false }
        let taskID = Self.taskID(kind: Self.packKind, id: packID)
        try await stage(taskID: taskID, kind: Self.packKind, id: packID, payload: payload)
        return try await upload(
            taskID: taskID,
            kind: Self.packKind,
            id: packID,
            payload: payload
        )
    }

    // Nodes, manifests and commits are derived from the tree and are re-created
    // by the next run if a crash intervenes, so they are not spooled. The publish
    // order (manifest before commit) still goes through the base store.
    @discardableResult
    public func putNode(_ node: DirectoryNode) async throws -> Bool {
        try await base.putNode(node)
    }

    public func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String {
        try await base.putManifest(payload, projectID: projectID, snapshotID: snapshotID)
    }

    public func putCommit(_ commit: SnapshotCommit) async throws {
        try await base.putCommit(commit)
    }

    // MARK: - Staging

    private static func taskID(kind: String, id: String) -> String {
        "\(kind):\(id)"
    }

    private func spoolURL(kind: String, id: String) -> URL {
        configuration.spoolRoot.appendingPathComponent("\(kind)-\(id)")
    }

    private func stage(taskID: String, kind: String, id: String, payload: Data) async throws {
        try ensureDirectories()
        let url = spoolURL(kind: kind, id: id)
        let current = try currentSpoolBytes()
        // Re-staging the same object replaces its own bytes; do not count them
        // twice (otherwise a retry could spuriously hit the soft limit).
        let existing = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let projected = current - existing + Int64(payload.count)
        if projected > configuration.softLimitBytes {
            throw UploadQueueError.spoolFull(
                pendingBytes: current,
                limitBytes: configuration.softLimitBytes
            )
        }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: url, options: .atomic)
        } catch {
            throw UploadQueueError.spoolWriteFailed(error.localizedDescription)
        }
        spoolBytes = projected
        try await index.enqueueUploads([
            PendingUploadV3(
                taskID: taskID,
                objectID: id,
                localPath: url.path,
                remotePath: kind,
                fileSize: Int64(payload.count),
                state: .pending,
                retryCount: 0
            )
        ])
    }

    private func upload(taskID: String, kind: String, id: String, payload: Data) async throws -> Bool {
        try await index.updateUploadState(taskID, state: .uploading, bumpRetry: false)
        do {
            let uploaded: Bool
            switch kind {
            case Self.objectKind:
                uploaded = try await base.putObject(payload, objectID: id)
            case Self.packKind:
                uploaded = try await base.putPack(payload, packID: id)
            default:
                throw UploadQueueError.invalidTask(taskID)
            }
            try await finish(taskID: taskID, kind: kind, id: id)
            return uploaded
        } catch {
            try? await index.updateUploadState(taskID, state: .failed, bumpRetry: true)
            throw error
        }
    }

    /// Removes the staged bytes only after the cloud confirmed the upload, then
    /// clears the journal row. A crash between the two leaves a file without a
    /// task, which `resumePending` resolves against the cloud.
    private func finish(taskID: String, kind: String, id: String) async throws {
        let url = spoolURL(kind: kind, id: id)
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        try? fileManager.removeItem(at: url)
        if let current = spoolBytes {
            spoolBytes = max(0, current - size)
        }
        try? await index.removeUpload(taskID)
    }

    // MARK: - Resume

    /// Uploads everything still owed to the cloud. Safe to call at launch and
    /// after a network failure. Stops scheduling new uploads after the first
    /// failure so an offline Mac does not hammer iCloud.
    public func resumePending(
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> UploadDrainReport {
        var report = UploadDrainReport()
        do {
            // A crash during upload leaves `.uploading`; it is not proof of an
            // upload, so it goes back to pending and is retried.
            for stale in try await index.pendingUploads(state: .uploading, limit: 10_000) {
                try await index.updateUploadState(stale.taskID, state: .pending, bumpRetry: false)
            }

            var work = try await index.pendingUploads(state: .pending, limit: 10_000)
            work += try await index.pendingUploads(state: .failed, limit: 10_000)
            work.sort { $0.createdAt < $1.createdAt }

            var retryExhausted = 0
            var queue: [PendingUploadV3] = []
            for task in work {
                if task.retryCount >= configuration.maxRetries {
                    retryExhausted += 1
                } else {
                    queue.append(task)
                }
            }
            report.skippedRetryExhausted = retryExhausted
            if retryExhausted > 0 {
                report.stoppedReason = "\(retryExhausted) 个上传任务已超过重试上限，数据仍保留在待上传目录"
            }
            guard !queue.isEmpty else { return report }

            var next = 0
            var stopScheduling = false
            let window = min(configuration.uploadConcurrency, queue.count)
            await withTaskGroup(of: Result<DrainOutcome, Error>.self) { group in
                func enqueue() {
                    guard !stopScheduling, next < queue.count else { return }
                    let task = queue[next]
                    next += 1
                    group.addTask { [self] in
                        if isCancelled() {
                            return .failure(CloudFirstEngineError.cancelled)
                        }
                        do {
                            return .success(try await drain(task))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                for _ in 0..<window { enqueue() }
                while let result = await group.next() {
                    report.attempted += 1
                    switch result {
                    case .success(let outcome):
                        switch outcome {
                        case .uploaded(let bytes):
                            report.uploaded += 1
                            report.bytesUploaded += bytes
                        case .alreadyPresent:
                            report.alreadyPresent += 1
                        }
                        enqueue()
                    case .failure(let error):
                        report.failed += 1
                        report.errors.append("\(error)")
                        // Keep the remaining tasks staged, but do not keep
                        // hitting a network that is clearly unavailable.
                        stopScheduling = true
                    }
                }
            }
        } catch {
            report.failed += 1
            report.errors.append("\(error)")
        }
        return report
    }

    private enum DrainOutcome {
        case uploaded(Int64)
        case alreadyPresent
    }

    private func drain(_ task: PendingUploadV3) async throws -> DrainOutcome {
        let kind = task.remotePath
        let url = URL(fileURLWithPath: task.localPath)
        guard let payload = try? Data(contentsOf: url) else {
            // The file is gone, but that is only acceptable when the cloud
            // already holds the object (crash between upload and journal clean).
            let present: Bool
            switch kind {
            case Self.objectKind:
                present = try await base.hasObject(task.objectID)
            case Self.packKind:
                present = try await base.hasPack(task.objectID)
            default:
                throw UploadQueueError.invalidTask(task.taskID)
            }
            guard present else {
                try await index.updateUploadState(task.taskID, state: .failed, bumpRetry: true)
                throw UploadQueueError.spoolReadFailed("待上传文件缺失：\(task.localPath)")
            }
            try await index.removeUpload(task.taskID)
            return .alreadyPresent
        }

        try await index.updateUploadState(task.taskID, state: .uploading, bumpRetry: false)
        do {
            let uploaded: Bool
            switch kind {
            case Self.objectKind:
                uploaded = try await base.putObject(payload, objectID: task.objectID)
            case Self.packKind:
                uploaded = try await base.putPack(payload, packID: task.objectID)
            default:
                throw UploadQueueError.invalidTask(task.taskID)
            }
            try? fileManager.removeItem(at: url)
            if let current = spoolBytes {
                spoolBytes = max(0, current - Int64(payload.count))
            }
            try await index.removeUpload(task.taskID)
            return uploaded ? .uploaded(Int64(payload.count)) : .alreadyPresent
        } catch {
            try? await index.updateUploadState(task.taskID, state: .failed, bumpRetry: true)
            throw error
        }
    }

    // MARK: - Status

    public func status() async -> SpoolStatus {
        let tasks = (try? await index.pendingUploads(state: nil, limit: 100_000)) ?? []
        let fileBytes = (try? currentSpoolBytes()) ?? 0
        let dbBytes = tasks.reduce(Int64(0)) { $0 + $1.fileSize }
        return SpoolStatus(
            pendingTasks: tasks.count,
            pendingBytes: max(dbBytes, fileBytes),
            spoolFileBytes: fileBytes,
            softLimitBytes: configuration.softLimitBytes,
            oldestPendingAt: tasks.map(\.createdAt).min(),
            oversized: max(dbBytes, fileBytes) > configuration.softLimitBytes
        )
    }

    public func pendingBytes() async throws -> Int64 {
        try await index.pendingUploadBytes()
    }

    // MARK: - Spool accounting

    private func ensureDirectories() throws {
        try fileManager.createDirectory(
            at: configuration.spoolRoot,
            withIntermediateDirectories: true
        )
    }

    private func currentSpoolBytes() throws -> Int64 {
        if let spoolBytes { return spoolBytes }
        let url = configuration.spoolRoot
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            spoolBytes = 0
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        spoolBytes = total
        return total
    }
}
