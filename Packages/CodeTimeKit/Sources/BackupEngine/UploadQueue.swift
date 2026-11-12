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
    /// Fixed lock stripes. Per-object lock files grow without bound on a large
    /// backup; a stable hash maps every object into this fixed set.
    public var lockStripeCount: Int

    public init(
        spoolRoot: URL,
        softLimitBytes: Int64 = 2 * 1024 * 1024 * 1024,
        uploadConcurrency: Int = 2,
        maxRetries: Int = 5,
        leaseTimeout: TimeInterval = 120,
        retryBaseDelay: TimeInterval = 2,
        retryMaxDelay: TimeInterval = 300,
        retryJitterFraction: Double = 0.2,
        lockStripeCount: Int = 1024
    ) {
        self.spoolRoot = spoolRoot
        self.softLimitBytes = max(0, softLimitBytes)
        self.uploadConcurrency = max(1, uploadConcurrency)
        self.maxRetries = max(0, maxRetries)
        self.leaseTimeout = max(0, leaseTimeout)
        self.retryBaseDelay = max(0, retryBaseDelay)
        self.retryMaxDelay = max(0, retryMaxDelay)
        self.retryJitterFraction = min(1, max(0, retryJitterFraction))
        self.lockStripeCount = min(65_536, max(1, lockStripeCount))
    }
}

public struct SpoolStatus: Sendable, Equatable {
    public var pendingTasks: Int
    public var pendingBytes: Int64
    public var spoolFileBytes: Int64
    public var softLimitBytes: Int64
    public var oldestPendingAt: Date?
    public var oversized: Bool
    /// Fixed-size lock stripe directory accounting.
    public var lockFileCount: Int
    public var lockBytes: Int64

    public init(
        pendingTasks: Int = 0,
        pendingBytes: Int64 = 0,
        spoolFileBytes: Int64 = 0,
        softLimitBytes: Int64 = 0,
        oldestPendingAt: Date? = nil,
        oversized: Bool = false,
        lockFileCount: Int = 0,
        lockBytes: Int64 = 0
    ) {
        self.pendingTasks = pendingTasks
        self.pendingBytes = pendingBytes
        self.spoolFileBytes = spoolFileBytes
        self.softLimitBytes = softLimitBytes
        self.oldestPendingAt = oldestPendingAt
        self.oversized = oversized
        self.lockFileCount = lockFileCount
        self.lockBytes = lockBytes
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
        switch try await objectState(objectID) {
        case .uploaded, .verified, .packed:
            return true
        case .absent, .staged, .uploading, .failed, .inaccessible:
            return false
        }
    }

    public func hasPack(_ packID: String) async throws -> Bool {
        // A pack has no random nonce, but it still must be upload-confirmed. The
        // base store owns the provider-specific check.
        try await base.packState(packID).isDurablyPresent
    }

    /// Durable state, with the journal taking priority over a bare file name.
    public func objectState(_ objectID: String) async throws -> CloudObjectState {
        let taskID = Self.taskID(kind: Self.objectKind, id: objectID)
        if let task = try? await index.uploadTask(taskID) {
            switch task.state {
            case .pending, .uploading:
                return .staged
            case .failed:
                // A journal failure can be stale (or the cloud object may have
                // landed despite a timeout). Report the real remote state first.
                return try await remoteState(
                    kind: Self.objectKind, id: objectID, localSize: Int(task.fileSize)
                )
            case .uploadedPendingCleanup, .uploaded, .completed:
                // The journal says "uploaded", but the object may since have been
                // deleted in iCloud. Never reuse it without a fresh remote check.
                return try await remoteState(
                    kind: Self.objectKind, id: objectID, localSize: Int(task.fileSize)
                )
            }
        }
        let url = spoolURL(kind: Self.objectKind, id: objectID)
        if fileManager.fileExists(atPath: url.path) {
            return .staged
        }
        return try await remoteState(kind: Self.objectKind, id: objectID, localSize: 0)
    }

    private func remoteState(
        kind: String,
        id: String,
        localSize: Int
    ) async throws -> CloudObjectState {
        do {
            let state: CloudObjectState
            if kind == Self.packKind {
                state = try await base.packState(id)
            } else {
                state = try await base.objectState(id)
            }
            if case .uploaded(let size) = state {
                return .uploaded(storedSize: size > 0 ? size : localSize)
            }
            return state
        } catch {
            return .inaccessible(error.localizedDescription)
        }
    }

    /// Pack lifecycle with the same journal priority as objects. The protocol
    /// default would collapse `.inaccessible` into “not uploaded”, which is
    /// unsafe for incremental reuse.
    public func packState(_ packID: String) async throws -> CloudObjectState {
        let taskID = Self.taskID(kind: Self.packKind, id: packID)
        if let task = try? await index.uploadTask(taskID) {
            switch task.state {
            case .pending, .uploading:
                return .staged
            case .failed, .uploadedPendingCleanup, .uploaded, .completed:
                return try await remoteState(
                    kind: Self.packKind, id: packID, localSize: Int(task.fileSize)
                )
            }
        }
        let url = spoolURL(kind: Self.packKind, id: packID)
        if fileManager.fileExists(atPath: url.path) {
            return .staged
        }
        return try await remoteState(kind: Self.packKind, id: packID, localSize: 0)
    }

    /// The single write transaction for an object: lock → state → spool →
    /// validate → upload → confirm → cleanup. No caller may publish a reference
    /// until this returns.
    public func ensureObjectReady(
        _ objectID: String,
        payload: Data,
        storedSize: Int
    ) async throws -> StoredObjectLocation {
        let taskID = Self.taskID(kind: Self.objectKind, id: objectID)
        let lease = try await acquireUploadLease(
            kind: Self.objectKind, id: objectID, timeout: configuration.leaseTimeout
        )
        defer { lease.release() }

        let state = try await objectState(objectID)
        switch state {
        case .uploaded(let size), .verified(let size):
            return StoredObjectLocation(storedSize: size > 0 ? size : storedSize)
        case .packed(let packID, let offset, let size):
            return StoredObjectLocation(storedSize: size, packID: packID, packOffset: offset)
        case .inaccessible(let detail):
            throw CloudObjectLifecycleError.stateUnavailable(objectID: objectID, detail: detail)
        case .failed(let detail):
            // An explicit retry is allowed, but only after the backoff and retry
            // budget allow it. The engine will otherwise fail the snapshot.
            if let task = try? await index.uploadTask(taskID),
               task.retryCount >= configuration.maxRetries {
                throw CloudObjectLifecycleError.writerFailed(objectID: objectID, detail: detail)
            }
            if let task = try? await index.uploadTask(taskID),
               let next = task.nextAttemptAt, next > Date() {
                throw CloudObjectLifecycleError.uploadNotConfirmed(
                    objectID: objectID,
                    detail: "退避中，稍后重试"
                )
            }
        case .uploading:
            // A different writer owns this ID. Wait for its confirmed location
            // (or its error); never create a second ciphertext/spool entry.
            return try await base.ensureObjectReady(
                objectID,
                payload: payload,
                storedSize: storedSize
            )
        case .absent, .staged:
            break
        }

        try await stage(taskID: taskID, kind: Self.objectKind, id: objectID, payload: payload)
        let uploaded = try await upload(
            taskID: taskID,
            kind: Self.objectKind,
            id: objectID,
            payload: payload
        )
        _ = uploaded
        return StoredObjectLocation(storedSize: payload.count)
    }

    @discardableResult
    public func putObject(_ payload: Data, objectID: String) async throws -> Bool {
        let before = try? await objectState(objectID)
        let existed: Bool
        switch before {
        case .uploaded, .verified, .packed:
            existed = true
        default:
            existed = false
        }
        _ = try await ensureObjectReady(objectID, payload: payload, storedSize: payload.count)
        return !existed
    }

    @discardableResult
    public func putPack(_ payload: Data, packID: String) async throws -> Bool {
        let taskID = Self.taskID(kind: Self.packKind, id: packID)
        // Lock first, then inspect: a check outside the lock can race another
        // process that is writing the same pack.
        let lease = try await acquireUploadLease(
            kind: Self.packKind, id: packID, timeout: configuration.leaseTimeout
        )
        defer { lease.release() }
        // A terminal journal row is only a hint. It does not prove the pack is
        // still in the cloud (the user may have deleted it), so always verify
        // the real remote state before reusing or re-uploading.
        if try await waitForConfirmedRemote(kind: Self.packKind, id: packID) {
            // Confirmed location is not enough: the existing pack must still
            // match the payload (same ID, same bytes). The base store performs
            // the strict comparison and never overwrites a mismatch.
            _ = try await base.putPack(payload, packID: packID)
            return false
        }
        // Structural validation is unconditional; the injected validator adds
        // object-level AEAD/identity checks (see CodeTimeService).
        do {
            _ = try ObjectPackValidator.validate(payload: payload, packID: packID)
        } catch {
            throw UploadQueueError.spoolReadFailed("Pack 结构校验失败：\(packID) \(error)")
        }
        if let validate, !validate(payload, packID, true) {
            throw UploadQueueError.spoolReadFailed("Pack 内容校验失败：\(packID)")
        }
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
        // Quota check + write must be one cross-process critical section. Keep
        // the flock strictly synchronous: releasing it before the journal await
        // avoids actor reentrancy deadlock (Task B blocks on flock while Task A
        // waits for the actor after SQLite). A crash before the journal write is
        // repaired by UploadJournalReconciler, which adopts the orphan file.
        do {
            let quotaFD = try openSpoolQuotaLock()
            defer { close(quotaFD) }
            let current = try currentSpoolBytes(refresh: true)
            // Re-staging the same object replaces its own bytes; do not count
            // them twice (otherwise a retry could spuriously hit the limit).
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
        }
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
        let pageSize = 10_000
        do {
            // Reset stale `.uploading` rows page by page. A crash during upload
            // is not proof of an upload; the loser later confirms against cloud.
            var resetCursor: UploadTaskCursor?
            while true {
                let page = try await index.pendingUploads(
                    after: resetCursor, state: .uploading, limit: pageSize
                )
                guard !page.isEmpty else { break }
                for stale in page {
                    try await index.updateUploadState(stale.taskID, state: .pending, bumpRetry: false)
                }
                resetCursor = UploadTaskCursor(page[page.count - 1])
            }

            // Clean up already-confirmed tasks in stable pages.
            for state in [UploadTaskState.uploadedPendingCleanup, .uploaded, .completed] {
                var cursor: UploadTaskCursor?
                while true {
                    let page = try await index.pendingUploads(
                        after: cursor, state: state, limit: pageSize
                    )
                    guard !page.isEmpty else { break }
                    for task in page {
                        let url = URL(fileURLWithPath: task.localPath)
                        if fileManager.fileExists(atPath: url.path) {
                            do { try fileManager.removeItem(at: url) }
                            catch { continue }
                        }
                        try? await index.removeUpload(task.taskID)
                    }
                    cursor = UploadTaskCursor(page[page.count - 1])
                }
            }

            var stopScheduling = false
            // Pending then failed, each paginated with a durable cursor. A
            // backlog larger than one page must never strand later tasks.
            for state in [UploadTaskState.pending, .failed] {
                var cursor: UploadTaskCursor?
                while !stopScheduling && !isCancelled() {
                    let page = try await index.pendingUploads(
                        after: cursor, state: state, limit: pageSize
                    )
                    guard !page.isEmpty else { break }
                    cursor = UploadTaskCursor(page[page.count - 1])

                    var retryExhausted = 0
                    var deferred = 0
                    var queue: [PendingUploadV3] = []
                    let now = Date()
                    for task in page {
                        if task.retryCount >= configuration.maxRetries {
                            retryExhausted += 1
                        } else if let nextAttempt = task.nextAttemptAt, nextAttempt > now {
                            deferred += 1
                        } else {
                            queue.append(task)
                        }
                    }
                    report.skippedRetryExhausted += retryExhausted
                    report.deferred += deferred
                    if retryExhausted > 0 {
                        report.stoppedReason =
                            "\(report.skippedRetryExhausted) 个上传任务已超过重试上限，数据仍保留在待上传目录"
                    }
                    guard !queue.isEmpty else { continue }

                    let batch = await drainBatch(queue, isCancelled: isCancelled)
                    report.attempted += batch.report.attempted
                    report.uploaded += batch.report.uploaded
                    report.bytesUploaded += batch.report.bytesUploaded
                    report.alreadyPresent += batch.report.alreadyPresent
                    report.skippedBusy += batch.report.skippedBusy
                    report.failed += batch.report.failed
                    report.errors.append(contentsOf: batch.report.errors)
                    stopScheduling = batch.stopScheduling
                }
            }
        } catch {
            report.failed += 1
            report.errors.append("\(error)")
        }
        return report
    }

    private func drainBatch(
        _ tasks: [PendingUploadV3],
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> (report: UploadDrainReport, stopScheduling: Bool) {
        var report = UploadDrainReport()
        var next = 0
        var stopScheduling = false
        let window = min(configuration.uploadConcurrency, tasks.count)
        await withTaskGroup(of: Result<DrainOutcome, Error>.self) { group in
            func enqueue() {
                guard !stopScheduling, next < tasks.count else { return }
                let task = tasks[next]
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
                    stopScheduling = true
                }
            }
        }
        return (report, stopScheduling)
    }

    private enum DrainOutcome {
        case uploaded(Int64)
        case alreadyPresent
        case busy
    }

    /// True only when the backend says the object/pack is durably present.
    /// `.uploading` is waited on; `.failed`, `.inaccessible` and timeouts throw.
    /// A raw `hasPack`/`hasObject` check is explicitly not sufficient here.
    private func waitForConfirmedRemote(kind: String, id: String) async throws -> Bool {
        let deadline = Date().addingTimeInterval(configuration.leaseTimeout)
        while true {
            let state: CloudObjectState
            switch kind {
            case Self.objectKind:
                state = try await base.objectState(id)
            case Self.packKind:
                state = try await base.packState(id)
            default:
                throw UploadQueueError.invalidTask("\(kind):\(id)")
            }
            switch state {
            case .uploaded, .verified, .packed:
                return true
            case .absent, .staged:
                return false
            case .uploading:
                if Date() >= deadline {
                    throw CloudObjectLifecycleError.uploadNotConfirmed(
                        objectID: id,
                        detail: "等待 \(kind) 上传确认超时"
                    )
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            case .failed:
                // Not reusable, but not terminal: the caller still has the
                // exact payload and the base store will rewrite/re-submit it.
                return false
            case .inaccessible(let detail):
                throw CloudObjectLifecycleError.stateUnavailable(objectID: id, detail: detail)
            }
        }
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
            // confirms the object is durable (crash between upload and journal
            // clean). A local name or a still-uploading file is not enough.
            guard try await waitForConfirmedRemote(kind: kind, id: task.objectID) else {
                await markFailure(taskID: task.taskID, retryCount: task.retryCount)
                throw UploadQueueError.spoolReadFailed("待上传文件缺失：\(task.localPath)")
            }
            try await finish(taskID: task.taskID, kind: kind, id: task.objectID)
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
            // One cleanup path only: `finish` keeps the journal row when file
            // removal fails, so a successful upload never loses its spool record.
            try await finish(taskID: task.taskID, kind: kind, id: task.objectID)
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
        let locks = lockStats()
        return SpoolStatus(
            pendingTasks: tasks.count,
            pendingBytes: max(dbBytes, fileBytes),
            spoolFileBytes: fileBytes,
            softLimitBytes: configuration.softLimitBytes,
            oldestPendingAt: tasks.map(\.createdAt).min(),
            oversized: max(dbBytes, fileBytes) > configuration.softLimitBytes,
            lockFileCount: locks.count,
            lockBytes: locks.bytes
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

    /// Cross-process spool quota lock. It is deliberately separate from the
    /// striped per-object upload locks and never contains payload data.
    private func openSpoolQuotaLock() throws -> Int32 {
        let quotaDirectory = configuration.spoolRoot.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: quotaDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw UploadQueueError.spoolWriteFailed("无法创建 spool 配额锁目录：\(error)")
        }
        let path = quotaDirectory.appendingPathComponent("spool-quota.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw UploadQueueError.spoolWriteFailed("无法打开 spool 配额锁：\(path)")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw UploadQueueError.spoolWriteFailed("无法锁定 spool 配额：\(path)")
        }
        return descriptor
    }

    private func currentSpoolBytes(refresh: Bool = false) throws -> Int64 {
        if !refresh, let spoolBytes { return spoolBytes }
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
    /// Fixed-size striped flock. A stable SHA-256 mapping (never Swift's
    /// randomized Hasher) ensures every process chooses the same stripe for an
    /// object without creating one file per object.
    func acquireUploadLease(kind: String, id: String, timeout: TimeInterval = 120) async throws -> UploadLease {
        let directory = lockDirectory
        do { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw UploadQueueError.spoolWriteFailed("无法创建上传锁目录：\(error)") }

        let digest = CanonicalHashing.sha256Hex(Data("\(kind):\(id)".utf8))
        let prefix = digest.prefix(8)
        let value = Int(prefix, radix: 16) ?? 0
        let stripe = value % configuration.lockStripeCount
        let path = directory.appendingPathComponent(String(format: "stripe-%04d.lock", stripe)).path
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

    var lockDirectory: URL {
        configuration.spoolRoot.deletingLastPathComponent()
            .appendingPathComponent("upload-locks", isDirectory: true)
    }

    /// Lock directory accounting, kept separate from spool payload bytes.
    func lockStats() -> (count: Int, bytes: Int64) {
        guard let enumerator = fileManager.enumerator(
            at: lockDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return (0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            count += 1
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (count, bytes)
    }

    /// Only call while holding the exclusive maintenance lease. Removes legacy
    /// per-object lock files (never stripe files).
    @discardableResult
    public func removeLegacyPerObjectLocks() throws -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: lockDirectory,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        var removed = 0
        for url in entries where !url.lastPathComponent.hasPrefix("stripe-") {
            do { try fileManager.removeItem(at: url); removed += 1 } catch {}
        }
        return removed
    }
}
