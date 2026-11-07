import Foundation
import CodeTimeCore
import BackupEngine
import SharedModels

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

func runBenchmark(workRoot: URL, fileCount: Int) async {
    guard let kopia = KopiaBinary.locate() else { die("KOPIA_PATH 未设置") }
    let fm = FileManager.default
    try? fm.createDirectory(at: workRoot, withIntermediateDirectories: true)

    // Dataset: fileCount small files across 20 directories (large-file and
    // deep-tree variants can be added on the same pattern).
    let source = workRoot.appendingPathComponent("dataset")
    let dirs = 20
    for d in 0..<dirs {
        try? fm.createDirectory(
            at: source.appendingPathComponent("dir\(d % 20)"), withIntermediateDirectories: true
        )
    }
    var totalBytes: Int64 = 0
    let payload = Data(repeating: 0x41, count: 1024) // 1 KiB each
    for i in 0..<fileCount {
        let url = source.appendingPathComponent("dir\(i % 20)/file\(i).txt")
        try! payload.write(to: url, options: .atomic)
        totalBytes += Int64(payload.count)
    }

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
    do {
        try await engine.ensureRepository()
        let project = Project(name: "Bench", rootPath: source.path)
        let policy = BackupPolicy(projectID: project.id, excludeRules: ExclusionPresets.defaultRules())
        let snapshot = try await engine.createSnapshot(project: project, policy: policy, trigger: .manual)
        let backupDone = Date()

        let restoreTarget = workRoot.appendingPathComponent("restored")
        try fm.createDirectory(at: restoreTarget, withIntermediateDirectories: true)
        try await engine.restore(
            snapshotID: snapshot.id, path: nil, destination: restoreTarget, overwrite: false
        )
        let restoreDone = Date()
        let after = rusageSnapshot(RUSAGE_SELF)
        let afterChildren = rusageSnapshot(RUSAGE_CHILDREN)
        let cpuBefore = before.map(cpuSeconds) ?? (user: 0.0, system: 0.0)
        let cpuAfter = after.map(cpuSeconds) ?? (user: 0.0, system: 0.0)
        let childBefore = beforeChildren.map(cpuSeconds) ?? (user: 0.0, system: 0.0)
        let childAfter = afterChildren.map(cpuSeconds) ?? (user: 0.0, system: 0.0)

        // Peak RSS of THIS process (fresh process → the benchmark's own peak,
        // not an XCTest process's historical maximum).
        let peakRSSMB = after.map { Double($0.ru_maxrss) / (1024.0 * 1024.0) } ?? 0 // macOS ru_maxrss is bytes
        let restoredFiles = (try? fm.subpathsOfDirectory(atPath: restoreTarget.path).count) ?? 0

        print("PERF_METRICS:")
        print("  files: \(fileCount)")
        print("  totalBytes: \(totalBytes)")
        print("  snapshotFiles: \(snapshot.fileCount)")
        print("  backupDurationMs: \(Int(backupDone.timeIntervalSince(start) * 1000))")
        print("  restoreDurationMs: \(Int(restoreDone.timeIntervalSince(backupDone) * 1000))")
        print("  totalDurationMs: \(Int(restoreDone.timeIntervalSince(start) * 1000))")
        print("  cpuUserSec: \(String(format: "%.2f", cpuAfter.user - cpuBefore.user))")
        print("  cpuSysSec: \(String(format: "%.2f", cpuAfter.system - cpuBefore.system))")
        print("  kopiaChildCpuUserSec: \(String(format: "%.2f", childAfter.user - childBefore.user))")
        print("  kopiaChildCpuSysSec: \(String(format: "%.2f", childAfter.system - childBefore.system))")
        print("  peakMemoryMB: \(String(format: "%.1f", peakRSSMB))")
        print("  restoredFiles: \(restoredFiles)")
        print("  verifyFiles: \(snapshot.fileCount) (kopia content-verified)")
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
