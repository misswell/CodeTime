import Foundation
import SharedModels

public enum UploadQueueError: Error, Sendable, Equatable {
    /// The spool soft limit would be exceeded. New chunks must not be generated;
    /// everything already spooled stays exactly where it is.
    case spoolFull(pendingBytes: Int64, limitBytes: Int64)
    case spoolWriteFailed(String)
    case spoolReadFailed(String)
    case invalidTask(String)
    case leaseUnavailable(String)

    public var diagnosticCode: String {
        switch self {
        case .spoolFull: return "ICLOUD_UPLOAD_TIMEOUT"
        case .spoolWriteFailed, .spoolReadFailed, .invalidTask: return "ICLOUD_UPLOAD_FAILED"
        case .leaseUnavailable: return "ICLOUD_UPLOAD_TIMEOUT"
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
    /// How long to wait for another process uploading the same object ID.
    public var leaseTimeout: TimeInterval
    /// First retry delay. Production uses 2s, then doubles up to `retryMaxDelay`.
    /// Zero disables the persisted delay (tests and explicit manual retries).
    public var retryBaseDelay: TimeInterval
    public var retryMaxDelay: TimeInterval
    /// ± fraction of random jitter, so two Macs do not retry in lockstep.
    public var retryJitterFraction: Double

    public init(
        spoolRoot: URL,
        softLimitBytes: Int64 = 2 * 1024 * 1024 * 1024,
        uploadConcurrency: Int = 2,
        maxRetries: Int = 5,
        leaseTimeout: TimeInterval = 120,
        retryBaseDelay: TimeInterval = 2,
        retryMaxDelay: TimeInterval = 300,
        retryJitterFraction: Double = 0.2
    ) {
        self.spoolRoot = spoolRoot
        self.softLimitBytes = max(0, softLimitBytes)
        self.uploadConcurrency = max(1, uploadConcurrency)
        self.maxRetries = max(0, maxRetries)
        self.leaseTimeout = max(0, leaseTimeout)
        self.retryBaseDelay = max(0, retryBaseDelay)
        self.retryMaxDelay = max(0, retryMaxDelay)
        self.retryJitterFraction = min(1, max(0, retryJitterFraction))
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
    public var skippedBusy: Int
    public var skippedRetryExhausted: Int
    /// Tasks whose exponential backoff has not elapsed yet.
    public var deferred: Int
    public var stoppedReason: String?

    public init(
        attempted: Int = 0,
        uploaded: Int = 0,
        alreadyPresent: Int = 0,
        failed: Int = 0,
        bytesUploaded: Int64 = 0,
        errors: [String] = [],
        skippedBusy: Int = 0,
        skippedRetryExhausted: Int = 0,
        deferred: Int = 0,
        stoppedReason: String? = nil
    ) {
        self.attempted = attempted
        self.uploaded = uploaded
        self.alreadyPresent = alreadyPresent
        self.failed = failed
        self.bytesUploaded = bytesUploaded
        self.errors = errors
        self.skippedBusy = skippedBusy
        self.skippedRetryExhausted = skippedRetryExhausted
        self.deferred = deferred
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
    /// Verifies staged bytes before they are trusted. A corrupted spool file must
    /// never become a published object; it stays failed for the next backup run
    /// (which re-reads the source file) instead.
    private let validate: (@Sendable (Data, String, Bool) -> Bool)?
    private var spoolBytes: Int64?

    public init(
        base: CloudObjectSink,
        index: CloudSnapshotIndex,
        configuration: UploadQueueConfiguration,
        fileManager: FileManager = .default,
        validate: (@Sendable (Data, String, Bool) -> Bool)? = nil
    ) {
        self.base = base
        self.index = index
        self.configuration = configuration
        self.fileManager = fileManager
        self.validate = validate
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
        let lease = try await acquireUploadLease(
            kind: Self.objectKind, id: objectID, timeout: configuration.leaseTimeout
        )
        defer { lease.release() }
        // Another process may have finished while we waited for the lease.
        if try await base.hasObject(objectID) { return false }
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
        let lease = try await acquireUploadLease(
            kind: Self.packKind, id: packID, timeout: configuration.leaseTimeout
        )
        defer { lease.release() }
        if try await base.hasPack(packID) { return false }
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
            try autoreleasepool { try payload.write(to: url, options: .atomic) }
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
        if let validate, !validate(payload, id, kind == Self.packKind) {
            await markFailure(taskID: taskID, retryCount: 0)
            throw UploadQueueError.spoolReadFailed("待上传数据校验失败：\(id)")
        }
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
            await markFailure(taskID: taskID, retryCount: 0)
            throw error
        }
    }

    /// Exponential backoff with jitter, persisted in the journal. A task is kept
    /// forever; only the automatic retry is delayed.
    private func retryDelay(attempt: Int) -> TimeInterval {
        guard configuration.retryBaseDelay > 0 else { return 0 }
        let exponent = pow(2.0, Double(max(0, attempt - 1)))
        let raw = min(configuration.retryMaxDelay, configuration.retryBaseDelay * exponent)
        let jitter = raw * configuration.retryJitterFraction * Double.random(in: -1...1)
        return max(0, raw + jitter)
    }

    private func markFailure(taskID: String, retryCount: Int) async {
        let next = Date().addingTimeInterval(retryDelay(attempt: retryCount + 1))
        if let backoff = index as? UploadBackoffIndexing {
            try? await backoff.updateUploadBackoff(
                taskID,
                state: .failed,
                bumpRetry: true,
                nextAttemptAt: next
            )
        } else {
            try? await index.updateUploadState(taskID, state: .failed, bumpRetry: true)
        }
    }

    /// Removes the staged bytes only after the cloud confirmed the upload, then
    /// clears the journal row. A crash between the two leaves a file without a
    /// task, which `resumePending` resolves against the cloud.
    private func finish(taskID: String, kind: String, id: String) async throws {
        let url = spoolURL(kind: kind, id: id)
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                // The cloud copy is confirmed, but the local cleanup is not done.
                // Keep the row so a later reconciliation can retry; never pretend
                // the task completed.
                try? await index.updateUploadState(
                    taskID, state: .uploadedPendingCleanup, bumpRetry: false
                )
                return
            }
        }
        if let current = spoolBytes {
            spoolBytes = max(0, current - size)
        }
        do {
            try await index.removeUpload(taskID)
        } catch {
            // File is gone and cloud has the bytes; the row is bookkeeping only.
            try? await index.updateUploadState(taskID, state: .uploaded, bumpRetry: false)
        }
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
            // upload. Resetting is safe even if another process is uploading the
            // same task: writes are idempotent, and the loser sees the file gone
            // and confirms the object in the cloud instead.
            for stale in try await index.pendingUploads(state: .uploading, limit: 10_000) {
                try await index.updateUploadState(stale.taskID, state: .pending, bumpRetry: false)
            }
            // Clean up tasks whose upload was already confirmed.
            var cleanupOnly = try await index.pendingUploads(state: .uploadedPendingCleanup, limit: 10_000)
            cleanupOnly += try await index.pendingUploads(state: .uploaded, limit: 10_000)
            cleanupOnly += try await index.pendingUploads(state: .completed, limit: 10_000)
            for task in cleanupOnly {
                let url = URL(fileURLWithPath: task.localPath)
                if fileManager.fileExists(atPath: url.path) {
                    do { try fileManager.removeItem(at: url) }
                    catch { continue }
                }
                try? await index.removeUpload(task.taskID)
            }

            var work = try await index.pendingUploads(state: .pending, limit: 10_000)
            work += try await index.pendingUploads(state: .failed, limit: 10_000)
            work.sort { $0.createdAt < $1.createdAt }

            var retryExhausted = 0
            var deferred = 0
            var queue: [PendingUploadV3] = []
            let now = Date()
            for task in work {
                if task.retryCount >= configuration.maxRetries {
                    retryExhausted += 1
                } else if let nextAttempt = task.nextAttemptAt, nextAttempt > now {
                    // Exponential backoff is durable: relaunching the app must not
                    // turn it into a tight retry loop.
                    deferred += 1
                } else {
                    queue.append(task)
                }
            }
            report.skippedRetryExhausted = retryExhausted
            report.deferred = deferred
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
                        case .busy:
                            report.skippedBusy += 1
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
        case busy
    }

    private func drain(_ task: PendingUploadV3) async throws -> DrainOutcome {
        let kind = task.remotePath
        let lease: UploadLease
        do {
            lease = try await acquireUploadLease(kind: kind, id: task.objectID, timeout: 0.5)
        } catch UploadQueueError.leaseUnavailable {
            return .busy
        }
        defer { lease.release() }
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
                await markFailure(taskID: task.taskID, retryCount: task.retryCount)
                throw UploadQueueError.spoolReadFailed("待上传文件缺失：\(task.localPath)")
            }
            try await index.removeUpload(task.taskID)
            return .alreadyPresent
        }

        try await index.updateUploadState(task.taskID, state: .uploading, bumpRetry: false)
        if let validate, !validate(payload, task.objectID, kind == Self.packKind) {
            await markFailure(taskID: task.taskID, retryCount: task.retryCount)
            throw UploadQueueError.spoolReadFailed("待上传数据校验失败：\(task.objectID)")
        }
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
            await markFailure(taskID: task.taskID, retryCount: task.retryCount)
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

// MARK: - Cross-process per-object upload lease

/// One lock file per object/pack ID under `spool/locks`. Two CodeTime processes
/// cannot write the same spool file or race two different AES-GCM ciphertexts for
/// one object ID. Stale locks disappear with the process that held them.
final class UploadLease: @unchecked Sendable {
    private var fd: Int32?
    private let lock = NSLock()

    init(fd: Int32) { self.fd = fd }

    deinit { release() }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard let descriptor = fd else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        fd = nil
    }
}

extension UploadQueue {
    /// Blocks until the object's writer slot is free. A timeout is an explicit
    /// error; callers must not proceed and create a second ciphertext for one ID.
    func acquireUploadLease(kind: String, id: String, timeout: TimeInterval = 120) async throws -> UploadLease {
        // Lock files live beside (not inside) the spool so the spool directory
        // only contains encrypted payloads.
        let directory = configuration.spoolRoot.deletingLastPathComponent()
            .appendingPathComponent("upload-locks", isDirectory: true)
        do { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw UploadQueueError.spoolWriteFailed("无法创建上传锁目录：\(error)") }
        let path = directory.appendingPathComponent("\(kind)-\(id).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw UploadQueueError.spoolWriteFailed("无法打开上传锁：\(path)")
        }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return UploadLease(fd: descriptor)
            }
            if Date() >= deadline {
                close(descriptor)
                throw UploadQueueError.leaseUnavailable("对象正在由另一个进程上传：\(id)")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
