import Foundation
import SharedModels

/// Rebuilds the repository record from the on-disk directory when SQLite is lost.
/// A missing database must not turn an existing backup repository into an orphan and
/// create a new empty one.
public enum RepositoryDiscovery {
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
