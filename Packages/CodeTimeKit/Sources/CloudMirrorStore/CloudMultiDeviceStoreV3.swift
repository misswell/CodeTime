import Foundation
import SharedModels

/// Read side of Cloud Format v3 across every device namespace.
///
/// Writes always go to this Mac's namespace, but a recovered project's history
/// lives in the namespace of the device that wrote it. Reads therefore search the
/// local namespace first and then the other devices; nodes and objects are
/// content addressed, so finding the same ID in any namespace is the same bytes.
public actor CloudMultiDeviceStoreV3: CloudObjectSource {
    private let root: URL
    private let localDeviceID: String
    private let masterKey: Data
    private let access: CloudFileAccess
    private let tracker: CloudUploadTracking
    private let eviction: ICloudEvictionManager?
    private let leaseManager: LocalCopyLeaseManager
    private let cloudAccess: CloudAccessCoordinator
    /// A device list is a cache with a short lifetime, not a session constant:
    /// another Mac may come online, be reset, or disappear while this process runs.
    private let deviceListTTL: TimeInterval
    private var deviceIDs: [String]?
    private var deviceListLoadedAt: Date?
    private var snapshotDevices: [String: String] = [:]

    public init(
        root: URL,
        localDeviceID: String,
        masterKey: Data,
        access: CloudFileAccess = LocalFileAccess(),
        tracker: CloudUploadTracking = NoopUploadTracker(),
        eviction: ICloudEvictionManager? = nil,
        deviceListTTL: TimeInterval = 60
    ) {
        self.root = root
        self.localDeviceID = localDeviceID
        self.masterKey = masterKey
        self.access = access
        self.tracker = tracker
        self.eviction = eviction
        self.leaseManager = LocalCopyLeaseManager()
        self.cloudAccess = CloudAccessCoordinator(
            access: access,
            tracker: tracker,
            eviction: eviction,
            leaseManager: leaseManager,
            expectsUbiquitous: eviction != nil
        )
        self.deviceListTTL = max(0, deviceListTTL)
    }

    private func store(deviceID: String) -> CloudObjectStoreV3 {
        CloudObjectStoreV3(
            root: root,
            deviceID: deviceID,
            masterKey: masterKey,
            access: access,
            tracker: tracker,
            eviction: eviction,
            leaseManager: leaseManager
        )
    }

    /// Re-reads the device directory. A failure never replaces a usable cached
    /// list with an empty one, and an empty successful listing is cached only
    /// after it was actually observed.
    public func refreshDeviceList(force: Bool) async throws {
        if !force,
           let loadedAt = deviceListLoadedAt,
           Date().timeIntervalSince(loadedAt) < deviceListTTL {
            return
        }
        let directory = root.appendingPathComponent("devices", isDirectory: true)
        let entries: [URL]
        do {
            entries = try await cloudAccess.list(directory, keys: [.isDirectoryKey])
        } catch {
            // Keep `deviceIDs` intact: losing a device from the cache is how a
            // reader silently forgets another Mac's history.
            throw CloudObjectStoreV3Error.notConfirmed(
                "无法枚举设备列表：\(error.localizedDescription)"
            )
        }
        var ids = entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map(\.lastPathComponent)
        // Local first: most reads hit the device that is still writing.
        ids.sort { lhs, rhs in
            if lhs == localDeviceID { return true }
            if rhs == localDeviceID { return false }
            return lhs < rhs
        }
        deviceIDs = ids
        deviceListLoadedAt = Date()
    }

    /// Called after settings/container changes and when the app returns to the
    /// foreground. The next read performs a forced refresh.
    public func invalidateDeviceList() {
        deviceIDs = nil
        deviceListLoadedAt = nil
        snapshotDevices.removeAll()
    }

    /// Last successfully observed list, for diagnostics. Never triggers I/O.
    public func cachedDeviceIDs() -> [String] {
        deviceIDs ?? []
    }

    private func deviceIDs() async throws -> [String] {
        // A failed refresh is an error, not an empty device list. A caller that
        // cannot enumerate devices cannot prove an object is absent.
        try await refreshDeviceList(force: false)
        return deviceIDs ?? []
    }

    // MARK: - CloudObjectSource

    public func readCommit(projectID: UUID, snapshotID: String) async throws -> SnapshotCommit? {
        if let device = snapshotDevices[snapshotID] {
            return try await store(deviceID: device).readCommit(
                projectID: projectID, snapshotID: snapshotID
            )
        }
        for device in try await deviceIDs() {
            if let commit = try await store(deviceID: device).readCommit(
                projectID: projectID, snapshotID: snapshotID
            ) {
                snapshotDevices[snapshotID] = device
                return commit
            }
        }
        return nil
    }

    public func readManifestPayload(projectID: UUID, snapshotID: String) async throws -> Data {
        if let device = snapshotDevices[snapshotID] {
            return try await store(deviceID: device).readManifestPayload(
                projectID: projectID, snapshotID: snapshotID
            )
        }
        // Normally readCommit ran first. If not, discover the device, then retry.
        if try await readCommit(projectID: projectID, snapshotID: snapshotID) == nil {
            throw CloudObjectStoreV3Error.manifestMissing(snapshotID)
        }
        guard let device = snapshotDevices[snapshotID] else {
            throw CloudObjectStoreV3Error.manifestMissing(snapshotID)
        }
        return try await store(deviceID: device).readManifestPayload(
            projectID: projectID, snapshotID: snapshotID
        )
    }

    public func readNode(_ nodeID: String) async throws -> DirectoryNode {
        var firstError: Error?
        for device in try await deviceIDs() {
            do {
                return try await store(deviceID: device).readNode(nodeID)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        throw CloudObjectStoreV3Error.nodeMissing(nodeID)
    }

    public func readObject(_ objectID: String) async throws -> Data {
        guard let data = try await readObjectIfPresent(objectID) else {
            throw CloudObjectStoreV3Error.objectMissing(objectID)
        }
        return data
    }

    public func readPack(_ packID: String) async throws -> Data {
        guard let data = try await readPackIfPresent(packID) else {
            throw CloudObjectStoreV3Error.objectMissing(packID)
        }
        return data
    }

    /// Tries every device namespace. An inaccessible namespace makes the result
    /// unknown unless another namespace produced the bytes; it is never reported
    /// as absent.
    public func readObjectIfPresent(_ objectID: String) async throws -> Data? {
        var firstError: Error?
        for device in try await deviceIDs() {
            do {
                if let data = try await store(deviceID: device).readObjectIfPresent(objectID) {
                    return data
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return nil
    }

    public func readPackIfPresent(_ packID: String) async throws -> Data? {
        var firstError: Error?
        for device in try await deviceIDs() {
            do {
                if let data = try await store(deviceID: device).readPackIfPresent(packID) {
                    return data
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return nil
    }

    public func commits(projectID: UUID) async throws -> [SnapshotCommit] {
        var seen = Set<String>()
        var result: [SnapshotCommit] = []
        for device in try await deviceIDs() {
            let commits: [SnapshotCommit]
            do {
                commits = try await store(deviceID: device).strictCommits(projectID: projectID)
            } catch {
                // One unreadable device makes the cross-device list incomplete.
                // Report the failure instead of presenting a partial history.
                throw CloudObjectStoreV3Error.notConfirmed(
                    "无法读取设备 \(device) 的提交标记：\(error.localizedDescription)"
                )
            }
            for commit in commits where seen.insert(commit.snapshotID).inserted {
                snapshotDevices[commit.snapshotID] = device
                result.append(commit)
            }
        }
        return result.sorted { $0.committedAt < $1.committedAt }
    }
}
