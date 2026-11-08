import XCTest
import Foundation
@testable import SharedModels
@testable import CloudMirrorStore
@testable import CodeTimeSecurity
@testable import Persistence
@testable import CodeTimeCore

/// Seventh-round reliability regressions (CT-117 … CT-128).
/// P1: a protection copy must never be reclaimed by the prune that follows its
/// own creation; oversized copies are kept and reported. The cloud verifier
/// hashes every unique object once. Device identity survives Migration
/// Assistant clones. The docs-consistency gate rejects wrong bindings.
/// Every test drives the real production entry points.
final class SeventhRoundRegressionTests: XCTestCase {

    private var root: URL!
    private var keychain: KeychainStore!
    private let projectID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-ct7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        keychain = KeychainStore(service: "com.codetime.test.ct7.\(UUID().uuidString)")
    }

    override func tearDown() {
        // The seams are process-global; never leak them into another test.
        ProtectedCopyStore.maximumBytesPerProjectOverride = nil
        ProtectedCopyStore.maximumCopiesPerProjectOverride = nil
        ProtectedCopyStore.payloadCopyHandler = nil
        for copy in ProtectedCopyStore.activeCopies() {
            ProtectedCopyStore.unregisterActiveCopy(URL(fileURLWithPath: copy))
        }
        keychain.deleteAllSecrets()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    private var recoveryRoot: URL { root.appendingPathComponent("recovery", isDirectory: true) }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createCopy(target: URL) throws -> ProtectedCopyStore.CopyReceipt {
        try ProtectedCopyStore.createCopy(
            target: target,
            projectID: projectID,
            projectRoot: root,
            recoveryRoot: recoveryRoot
        )
    }

    private func assertValid(_ directory: URL, _ message: String = "副本必须通过完整校验",
                             file: StaticString = #filePath, line: UInt = #line) {
        if case .invalid(let reason) = ProtectedCopyStore.verifyCopy(directory: directory) {
            XCTFail("\(message)：\(reason)", file: file, line: line)
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeCloud(_ name: String) throws -> RegressionCloud {
        try RegressionCloud(name: name)
    }

    private func runReportCheck(_ arguments: [String]) -> (exit: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repoRoot.appendingPathComponent("Scripts/check_test_report.py").path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func copyEngineeringDocs(to directory: URL) throws {
        let source = repoRoot.appendingPathComponent("Docs/Engineering", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["TEST_REPORT.md", "IMPLEMENTATION_STATUS.md", "KNOWN_LIMITATIONS.md"] {
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            try data.write(to: directory.appendingPathComponent(name))
        }
    }

    // MARK: - CT-117 (P1): an oversized copy must survive its own prune

    func testCT117_OversizedFileProtectionCopySurvivesItsOwnPrune() async throws {
        ProtectedCopyStore.maximumBytesPerProjectOverride = 1024 * 1024 // 1 MiB soft budget
        let projectRoot = try makeDirectory("ct117-project")
        let target = projectRoot.appendingPathComponent("large.bin")
        try Data(count: 4 * 1024 * 1024).write(to: target) // 4 MiB > budget

        let receipt = try createCopy(target: target)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: receipt.directory.path),
            "超限的新建保护副本不得被创建后的清理删除"
        )
        XCTAssertTrue(receipt.overBudget, "超额必须显式上报")
        XCTAssertEqual(receipt.sizeBytes, 4 * 1024 * 1024)
        XCTAssertEqual(receipt.manifest.status, .verified)
        assertValid(receipt.directory)

        // Scale acceptance: a real 3 GiB (sparse) file through the same entry.
        if ProcessInfo.processInfo.environment["CODETIME_SCALE_TESTS"] == "1" {
            let big = projectRoot.appendingPathComponent("three-gb.bin")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: 3 * 1024 * 1024 * 1024)
            try handle.close()
            let receipt3GB = try createCopy(target: big)
            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt3GB.directory.path))
            XCTAssertEqual(receipt3GB.sizeBytes, 3 * 1024 * 1024 * 1024)
            XCTAssertTrue(receipt3GB.overBudget)
            assertValid(receipt3GB.directory)
        }
    }

    // MARK: - CT-118: oversized directory kept, over-budget surfaced

    func testCT118_OversizedDirectoryProtectionKeptWithOverBudgetStatus() async throws {
        ProtectedCopyStore.maximumBytesPerProjectOverride = 1024 * 1024
        let source = try makeDirectory("ct118-src")
        for index in 0..<3 {
            try Data(count: 512 * 1024).write(to: source.appendingPathComponent("f\(index).bin"))
        }

        let receipt = try createCopy(target: source)

        XCTAssertTrue(receipt.overBudget)
        XCTAssertEqual(receipt.sizeBytes, 3 * 512 * 1024)
        XCTAssertEqual(receipt.manifest.fileCount, 3, "目录清单必须记录文件数量")
        assertValid(receipt.directory)

        let status = ProtectedCopyStore.status(projectID: projectID, recoveryRoot: recoveryRoot)
        XCTAssertTrue(status.overBudget, "status 必须向 UI 暴露超额状态")
        XCTAssertGreaterThan(status.totalBytes, status.budgetBytes)

        // Symlinks participate in the tree digest: adding one changes the identity.
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link").path,
            withDestinationPath: "f0.bin"
        )
        let withLink = try createCopy(target: source)
        XCTAssertEqual(withLink.manifest.fileCount, 4, "符号链接必须计入树摘要")
        assertValid(withLink.directory)
    }

    // MARK: - CT-119: source changing mid-copy must not fake success

    func testCT119_SourceMutatedDuringCopyAbortsInsteadOfFakeProtection() throws {
        let fileManager = FileManager.default
        let source = try makeDirectory("ct119-src")
        try Data(Data("initial-content-".utf8) + Data(count: 4096)).write(to: source.appendingPathComponent("a.txt"))

        // 1) Payload diverges while the source stays stable → fail immediately.
        ProtectedCopyStore.payloadCopyHandler = { src, dst in
            try fileManager.copyItem(at: src, to: dst)
            try Data("tampered".utf8).write(to: dst.appendingPathComponent("a.txt"))
        }
        XCTAssertThrowsError(try createCopy(target: source), "副本与源不一致必须失败") { error in
            XCTAssertTrue(String(describing: error).contains("哈希与源目录不一致"), "\(error)")
        }
        XCTAssertTrue(
            ProtectedCopyStore.listManifests(projectID: projectID, recoveryRoot: recoveryRoot).isEmpty,
            "失败的副本不得留下有效清单"
        )

        // 2) Source keeps changing → retry once, then abort the overwrite restore.
        ProtectedCopyStore.payloadCopyHandler = { src, dst in
            try fileManager.copyItem(at: src, to: dst)
            let handle = try FileHandle(forWritingTo: src.appendingPathComponent("a.txt"))
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data("x".utf8))
            try handle.close()
        }
        XCTAssertThrowsError(try createCopy(target: source), "源持续变化必须中止") { error in
            XCTAssertTrue(String(describing: error).contains("持续变化"), "\(error)")
        }
        XCTAssertTrue(
            ProtectedCopyStore.listManifests(projectID: projectID, recoveryRoot: recoveryRoot).isEmpty,
            "不确定的副本不得成为有效保护记录"
        )

        // 3) Positive control: a stable source still produces a verified copy.
        ProtectedCopyStore.payloadCopyHandler = nil
        let receipt = try createCopy(target: source)
        assertValid(receipt.directory)
    }

    // MARK: - CT-120: tampered copy fails verification and listing

    func testCT120_TamperedProtectionCopyFailsVerificationAndListing() async throws {
        let target = root.appendingPathComponent("ct120.bin")
        try Data(count: 10 * 1024).write(to: target)
        let receipt = try createCopy(target: target)
        assertValid(receipt.directory)

        let payload = receipt.directory.appendingPathComponent("payload")
        var data = try Data(contentsOf: payload)
        data[0] ^= 0xFF // 等长覆写：只破坏内容，不改变大小
        try data.write(to: payload)

        guard case .invalid(let reason) = ProtectedCopyStore.verifyCopy(directory: receipt.directory) else {
            return XCTFail("被篡改的副本必须校验失败")
        }
        XCTAssertTrue(reason.contains("SHA-256"), "失败原因应指向哈希不一致：\(reason)")

        XCTAssertTrue(
            ProtectedCopyStore.listManifests(projectID: projectID, recoveryRoot: recoveryRoot).isEmpty,
            "损坏副本不得作为有效保护副本列出"
        )
        let including = ProtectedCopyStore.listManifests(projectID: projectID, recoveryRoot: recoveryRoot, includeInvalid: true)
        XCTAssertEqual(including.count, 1)
        XCTAssertEqual(including.first?.status, .invalid, "损坏副本必须在磁盘上被标记为 invalid")

        let audit = ProtectedCopyStore.auditProject(projectID: projectID, recoveryRoot: recoveryRoot)
        XCTAssertEqual(audit.count, 1, "定期校验必须发现损坏副本")
    }

    // MARK: - CT-121: prune never deletes the newest or an active copy

    func testCT121_PruneNeverDeletesNewestOrActiveCopies() async throws {
        ProtectedCopyStore.maximumBytesPerProjectOverride = 100 * 1024
        let target = root.appendingPathComponent("ct121.bin")
        try Data(count: 40 * 1024).write(to: target)

        let first = try createCopy(target: target)
        let second = try createCopy(target: target)
        let third = try createCopy(target: target)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first.directory.path),
            "超出预算的旧副本按策略清理"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.directory.path), "最新副本必须保留")
        assertValid(third.directory)

        // An active copy survives even when the project is over budget.
        ProtectedCopyStore.registerActiveCopy(second.directory)
        let fourth = try createCopy(target: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.path), "活动副本不得被清理")
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fourth.directory.path))
        ProtectedCopyStore.unregisterActiveCopy(second.directory)
    }

    // MARK: - CT-122: a copy referenced by a live restore is protected

    func testCT122_ActiveRestoreCopyProtectedFromPrune() async throws {
        ProtectedCopyStore.maximumBytesPerProjectOverride = 60 * 1024
        let target = root.appendingPathComponent("ct122.bin")
        try Data(count: 50 * 1024).write(to: target)

        let active = try createCopy(target: target)
        ProtectedCopyStore.registerActiveCopy(active.directory)
        defer { ProtectedCopyStore.unregisterActiveCopy(active.directory) }

        let newer = try createCopy(target: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.directory.path), "恢复活动引用的副本不得被清理")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.directory.path))

        let status = ProtectedCopyStore.status(projectID: projectID, recoveryRoot: recoveryRoot)
        XCTAssertTrue(status.overBudget, "为保护活动副本而超额必须在状态中体现")

        ProtectedCopyStore.unregisterActiveCopy(active.directory)
        let last = try createCopy(target: target)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: active.directory.path),
            "解除引用后按容量策略清理"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: newer.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: last.directory.path), "最新副本始终保留")
    }

    // MARK: - CT-123: duplicate cloud objects are hashed once

    func testCT123_DuplicateObjectsVerifiedOncePerUniqueHash() async throws {
        final class HashCountBox: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                defer { lock.unlock() }
                count += 1
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        struct CountingFileAccess: CloudFileAccess {
            let base: LocalFileAccess
            let counter: HashCountBox
            func read(_ url: URL) async throws -> Data { try await base.read(url) }
            func writeAtomically(_ data: Data, to url: URL) async throws { try await base.writeAtomically(data, to: url) }
            func move(_ source: URL, to destination: URL) async throws { try await base.move(source, to: destination) }
            func copy(_ source: URL, to destination: URL) async throws { try await base.copy(source, to: destination) }
            func remove(_ url: URL) async throws { try await base.remove(url) }
            func list(_ url: URL, keys: [URLResourceKey]) async throws -> [URL] { try await base.list(url, keys: keys) }
            func ensureDirectory(_ url: URL) async throws { try await base.ensureDirectory(url) }
            func download(_ url: URL, timeout: TimeInterval) async throws { try await base.download(url, timeout: timeout) }
            func hash(_ url: URL) async throws -> String {
                counter.increment()
                return try await base.hash(url)
            }
        }

        let cloud = try makeCloud("ct123")
        defer { cloud.cleanup() }
        let counter = HashCountBox()
        let device = UUID()
        let store = cloud.store(deviceID: device, fileAccess: CountingFileAccess(base: LocalFileAccess(), counter: counter))

        for index in 0..<6 {
            try cloud.workspace.writeFile("dup\(index).txt", index < 3 ? "alpha-content" : "beta-content")
        }
        let generation = try await cloud.publish(store, deviceID: device)

        let before = counter.value
        let result = try await store.verifyGeneration(generation)
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(counter.value - before, 2, "六个文件只有两个唯一对象：每个对象只应完整哈希一次")
        XCTAssertTrue(result.details.contains("2 个唯一对象"), "统计必须报告唯一对象数：\(result.details)")
        XCTAssertTrue(result.details.contains("6 个文件引用"), "统计必须报告文件引用数：\(result.details)")
        XCTAssertEqual(result.bytesChecked, Int64("alpha-content".utf8.count + "beta-content".utf8.count))

        // Restore reuses the per-object verdict instead of re-verifying every
        // file reference: 2 unique verifications + 6 temp-copy hashes.
        let destination = cloud.workspace.root.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        let beforeRestore = counter.value
        try await store.restoreRepository(generationId: generation, destination: destination)
        XCTAssertEqual(counter.value - beforeRestore, 8, "恢复过程只对唯一对象做完整校验")
    }

    // MARK: - CT-124: a cloned database on a new Mac mints a new identity

    func testCT124_ClonedDatabaseOnNewMacMintsNewDeviceIdentity() async throws {
        func makePaths() throws -> AppPaths {
            let paths = AppPaths(root: root.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true))
            try paths.createDirectories()
            return paths
        }

        // Machine A (simulated Mac one).
        let pathsA = try makePaths()
        let serviceA = try CodeTimeService(paths: pathsA, keychain: keychain, hardwareUUIDProvider: { "hw-aaaa-mac-one" })
        let reportA = try await serviceA.bootstrap()
        XCTAssertEqual(reportA.device.hardwareUUID, "hw-aaaa-mac-one")

        // A sibling process on the SAME Mac reuses the identity.
        let serviceA2 = try CodeTimeService(paths: pathsA, keychain: keychain, hardwareUUIDProvider: { "hw-aaaa-mac-one" })
        let reportA2 = try await serviceA2.bootstrap()
        XCTAssertEqual(reportA2.device.id, reportA.device.id, "同一台机器的多个进程必须共享设备身份")

        // Migration Assistant clones the data onto a different Mac (hw-B):
        // the stored identity must NOT be reused; a fresh one is minted.
        let serviceB = try CodeTimeService(paths: pathsA, keychain: keychain, hardwareUUIDProvider: { "hw-bbbb-mac-two" })
        let reportB = try await serviceB.bootstrap()
        XCTAssertNotEqual(reportB.device.id, reportA.device.id, "新物理设备必须有独立 Device ID")
        XCTAssertEqual(reportB.device.hardwareUUID, "hw-bbbb-mac-two")
        XCTAssertEqual(reportB.repository.id, reportA.repository.id, "设备身份变化不得推翻本地仓库记录")

        // A legacy record without an anchor is adopted, not replaced.
        let pathsL = try makePaths()
        let legacyID = UUID()
        let legacyDB = try SQLiteStore(path: pathsL.database.path)
        try await legacyDB.setCodable(
            DeviceIdentity(id: legacyID, name: "legacy", model: "Mac14,2"),
            forKey: "device.identity"
        )
        let serviceL = try CodeTimeService(paths: pathsL, keychain: keychain, hardwareUUIDProvider: { "hw-cccc-mac-three" })
        let reportL = try await serviceL.bootstrap()
        XCTAssertEqual(reportL.device.id, legacyID, "缺少锚点的旧记录应被采用而非换新")
        XCTAssertEqual(reportL.device.hardwareUUID, "hw-cccc-mac-three")
    }

    // MARK: - CT-125: two Macs publishing concurrently

    func testCT125_TwoMacsPublishingConcurrentlyKeepIndependentGenerations() async throws {
        let cloud = try makeCloud("ct125")
        defer { cloud.cleanup() }
        let macA = UUID()
        let macB = UUID()
        let storeA = cloud.store(deviceID: macA)
        let storeB = cloud.store(deviceID: macB)

        try cloud.workspace.writeFile("shared.txt", "concurrent-v1")
        async let generationA: UUID = cloud.publish(storeA, deviceID: macA)
        async let generationB: UUID = cloud.publish(storeB, deviceID: macB)
        let (generationAID, generationBID) = try await (generationA, generationB)

        XCTAssertNotEqual(generationAID, generationBID)
        let outcomeA = try await storeA.verifyGeneration(generationAID).outcome
        let outcomeB = try await storeB.verifyGeneration(generationBID).outcome
        XCTAssertEqual(outcomeA, .passed)
        XCTAssertEqual(outcomeB, .passed)
        XCTAssertEqual(
            try cloud.workspace.commitFiles(deviceID: macA, repositoryID: cloud.repositoryID).count, 1
        )
        XCTAssertEqual(
            try cloud.workspace.commitFiles(deviceID: macB, repositoryID: cloud.repositoryID).count, 1,
            "两台 Mac 并发发布不得互相破坏提交"
        )
    }

    // MARK: - CT-126: GC on one Mac never touches another Mac's objects

    func testCT126_GCOnOneMacNeverDeletesOtherMacsCommittedObjects() async throws {
        let cloud = try makeCloud("ct126")
        defer { cloud.cleanup() }
        let macA = UUID()
        let macB = UUID()
        let storeA = cloud.store(deviceID: macA, sweepGrace: 0)
        let storeB = cloud.store(deviceID: macB, sweepGrace: 0)

        try cloud.workspace.writeFile("a.txt", "v1")
        _ = try await cloud.publish(storeA, deviceID: macA, createdAt: Date().addingTimeInterval(-600))
        try cloud.workspace.writeFile("a.txt", "v2")
        try cloud.workspace.writeFile("b-only.txt", "b1")
        let generationB = try await cloud.publish(storeB, deviceID: macB, createdAt: Date().addingTimeInterval(-300))
        try cloud.workspace.removeRepositoryFile("b-only.txt")

        let objectsBBefore = try cloud.workspace
            .objectFiles(deviceID: macB, repositoryID: cloud.repositoryID)
            .map(\.lastPathComponent)
            .sorted()

        let report = try await storeA.cleanup(repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 0)
        // 多设备安全设计：检测到其他设备的仓库时 GC 跳过物理删除（CT-105 语义），
        // 这正是"绝不因并发操作错误删除云端数据"的保障。
        XCTAssertNotNil(report.skippedReason, "检测到其他设备时 GC 必须跳过物理删除")
        XCTAssertTrue(report.skippedReason?.contains("跳过物理删除") == true)

        XCTAssertEqual(
            try cloud.workspace.objectFiles(deviceID: macB, repositoryID: cloud.repositoryID).map(\.lastPathComponent).sorted(),
            objectsBBefore,
            "GC 不得删除另一台设备已提交引用的对象"
        )
        let outcomeB = try await storeB.verifyGeneration(generationB).outcome
        XCTAssertEqual(outcomeB, .passed)
    }

    // MARK: - CT-127: wrong report binding fails the gate

    func testCT127_TestReportBindingMismatchFailsConsistencyCheck() throws {
        // Positive control: the committed docs are consistent.
        let passing = runReportCheck(["--repo-root", repoRoot.path])
        XCTAssertEqual(passing.exit, 0, "当前仓库报告应当通过一致性检查：\(passing.output)")

        // Negative: a report bound to a commit that is not an ancestor of HEAD.
        let docs = root.appendingPathComponent("docs-wrong-commit", isDirectory: true)
        try copyEngineeringDocs(to: docs)
        let reportURL = docs.appendingPathComponent("TEST_REPORT.md")
        let report = try String(contentsOf: reportURL, encoding: .utf8)
        let bogus = String(repeating: "b", count: 40)
        let pattern = "(\"commit\"\\s*:\\s*\")[0-9a-f]{7,40}(\")"
        guard report.range(of: pattern, options: .regularExpression) != nil else {
            return XCTFail("TEST_REPORT 缺少可替换的 commit 绑定")
        }
        let tampered = report.replacingOccurrences(
            of: pattern,
            with: "$1" + bogus + "$2",
            options: .regularExpression
        )
        try tampered.write(to: reportURL, atomically: true, encoding: .utf8)
        let failing = runReportCheck(["--repo-root", repoRoot.path, "--docs-dir", docs.path])
        XCTAssertNotEqual(failing.exit, 0, "绑定错误 Commit 的报告必须被拒绝")
        XCTAssertTrue(failing.output.contains("祖先"), "\(failing.output)")
    }

    // MARK: - CT-128: skipped tests counted as passed fail the gate

    func testCT128_SkippedTestsCountedAsPassedFailTheCheck() throws {
        let docs = root.appendingPathComponent("docs-skip-as-pass", isDirectory: true)
        try copyEngineeringDocs(to: docs)
        let reportURL = docs.appendingPathComponent("TEST_REPORT.md")
        var report = try String(contentsOf: reportURL, encoding: .utf8)
        // Claim skipped tests as passed inside the machine-readable block.
        report = report.replacingOccurrences(
            of: #""passed"\s*:\s*\d+"#,
            with: "\"passed\": 999999",
            options: .regularExpression
        )
        try report.write(to: reportURL, atomically: true, encoding: .utf8)

        let failing = runReportCheck(["--repo-root", repoRoot.path, "--docs-dir", docs.path, "--no-git"])
        XCTAssertNotEqual(failing.exit, 0, "跳过项计入通过的报告必须被拒绝")
        XCTAssertTrue(failing.output.contains("计入通过"), "\(failing.output)")

        // A second mutation: the other docs disagree with TEST_REPORT.
        let docs2 = root.appendingPathComponent("docs-mismatch", isDirectory: true)
        try copyEngineeringDocs(to: docs2)
        let statusURL = docs2.appendingPathComponent("IMPLEMENTATION_STATUS.md")
        var status = try String(contentsOf: statusURL, encoding: .utf8)
        status = status.replacingOccurrences(
            of: #"\| 全量测试（本机）\s*\|\s*\d+"#,
            with: "| 全量测试（本机） | 1",
            options: .regularExpression
        )
        try status.write(to: statusURL, atomically: true, encoding: .utf8)
        let mismatch = runReportCheck(["--repo-root", repoRoot.path, "--docs-dir", docs2.path, "--no-git"])
        XCTAssertNotEqual(mismatch.exit, 0, "文档间统计不一致必须被拒绝")
        XCTAssertTrue(mismatch.output.contains("不一致"), "\(mismatch.output)")
    }
}
