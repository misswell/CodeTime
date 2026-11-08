import XCTest
import Foundation
@testable import SharedModels
@testable import CloudMirrorStore
@testable import CodeTimeSecurity
@testable import Persistence
@testable import BackupEngine
@testable import CodeTimeCore

/// Fifth-round reliability regressions (CT-082 … CT-098).
/// Every test drives real production code or real child processes — no
/// hand-constructed result maps.
final class FifthRoundRegressionTests: XCTestCase {

    private var root: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-ct5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lifecycleDir = root.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
        try? FileManager.default.removeItem(at: lifecycleDir)
        keychain = KeychainStore(service: "com.codetime.test.ct5.\(UUID().uuidString)")
        keychain.deleteAllSecrets()
        DataMigrator.crashPointForTesting = nil
        DataMigrator.sourceAgentExitTimeout = 45
    }

    override func tearDownWithError() throws {
        keychain.deleteAllSecrets()
        DataMigrator.crashPointForTesting = nil
        DataMigrator.sourceAgentExitTimeout = 45
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makePaths() throws -> AppPaths {
        let paths = AppPaths(root: root.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true))
        try paths.createDirectories()
        return paths
    }

    /// Locates the CodeTimeCrashChild executable built next to the test bundle.
    private func crashChildURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["CODETIME_CRASH_CHILD"] {
            return URL(fileURLWithPath: override)
        }
        // The SwiftPM test bundle lives at .build/debug/*.xctest; the child
        // executable is built next to it.
        var url = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("CodeTimeCrashChild")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let nested = url.appendingPathComponent(".build/debug/CodeTimeCrashChild")
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
            guard url.pathComponents.count > 1 else { break }
            url.deleteLastPathComponent()
        }
        throw XCTSkip("CodeTimeCrashChild 未构建（swift build 后重试）")
    }

    /// Runs the crash-child harness and returns (stdout, exitCode).
    @discardableResult
    private func runChild(_ args: [String], timeout: TimeInterval = 120) throws -> (String, Int32) {
        let process = Process()
        process.executableURL = try crashChildURL()
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        if let kopia = KopiaBinary.locate() { environment["KOPIA_PATH"] = kopia.path }
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw XCTRuntimeError("crash child timed out: \(args)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    private struct XCTRuntimeError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
    @discardableResult
    private func runChildChecked(_ args: [String], timeout: TimeInterval = 120) throws -> String {
        let (out, status) = try runChild(args, timeout: timeout)
        XCTAssertEqual(status, 0, "crash child failed (status \(status)): \(args)")
        return out
    }

    /// Starts the crash-child harness WITHOUT waiting (long-running holders).
    private func startChild(_ args: [String]) throws -> (process: Process, ready: Pipe) {
        let process = Process()
        process.executableURL = try crashChildURL()
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, stdout)
    }

    private func waitReady(_ pipe: Pipe, timeout: TimeInterval = 10) throws {
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { continue }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")),
               String(decoding: buffer[..<newline], as: UTF8.self).contains("ready") {
                return
            }
        }
        throw XCTRuntimeError("child did not become ready")
    }

    private func makeBetaSource() throws -> URL {
        let source = root.appendingPathComponent("beta-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("database"), withIntermediateDirectories: true
        )
        _ = try SQLiteStore(path: source.appendingPathComponent("database/codetime.sqlite").path)
        let repo = source.appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "kopia".write(to: repo.appendingPathComponent("kopia.repository"), atomically: true, encoding: .utf8)
        return source
    }

    // MARK: - CT-082 Candidate builds must not require the acceptance report

    func testCT082_CandidatePackagingDoesNotRequireAcceptanceReport() throws {
        // Resolve the repo root from the test file location (works from any cwd).
        let packageRelease = try String(
            contentsOf: repoScriptURL("package_release.sh"),
            encoding: .utf8
        )
        XCTAssertFalse(
            packageRelease.contains("require_icloud_acceptance"),
            "CT-082：candidate 打包脚本不得依赖双 Mac 验收报告（循环依赖）"
        )
        XCTAssertTrue(packageRelease.contains("xcarchive"), "candidate 仍必须执行归档")
    }

    // MARK: - CT-083 Acceptance report must bind the immutable artifact

    private func acceptanceReport(tag: String, sha: String?, commit: String? = nil) throws -> URL {
        let reportURL = root.appendingPathComponent("acceptance-\(UUID().uuidString).md")
        let content = """
        - 发布 tag：\(tag)
        - 构建 commit：\(commit ?? "7d5c3a1b9e2f4a6b8c0d1e2f3a4b5c6d7e8f9a0b")
        \(sha.map { "- Candidate Artifact：CodeTime-1.0.0-macos-universal.zip\n- Candidate Artifact SHA-256：\($0)" } ?? "- Candidate Artifact：（未填写）")
        - 执行时间：2026-11-08 12:00:00
        - 执行人：tester

        - Mac A：MacBook Pro / macOS 15.0 / 构建 1.0.0
        - Mac B：Mac mini / macOS 15.0 / 构建 1.0.0

        | 场景 | 操作 | 结果 |
        |---|---|---|
        | 首次上传 | 发布 | PASS |
        | 第二台发现 | 列出 | PASS |
        | 未下载读取 | 读取 | PASS |
        | 上传中断 | 重试 | PASS |
        | 恢复 | 校验 | PASS |
        | 迁移 | 迁移 | PASS |
        | 密钥不匹配 | 阻塞 | PASS |

        - 结果：PASS
        """
        try content.write(to: reportURL, atomically: true, encoding: .utf8)
        return reportURL
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/CodeTimeKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Packages/CodeTimeKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
    }

    private func repoScriptURL(_ name: String) -> URL {
        repoRootURL().appendingPathComponent("Scripts/\(name)")
    }

    private func runShell(_ command: [String], env: [String: String]) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = command
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        // CI 注入的 GITHUB_SHA 会泄漏进被测脚本，让 commit 校验对上 CI 的真实
        // commit 而不是 fixture。除非用例显式提供，一律隔离。
        if env["GITHUB_SHA"] == nil { environment.removeValue(forKey: "GITHUB_SHA") }
        process.environment = environment
        let process2 = process
        let outPipe = Pipe()
        let errPipe = Pipe()
        process2.standardOutput = outPipe
        process2.standardError = errPipe
        try? process2.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            + errPipe.fileHandleForReading.readDataToEndOfFile()
        process2.waitUntilExit()
        return (process2.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testCT083_AcceptanceReportMustBindImmutableArtifact() throws {
        let script = repoScriptURL("require_icloud_acceptance.sh").path
        let sha = String(repeating: "a", count: 64)

        // 1. Report WITHOUT the SHA field must fail.
        let missing = try acceptanceReport(tag: "v1.0.0", sha: nil)
        let r1 = runShell([script, "v1.0.0"], env: ["ICLOUD_ACCEPTANCE_REPORT": missing.path])
        XCTAssertNotEqual(r1.status, 0, "缺少 SHA-256 的验收报告必须被拒绝")
        XCTAssertTrue(r1.out.contains("SHA-256"), r1.out)

        // 2. Report WITH a SHA must pass (no expected SHA exported).
        let complete = try acceptanceReport(tag: "v1.0.0", sha: sha)
        let r2 = runShell([script, "v1.0.0"], env: ["ICLOUD_ACCEPTANCE_REPORT": complete.path])
        XCTAssertEqual(r2.status, 0, r2.out)

        // 3. Report SHA mismatching the downloaded artifact must fail.
        let r3 = runShell(
            [script, "v1.0.0"],
            env: ["ICLOUD_ACCEPTANCE_REPORT": complete.path, "EXPECTED_ARTIFACT_SHA": String(repeating: "b", count: 64)]
        )
        XCTAssertNotEqual(r3.status, 0, "验收报告与实际 Artifact SHA 不一致必须被拒绝")

        // 4. Matching SHA passes.
        let r4 = runShell(
            [script, "v1.0.0"],
            env: ["ICLOUD_ACCEPTANCE_REPORT": complete.path, "EXPECTED_ARTIFACT_SHA": sha]
        )
        XCTAssertEqual(r4.status, 0, r4.out)
    }

    // MARK: - CT-077 Candidate artifact SHA-256 verification (goal §9)

    func testCT077_CandidateArtifactSHA256Verification() throws {
        let script = repoScriptURL("require_icloud_acceptance.sh").path
        let goodSHA = String(repeating: "3f", count: 32)

        // SHA 格式错误必须失败（不是 64 位十六进制）。
        let badFormat = try acceptanceReport(tag: "v1.0.0", sha: String(repeating: "z", count: 64))
        let r1 = runShell([script, "v1.0.0"], env: ["ICLOUD_ACCEPTANCE_REPORT": badFormat.path])
        XCTAssertNotEqual(r1.status, 0, "非十六进制 SHA 必须被拒绝")

        // 报告中的 Commit 不一致必须失败。
        let rightCommit = "1111111111111111111111111111111111111111"
        let wrongCommitReport = try acceptanceReport(
            tag: "v1.0.0", sha: goodSHA, commit: "2222222222222222222222222222222222222222"
        )
        let r2 = runShell(
            [script, "v1.0.0"],
            env: ["ICLOUD_ACCEPTANCE_REPORT": wrongCommitReport.path, "GITHUB_SHA": rightCommit]
        )
        XCTAssertNotEqual(r2.status, 0, "构建 commit 与报告不一致必须被拒绝")

        // 报告中的 Tag 不一致必须失败。
        let r3 = runShell(
            [script, "v1.2.0"],
            env: ["ICLOUD_ACCEPTANCE_REPORT": try acceptanceReport(tag: "v1.0.0", sha: goodSHA).path]
        )
        XCTAssertNotEqual(r3.status, 0, "发布 tag 与报告不一致必须被拒绝")

        // 全部一致时通过。
        let r4 = runShell(
            [script, "v1.0.0"],
            env: [
                "ICLOUD_ACCEPTANCE_REPORT": try acceptanceReport(tag: "v1.0.0", sha: goodSHA, commit: rightCommit).path,
                "GITHUB_SHA": rightCommit,
                "EXPECTED_ARTIFACT_SHA": goodSHA,
            ]
        )
        XCTAssertEqual(r4.status, 0, r4.out)
    }

    // MARK: - CT-079 Manual release tag validation

    func testCT079_ManualReleaseTagMustExistAndPointAtBuildCommit() throws {
        // Stand up a throwaway git repo with one tagged commit.
        let repo = root.appendingPathComponent("tagrepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: String...) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
        _ = git("init")
        _ = git("config", "user.email", "t@t")
        _ = git("config", "user.name", "t")
        try "x".write(to: repo.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        _ = git("add", ".")
        _ = git("commit", "-m", "c1")
        let commit1 = git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try "y".write(to: repo.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        _ = git("commit", "-am", "c2")
        let commit2 = git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = git("tag", "v1.0.0", "HEAD") // tag points at commit2

        let script = repoScriptURL("validate_release_tag.sh").path

        // Tag 存在且指向当前 commit → 通过。
        let ok = runShell([script, "v1.0.0", commit2], env: ["GIT_DIR": repo.appendingPathComponent(".git").path])
        XCTAssertEqual(ok.status, 0, ok.out)

        // Tag 指向其他 commit → 失败。
        let wrongCommit = runShell([script, "v1.0.0", commit1], env: ["GIT_DIR": repo.appendingPathComponent(".git").path])
        XCTAssertNotEqual(wrongCommit.status, 0, "tag 指向其他 commit 必须失败")

        // Tag 不存在 → 明确失败。
        let missing = runShell([script, "v9.9.9", commit2], env: ["GIT_DIR": repo.appendingPathComponent(".git").path])
        XCTAssertNotEqual(missing.status, 0, "tag 不存在必须失败")
        XCTAssertTrue(missing.out.contains("不存在") || missing.out.contains("not found"), missing.out)
    }

    // MARK: - CT-081 (production-path rewrite) unreadable states are classified

    func testCT081_UnreadableStatesClassifiedByProductionListing() async throws {
        let cloud = try RegressionCloud(name: "ct081")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device)
        try cloud.workspace.writeFile("a.txt", "v1")
        _ = try await cloud.publish(store, deviceID: device)

        // A corrupt (undecryptable) manifest must classify as .corrupted by the
        // REAL production listing — never silently treated as published or empty.
        let corrupt = cloud.workspace.commitsDirectory(deviceID: device, repositoryID: cloud.repositoryID)
            .appendingPathComponent("\(UUID().uuidString).ctm")
        try Data("corrupt-manifest-bytes".utf8).write(to: corrupt)

        let entries = try await store.listGenerationEntries(repositoryId: cloud.repositoryID)
        XCTAssertEqual(entries.count, 2, "损坏清单必须保留为占位条目")
        let corruptEntry = entries.first { $0.generation == nil }
        XCTAssertNotNil(corruptEntry, "损坏清单不得被静默丢弃")
        XCTAssertEqual(corruptEntry?.readState, .corrupted)
        XCTAssertFalse(corruptEntry?.isRestorable ?? true, "损坏清单不可恢复")

        // The valid generation stays published and restorable.
        let valid = entries.first { $0.generation != nil }
        XCTAssertEqual(valid?.generation?.state, .published)
        XCTAssertTrue(valid?.isRestorable ?? false)
    }

    // MARK: - CT-084 Lifecycle shared/exclusive semantics across real processes

    func testCT084_SharedLocksCoexistExclusiveBlocksAndDeathReleases() throws {
        let lockPath = root.appendingPathComponent("lifecycle.lock").path

        // A holds the shared lock for 5s; B (also shared) must acquire while A
        // is still alive — multiple shared holders coexist.
        let (a, aReady) = try startChild(["hold-lifecycle", lockPath, "shared", "5"])
        try waitReady(aReady)
        let b = try runChildChecked(["hold-lifecycle", lockPath, "shared", "0.3"], timeout: 15)
        XCTAssertTrue(b.contains("ready"), b)

        // Exclusive must FAIL while a shared holder is alive (child exits 2).
        let (out, status) = try runChild(["hold-lifecycle", lockPath, "exclusive", "1"], timeout: 15)
        XCTAssertNotEqual(status, 0, "shared 持有期间 exclusive 必须失败: \(out)")
        XCTAssertTrue(out.contains("cannot acquire"), out)

        // Wait for A to die (SIGTERM by us = still a real cross-process death),
        // then exclusive must succeed — a dead process releases flock
        // automatically (kernel-guaranteed).
        a.terminate()
        a.waitUntilExit()
        let (out2, status2) = try runChild(["hold-lifecycle", lockPath, "exclusive", "0.5"], timeout: 15)
        XCTAssertEqual(status2, 0, "持有者退出后 exclusive 必须可获得: \(out2)")
    }

    // MARK: - CT-085 Agent stop protocol under a real lock holder

    func testCT085_MigrationWaitsForAgentExitAndRefusesStuckAgent() throws {
        let source = try makeBetaSource()
        let target = root.appendingPathComponent("release-ct85", isDirectory: true)
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)

        // A live agent that does NOT exit: migration must fail safe (short window).
        let sourceAgentLock = RepositoryLock(path: source.appendingPathComponent("agent.lock").path)
        XCTAssertTrue(sourceAgentLock.tryAcquire())
        DataMigrator.sourceAgentExitTimeout = 2
        XCTAssertThrowsError(try DataMigrator.performPending(target: target)) { error in
            XCTAssertTrue("\(error)".contains("Beta Agent"), "\(error)")
        }
        sourceAgentLock.release()

        // The same request completes once the agent lock is free.
        let result = try DataMigrator.performPending(target: target)
        XCTAssertGreaterThanOrEqual(result?.fileCount ?? 0, 2, "Agent 退出后迁移必须完成")
        XCTAssertFalse(DataMigrator.hasPendingRequest(target: target))
    }

    // MARK: - CT-086 Restore path safety (SafePath battery)

    func testCT086_SafePathRejectsTraversalSymlinkAndPrefixSiblings() throws {
        let repoRoot = root.appendingPathComponent("repo-root", isDirectory: true)
        let staging = repoRoot.appendingPathComponent("restore-ab12cd34-ef56ab78", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        // 1. 普通合法路径 — accepted, resolved.
        let ok = try SafePath.containedDirectChild(staging.path, within: repoRoot)
        XCTAssertEqual(ok.standardizedFileURL.path, staging.standardizedFileURL.path)

        // 2. `../` 穿越 — rejected.
        let traversal = staging.appendingPathComponent("../victim").path
        XCTAssertThrowsError(try SafePath.containedDirectChild(traversal, within: repoRoot))

        // 3. 同名前缀目录 — component-wise check must not match /repo-root-evil.
        let evilRoot = root.appendingPathComponent("repo-root-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: evilRoot, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SafePath.contained(staging.path, within: evilRoot))

        // 4. 绝对路径在根外 — rejected.
        XCTAssertThrowsError(try SafePath.contained(outside.path, within: repoRoot))

        // 5. 符号链接指向仓库外部 — rejected via resolved-path containment.
        let escapeLink = repoRoot.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)
        XCTAssertThrowsError(try SafePath.containedDirectChild(escapeLink.path, within: repoRoot))

        // 6. 符号链接嵌套 — link → link → outside must also be rejected.
        let inner = repoRoot.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let linkOne = repoRoot.appendingPathComponent("link-one")
        try FileManager.default.createSymbolicLink(at: linkOne, withDestinationURL: outside)
        let linkTwo = repoRoot.appendingPathComponent("link-two")
        try FileManager.default.createSymbolicLink(at: linkTwo, withDestinationURL: linkOne)
        XCTAssertThrowsError(try SafePath.containedDirectChild(linkTwo.path, within: repoRoot))

        // 7. 非直接子目录（嵌套更深）— rejected.
        let nested = inner.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SafePath.containedDirectChild(nested.path, within: repoRoot))

        // 8. 空 / NUL / 相对路径 — raw validation.
        XCTAssertThrowsError(try SafePath.validateRaw(""))
        XCTAssertThrowsError(try SafePath.validateRaw("a\0b"))
        XCTAssertThrowsError(try SafePath.validateRaw("relative/path"))

        // 9. O_NOFOLLOW 探测：目录被符号链接替换后必须拒绝删除类操作。
        let swapTarget = repoRoot.appendingPathComponent("swap-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: swapTarget, withIntermediateDirectories: true)
        try SafePath.assertRealDirectoryNotSymlink(swapTarget.path)
        try FileManager.default.removeItem(at: swapTarget)
        try FileManager.default.createSymbolicLink(at: swapTarget, withDestinationURL: outside)
        XCTAssertThrowsError(try SafePath.assertRealDirectoryNotSymlink(swapTarget.path))

        // 10/11. staging 派生与再计算一致；篡改的路径与派生不符。
        let repoID = UUID()
        let jobID = UUID()
        let derived = SafePath.stagingURL(in: repoRoot, repositoryID: repoID, jobID: jobID)
        XCTAssertTrue(SafePath.isDerivedStagingName(derived.lastPathComponent, repositoryID: repoID, jobID: jobID))
        XCTAssertFalse(SafePath.isDerivedStagingName("restore-\(UUID().uuidString.prefix(8))", repositoryID: repoID, jobID: jobID))
        XCTAssertEqual(derived.path, SafePath.stagingURL(in: repoRoot, repositoryID: repoID, jobID: jobID).path)

        // 12. 恢复目标不得指向应用数据根内部。
        XCTAssertThrowsError(try SafePath.validateRestoreDestination(
            repoRoot, protectedRoots: [repoRoot]
        ))
    }

    // MARK: - CT-087 Cloud restore lease is cross-process exclusive

    func testCT087_CloudRestoreLeaseIsCrossProcessExclusive() async throws {
        let database = try SQLiteStore(path: root.appendingPathComponent("lease-\(UUID().uuidString).sqlite").path)
        let job = CloudRestoreJob(
            repositoryID: UUID(), generationID: UUID(), sourceDeviceID: UUID(),
            state: .preparing, stagingPath: root.appendingPathComponent("staging").path
        )
        try await database.upsertCloudRestoreJob(job)

        let liveOwner = ProcessIdentity.current(isAgent: false)
        let otherOwner = ProcessIdentity(pid: liveOwner.pid + 77_777, startTime: 123.456, isAgent: true)

        // First claim wins.
        let claimed = try await database.claimCloudRestoreJob(
            id: job.id, owner: liveOwner, expiresAt: Date().addingTimeInterval(90)
        )
        XCTAssertNotNil(claimed)

        // A second process racing on the same job loses while the lease is held.
        let secondClaim = try await database.claimCloudRestoreJob(
            id: job.id, owner: otherOwner, expiresAt: Date().addingTimeInterval(90)
        )
        XCTAssertNil(secondClaim)

        // A stale worker cannot write progress over the current owner.
        var staleCopy = claimed!
        staleCopy.completedFiles = 999
        staleCopy.lease = nil
        let staleWrite = try await database.upsertCloudRestoreJob(staleCopy, owner: otherOwner)
        XCTAssertFalse(staleWrite)

        // Heartbeat renews only for the owner.
        let renewedOwner = try await database.renewCloudRestoreLease(
            id: job.id, owner: liveOwner, expiresAt: Date().addingTimeInterval(90)
        )
        XCTAssertTrue(renewedOwner)
        let renewedOther = try await database.renewCloudRestoreLease(
            id: job.id, owner: otherOwner, expiresAt: Date().addingTimeInterval(90)
        )
        XCTAssertFalse(renewedOther)

        // Owner-checked progress write succeeds and preserves the lease.
        var progress = claimed!
        progress.completedFiles = 3
        let progressWrite = try await database.upsertCloudRestoreJob(progress, owner: liveOwner)
        XCTAssertTrue(progressWrite)
        let afterWrite = try await database.cloudRestoreJob(id: job.id)
        XCTAssertEqual(afterWrite?.lease?.owner.pid, liveOwner.pid)

        // Terminal jobs are never claimable again.
        var done = progress
        done.state = .completed
        let doneWrite = try await database.upsertCloudRestoreJob(done, owner: liveOwner)
        XCTAssertTrue(doneWrite)
        try await database.releaseCloudRestoreLease(id: job.id, owner: liveOwner)
        let terminalClaim = try await database.claimCloudRestoreJob(
            id: job.id, owner: otherOwner, expiresAt: Date().addingTimeInterval(90)
        )
        XCTAssertNil(terminalClaim)
    }

    // MARK: - CT-088 GC fails closed when the device directory is unreadable

    func testCT088_GCFailsClosedWhenDeviceDirectoryUnreadable() async throws {
        let cloud = try RegressionCloud(name: "ct088")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device, sweepGrace: 0)
        try cloud.workspace.writeFile("a.txt", "v1")
        _ = try await cloud.publish(store, deviceID: device)

        // `devices` becomes a regular file: contentsOfDirectory fails with
        // ENOTDIR. GC must abort with a skippedReason, never delete.
        let devicesURL = cloud.workspace.storageRoot.appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.removeItem(at: devicesURL)
        try "not a directory".write(to: devicesURL, atomically: true, encoding: .utf8)

        let objectsBefore = try cloud.workspace.objectFiles(deviceID: device, repositoryID: cloud.repositoryID)
        let report = try await store.cleanup(repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 1)
        XCTAssertNotNil(report.skippedReason, "设备目录不可读时 GC 必须暂停")
        XCTAssertEqual(report.deletedObjects, 0)
        XCTAssertEqual(
            try cloud.workspace.objectFiles(deviceID: device, repositoryID: cloud.repositoryID),
            objectsBefore,
            "fail-closed 的 GC 不得删除任何对象"
        )
    }

    // MARK: - CT-089 Device registry exists and multi-device GC stays blocked

    func testCT089_DeviceRegistryRecordedAndMultiDeviceGCStaysBlocked() async throws {
        let cloud = try RegressionCloud(name: "ct089")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device, sweepGrace: 0)
        try cloud.workspace.writeFile("a.txt", "v1")
        _ = try await cloud.publish(store, deviceID: device)

        // CT-089: publishing records a persistent device-info.json entry.
        let registryURL = cloud.workspace.storageRoot
            .appendingPathComponent("devices/\(device.uuidString)", isDirectory: true)
            .appendingPathComponent("device-info.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: registryURL.path), "发布后必须留下设备注册记录")
        let registryData = try Data(contentsOf: registryURL)
        let registry = try JSONSerialization.jsonObject(with: registryData) as? [String: String]
        XCTAssertEqual(registry?["deviceID"], device.uuidString)
        XCTAssertNotNil(registry?["lastSeenAt"])

        // An offline second device directory keeps physical GC blocked — even
        // with no manifests inside (its data may not have synced yet).
        let offlineDevice = cloud.workspace.storageRoot
            .appendingPathComponent("devices/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: offlineDevice, withIntermediateDirectories: true)
        let report = try await store.cleanup(repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 1)
        XCTAssertNotNil(report.skippedReason)
        XCTAssertTrue(report.skippedReason?.contains("多设备") == true, report.skippedReason ?? "")
        XCTAssertGreaterThan(
            try cloud.workspace.objectFiles(deviceID: device, repositoryID: cloud.repositoryID).count, 0,
            "多设备场景下对象必须全部保留"
        )
    }

    // MARK: - CT-090 Migration idempotency with residual request

    func testCT090_MigrationIsIdempotentAndResidualRequestNeverReplacesAgain() throws {
        let source = try makeBetaSource()
        let target = root.appendingPathComponent("release-ct90", isDirectory: true)
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)
        let first = try DataMigrator.performPending(target: target)
        XCTAssertGreaterThanOrEqual(first?.fileCount ?? 0, 2)

        // Post-migration sentinel data created in the Release root.
        let sentinel = target.appendingPathComponent("database/codetime.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        // CT-090: simulate a RESIDUAL request — the same request file that was
        // already answered (deletion failed after a successful migration). The
        // lifecycle-dir completion record must make the re-run a no-op and never
        // replace the now newer Release data.
        let lifecycleDir = target.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
        let completionURL = lifecycleDir.appendingPathComponent(DataMigrator.completionName)
        let completionData = try Data(contentsOf: completionURL)
        let completion = try XCTUnwrap(
            JSONSerialization.jsonObject(with: completionData) as? [String: Any]
        )
        let completedRequestID = try XCTUnwrap(completion["requestID"] as? String)
        // Recreate the request file with the ALREADY-COMPLETED request ID.
        let bookmark = try SecurityScopedBookmarks.makeBookmark(for: source)
        let residual = """
        {"id":"\(completedRequestID)","sourcePath":"\(source.path)",\
        "sourceBookmark":"\(bookmark.base64EncodedString())",\
        "createdAt":"2026-11-07T00:00:00Z","allowReplaceRoot":true}
        """
        try residual.write(
            to: lifecycleDir.appendingPathComponent(DataMigrator.requestName),
            atomically: true,
            encoding: .utf8
        )
        let second = try DataMigrator.performPending(target: target)
        XCTAssertNil(second, "同一 RequestID 的残留请求不得再次执行数据替换")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path), "Release 数据不得被覆盖")
        XCTAssertFalse(DataMigrator.hasPendingRequest(target: target), "残留请求应被清理")
    }

    // MARK: - CT-091 Status recompute follows the newest snapshot

    func testCT091_StatusRecomputeFollowsNewestSnapshotNotLateUpload() async throws {
        let service = try CodeTimeService(paths: try makePaths(), keychain: keychain)
        let database = service.database
        let project = Project(name: "CT091", rootPath: root.appendingPathComponent("proj").path)
        try await database.upsertProject(project)

        var older = Snapshot(
            id: "snap-old-\(UUID())", projectID: project.id,
            createdAt: Date().addingTimeInterval(-600), status: .complete,
            fileCount: 1, totalSize: 10
        )
        older.cloudState = .synced
        try await database.upsertSnapshot(older)

        var newer = Snapshot(
            id: "snap-new-\(UUID())", projectID: project.id,
            createdAt: Date(), status: .complete,
            fileCount: 2, totalSize: 20
        )
        newer.cloudState = .failed
        try await database.upsertSnapshot(newer)
        // Newest snapshot failed → warning, regardless of the older snapshot.
        await service.recomputeProjectStatus(projectID: project.id)
        let status1 = try await database.projects().first?.status
        XCTAssertEqual(status1, .warning)

        // The OLD snapshot's upload finishing LAST must not flip the status.
        try await database.updateSnapshotCloud(id: older.id, cloudState: .synced, cloudGenerationID: nil)
        await service.recomputeProjectStatus(projectID: project.id)
        let status3 = try await database.projects().first?.status
        XCTAssertEqual(status3, .warning, "旧快照上传成功不能覆盖最新快照的失败状态")

        // A live backup job pins .backingUp over everything.
        let owner = ProcessIdentity.current(isAgent: false)
        let claimed = try await database.claimBackupJob(
            projectID: project.id, retryJobID: nil, trigger: .manual,
            owner: owner, expiresAt: Date().addingTimeInterval(90)
        )
        XCTAssertNotNil(claimed)
        await service.recomputeProjectStatus(projectID: project.id)
        let status2 = try await database.projects().first?.status
        XCTAssertEqual(status2, .backingUp, "正在备份时状态必须钉在 backingUp")
    }

    // MARK: - CT-092 Regression gate covers every required CT

    func testCT092_RegressionGateCoversAllRequiredTests() throws {
        let gate = try String(contentsOf: repoScriptURL("regression_gate.sh"), encoding: .utf8)
        XCTAssertTrue(gate.contains("range(1, 117)"), "门禁必须按索引检查 CT-001…CT-116 全量编号")
        XCTAssertTrue(gate.contains("REGRESSION_INDEX.json"), "门禁必须由 REGRESSION_INDEX.json 驱动")
        let indexURL = repoScriptURL("../REGRESSION_INDEX.json").standardizedFileURL
        let indexData = try Data(contentsOf: indexURL)
        let index = try JSONSerialization.jsonObject(with: indexData) as? [[String: Any]]
        XCTAssertNotNil(index, "REGRESSION_INDEX.json 必须是数组")
        XCTAssertEqual(index?.count, 116, "回归索引必须登记 CT-001…CT-116")
        let ids = Set(index?.compactMap { $0["id"] as? String } ?? [])
        for number in 1...116 {
            let ctID = String(format: "CT-%03d", number)
            XCTAssertTrue(ids.contains(ctID), "\(ctID) missing from index")
        }
        // Every required entry's test must exist in the test sources.
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = try FileManager.default.contentsOfDirectory(atPath: testsDir.path)
            .filter { $0.hasSuffix(".swift") }
            .map { try String(contentsOf: testsDir.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        for entry in index ?? [] {
            guard entry["required"] as? Bool == true, let test = entry["test"] as? String else { continue }
            XCTAssertTrue(sources.contains("func \(test)()"), "必需测试 \(test) 必须存在于测试源码")
        }
    }

    // MARK: - CT-093 Coordinators drive the real service APIs

    func testCT093_CoordinatorsDriveRealServiceAPIs() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()
        let backup = BackupCoordinator(service)
        let restore = RestoreCoordinator(service)
        let publish = CloudPublishCoordinator(service)
        let verification = VerificationCoordinator(service)

        let source = root.appendingPathComponent("ct93-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "code\n".write(to: source.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let project = try await service.addProject(url: source)

        // Through the coordinator, not the service directly.
        let outcome = try await backup.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertEqual(outcome.snapshot.status, .complete)
        let listed = try await backup.snapshots(projectID: project.id)
        XCTAssertEqual(listed.count, 1)
        _ = try await restore.restoreJobs(limit: 10)
        let summary = try await publish.cloudSummary()
        _ = summary
        let verified = try await verification.verifySnapshot(projectID: project.id, snapshotID: outcome.snapshot.id)
        XCTAssertEqual(verified.outcome, .passed)
    }

    // MARK: - CT-094 Benchmark runs in an isolated child with real metrics

    func testCT094_BenchmarkRunsInIsolatedChildWithRealMetrics() throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let work = root.appendingPathComponent("bench-ct94", isDirectory: true)
        let out = try runChildChecked(["bench", work.path, "60"], timeout: 300)
        let metrics = try XCTUnwrap(perfMetrics(from: out), "子进程必须输出 PERF_METRICS")
        XCTAssertEqual(metrics["files"], "60")
        // CT-115: the dataset also contains an empty file, a hidden file, a
        // Unicode name and a symlink, all content-verified after restore.
        XCTAssertEqual(metrics["contentCheck"], "PASS", out)
        XCTAssertEqual(metrics["contentMismatches"], "0")
        XCTAssertGreaterThan(Double(metrics["cpuUserSec"] ?? "") ?? 0, 0, "CPU user 时间必须来自真实采样")
        XCTAssertGreaterThan(Double(metrics["kopiaChildCpuUserSec"] ?? "") ?? 0, 0, "必须单独采样 kopia 子进程 CPU（RUSAGE_CHILDREN）")
        let peak = Double(metrics["peakMemoryMB"] ?? "") ?? 0
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThan(peak, 8_192, "峰值内存是本进程真实峰值，不可能是历史累计")
        XCTAssertGreaterThanOrEqual(Int(metrics["snapshotFiles"] ?? "") ?? 0, 60)
    }

    // MARK: - CT-095 Medium-scale benchmark

    func testCT095_MediumScaleBenchmarkCompletes() throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let work = root.appendingPathComponent("bench-ct95", isDirectory: true)
        // CT-115: Medium scale = 10,000 files, content-verified by the child.
        let out = try runChildChecked(["bench", work.path, "10000"], timeout: 900)
        let metrics = try XCTUnwrap(perfMetrics(from: out))
        XCTAssertEqual(metrics["contentCheck"], "PASS", out)
        XCTAssertEqual(metrics["contentMismatches"], "0")
        XCTAssertGreaterThanOrEqual(Int(metrics["snapshotFiles"] ?? "") ?? 0, 10_000)
        XCTAssertGreaterThan(Int(metrics["backupDurationMs"] ?? "") ?? 0, 0)
        XCTAssertGreaterThan(Int(metrics["restoreDurationMs"] ?? "") ?? 0, 0)
    }

    // MARK: - CT-096 repositoryUsage fails closed and counts hidden files

    func testCT096_RepositoryUsageFailsClosedAndCountsHiddenFiles() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        let repos = paths.repositories
        try FileManager.default.createDirectory(at: repos.appendingPathComponent("r1/repo"), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1_000).write(
            to: repos.appendingPathComponent("r1/repo/visible.bin"), options: .atomic
        )
        // Hidden files ARE counted (consistent with the migration scan).
        try Data(repeating: 0x42, count: 500).write(
            to: repos.appendingPathComponent("r1/repo/.hidden"), options: .atomic
        )
        let usage = try await service.repositoryUsage()
        XCTAssertEqual(usage, 1_500, "可见与隐藏文件都必须计入")

        // A scan error makes the total UNKNOWN — never a partial number.
        try FileManager.default.createDirectory(at: repos.appendingPathComponent("r1/locked"), withIntermediateDirectories: true)
        try "x".write(to: repos.appendingPathComponent("r1/locked/file"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: repos.appendingPathComponent("r1/locked").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repos.appendingPathComponent("r1/locked").path) }
        // Structural change to the repositories root invalidates the usage cache
        // (CT-096: 仓库变化后缓存必须失效). Sleep past the 1s mtime granularity
        // so the change is observable.
        Thread.sleep(forTimeInterval: 1.1)
        try "invalidate".write(to: repos.appendingPathComponent(".cache-bust"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: repos.appendingPathComponent(".cache-bust"))
        let broken = try await service.repositoryUsage()
        XCTAssertNil(broken, "扫描错误必须返回未知，而不是部分结果")
    }

    // MARK: - CT-097 Upload job lease heartbeat and stale-owner protection

    func testCT097_UploadJobLeaseRequiresHeartbeatAndStaleOwnerCannotFinish() async throws {
        let database = try SQLiteStore(path: root.appendingPathComponent("db-\(UUID()).sqlite").path)
        let project = Project(name: "CT097", rootPath: root.appendingPathComponent("p").path)
        try await database.upsertProject(project)
        let job = BackupJob(projectID: project.id, type: .upload, state: .queued, trigger: .manual)
        try await database.upsertJob(job)

        let first = ProcessIdentity.current(isAgent: false)
        let second = ProcessIdentity(pid: first.pid + 88_888, startTime: 42.42, isAgent: false)

        let firstClaim = try await database.acquireJobLease(id: job.id, owner: first, expiresAt: Date().addingTimeInterval(90))
        XCTAssertNotNil(firstClaim)
        let racingClaim = try await database.acquireJobLease(id: job.id, owner: second, expiresAt: Date().addingTimeInterval(90))
        XCTAssertNil(racingClaim)

        // Heartbeat renews for the owner only.
        let renewed1 = try await database.renewJobLease(id: job.id, owner: first, expiresAt: Date().addingTimeInterval(90))
        XCTAssertTrue(renewed1)
        let renewed2 = try await database.renewJobLease(id: job.id, owner: second, expiresAt: Date().addingTimeInterval(90))
        XCTAssertFalse(renewed2)

        // Simulate owner death + expiry: the lease becomes reclaimable.
        // A PID that does not exist (and start time 1.0) → provably dead owner.
        let dead = ProcessIdentity(pid: 999_999_999, startTime: 1.0, isAgent: false)
        let expiredRow = try await database.job(id: job.id)
        var expiredJob = try XCTUnwrap(expiredRow)
        expiredJob.lease = JobLease(owner: dead, heartbeatAt: Date().addingTimeInterval(-600), leaseExpiresAt: Date().addingTimeInterval(-300))
        try await database.upsertJob(expiredJob)
        let reclaimed = try await database.acquireJobLease(id: job.id, owner: second, expiresAt: Date().addingTimeInterval(90))
        XCTAssertNotNil(reclaimed)

        // The stale owner can no longer finish the job it lost.
        try await database.finishJob(id: job.id, state: .succeeded, owner: first)
        let afterRow = try await database.job(id: job.id)
        let after = try XCTUnwrap(afterRow)
        XCTAssertEqual(after.state, .running, "旧 owner 不能覆盖新 owner 的任务状态")
    }

    // MARK: - CT-098 Real SIGKILL crash recovery at every migration phase

    func testCT098_MigrationSurvivesRealSIGKILLAtEveryPhase() throws {
        guard FileManager.default.fileExists(atPath: (try? crashChildURL().path) ?? "") else {
            throw XCTSkip("CodeTimeCrashChild 未构建")
        }
        // Second flag = whether the target's migration-complete.json must exist
        // at the crash position (the record is written AFTER the replace).
        let phases: [(String, Bool)] = [
            ("before-copy", false),   // staging may exist, target untouched
            ("during-copy", false),   // partial copy
            ("after-verify", false),  // staging verified, not installed
            ("before-replace", false),
            ("after-replace", false), // replaced, completion record NOT yet written
            ("after-complete", true), // everything done, request deletion pending
        ]
        for (phase, targetExpected) in phases {
            let source = try makeBetaSource()
            try "sentinel-\(phase)".write(
                to: source.appendingPathComponent("sentinel.txt"), atomically: true, encoding: .utf8
            )
            let target = root.appendingPathComponent("release-ct98-\(phase)", isDirectory: true)

            // Crash at the phase inside a REAL child process (SIGKILL).
            let (out, status) = try runChild(["migrate", source.path, target.path, phase], timeout: 120)
            // For an uncaught-signal death, terminationStatus IS the signal number.
            XCTAssertEqual(status, Int32(SIGKILL), "阶段 \(phase) 应以 SIGKILL 终止: out=\(out) status=\(status)")

            // Source must be intact — the migration never mutates the source.
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: source.appendingPathComponent("database/codetime.sqlite").path),
                "\(phase): 源数据必须完整"
            )
            // Target state must be one of the well-defined crash positions.
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: target.appendingPathComponent("migration-complete.json").path),
                targetExpected || phase == "after-complete",
                "\(phase): 目标完成记录状态必须与崩溃位置一致"
            )

            // Recovery: a fresh run must complete (or no-op) and never corrupt.
            DataMigrator.sourceAgentExitTimeout = 5
            let resumed = try DataMigrator.performPending(target: target)
            if phase == "after-complete" {
                XCTAssertNil(resumed, "\(phase): 已完成迁移的残留请求必须被识别为完成")
            } else {
                XCTAssertNotNil(resumed, "\(phase): 崩溃后重试必须完成迁移")
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: target.appendingPathComponent("database/codetime.sqlite").path),
                "\(phase): 恢复后目标必须有数据库"
            )
            let sentinelContent = try String(contentsOf: target.appendingPathComponent("sentinel.txt"), encoding: .utf8)
            XCTAssertEqual(
                sentinelContent.trimmingCharacters(in: .whitespacesAndNewlines),
                "sentinel-\(phase)",
                "\(phase): 数据必须完整无重复覆盖"
            )
            XCTAssertFalse(DataMigrator.hasPendingRequest(target: target), "\(phase): 请求文件最终必须被清理")
        }
    }

    private func perfMetrics(from output: String) -> [String: String]? {
        guard let range = output.range(of: "PERF_METRICS:") else { return nil }
        var metrics: [String: String] = [:]
        for line in output[range.upperBound...].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(":"), !trimmed.contains("PERF") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            metrics[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
        return metrics.isEmpty ? nil : metrics
    }
}
