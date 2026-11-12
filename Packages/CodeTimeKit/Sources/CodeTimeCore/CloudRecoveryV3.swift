import Foundation
import SharedModels
import BackupEngine
import CloudMirrorStore

/// One project discovered in a Cloud Format v3 container. Nothing here contains
/// file contents or project paths — v3 never stores those in discoverable form.
public struct V3RecoveryProject: Sendable, Equatable, Identifiable {
    public var projectID: UUID
    public var sourceDeviceID: String
    public var snapshotCount: Int
    public var latestSnapshotID: String?
    public var latestBackupAt: Date?
    public var latestFileCount: Int
    public var latestBytes: Int64
    public var restorable: Bool
    public var detail: String

    /// The same project may continue on two devices; both histories stay
    /// selectable, so identity includes the device namespace.
    public var id: String { "\(sourceDeviceID)-\(projectID.uuidString)" }
}

/// New-Mac discovery for Cloud Format v3 (§9.5).
///
/// Scans `v3/devices/<device>/projects/<project>/snapshots/*.commit`, then proves
/// the newest version is actually readable: the manifest must hash to the commit
/// value, decrypt with the recovery key, and describe a consistent tree. Only
/// projects that pass are offered for restore.
public enum CloudRecoveryV3 {
    public static func scan(root: URL, masterKey: Data) async throws -> [V3RecoveryProject] {
        let fm = FileManager.default
        let devicesRoot = root.appendingPathComponent("devices", isDirectory: true)
        guard fm.fileExists(atPath: devicesRoot.path) else { return [] }
        let devices = (try? fm.contentsOfDirectory(
            at: devicesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []

        var results: [V3RecoveryProject] = []
        for deviceURL in devices where (try? deviceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let deviceID = deviceURL.lastPathComponent
            let projectsRoot = deviceURL.appendingPathComponent("projects", isDirectory: true)
            let projectDirs = (try? fm.contentsOfDirectory(
                at: projectsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            for projectURL in projectDirs {
                guard let projectID = UUID(uuidString: projectURL.lastPathComponent) else { continue }
                let store = CloudObjectStoreV3(root: root, deviceID: deviceID, masterKey: masterKey)
                let commits: [SnapshotCommit]
                do {
                    commits = try await store.strictCommits(projectID: projectID)
                } catch {
                    results.append(V3RecoveryProject(
                        projectID: projectID,
                        sourceDeviceID: deviceID,
                        snapshotCount: 0,
                        latestSnapshotID: nil,
                        latestBackupAt: nil,
                        latestFileCount: 0,
                        latestBytes: 0,
                        restorable: false,
                        detail: "提交标记不可读：\(error)"
                    ))
                    continue
                }
                guard let latest = commits.max(by: { $0.committedAt < $1.committedAt }) else {
                    continue
                }
                var restorable = true
                var detail = "可恢复"
                do {
                    let reader = CloudRestoreEngine(masterKey: masterKey, source: store)
                    let manifest = try await reader.loadManifest(
                        projectID: projectID,
                        snapshotID: latest.snapshotID
                    )
                    guard manifest.digestMatches else {
                        throw CloudRestoreError.manifestCorrupt
                    }
                } catch {
                    restorable = false
                    detail = "最新版本不可读：\(error)"
                }
                if restorable,
                   let blocked = try? await store.blockedSnapshotIDs(),
                   blocked.contains(latest.snapshotID) {
                    restorable = false
                    detail = "最新版本处于 GC 清理屏障中，恢复已阻止"
                }
                results.append(V3RecoveryProject(
                    projectID: projectID,
                    sourceDeviceID: deviceID,
                    snapshotCount: commits.count,
                    latestSnapshotID: latest.snapshotID,
                    latestBackupAt: latest.committedAt,
                    latestFileCount: latest.fileCount,
                    latestBytes: latest.totalBytes,
                    restorable: restorable,
                    detail: detail
                ))
            }
        }
        return results.sorted {
            ($0.latestBackupAt ?? .distantPast) > ($1.latestBackupAt ?? .distantPast)
        }
    }

    /// All committed versions for one project, newest first. The recovery UI uses
    /// this to offer a time point instead of only "latest".
    public static func snapshots(
        root: URL,
        deviceID: String,
        projectID: UUID,
        masterKey: Data
    ) async throws -> [SnapshotCommit] {
        let store = CloudObjectStoreV3(root: root, deviceID: deviceID, masterKey: masterKey)
        return try await store.strictCommits(projectID: projectID)
            .sorted { $0.committedAt > $1.committedAt }
    }
}
