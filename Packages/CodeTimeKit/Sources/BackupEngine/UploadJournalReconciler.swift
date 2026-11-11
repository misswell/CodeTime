import Foundation
import SharedModels

public struct UploadReconcileReport: Sendable, Equatable {
    public var adoptedFiles: Int
    public var removedOrphans: Int
    public var removedConfirmedTasks: Int
    public var missingFiles: Int
    public var quarantined: [String]
    public var failedTasks: Int
    public var errors: [String]

    public init(
        adoptedFiles: Int = 0,
        removedOrphans: Int = 0,
        removedConfirmedTasks: Int = 0,
        missingFiles: Int = 0,
        quarantined: [String] = [],
        failedTasks: Int = 0,
        errors: [String] = []
    ) {
        self.adoptedFiles = adoptedFiles
        self.removedOrphans = removedOrphans
        self.removedConfirmedTasks = removedConfirmedTasks
        self.missingFiles = missingFiles
        self.quarantined = quarantined
        self.failedTasks = failedTasks
        self.errors = errors
    }
}

/// Reconciles the encrypted spool directory with the SQLite upload journal after
/// a crash. It never deletes bytes it cannot identify: unknown/partial files are
/// moved to `spool/quarantine` and reported, while files whose upload is already
/// confirmed may be removed.
public struct UploadJournalReconciler: Sendable {
    private let spoolRoot: URL
    private let index: CloudSnapshotIndex
    private let cloud: CloudObjectSink
    private let validate: (@Sendable (Data, String, Bool) -> Bool)?
    private let fileManager: FileManager
    private let clock: @Sendable () -> Date

    public init(
        spoolRoot: URL,
        index: CloudSnapshotIndex,
        cloud: CloudObjectSink,
        validate: (@Sendable (Data, String, Bool) -> Bool)? = nil,
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.spoolRoot = spoolRoot
        self.index = index
        self.cloud = cloud
        self.validate = validate
        self.fileManager = fileManager
        self.clock = clock
    }

    public func reconcile() async -> UploadReconcileReport {
        var report = UploadReconcileReport()
        let tasks: [PendingUploadV3]
        do { tasks = try await index.pendingUploads(state: nil, limit: 100_000) }
        catch {
            report.errors.append("无法读取上传日志：\(error)")
            return report
        }
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: spoolRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
            )
        } catch {
            report.errors.append("无法枚举 spool：\(error)")
            return report
        }

        var recognized: Set<String> = []
        var taskByID: [String: PendingUploadV3] = [:]
        for task in tasks { taskByID[task.taskID] = task }

        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix(".") {
                // A crash while writing atomically can leave a temp file. Keep it
                // in quarantine instead of guessing at its contents.
                if moveToQuarantine(file, report: &report) { continue }
            }
            guard let (kind, id) = Self.parse(name) else {
                _ = moveToQuarantine(file, report: &report)
                continue
            }
            let taskID = "\(kind):\(id)"
            recognized.insert(taskID)
            if taskByID[taskID] == nil {
                // File without journal row. Adopt only if it validates; otherwise
                // quarantine it and leave a failed task for the user to see.
                let data = try? Data(contentsOf: file)
                let valid = data.map { payload in
                    validate?(payload, id, kind == UploadQueue.packKind) ?? true
                } ?? false
                if valid, let data {
                    let task = PendingUploadV3(
                        taskID: taskID,
                        objectID: id,
                        localPath: file.path,
                        remotePath: kind,
                        fileSize: Int64(data.count),
                        state: .pending,
                        retryCount: 0,
                        createdAt: clock()
                    )
                    do {
                        try await index.enqueueUploads([task])
                        taskByID[taskID] = task
                        report.adoptedFiles += 1
                    } catch {
                        report.errors.append("无法登记孤儿文件 \(name)：\(error)")
                    }
                } else {
                    _ = moveToQuarantine(file, report: &report)
                }
            }
        }

        for task in tasks {
            if task.state == .completed {
                try? await index.removeUpload(task.taskID)
                report.removedConfirmedTasks += 1
                continue
            }
            if task.state == .uploadedPendingCleanup || task.state == .uploaded {
                let url = URL(fileURLWithPath: task.localPath)
                do {
                    if fileManager.fileExists(atPath: url.path) {
                        try fileManager.removeItem(at: url)
                    }
                    try await index.removeUpload(task.taskID)
                    report.removedConfirmedTasks += 1
                } catch {
                    report.errors.append("清理已确认任务失败 \(task.taskID)：\(error)")
                }
                continue
            }
            let url = URL(fileURLWithPath: task.localPath)
            guard fileManager.fileExists(atPath: url.path) else {
                report.missingFiles += 1
                do {
                    switch task.remotePath {
                    case UploadQueue.objectKind:
                        if try await cloud.hasObject(task.objectID) {
                            try await index.removeUpload(task.taskID)
                            report.removedConfirmedTasks += 1
                        } else {
                            try await index.updateUploadState(task.taskID, state: .failed, bumpRetry: true)
                            report.failedTasks += 1
                        }
                    case UploadQueue.packKind:
                        if try await cloud.hasPack(task.objectID) {
                            try await index.removeUpload(task.taskID)
                            report.removedConfirmedTasks += 1
                        } else {
                            try await index.updateUploadState(task.taskID, state: .failed, bumpRetry: true)
                            report.failedTasks += 1
                        }
                    default:
                        try await index.updateUploadState(task.taskID, state: .failed, bumpRetry: true)
                        report.failedTasks += 1
                    }
                } catch {
                    report.errors.append("核对待上传任务 \(task.taskID) 失败：\(error)")
                }
                continue
            }
            if task.state == .uploading {
                try? await index.updateUploadState(task.taskID, state: .pending, bumpRetry: false)
            }
        }

        // Files whose task was removed after confirmation.
        for file in files {
            guard let (kind, id) = Self.parse(file.lastPathComponent) else { continue }
            let taskID = "\(kind):\(id)"
            if taskByID[taskID] == nil, !recognized.contains(taskID) {
                _ = moveToQuarantine(file, report: &report)
            }
        }
        return report
    }

    static func parse(_ name: String) -> (kind: String, id: String)? {
        for kind in [UploadQueue.objectKind, UploadQueue.packKind] {
            let prefix = "\(kind)-"
            guard name.hasPrefix(prefix) else { continue }
            let id = String(name.dropFirst(prefix.count))
            guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return nil }
            return (kind, id)
        }
        return nil
    }

    private func moveToQuarantine(_ file: URL, report: inout UploadReconcileReport) -> Bool {
        let stamp = ISO8601DateFormatter().string(from: clock())
            .replacingOccurrences(of: ":", with: "-")
        let directory = spoolRoot.appendingPathComponent("quarantine/\(stamp)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(file.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: file, to: destination)
            report.quarantined.append(destination.path)
            return true
        } catch {
            report.errors.append("无法隔离 \(file.lastPathComponent)：\(error)")
            return false
        }
    }
}
