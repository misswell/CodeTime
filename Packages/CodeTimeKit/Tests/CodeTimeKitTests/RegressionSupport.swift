import Foundation
import XCTest
import CryptoKit
@testable import SharedModels
@testable import CloudMirrorStore
@testable import CodeTimeSecurity
@testable import Persistence

// MARK: - Providers

struct RegressionPassword: RepositoryPasswordProviding {
    let value: String
    func repositoryPassword() throws -> String { value }
}

struct RegressionMasterKey: MasterKeyProviding {
    let value: Data
    func masterKey() throws -> Data { value }
}

// MARK: - In-memory persistence seams

/// Keeps GC journals between store instances so a simulated crash can resume.
final class MemoryJournalStore: GCJournalProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var journals: [UUID: GCJournal] = [:]
    /// Simulates the passage of the grace period without sleeping.
    var fastForwardGraceDeadline = false

    func loadUnfinishedGCJournal(repositoryID: UUID) async throws -> GCJournal? {
        lock.lock()
        defer { lock.unlock() }
        let unfinished = journals.values
            .filter { $0.repositoryID == repositoryID && $0.phase != .completed }
            .sorted { $0.updatedAt < $1.updatedAt }
        guard var journal = unfinished.last else { return nil }
        if fastForwardGraceDeadline, journal.graceDeadline != nil {
            journal.graceDeadline = Date().addingTimeInterval(-1)
        }
        return journal
    }

    func saveGCJournal(_ journal: GCJournal) async throws {
        lock.lock()
        journals[journal.id] = journal
        lock.unlock()
    }

    func deleteGCJournal(id: UUID) async throws {
        lock.lock()
        journals[id] = nil
        lock.unlock()
    }

    func latest(repositoryID: UUID) -> GCJournal? {
        lock.lock()
        defer { lock.unlock() }
        return journals.values
            .filter { $0.repositoryID == repositoryID }
            .sorted { $0.updatedAt < $1.updatedAt }
            .last
    }
}

final class MemoryObjectIndexStore: CloudObjectIndexProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: [CloudObjectIndexEntry]] = [:]

    func loadObjectIndex(repositoryID: UUID) async throws -> [CloudObjectIndexEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries[repositoryID] ?? []
    }

    func saveObjectIndex(_ entries: [CloudObjectIndexEntry], repositoryID: UUID) async throws {
        lock.lock()
        self.entries[repositoryID] = entries
        lock.unlock()
    }
}

final class MemoryHashCacheStore: ObjectHashCacheProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ObjectHashCacheEntry] = [:]

    func seed(_ entry: ObjectHashCacheEntry) {
        lock.lock()
        entries[entry.relativePath] = entry
        lock.unlock()
    }

    func loadHashCache(repositoryID: UUID, paths: [String]) async throws -> [String: ObjectHashCacheEntry] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: ObjectHashCacheEntry] = [:]
        for path in paths {
            if let entry = entries[path] { result[path] = entry }
        }
        return result
    }

    func saveHashCache(_ entries: [ObjectHashCacheEntry], repositoryID: UUID) async throws {
        lock.lock()
        for entry in entries { self.entries[entry.relativePath] = entry }
        lock.unlock()
    }

    func entry(_ path: String) -> ObjectHashCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }
}

/// Upload tracker whose confirmation behaviour can change between publishes.
actor SwitchableUploadTracker: CloudUploadTracking {
    private var blockedFragment: String?
    private var failEverything: Bool
    private(set) var confirmedURLs: [URL] = []

    init(failEverything: Bool = false) {
        self.failEverything = failEverything
    }

    func block(_ fragment: String?) { blockedFragment = fragment }
    func setFailEverything(_ value: Bool) { failEverything = value }

    func waitForUpload(_ url: URL, timeout: TimeInterval) async throws {
        if failEverything {
            throw CloudStoreError.uploadNotConfirmed(url.lastPathComponent)
        }
        if let blockedFragment, url.path.contains(blockedFragment) {
            throw CloudStoreError.uploadNotConfirmed(url.lastPathComponent)
        }
        confirmedURLs.append(url)
    }
}

// MARK: - Workspace

final class RegressionWorkspace {
    let root: URL

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-reg-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var storageRoot: URL { root.appendingPathComponent("cloud", isDirectory: true) }
    var repositoryURL: URL { root.appendingPathComponent("repo", isDirectory: true) }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeFile(_ relative: String, _ contents: String) throws {
        let url = repositoryURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeData(_ relative: String, _ data: Data) throws {
        let url = repositoryURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func removeRepositoryFile(_ relative: String) throws {
        try FileManager.default.removeItem(at: repositoryURL.appendingPathComponent(relative))
    }

    func deviceRepositoryURL(deviceID: UUID, repositoryID: UUID) -> URL {
        storageRoot
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent(deviceID.uuidString, isDirectory: true)
            .appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(repositoryID.uuidString, isDirectory: true)
    }

    func commitsDirectory(deviceID: UUID, repositoryID: UUID) -> URL {
        deviceRepositoryURL(deviceID: deviceID, repositoryID: repositoryID)
            .appendingPathComponent("commits", isDirectory: true)
    }

    func commitURL(deviceID: UUID, repositoryID: UUID, generationID: UUID) -> URL {
        commitsDirectory(deviceID: deviceID, repositoryID: repositoryID)
            .appendingPathComponent("\(generationID.uuidString).ctm")
    }

    func tombstoneURLs(deviceID: UUID, repositoryID: UUID) -> [URL] {
        let directory = commitsDirectory(deviceID: deviceID, repositoryID: repositoryID)
            .appendingPathComponent("tombstones", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "ctm" }
    }

    func objectURL(deviceID: UUID, repositoryID: UUID, hash: String) -> URL {
        deviceRepositoryURL(deviceID: deviceID, repositoryID: repositoryID)
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    /// All regular object files (excludes quarantine and temp files).
    func objectFiles(deviceID: UUID, repositoryID: UUID) -> [URL] {
        let directory = deviceRepositoryURL(deviceID: deviceID, repositoryID: repositoryID)
            .appendingPathComponent("objects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            if url.lastPathComponent.hasPrefix(".tmp-") { continue }
            if url.path.contains("/quarantine/") { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    func commitFiles(deviceID: UUID, repositoryID: UUID) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: commitsDirectory(deviceID: deviceID, repositoryID: repositoryID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "ctm" }
    }

    func readFileBytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

// MARK: - Cloud fixture

struct RegressionCloud {
    let workspace: RegressionWorkspace
    let repositoryID: UUID
    let masterKey: Data
    let password: String

    init(name: String) throws {
        workspace = try RegressionWorkspace(name: name)
        repositoryID = UUID()
        masterKey = Data((0..<32).map { UInt8(($0 * 37 + 11) % 251) })
        password = "regression-password-\(name)"
    }

    func cleanup() { workspace.cleanup() }

    func store(
        deviceID: UUID,
        masterKey key: Data? = nil,
        password passwordOverride: String? = nil,
        tracker: any CloudUploadTracking = NoopUploadTracker(),
        lockURL: URL? = nil,
        publishLockURL: URL? = nil,
        journalStore: any GCJournalProviding = NoopGCJournalStore(),
        indexStore: any CloudObjectIndexProviding = NoopObjectIndexStore(),
        hashCacheStore: any ObjectHashCacheProviding = NoopHashCacheStore(),
        sweepGrace: TimeInterval = 3_600,
        maxScannedFiles: Int = 2_000_000,
        uploadParallelism: Int = 4,
        fileAccess: (any CloudFileAccess)? = nil
    ) -> CloudMirrorStore {
        CloudMirrorStore(configuration: .init(
            storageRoot: workspace.storageRoot,
            repositoryID: repositoryID,
            repositoryURL: workspace.repositoryURL,
            deviceID: deviceID,
            deviceName: "Regression-\(deviceID.uuidString.prefix(4))",
            masterKeyProvider: RegressionMasterKey(value: key ?? masterKey),
            passwordProvider: RegressionPassword(value: passwordOverride ?? password),
            uploadTracker: tracker,
            coordinatedIO: false,
            uploadTimeout: 60,
            lockURL: lockURL,
            publishLockURL: publishLockURL,
            journalStore: journalStore,
            indexStore: indexStore,
            hashCacheStore: hashCacheStore,
            sweepGrace: sweepGrace,
            maxScannedFiles: maxScannedFiles,
            uploadParallelism: uploadParallelism,
            fileAccessOverride: fileAccess
        ))
    }

    @discardableResult
    func publish(
        _ store: CloudMirrorStore,
        deviceID: UUID,
        createdAt: Date = Date(),
        snapshotIDs: [String] = []
    ) async throws -> UUID {
        let generationID = UUID()
        let generation = CloudGeneration(
            id: generationID,
            repositoryID: repositoryID,
            deviceID: deviceID,
            createdAt: createdAt,
            snapshotIDs: snapshotIDs
        )
        try await store.publish(repositoryId: repositoryID, generation: generation)
        return generationID
    }
}

actor ProgressRecorder {
    private(set) var completedCounts: [Int] = []
    private(set) var completedBytes: [Int64] = []

    func record(_ progress: CloudMirrorStore.RestoreProgress) {
        completedCounts.append(progress.completedFiles)
        completedBytes.append(progress.completedBytes)
    }

    func maximum() -> Int { completedCounts.max() ?? 0 }
    func values() -> [Int] { completedCounts }
}

// MARK: - Assertions

func assertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "应当抛出错误",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {
        verify(error)
    }
}

func sha256Hex(_ string: String) -> String {
    Hashing.sha256Hex(Data(string.utf8))
}

func makeEnvironmentFile(_ relative: String, contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("codetime-env-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let file = url.appendingPathComponent(relative)
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return url
}
