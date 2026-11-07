import Foundation
import SharedModels

/// Rebuilds the repository record from the on-disk directory when SQLite is lost.
/// A missing database must not turn an existing backup repository into an orphan and
/// create a new empty one.
public enum RepositoryDiscovery {
    /// Chooses a repository without ever silently switching a registered ID.
    /// Returns nil only when no repository exists at all.
    public static func select(
        stored: RepositoryRecord?,
        discovered: [RepositoryRecord]
    ) throws -> RepositoryRecord? {
        if let stored {
            if let matching = discovered.first(where: { $0.id == stored.id }) {
                return matching
            }
            if !discovered.isEmpty {
                throw CodeTimeError.repositoryUnavailable(
                    "已登记仓库丢失，同时发现不同 ID 的本地仓库；请手动选择，CodeTime 不会自动切换"
                )
            }
            return stored
        }
        if discovered.count > 1 {
            throw CodeTimeError.repositoryUnavailable(
                "发现多个本地备份仓库，请先移走不需要的目录，避免误连到错误的仓库"
            )
        }
        return discovered.first
    }

    public static func discover(in repositoriesRoot: URL) throws -> [RepositoryRecord] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: repositoriesRoot.path) else { return [] }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: repositoriesRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: []
            )
        } catch {
            throw CodeTimeError.repositoryUnavailable(
                "无法读取本地仓库目录：\(error.localizedDescription)"
            )
        }

        var records: [RepositoryRecord] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            guard let directoryID = UUID(uuidString: child.lastPathComponent) else { continue }

            let metadataURL = child.appendingPathComponent("repository.json")
            var metadata: RepositoryMetadata?
            if let data = try? Data(contentsOf: metadataURL) {
                metadata = try? JSONDecoder().decode(RepositoryMetadata.self, from: data)
            }
            let repositoryID = metadata?.repositoryID ?? directoryID
            guard repositoryID == directoryID else { continue }

            let repositoryURL = child.appendingPathComponent("repo", isDirectory: true)
            let configURL = child.appendingPathComponent("kopia.config")
            let repoExists = fileManager.fileExists(atPath: repositoryURL.path)
            let configExists = fileManager.fileExists(atPath: configURL.path)
            guard repoExists || configExists else { continue }

            records.append(RepositoryRecord(
                id: repositoryID,
                path: repositoryURL.path,
                configPath: configURL.path,
                createdAt: metadata?.createdAt
                    ?? (try? child.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    ?? Date(),
                metadata: metadata
            ))
        }
        return records
    }
}
