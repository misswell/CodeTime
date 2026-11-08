import Foundation
import CodeTimeCore
import BackupEngine
import SharedModels
import CodeTimeSecurity

/// CT-098 / CT-072 regression-test harness. Runs as a REAL child process so the
/// test suite can exercise true SIGKILL deaths and cross-process flock
/// semantics. Not part of the product.
///
/// Modes (argv[1]):
///   migrate <sourcePath> <targetPath> <crashPoint>
///       Writes a migration request, runs performPending and SIGKILLs itself at
///       the named phase (before-copy, during-copy, after-verify,
///       before-replace, after-replace, after-complete, none).
///   hold-lifecycle <lockPath> <shared|exclusive> <seconds>
///       Acquires the lifecycle lock, reports readiness on stdout, holds the
///       lock for <seconds> or until SIGKILLed.
///   hold-agent <lockPath> <seconds>
///       Acquires a RepositoryLock (agent-style), reports readiness, holds.
///   bench <workDir> <fileCount>
///       CT-094/095: runs a REAL backup + restore against a fresh Kopia
///       repository in this dedicated process, so RUSAGE_SELF/CHILDREN measure
///       exactly this benchmark (no XCTest process history, no accumulated RSS).

setvbuf(stdout, nil, _IONBF, 0)

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("crash-child: \(message)\n".utf8))
    exit(2)
}

struct BenchPassword: RepositoryPasswordProviding {
    let value: String
    func repositoryPassword() throws -> String { value }
}

@discardableResult
func rusageSnapshot(_ who: Int32) -> rusage? {
    var usage = rusage()
    guard getrusage(Int32(who), &usage) == 0 else { return nil }
    return usage
}

func cpuSeconds(_ usage: rusage) -> (user: Double, system: Double) {
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return (user, system)
}

func sha256Hex(_ data: Data) -> String {
    // CryptoKit is unavailable without an import; use the same incremental
    // SHA-256 the app uses through Foundation's file hashing helper.
    Hashing.sha256Hex(data)
}

/// CT-115: the benchmark dataset is deliberately varied — plain files, nested
/// directories, an EMPTY file, a HIDDEN file, a file with non-ASCII/special
/// characters and a symlink — and the restored tree is compared file by file
/// (existence, size, SHA-256). "kopia exited 0" is not a correctness check.
nonisolated(unsafe) var symlinkExpectation: (relative: String, destination: String)?

func makeDataset(root: URL, fileCount: Int) throws -> [String: (size: Int, hash: String)] {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    var manifest: [String: (size: Int, hash: String)] = [:]
    let dirs = 20
    for d in 0..<dirs {
        try fm.createDirectory(
            at: root.appendingPathComponent("dir\(d)/nested\(d % 3)", isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    func write(_ relative: String, _ data: Data) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        manifest[relative] = (data.count, sha256Hex(data))
    }
    let payload = Data(repeating: 0x41, count: 1024)
    for i in 0..<fileCount {
        // Vary the content so hashing (not just size) is exercised.
        var data = payload
        data[0] = UInt8(truncatingIfNeeded: i)
        data[1] = UInt8(truncatingIfNeeded: i >> 8)
        try write("dir\(i % 20)/nested\(i % 3)/file\(i).txt", data)
    }
    try write("empty.txt", Data())
    try write(".hidden-config", Data("hidden\n".utf8))
    try write("dir0/特殊 名称 (1).txt", Data("unicode\n".utf8))
    // A symlink inside the tree: kopia stores it as a link, the restore must
    // reproduce it rather than the target's content.
    let target = root.appendingPathComponent("dir0/file0.txt")
    let link = root.appendingPathComponent("dir0/link-to-file0")
    if fm.fileExists(atPath: link.path) { try? fm.removeItem(at: link) }
    do {
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.lastPathComponent)
        symlinkExpectation = (relative: "dir0/link-to-file0", destination: "file0.txt")
    } catch {
        symlinkExpectation = nil
    }
    return manifest
}

/// Compares the restored tree against the dataset manifest.
func verifyRestoredTree(root: URL, manifest: [String: (size: Int, hash: String)]) -> (files: Int, mismatches: [String]) {
    let fm = FileManager.default
    var mismatches: [String] = []
    var checked = 0
    for (relative, expected) in manifest {
        let url = root.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: url) else {
            mismatches.append("missing:\(relative)")
            continue
        }
        checked += 1
        if data.count != expected.size { mismatches.append("size:\(relative)") ; continue }
        if sha256Hex(data) != expected.hash { mismatches.append("hash:\(relative)") }
    }
    // Directory structure: every dataset directory must exist after restore.
    for d in 0..<20 {
        let dir = root.appendingPathComponent("dir\(d)/nested\(d % 3)", isDirectory: true)
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
            mismatches.append("missing-dir:dir\(d)/nested\(d % 3)")
        }
    }
    // Hidden file must be present too (the scan must not skip it silently).
    if !fm.fileExists(atPath: root.appendingPathComponent(".hidden-config").path) {
        mismatches.append("missing-hidden:.hidden-config")
    }
    // P2-7: the symlink must be restored AS A SYMLINK with the same destination.
    if let expectation = symlinkExpectation {
        let link = root.appendingPathComponent(expectation.relative)
        let values = try? link.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink != true {
            mismatches.append("symlink-not-a-link:\(expectation.relative)")
        } else if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  destination != expectation.destination {
            mismatches.append("symlink-destination:\(expectation.relative)")
        }
    }
    return (checked, mismatches)
}

func runBenchmark(workRoot: URL, fileCount: Int) async {
    guard let kopia = KopiaBinary.locate() else { die("KOPIA_PATH 未设置") }
    let fm = FileManager.default
    try? fm.createDirectory(at: workRoot, withIntermediateDirectories: true)

    let source = workRoot.appendingPathComponent("dataset")
    let manifest: [String: (size: Int, hash: String)]
    do {
        manifest = try makeDataset(root: source, fileCount: fileCount)
    } catch {
        die("dataset creation failed: \(error)")
    }
    let totalBytes = manifest.values.reduce(Int64(0)) { $0 + Int64($1.size) }

    let engine = KopiaBackupEngine(configuration: .init(
        repositoryID: UUID(),
        repositoriesRoot: workRoot.appendingPathComponent("repositories"),
        cacheURL: workRoot.appendingPathComponent("cache"),
        logsURL: workRoot.appendingPathComponent("logs"),
        binaryURL: kopia,
        passwordProvider: BenchPassword(value: "bench-password-123"),
        gitProvider: nil,
        defaultParallelism: 2
    ))

    let before = rusageSnapshot(RUSAGE_SELF)
    let beforeChildren = rusageSnapshot(RUSAGE_CHILDREN)
    let start = Date()
    var snapshotFileCount = 0
    do {
        try await engine.ensureRepository()
        let project = Project(name: "Bench", rootPath: source.path)
        let policy = BackupPolicy(projectID: project.id, excludeRules: ExclusionPresets.defaultRules())
        let snapshot = try await engine.createSnapshot(project: project, policy: policy, trigger: .manual)
        snapshotFileCount = snapshot.fileCount
        let backupDone = Date()

        // Incremental backup of an unchanged tree: must be much cheaper than the
        // first one; the ratio is reported, not asserted (CI variance).
        let incrementalStart = Date()
        _ = try await engine.createSnapshot(project: project, policy: policy, trigger: .manual)
        let incrementalDone = Date()

        let restoreTarget = workRoot.appendingPathComponent("restored")
        try fm.createDirectory(at: restoreTarget, withIntermediateDirectories: true)
        try await engine.restore(
            snapshotID: snapshot.id, path: nil, destination: restoreTarget, overwrite: false
        )
        let restoreDone = Date()

        let verification = verifyRestoredTree(root: restoreTarget, manifest: manifest)
        let after = rusageSnapshot(RUSAGE_SELF)
        let afterChildren = rusageSnapshot(RUSAGE_CHILDREN)
        let cpuBefore = before.map(cpuSeconds) ?? (user: 0.0, system: 0.0)
        let cpuAfter = after.map(cpuSeconds) ?? (user: 0.0, system: 0.0)
        let childBefore = beforeChildren.map(cpuSeconds) ?? (user: 0.0, system: 0.0)
        let childAfter = afterChildren.map(cpuSeconds) ?? (user: 0.0, system: 0.0)
        let peakRSSMB = after.map { Double($0.ru_maxrss) / (1024.0 * 1024.0) } ?? 0

        print("PERF_METRICS:")
        print("  files: \(fileCount)")
        print("  totalBytes: \(totalBytes)")
        print("  snapshotFiles: \(snapshotFileCount)")
        print("  backupDurationMs: \(Int(backupDone.timeIntervalSince(start) * 1000))")
        print("  incrementalBackupDurationMs: \(Int(incrementalDone.timeIntervalSince(incrementalStart) * 1000))")
        print("  restoreDurationMs: \(Int(restoreDone.timeIntervalSince(backupDone) * 1000))")
        print("  totalDurationMs: \(Int(restoreDone.timeIntervalSince(start) * 1000))")
        print("  cpuUserSec: \(String(format: "%.2f", cpuAfter.user - cpuBefore.user))")
        print("  cpuSysSec: \(String(format: "%.2f", cpuAfter.system - cpuBefore.system))")
        print("  kopiaChildCpuUserSec: \(String(format: "%.2f", childAfter.user - childBefore.user))")
        print("  kopiaChildCpuSysSec: \(String(format: "%.2f", childAfter.system - childBefore.system))")
        print("  peakMemoryMB: \(String(format: "%.1f", peakRSSMB))")
        print("  verifiedFiles: \(verification.files)")
        print("  contentMismatches: \(verification.mismatches.count)")
        if !verification.mismatches.isEmpty {
            print("  mismatchSamples: \(verification.mismatches.prefix(5).joined(separator: ","))")
        }
        print("  verifyMode: size+sha256+structure+hidden+symlink")
        if verification.mismatches.isEmpty && verification.files == manifest.count {
            print("  contentCheck: PASS")
        } else {
            print("  contentCheck: FAIL")
            exit(3)
        }
    } catch {
        die("benchmark failed: \(error)")
    }
    exit(0)
}

guard CommandLine.arguments.count >= 2 else { die("missing mode") }

switch CommandLine.arguments[1] {
case "migrate":
    guard CommandLine.arguments.count >= 5 else { die("migrate needs source target crashPoint") }
    let source = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let target = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    let crashPoint = CommandLine.arguments[4]
    DataMigrator.crashPointForTesting = crashPoint == "none" ? nil : crashPoint
    do {
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)
        let result = try DataMigrator.performPending(target: target)
        print("migrated files=\(result?.fileCount ?? 0)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("migrate failed: \(error)\n".utf8))
        exit(1)
    }

case "hold-lifecycle":
    guard CommandLine.arguments.count >= 5 else { die("hold-lifecycle needs lockPath mode seconds") }
    let lock = LifecycleLock(path: CommandLine.arguments[2])
    let mode: LifecycleLock.Mode = CommandLine.arguments[3] == "exclusive" ? .exclusive : .shared
    guard lock.tryAcquire(mode) else { die("cannot acquire \(mode)") }
    print("ready")
    let seconds = TimeInterval(CommandLine.arguments[4]) ?? 60
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    exit(0)

case "hold-agent":
    guard CommandLine.arguments.count >= 4 else { die("hold-agent needs lockPath seconds") }
    let lock = RepositoryLock(path: CommandLine.arguments[2])
    guard lock.tryAcquire() else { die("cannot acquire agent lock") }
    print("ready")
    let seconds = TimeInterval(CommandLine.arguments[3]) ?? 60
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    exit(0)

case "bench":
    guard CommandLine.arguments.count >= 4 else { die("bench needs workDir fileCount") }
    let workRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let fileCount = Int(CommandLine.arguments[3]) ?? 300
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await runBenchmark(workRoot: workRoot, fileCount: fileCount)
        semaphore.signal()
    }
    semaphore.wait()

default:
    die("unknown mode \(CommandLine.arguments[1])")
}
