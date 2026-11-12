import XCTest
import Foundation

/// CT-197…CT-200: the dual-Mac report is generated from per-scenario evidence;
/// a missing scenario, same host, hash mismatch or incomplete restore must block
/// the release instead of becoming a hardcoded PASS.
final class ICloudAcceptanceEvidenceTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("acceptance-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    func testCT197_MissingScenarioEvidenceBlocksReport() throws {
        let evidence = workspace.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try makeEvidenceSet(into: evidence, omitting: "gc_barrier")
        let a = try writeAB(host: "Mac-A", fileCount: 2)
        let b = try writeAB(host: "Mac-B", fileCount: 2, verified: true)
        let result = try runReport(a: a, b: b, evidence: evidence)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("missing scenario evidence"), result.output)
        XCTAssertTrue(result.output.contains("gc_barrier"), result.output)
    }

    func testCT198_SameHostCannotPassDualMacAcceptance() throws {
        let evidence = workspace.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try makeEvidenceSet(into: evidence, host: "same-host")
        let a = try writeAB(host: "same-host", fileCount: 2)
        let b = try writeAB(host: "same-host", fileCount: 2, verified: true)
        let result = try runReport(a: a, b: b, evidence: evidence)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("different hosts"), result.output)
    }

    func testCT199_CandidateHashMismatchAndIncompleteRestoreBlock() throws {
        let evidence = workspace.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try makeEvidenceSet(into: evidence, brokenScenario: "full_restore")
        let a = try writeAB(host: "Mac-A", fileCount: 2)
        let b = try writeAB(host: "Mac-B", fileCount: 2, verified: true)
        let result = try runReport(a: a, b: b, evidence: evidence)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("full_restore"), result.output)

        let evidence2 = workspace.appendingPathComponent("evidence2", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence2, withIntermediateDirectories: true)
        try makeEvidenceSet(into: evidence2, candidateSHA: String(repeating: "f", count: 64))
        let result2 = try runReport(a: a, b: b, evidence: evidence2)
        XCTAssertNotEqual(result2.status, 0)
        XCTAssertTrue(result2.output.contains("candidate hash mismatch"), result2.output)
    }

    func testCT200_RecordProducesStructuredEvidenceAndReportIsNotHardcoded() throws {
        let script = repoRoot.appendingPathComponent("Scripts/icloud_acceptance.sh").path
        let out = workspace.appendingPathComponent("first.json")
        let record = try run([script, "record",
            "--scenario", "first_backup",
            "--result", "passed",
            "--device-id", "device-A",
            "--host", "Mac-A",
            "--candidate-sha", String(repeating: "a", count: 64),
            "--commit", String(repeating: "b", count: 40),
            "--assertions", #"{"upload_confirmed":true,"spool_empty":true}"#,
            "--out", out.path])
        XCTAssertEqual(record.status, 0, record.output)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
        )
        XCTAssertEqual(json["scenario"] as? String, "first_backup")
        XCTAssertEqual(json["result"] as? String, "passed")
        XCTAssertEqual((json["assertions"] as? [String: Any])?["upload_confirmed"] as? Bool, true)

        // A report with the old hardcoded table but no evidence directory is refused.
        let report = workspace.appendingPathComponent("report.md")
        let a = try writeAB(host: "Mac-A", fileCount: 2)
        let b = try writeAB(host: "Mac-B", fileCount: 2, verified: true)
        let refused = try runReport(a: a, b: b, evidence: workspace.appendingPathComponent("missing"))
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertTrue(refused.output.contains("missing scenario evidence dir")
            || refused.output.contains("missing"), refused.output)
    }

    // MARK: - Fixtures

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var commit: String { String(repeating: "b", count: 40) }
    private var candidate: String { String(repeating: "a", count: 64) }

    private func scenarioAssertions(_ scenario: String) -> [String: Any] {
        switch scenario {
        case "first_backup":
            return ["upload_confirmed": true, "spool_empty": true]
        case "cross_device_discovery":
            return ["discovered": true]
        case "metadata_only_read":
            return ["object_body_downloaded": false]
        case "repeat_backup":
            return ["no_redownload": true]
        case "interrupted_upload":
            return ["snapshot_not_published": true, "spool_preserved": true]
        case "upload_recovery":
            return ["retry_completed": true]
        case "full_restore":
            return ["verified": true, "checked_files": 2, "expected_files": 2]
        case "wrong_key":
            return ["blocked": true]
        case "gc_barrier":
            return ["restore_blocked": true, "ack_durable": true]
        case "gc_resume":
            return ["resumed": true]
        case "migration":
            return ["legacy_readable": true]
        default:
            return [:]
        }
    }

    private let scenarios = [
        "first_backup", "cross_device_discovery", "metadata_only_read",
        "repeat_backup", "interrupted_upload", "upload_recovery",
        "full_restore", "wrong_key", "gc_barrier", "gc_resume", "migration",
    ]

    private func makeEvidenceSet(
        into directory: URL,
        host: String? = nil,
        omitting: String? = nil,
        brokenScenario: String? = nil,
        candidateSHA: String? = nil
    ) throws {
        for (index, scenario) in scenarios.enumerated() where scenario != omitting {
            var assertions = scenarioAssertions(scenario)
            if scenario == brokenScenario {
                assertions["verified"] = false
            }
            let record: [String: Any] = [
                "scenario": scenario,
                "result": "passed",
                "device_id": "device-\(index % 2 == 0 ? "A" : "B")",
                "host": host ?? "Mac-\(index % 2 == 0 ? "A" : "B")",
                "model": "MacBookPro18,3",
                "macOS": "27.2.1",
                "app_version": "1.0.0",
                "candidate_sha256": candidateSHA ?? candidate,
                "commit": commit,
                "started_at": "2026-11-12T00:00:00Z",
                "finished_at": "2026-11-12T00:01:00Z",
                "assertions": assertions,
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("\(scenario).json"))
        }
    }

    private func writeAB(host: String, fileCount: Int, verified: Bool = false) throws -> URL {
        let payload: [String: Any] = [
            "host": host,
            "model": "MacBookPro18,3",
            "macOS": "27.2.1",
            "fileCount": fileCount,
            "expectedFiles": fileCount,
            "checkedFiles": verified ? fileCount : 0,
            "verified": verified,
            "generatedAt": "2026-11-12T00:00:00Z",
            "missing": [],
            "mismatched": [],
        ]
        let url = workspace.appendingPathComponent("\(host)-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: url)
        return url
    }

    private func runReport(a: URL, b: URL, evidence: URL) throws -> (status: Int32, output: String) {
        try run([repoRoot.appendingPathComponent("Scripts/icloud_acceptance.sh").path,
            "report",
            "--a", a.path,
            "--b", b.path,
            "--evidence-dir", evidence.path,
            "--tag", "v1.0.0",
            "--commit", commit,
            "--candidate-sha", candidate,
            "--candidate-name", "CodeTime-1.0.0-macos-universal.zip",
            "--run", "12345",
            "--operator", "tester",
            "--out", workspace.appendingPathComponent("report-\(UUID().uuidString).md").path])
    }

    private func run(_ command: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = command
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GITHUB_SHA")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
