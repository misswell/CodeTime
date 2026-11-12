import XCTest
import Foundation

/// CT-230…CT-233: the revised release gate is single-Mac only. It must reject
/// missing evidence, multiple hosts, and hand-written PASS reports.
final class SingleMacAcceptanceEvidenceTests: XCTestCase {
    private var workspace: URL!
    private let candidate = String(repeating: "a", count: 64)
    private let commit = String(repeating: "b", count: 40)

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-mac-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let scenarios = [
        "backup_created", "upload_confirmed", "app_restart", "cache_cleared",
        "redownload_from_icloud", "restore_to_new_directory", "sha256_all_files",
        "metadata_and_symlinks", "upload_interruption", "upload_crash_recovery",
        "restore_interruption", "gc_safe_single_device", "space_management",
    ]

    private func assertions(_ scenario: String) -> [String: Any] {
        switch scenario {
        case "backup_created": return ["commit_published": true]
        case "upload_confirmed": return ["upload_confirmed": true, "pending_tasks": 0]
        case "app_restart": return ["snapshot_readable_after_restart": true]
        case "cache_cleared": return ["cache_bytes": 0]
        case "redownload_from_icloud": return ["redownloaded": true]
        case "restore_to_new_directory": return ["restored_files": 3, "expected_files": 3]
        case "sha256_all_files": return ["sha256_all": true, "checked_files": 3, "expected_files": 3]
        case "metadata_and_symlinks": return ["modes": true, "mtimes": true, "symlinks": true]
        case "upload_interruption":
            return ["snapshot_not_published": true, "spool_preserved": true, "retry_completed": true]
        case "upload_crash_recovery":
            return ["journal_recovered": true, "no_duplicate_upload": true]
        case "restore_interruption":
            return ["partial_rejected": true, "resume_completed": true]
        case "gc_safe_single_device":
            return [
                "active_restore_blocks_delete": true,
                "referenced_objects_protected": true,
                "pack_protected": true,
                "incomplete_reference_aborts": true,
                "resume_idempotent": true,
            ]
        case "space_management":
            return ["spool_within_budget": true, "cache_within_budget": true, "locks_bounded": true]
        default: return [:]
        }
    }

    private func writeEvidence(
        into directory: URL,
        omitting: String? = nil,
        host: String = "Mac-A",
        device: String = "device-A",
        evidenceKind: String = "real"
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scenario in scenarios where scenario != omitting {
            let entry: [String: Any] = [
                "scenario": scenario,
                "result": "passed",
                "device_id": device,
                "host": host,
                "model": "MacBookPro18,3",
                "macOS": "27.2.1",
                "app_version": "1.0.0",
                "candidate_sha256": candidate,
                "commit": commit,
                "evidence_kind": evidenceKind,
                "started_at": "2026-11-12T00:00:00Z",
                "finished_at": "2026-11-12T00:01:00Z",
                "assertions": assertions(scenario),
            ]
            try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("\(scenario).json"))
        }
    }

    private func makeReport(
        _ evidence: URL,
        allowFixture: Bool = false
    ) throws -> (status: Int32, output: String, url: URL) {
        let report = workspace.appendingPathComponent("report-\(UUID().uuidString).md")
        let result = try run([
            repoRoot.appendingPathComponent("Scripts/single_mac_acceptance.sh").path,
            "report",
            "--evidence-dir", evidence.path,
            "--tag", "v1.0.0",
            "--commit", commit,
            "--candidate-sha", candidate,
            "--candidate-name", "CodeTime-1.0.0-macos-universal.zip",
            "--run", "12345",
            "--operator", "tester",
            "--out", report.path,
        ], environment: allowFixture ? ["SINGLE_MAC_ACCEPTANCE_ALLOW_FIXTURE": "1"] : [:])
        return (result.status, result.output, report)
    }

    func testCT230_MissingSingleMacScenarioBlocksReport() throws {
        let evidence = workspace.appendingPathComponent("evidence", isDirectory: true)
        try writeEvidence(into: evidence, omitting: "gc_safe_single_device")
        let result = try makeReport(evidence)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("missing scenarios"), result.output)
        XCTAssertTrue(result.output.contains("gc_safe_single_device"), result.output)
    }

    func testCT231_TwoHostsCannotPassSingleMacGate() throws {
        let evidence = workspace.appendingPathComponent("evidence", isDirectory: true)
        try writeEvidence(into: evidence, host: "Mac-A")
        let duplicate: [String: Any] = [
            "scenario": "backup_created",
            "result": "passed",
            "device_id": "device-B",
            "host": "Mac-B",
            "model": "MacBookPro18,3",
            "macOS": "27.2.1",
            "app_version": "1.0.0",
            "candidate_sha256": candidate,
            "commit": commit,
            "evidence_kind": "real",
            "started_at": "2026-11-12T00:00:00Z",
            "finished_at": "2026-11-12T00:01:00Z",
            "assertions": assertions("backup_created"),
        ]
        try JSONSerialization.data(withJSONObject: duplicate, options: [.sortedKeys])
            .write(to: evidence.appendingPathComponent("backup_created-other.json"))
        let result = try makeReport(evidence)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("duplicate") || result.output.contains("exactly one host"),
                      result.output)
    }

    func testCT232_CompleteSingleMacEvidenceGeneratesReportAndPassesGate() throws {
        let evidence = workspace.appendingPathComponent("evidence", isDirectory: true)
        try writeEvidence(into: evidence)
        let result = try makeReport(evidence)
        XCTAssertEqual(result.status, 0, result.output)
        let report = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(report.contains("- Mac：Mac-A / 设备 device-A / App 1.0.0"))
        XCTAssertTrue(report.contains("多设备能力不在本次发布范围内"))
        for scenario in scenarios {
            XCTAssertTrue(report.contains("| \(scenario) |"), "报告缺少 \(scenario)")
        }

        let gate = try run(
            [repoRoot.appendingPathComponent("Scripts/require_single_mac_acceptance.sh").path, "v1.0.0"],
            environment: [
                "SINGLE_MAC_ACCEPTANCE_REPORT": result.url.path,
                "SINGLE_MAC_ACCEPTANCE_EVIDENCE_DIR": evidence.path,
                "GITHUB_SHA": commit,
                "EXPECTED_ARTIFACT_SHA": candidate,
            ]
        )
        XCTAssertEqual(gate.status, 0, gate.output)
    }

    func testCT257_FixtureEvidenceCannotPassReleaseGate() throws {
        let evidence = workspace.appendingPathComponent("fixture-evidence", isDirectory: true)
        try writeEvidence(into: evidence, evidenceKind: "fixture")
        let report = try makeReport(evidence, allowFixture: true)
        XCTAssertEqual(report.status, 0, report.output)
        let gate = try run(
            [repoRoot.appendingPathComponent("Scripts/require_single_mac_acceptance.sh").path, "v1.0.0"],
            environment: [
                "SINGLE_MAC_ACCEPTANCE_REPORT": report.url.path,
                "SINGLE_MAC_ACCEPTANCE_EVIDENCE_DIR": evidence.path,
                "GITHUB_SHA": commit,
                "EXPECTED_ARTIFACT_SHA": candidate,
            ]
        )
        XCTAssertNotEqual(gate.status, 0)
        XCTAssertTrue(gate.output.contains("fixture evidence"), gate.output)
    }

    func testCT233_HandWrittenPassWithoutEvidenceIsRejected() throws {
        let report = workspace.appendingPathComponent("manual.md")
        let text = """
        - 发布 tag：v1.0.0
        - 构建 commit：\(commit)
        - Candidate Artifact：CodeTime-1.0.0-macos-universal.zip
        - Candidate Artifact SHA-256：\(candidate)
        - 执行时间：2026-11-12 00:00:00
        - 执行人：tester
        - Mac：Mac-A / 设备 device-A / App 1.0.0
        - 场景证据目录：\(workspace.path)
        本次发布只验收单 Mac + iCloud Drive；多设备能力不在本次发布范围内。
        | backup_created | fake | PASS |
        - 结果：PASS
        """
        try text.write(to: report, atomically: true, encoding: .utf8)
        let gate = try run(
            [repoRoot.appendingPathComponent("Scripts/require_single_mac_acceptance.sh").path, "v1.0.0"],
            environment: ["SINGLE_MAC_ACCEPTANCE_REPORT": report.path]
        )
        XCTAssertNotEqual(gate.status, 0)
        XCTAssertTrue(gate.output.contains("缺少场景证据"), gate.output)
    }

    private func run(_ command: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = command
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        env.removeValue(forKey: "GITHUB_SHA")
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
