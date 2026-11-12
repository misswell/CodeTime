import Foundation
import Darwin
import SharedModels
import BackupEngine
import CloudMirrorStore
import Persistence
import CodeTimeSecurity

// §16.H / §17 acceptance harness. It is intentionally NOT part of the product
// or the regression gate: it needs a real iCloud Drive folder and large volumes.

private let masterKey = Data((0..<32).map { UInt8(($0 * 31 + 7) % 251) })

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

private func directoryBytes(_ url: URL, physical: Bool = false) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
    ) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        guard let values = try? file.resourceValues(
            forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        ), values.isRegularFile == true else { continue }
        total += Int64(physical ? (values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                                : (values.fileSize ?? 0))
    }
    return total
}

private func peakMemoryBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    // macOS reports ru_maxrss in bytes.
    return Int64(usage.ru_maxrss)
}

private func residentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
}

/// Samples resident memory only during the measured backup, excluding dataset
/// generation (which allocates its own temporary buffers).
private final class ResidentPeak: @unchecked Sendable {
    private var task: Task<Void, Never>?
    private var peak: Int64 = 0
    private let lock = NSLock()

    func start() {
        task = Task { [self] in
            while !Task.isCancelled {
                let value = residentBytes()
                lock.lock()
                peak = max(peak, value)
                lock.unlock()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stop() async -> Int64 {
        task?.cancel()
        await task?.value
        lock.lock(); defer { lock.unlock() }
        return peak
    }
}

private func emit(_ prefix: String, _ values: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    print("\(prefix) \(text)")
    fflush(stdout)
}

private func makeRandomBlock(seed: UInt64, size: Int) -> Data {
    var state = seed | 1
    var bytes = [UInt8](repeating: 0, count: size)
    for index in 0..<size {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
    }
    return Data(bytes)
}

/// Writes a file with the requested logical size. When `physicalRatio < 1`, only
/// that fraction is backed by random data and the rest stays a sparse hole; this
/// allows a 100 GB logical input on an 80 GB volume while still exercising
/// streaming, chunking, encryption and compression on real bytes.
private func writeTestFile(
    at url: URL,
    logicalBytes: Int64,
    physicalRatio: Double,
    blockSize: Int = 4 * 1024 * 1024
) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let ratio = min(1.0, max(0.01, physicalRatio))
    let stride = max(blockSize, Int(Double(blockSize) / ratio))
    var offset: Int64 = 0
    var blockIndex: UInt64 = 0
    while offset < logicalBytes {
        let remaining = Int(min(Int64(blockSize), logicalBytes - offset))
        let block = makeRandomBlock(seed: blockIndex &+ 0x9E3779B97F4A7C15, size: remaining)
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: block)
        blockIndex += 1
        offset += Int64(stride)
    }
    try handle.truncate(atOffset: UInt64(logicalBytes))
}

private func makeProjectFiles(_ root: URL, count: Int, bytesPerFile: Int) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<count {
        let directory = root.appendingPathComponent("d\(index / 1000)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = "file-\(index)-".data(using: .utf8)!
            + makeRandomBlock(seed: UInt64(index) &+ 1, size: max(0, bytesPerFile - 16))
        try payload.write(to: directory.appendingPathComponent("f\(index).bin"))
    }
}

private func runBackup(
    projectID: UUID,
    sourceRoot: URL,
    database: SQLiteStore,
    cloudRoot: URL,
    spool: URL,
    objectCacheLimit: Int64
) async throws -> (report: BackupRunReport, seconds: Double) {
    let encoder = ObjectEncoder(masterKey: masterKey)
    let store = CloudObjectStoreV3(
        root: cloudRoot,
        deviceID: "acceptance-device",
        masterKey: masterKey,
        objectValidator: { payload, id in
            (try? encoder.decode(payload, objectID: id)) != nil
        }
    )
    try await store.prepare(deviceName: "V3Acceptance")
    let queue = UploadQueue(
        base: store,
        index: database,
        configuration: UploadQueueConfiguration(
            spoolRoot: spool,
            softLimitBytes: objectCacheLimit,
            uploadConcurrency: 2
        ),
        validate: { payload, id, isPack in
            if isPack {
                guard let entries = try? ObjectPackValidator.validate(payload: payload, packID: id) else {
                    return false
                }
                return entries.allSatisfy { entry in
                    let (end, overflow) = entry.offset.addingReportingOverflow(entry.length)
                    guard !overflow, end <= payload.count else { return false }
                    return (try? encoder.decode(
                        payload.subdata(in: entry.offset..<end),
                        objectID: entry.objectID
                    )) != nil
                }
            }
            return (try? encoder.decode(payload, objectID: id)) != nil
        }
    )
    let engine = CloudFirstBackupEngine(
        masterKey: masterKey,
        deviceID: "acceptance-device",
        index: database,
        sink: queue
    )
    let started = Date()
    let report = try await engine.run(
        projectID: projectID,
        root: sourceRoot,
        matcher: ExclusionMatcher(rules: [])
    )
    return (report, Date().timeIntervalSince(started))
}

private func commandPerf(_ arguments: [String]) async throws {
    guard arguments.count >= 3 else { fail("usage: perf <workRoot> large <logicalBytes> <physicalRatio> | small <count> <fileBytes>") }
    let workRoot = URL(fileURLWithPath: arguments[0], isDirectory: true)
    let kind = arguments[1]
    let fm = FileManager.default
    try fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
    let source = workRoot.appendingPathComponent("source", isDirectory: true)
    let cloud = workRoot.appendingPathComponent("cloud", isDirectory: true)
    let appData = workRoot.appendingPathComponent("appdata", isDirectory: true)
    let spool = appData.appendingPathComponent("spool/pending", isDirectory: true)
    try fm.createDirectory(at: appData, withIntermediateDirectories: true)
    try fm.createDirectory(at: spool, withIntermediateDirectories: true)
    let database = try SQLiteStore(path: appData.appendingPathComponent("codetime.sqlite").path)

    var scenario = ""
    var logicalBytes: Int64 = 0
    var files = 0
    let projectID = UUID()
    switch kind {
    case "large":
        let size = Int64(arguments[2]) ?? 10 * 1024 * 1024 * 1024
        let ratio = Double(arguments.count > 3 ? arguments[3] : "1.0") ?? 1.0
        logicalBytes = size
        files = 1
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("large.bin")
        let createStarted = Date()
        let existingDataset = arguments.contains("--existing")
        if !existingDataset {
            try writeTestFile(at: file, logicalBytes: size, physicalRatio: ratio)
        }
        let createSeconds = Date().timeIntervalSince(createStarted)
        if arguments.contains("--prepare-only") {
            print("V3PERF_PREPARED \(file.path)")
            return
        }
        let sampler = ResidentPeak()
        sampler.start()
        let first = try await runBackup(
            projectID: projectID, sourceRoot: source,
            database: database, cloudRoot: cloud, spool: spool,
            objectCacheLimit: 32 * 1024 * 1024 * 1024
        )
        let firstPeak = await sampler.stop()
        let skipIncremental = arguments.contains("--no-incremental")
        var second = first
        var secondPeak = firstPeak
        if !skipIncremental {
            // Change 1 KiB in the middle: only nearby chunks should be uploaded.
            let handle = try FileHandle(forWritingTo: file)
            try handle.seek(toOffset: UInt64(size / 2))
            try handle.write(contentsOf: makeRandomBlock(seed: 424242, size: 1024))
            try handle.close()
            let incrementalSampler = ResidentPeak()
            incrementalSampler.start()
            second = try await runBackup(
                projectID: projectID, sourceRoot: source,
                database: database, cloudRoot: cloud, spool: spool,
                objectCacheLimit: 32 * 1024 * 1024 * 1024
            )
            secondPeak = await incrementalSampler.stop()
        }
        scenario = ratio >= 0.999 ? "single-large-file" : "single-large-file-sparse-\(ratio)"
        emit("V3PERF_RESULT", [
            "scenario": scenario,
            "logicalBytes": size,
            "sourcePhysicalBytes": directoryBytes(source, physical: true),
            "createSeconds": createSeconds,
            "backupSeconds": first.seconds,
            "firstBytesUploaded": first.report.bytesUploaded,
            "firstObjectsUploaded": first.report.objectsUploaded,
            "firstBytesRead": first.report.bytesRead,
            "incrementalSeconds": second.seconds,
            "incrementalBytesUploaded": second.report.bytesUploaded,
            "incrementalObjectsUploaded": second.report.objectsUploaded,
            "incrementalBytesRead": second.report.bytesRead,
            "peakMemoryBytes": peakMemoryBytes(),
            "backupPeakResidentBytes": firstPeak,
            "incrementalPeakResidentBytes": secondPeak,
            "databaseBytes": directoryBytes(appData),
            "spoolBytesAfter": directoryBytes(spool),
            "cloudBytes": directoryBytes(cloud),
            "files": files,
            "committed": first.report.committed && second.report.committed,
        ])
    case "small":
        let count = Int(arguments[2]) ?? 100_000
        let bytesPerFile = Int(arguments.count > 3 ? arguments[3] : "1024") ?? 1024
        files = count
        logicalBytes = Int64(count * bytesPerFile)
        let createStarted = Date()
        try makeProjectFiles(source, count: count, bytesPerFile: bytesPerFile)
        let createSeconds = Date().timeIntervalSince(createStarted)
        let first = try await runBackup(
            projectID: projectID, sourceRoot: source,
            database: database, cloudRoot: cloud, spool: spool,
            objectCacheLimit: 4 * 1024 * 1024 * 1024
        )
        let second = try await runBackup(
            projectID: projectID, sourceRoot: source,
            database: database, cloudRoot: cloud, spool: spool,
            objectCacheLimit: 4 * 1024 * 1024 * 1024
        )
        emit("V3PERF_RESULT", [
            "scenario": "many-small-files",
            "files": count,
            "logicalBytes": logicalBytes,
            "sourcePhysicalBytes": directoryBytes(source, physical: true),
            "createSeconds": createSeconds,
            "backupSeconds": first.seconds,
            "firstBytesUploaded": first.report.bytesUploaded,
            "firstObjectsUploaded": first.report.objectsUploaded,
            "firstPacksUploaded": first.report.packsUploaded,
            "secondSeconds": second.seconds,
            "secondBytesUploaded": second.report.bytesUploaded,
            "secondFilesReused": second.report.filesReused,
            "peakMemoryBytes": peakMemoryBytes(),
            "databaseBytes": directoryBytes(appData),
            "spoolBytesAfter": directoryBytes(spool),
            "cloudBytes": directoryBytes(cloud),
            "committed": first.report.committed && second.report.committed,
        ])
    default:
        fail("unknown perf kind: \(kind)")
    }
    print("V3PERF_WORKROOT \(workRoot.path)")
}

private func commandICloud(_ arguments: [String]) async throws {
    guard arguments.count >= 1 else {
        fail("usage: icloud <iCloudDriveCodeTimeFolder> [--container <iCloudDriveRoot>]")
    }
    let iCloudFolder = URL(fileURLWithPath: arguments[0], isDirectory: true)
    var container = iCloudFolder.deletingLastPathComponent()
    if let index = arguments.firstIndex(of: "--container"), arguments.count > index + 1 {
        container = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    let fm = FileManager.default
    guard fm.fileExists(atPath: iCloudFolder.path) else {
        fail("iCloud folder does not exist: \(iCloudFolder.path)")
    }
    let workRoot = fm.temporaryDirectory
        .appendingPathComponent("V3ICloudAcceptance-\(UUID().uuidString)", isDirectory: true)
    let source = workRoot.appendingPathComponent("source", isDirectory: true)
    let appData = workRoot.appendingPathComponent("appdata", isDirectory: true)
    let spool = appData.appendingPathComponent("spool/pending", isDirectory: true)
    let cloudRoot = iCloudFolder.appendingPathComponent("CodeTimeV3Acceptance-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try fm.createDirectory(at: appData, withIntermediateDirectories: true)
    try fm.createDirectory(at: spool, withIntermediateDirectories: true)
    try fm.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: cloudRoot)
        try? fm.removeItem(at: workRoot)
    }
    try Data("tiny-file".utf8).write(to: source.appendingPathComponent("tiny.txt"))
    try Data(repeating: 0x5A, count: 2 * 1024 * 1024).write(to: source.appendingPathComponent("medium.bin"))

    let database = try SQLiteStore(path: appData.appendingPathComponent("codetime.sqlite").path)
    let encoder = ObjectEncoder(masterKey: masterKey)
    let store = CloudObjectStoreV3(
        root: cloudRoot,
        deviceID: "icloud-acceptance-device",
        masterKey: masterKey,
        access: ICloudCoordinatedFileAccess(),
        tracker: UbiquitousUploadTracker(containerURL: container),
        uploadTimeout: 300,
        eviction: ICloudEvictionManager(),
        objectValidator: { payload, id in
            (try? encoder.decode(payload, objectID: id)) != nil
        }
    )
    try await store.prepare(deviceName: "V3 Acceptance")
    let queue = UploadQueue(
        base: store,
        index: database,
        configuration: UploadQueueConfiguration(
            spoolRoot: spool,
            softLimitBytes: 512 * 1024 * 1024,
            uploadConcurrency: 2
        ),
        validate: { payload, id, isPack in
            if isPack {
                guard let entries = try? ObjectPackValidator.validate(payload: payload, packID: id) else {
                    return false
                }
                return entries.allSatisfy { entry in
                    let (end, overflow) = entry.offset.addingReportingOverflow(entry.length)
                    guard !overflow, end <= payload.count else { return false }
                    return (try? encoder.decode(
                        payload.subdata(in: entry.offset..<end),
                        objectID: entry.objectID
                    )) != nil
                }
            }
            return (try? encoder.decode(payload, objectID: id)) != nil
        }
    )
    let projectID = UUID()
    let engine = CloudFirstBackupEngine(
        masterKey: masterKey,
        deviceID: "icloud-acceptance-device",
        index: database,
        sink: queue
    )
    let started = Date()
    let report = try await engine.run(
        projectID: projectID,
        root: source,
        matcher: ExclusionMatcher(rules: [])
    )
    let uploadSeconds = Date().timeIntervalSince(started)
    guard report.committed else { fail("snapshot did not commit") }

    // A second, independent reader/store instance: this is the same path another
    // Mac would use after the version is visible.
    let readerStore = CloudObjectStoreV3(
        root: cloudRoot,
        deviceID: "icloud-acceptance-device",
        masterKey: masterKey,
        access: ICloudCoordinatedFileAccess(),
        tracker: UbiquitousUploadTracker(containerURL: container),
        uploadTimeout: 300
    )
    let restore = CloudRestoreEngine(
        masterKey: masterKey,
        source: readerStore,
        options: RestoreOptions(sourceRoots: [source])
    )
    let destination = workRoot.appendingPathComponent("restored", isDirectory: true)
    let restoreStarted = Date()
    let restoreReport = try await restore.restore(
        projectID: projectID,
        snapshotID: report.snapshotID,
        target: .project,
        destination: destination
    )
    let restoreSeconds = Date().timeIntervalSince(restoreStarted)
    let medium = try Data(contentsOf: destination.appendingPathComponent("medium.bin"))
    let tiny = try Data(contentsOf: destination.appendingPathComponent("tiny.txt"))

    // Real iCloud local-copy state and eviction attempt (best effort; macOS may
    // refuse while the file is open or the sync queue is busy).
    var objectURL: URL?
    if let enumerator = fm.enumerator(at: cloudRoot.appendingPathComponent("devices"), includingPropertiesForKeys: nil) {
        for case let url as URL in enumerator where url.path.contains("/objects/") {
            objectURL = url
            break
        }
    }
    var stateBefore = "missing"
    var stateAfter = "missing"
    var evicted = 0
    var evictionFailed = 0
    var skippedNotUploaded = 0
    if let objectURL {
        stateBefore = "\(UbiquitousFiles.state(of: objectURL))"
        let outcome = await ICloudEvictionManager().evictLocalCopies(of: [objectURL])
        evicted = outcome.evicted
        evictionFailed = outcome.failed.count
        skippedNotUploaded = outcome.skippedNotUploaded.count
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        stateAfter = "\(UbiquitousFiles.state(of: objectURL))"
    }
    emit("V3ICLOUD_RESULT", [
        "uploadSeconds": uploadSeconds,
        "restoreSeconds": restoreSeconds,
        "filesUploaded": report.filesScanned,
        "objectsUploaded": report.objectsUploaded,
        "packsUploaded": report.packsUploaded,
        "bytesUploaded": report.bytesUploaded,
        "restoredFiles": restoreReport.filesRestored,
        "restoredBytes": restoreReport.bytesWritten,
        "mediumVerified": medium == Data(repeating: 0x5A, count: 2 * 1024 * 1024),
        "tinyVerified": tiny == Data("tiny-file".utf8),
        "objectStateBeforeEviction": stateBefore,
        "objectStateAfterEviction": stateAfter,
        "evicted": evicted,
        "evictionFailed": evictionFailed,
        "skippedNotUploaded": skippedNotUploaded,
        "cloudRoot": cloudRoot.path,
    ])
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else {
    fail("usage: v3acceptance icloud <folder> | perf <workRoot> large <bytes> [ratio] | perf <workRoot> small <count> [bytes]")
}
do {
    switch command {
    case "icloud":
        try await commandICloud(Array(args.dropFirst()))
    case "perf":
        try await commandPerf(Array(args.dropFirst()))
    default:
        fail("unknown command: \(command)")
    }
} catch {
    fail("\(error)")
}
