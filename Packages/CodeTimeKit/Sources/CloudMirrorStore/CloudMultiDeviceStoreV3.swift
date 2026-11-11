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
    private var deviceIDs: [String]?
    private var snapshotDevices: [String: String] = [:]

    public init(
        root: URL,
        localDeviceID: String,
        masterKey: Data,
        access: CloudFileAccess = LocalFileAccess(),
        tracker: CloudUploadTracking = NoopUploadTracker()
    ) {
        self.root = root
        self.localDeviceID = localDeviceID
        self.masterKey = masterKey
        self.access = access
        self.tracker = tracker
    }

    private func store(deviceID: String) -> CloudObjectStoreV3 {
        CloudObjectStoreV3(
            root: root,
            deviceID: deviceID,
            masterKey: masterKey,
            access: access,
            tracker: tracker
        )
    }

    private func deviceIDs() async -> [String] {
        if let deviceIDs { return deviceIDs }
        let directory = root.appendingPathComponent("devices", isDirectory: true)
        let entries = (try? await access.list(directory, keys: [.isDirectoryKey])) ?? []
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
        return ids
    }

    // MARK: - CloudObjectSource

    public func readCommit(projectID: UUID, snapshotID: String) async throws -> SnapshotCommit? {
        if let device = snapshotDevices[snapshotID] {
            return try await store(deviceID: device).readCommit(
                projectID: projectID, snapshotID: snapshotID
            )
        }
        for device in await deviceIDs() {
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
        for device in await deviceIDs() {
            if let node = try? await store(deviceID: device).readNode(nodeID) {
                return node
            }
        }
        throw CloudObjectStoreV3Error.nodeMissing(nodeID)
    }

    public func readObject(_ objectID: String) async throws -> Data {
        for device in await deviceIDs() {
            if let data = try? await store(deviceID: device).readObject(objectID) {
                return data
            }
        }
        throw CloudObjectStoreV3Error.objectMissing(objectID)
    }

    public func readPack(_ packID: String) async throws -> Data {
        for device in await deviceIDs() {
            if let data = try? await store(deviceID: device).readPack(packID) {
                return data
            }
        }
        throw CloudObjectStoreV3Error.objectMissing(packID)
    }

    public func commits(projectID: UUID) async throws -> [SnapshotCommit] {
        var seen = Set<String>()
        var result: [SnapshotCommit] = []
        for device in await deviceIDs() {
            let commits = (try? await store(deviceID: device).commits(projectID: projectID)) ?? []
            for commit in commits where seen.insert(commit.snapshotID).inserted {
                snapshotDevices[commit.snapshotID] = device
                result.append(commit)
            }
        }
        return result.sorted { $0.committedAt < $1.committedAt }
    }
}
