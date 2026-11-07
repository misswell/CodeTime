import Foundation
import SharedModels

public struct AppPaths: Sendable {
    public let root: URL
    public let database: URL
    public let repositories: URL
    public let cache: URL
    public let spool: URL
    public let logs: URL
    public let recovery: URL
    public let schedulerLock: URL
    public let agentLock: URL
    /// Stable directory outside `root` that survives `replaceItemAt(root, …)`.
    /// Lifecycle coordination locks and migration journal files live here.
    public let lifecycleDir: URL
    public let migrationLock: URL
    public let migrationRequest: URL
    /// The unified shared/exclusive lifecycle lock file path.
    public let lifecycleLockPath: URL

    public init(root: URL) {
        self.root = root
        self.database = root.appendingPathComponent("database/codetime.sqlite")
        self.repositories = root.appendingPathComponent("repositories", isDirectory: true)
        self.cache = root.appendingPathComponent("cache", isDirectory: true)
        self.spool = root.appendingPathComponent("spool", isDirectory: true)
        self.logs = root.appendingPathComponent("logs", isDirectory: true)
        self.recovery = root.appendingPathComponent("recovery", isDirectory: true)
        // Lifecycle locks live OUTSIDE the replaceable data root so they survive
        // a whole-root swap during Beta → Release migration.
        self.lifecycleDir = root.deletingLastPathComponent()
            .appendingPathComponent("CodeTime-lifecycle", isDirectory: true)
        self.schedulerLock = lifecycleDir.appendingPathComponent("scheduler.lock")
        self.agentLock = lifecycleDir.appendingPathComponent("agent.lock")
        self.migrationLock = lifecycleDir.appendingPathComponent("migration.lock")
        self.migrationRequest = lifecycleDir.appendingPathComponent("migration-request.json")
        self.lifecycleLockPath = lifecycleDir.appendingPathComponent("lifecycle.lock")
    }

    public static func standard() throws -> AppPaths {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CodeTimeError.repositoryUnavailable("无法定位 Application Support")
        }
        return AppPaths(root: base.appendingPathComponent("CodeTime", isDirectory: true))
    }

    public func createDirectories() throws {
        let fileManager = FileManager.default
        for directory in [
            root,
            database.deletingLastPathComponent(),
            repositories,
            cache,
            spool,
            logs,
            recovery,
            lifecycleDir,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
