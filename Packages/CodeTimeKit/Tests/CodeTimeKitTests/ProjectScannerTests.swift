import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-153: project scanning — exclusions, symlink policy, identity-based
/// incremental detection and honest reporting of unreadable trees.
final class ProjectScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src/util"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        try Data("main".utf8).write(to: root.appendingPathComponent("src/main.swift"))
        try Data("helper".utf8).write(to: root.appendingPathComponent("src/util/helper.swift"))
        try Data("readme".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".env"))
        try Data("dep".utf8).write(to: root.appendingPathComponent("node_modules/pkg/index.js"))
        try Data("object".utf8).write(to: root.appendingPathComponent(".git/objects/ab"))
        try Record.redirectIfPossible(root.appendingPathComponent("src/link.swift"), to: "main.swift")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private enum Record {
        static func redirectIfPossible(_ url: URL, to target: String) {
            try? FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
    }

    private func matcher() -> ExclusionMatcher {
        ExclusionMatcher(rules: ExclusionPresets.defaultRules(), includeEnvFiles: false, includeGitDirectory: false)
    }

    func testCT153_ScanAppliesExclusionsAndKeepsStructure() throws {
        let scanner = ProjectScanner(matcher: matcher())
        let result = scanner.scan(root: root)

        let paths = Set(result.entries.map(\.path))
        XCTAssertTrue(paths.contains("src/main.swift"))
        XCTAssertTrue(paths.contains("src/util/helper.swift"))
        XCTAssertTrue(paths.contains("README.md"))
        XCTAssertFalse(paths.contains(".env"), "敏感配置文件默认必须排除")
        XCTAssertFalse(paths.contains("node_modules/pkg/index.js"), "node_modules 必须排除")
        XCTAssertFalse(paths.contains(".git/objects/ab"), "关闭 .git 后不得备份")
        XCTAssertTrue(paths.contains("empty"), "空目录必须保留（可恢复结构）")

        // Excluded content is counted so the UI can be honest about it.
        XCTAssertGreaterThanOrEqual(result.excludedCount, 3)
        XCTAssertGreaterThan(result.excludedBytes, 0)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.fileCount, 4, "文件数为 4（main/helper/link/README），目录不计入")
    }

    func testCT153_SymlinksAreRecordedNotFollowed() throws {
        let scanner = ProjectScanner(matcher: matcher())
        let result = scanner.scan(root: root)
        guard let link = result.entries.first(where: { $0.path == "src/link.swift" }) else {
            throw XCTSkip("当前文件系统不支持符号链接")
        }
        XCTAssertEqual(link.kind, .symlink)
        XCTAssertEqual(link.linkTarget, "main.swift", "必须记录链接目标而不是跟随")
        XCTAssertEqual(link.size, Int64("main.swift".utf8.count))
    }

    func testCT153_IncrementalChangeSetDetectsEditsAndDeletions() throws {
        let scanner = ProjectScanner(matcher: matcher())
        let first = scanner.scan(root: root)
        var identities: [String: FileIdentity] = [:]
        for entry in first.entries where entry.kind != .directory {
            identities[entry.path] = entry.identity
        }

        // No change → everything reused.
        let unchangedSet = scanner.changeSet(scan: scanner.scan(root: root), previousIdentities: identities)
        XCTAssertTrue(unchangedSet.changed.isEmpty, "无变化时不得重算任何文件")
        XCTAssertTrue(unchangedSet.removed.isEmpty)
        XCTAssertEqual(unchangedSet.unchanged.count, identities.count)

        // Edit one file, delete another.
        try Data("main-v2".utf8).write(to: root.appendingPathComponent("src/main.swift"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("README.md"))
        let second = scanner.scan(root: root)
        let changeSet = scanner.changeSet(scan: second, previousIdentities: identities)
        XCTAssertEqual(changeSet.changed.map(\.path), ["src/main.swift"])
        XCTAssertEqual(changeSet.removed, ["README.md"])
        XCTAssertTrue(changeSet.unchanged.contains { $0.path == "src/util/helper.swift" })
    }

    func testCT153_UnreadableDirectoryMarksScanIncomplete() throws {
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("inside.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let scanner = ProjectScanner(matcher: matcher())
        let result = scanner.scan(root: root)
        if getuid() == 0 {
            throw XCTSkip("root 不受权限限制")
        }
        XCTAssertFalse(result.isComplete, "无法读取的子树必须让扫描标记为不完整")
        XCTAssertFalse(result.permissionErrors.isEmpty)
    }

    func testCT153_MaxFilesTruncatesAndSaysSo() throws {
        let scanner = ProjectScanner(matcher: matcher(), options: ScanOptions(maxFiles: 2))
        let result = scanner.scan(root: root)
        XCTAssertLessThanOrEqual(result.entries.count, 3)
        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.truncatedReason)
    }

    func testCT153_IdentityIsStableForUntouchedFileAndChangesOnEdit() throws {
        let url = root.appendingPathComponent("src/main.swift")
        let before = try XCTUnwrap(ProjectScanner.identity(of: url))
        let again = try XCTUnwrap(ProjectScanner.identity(of: url))
        XCTAssertEqual(before, again)

        try Data("changed-content".utf8).write(to: url)
        let after = try XCTUnwrap(ProjectScanner.identity(of: url))
        XCTAssertNotEqual(before, after, "内容/大小变化必须改变身份")
        XCTAssertEqual(after.size, Int64("changed-content".utf8.count))
    }
}
