import Foundation
import SharedModels

/// Read-only Git inspection. This type never runs commands that can change the
/// working tree (no commit/stash/checkout/reset).
public struct GitInspector: GitCapturing, Sendable {
    public init() {}

    public func capture(repositoryPath: String) -> GitMetadata? {
        guard let git = Self.gitBinary else { return nil }
        let root = URL(fileURLWithPath: repositoryPath)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            // Worktrees use a .git file; rev-parse resolves them correctly.
            guard let gitDir = run(git, ["-C", repositoryPath, "rev-parse", "--git-dir"]),
                  !gitDir.isEmpty else { return nil }
            return metadata(git: git, path: repositoryPath)
        }
        return metadata(git: git, path: repositoryPath)
    }

    private func metadata(git: URL, path: String) -> GitMetadata? {
        guard let branch = run(git, ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]) else { return nil }
        let head = run(git, ["-C", path, "rev-parse", "--short", "HEAD"])
        let status = run(git, ["-C", path, "status", "--porcelain", "--untracked-files=normal"]) ?? ""
        let lines = status.split(separator: "\n")
        let untracked = lines.contains { $0.hasPrefix("??") }
        return GitMetadata(
            branch: branch.isEmpty ? nil : branch,
            head: head?.isEmpty == true ? nil : head,
            isDirty: !lines.isEmpty,
            hasUntrackedFiles: untracked
        )
    }

    private func run(_ git: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-git-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        process.standardOutput = handle

        do { try process.run() } catch {
            try? handle.close()
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            try? handle.close()
            return nil
        }
        try? handle.close()
        let data = (try? Data(contentsOf: tempURL)) ?? Data()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var gitBinary: URL? {
        for path in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
