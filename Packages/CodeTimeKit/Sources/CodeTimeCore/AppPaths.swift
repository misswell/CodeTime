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

    public init(root: URL) {
        self.root = root
        self.database = root.appendingPathComponent("database/codetime.sqlite")
        self.repositories = root.appendingPathComponent("repositories", isDirectory: true)
        self.cache = root.appendingPathComponent("cache", isDirectory: true)
        self.spool = root.appendingPathComponent("spool", isDirectory: true)
        self.logs = root.appendingPathComponent("logs", isDirectory: true)
        self.recovery = root.appendingPathComponent("recovery", isDirectory: true)
        self.schedulerLock = root.appendingPathComponent("scheduler.lock")
        self.agentLock = root.appendingPathComponent("agent.lock")
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
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
