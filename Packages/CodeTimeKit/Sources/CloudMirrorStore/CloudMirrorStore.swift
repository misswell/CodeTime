import Foundation
import Darwin
import SharedModels
import CodeTimeSecurity

public actor CloudMirrorStore: CloudStore {
    public struct Configuration: Sendable {
        public var storageRoot: URL
        public var repositoryID: UUID
        public var repositoryURL: URL
        public var deviceID: UUID
        public var masterKeyProvider: any MasterKeyProviding
        public var passwordProvider: any RepositoryPasswordProviding
        public var uploadTracker: any CloudUploadTracking
        public var coordinatedIO: Bool
        public var uploadTimeout: TimeInterval
        public var lockURL: URL?

        public init(
            storageRoot: URL,
            repositoryID: UUID,
            repositoryURL: URL,
            deviceID: UUID,
            masterKeyProvider: any MasterKeyProviding,
            passwordProvider: any RepositoryPasswordProviding,
            uploadTracker: any CloudUploadTracking = NoopUploadTracker(),
            coordinatedIO: Bool = false,
            uploadTimeout: TimeInterval = 900,
            lockURL: URL? = nil
        ) {
            self.storageRoot = storageRoot
            self.repositoryID = repositoryID
            self.repositoryURL = repositoryURL
            self.deviceID = deviceID
            self.masterKeyProvider = masterKeyProvider
            self.passwordProvider = passwordProvider
            self.uploadTracker = uploadTracker
            self.coordinatedIO = coordinatedIO
            self.uploadTimeout = uploadTimeout
            self.lockURL = lockURL
        }
    }

    private struct CachedHash {
        var size: Int64
        var modifiedAt: Date?
        var hash: String
    }

    private let configuration: Configuration
    private let fileManager = FileManager.default
    private var hashCache: [String: CachedHash] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let formatName = "codetime-cloud-format"
    private let formatVersion = 1

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public nonisolated var storageRoot: URL { configuration.storageRoot }

    private var baseURL: URL { configuration.storageRoot }
    private var deviceRepositoryURL: URL {
        baseURL
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent(configuration.deviceID.uuidString, isDirectory: true)
            .appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(configuration.repositoryID.uuidString, isDirectory: true)
    }
    private var objectsURL: URL { deviceRepositoryURL.appendingPathComponent("objects", isDirectory: true) }
    private var commitsURL: URL { deviceRepositoryURL.appendingPathComponent("commits", isDirectory: true) }
    private var recoveryInfoURL: URL { deviceRepositoryURL.appendingPathComponent("recovery-info.json") }

    // MARK: - Format

    private func prepare() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let formatURL = baseURL.appendingPathComponent("format.json")
        if fileManager.fileExists(atPath: formatURL.path) {
            let data = try Data(contentsOf: formatURL)
            let format = try decoder.decode(CloudFormatFile.self, from: data)
            guard format.format == formatName, format.version == formatVersion else {
                throw CloudStoreError.invalidFormat("不支持的版本 \(format.version)")
            }
        } else {
            let format = CloudFormatFile(format: formatName, version: formatVersion, createdAt: Date())
            let data = try encoder.encode(format)
            try CoordinatedIO.writeData(data, to: formatURL, coordinated: configuration.coordinatedIO)
        }
        try fileManager.createDirectory(at: objectsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: commitsURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: recoveryInfoURL.path) {
            try writeRecoveryInfo()
        }
    }

    private func writeRecoveryInfo() throws {
        let masterKey = try configuration.masterKeyProvider.masterKey()
        let payload = RecoveryPayload(
            repositoryId: configuration.repositoryID,
            repositoryPassword: try configuration.passwordProvider.repositoryPassword(),
            formatVersion: formatVersion,
            createdAt: Date()
        )
        let payloadData = try encoder.encode(payload)
        let sealed = try CryptoBox.seal(
            payloadData,
            masterKey: masterKey,
            context: recoveryContext(repositoryID: configuration.repositoryID)
        )
        let info = RecoveryInfoFile(
            formatVersion: formatVersion,
            repositoryId: configuration.repositoryID,
            deviceId: configuration.deviceID,
            createdAt: Date(),
            payload: sealed
        )
        let data = try encoder.encode(info)
        try CoordinatedIO.writeData(data, to: recoveryInfoURL, coordinated: configuration.coordinatedIO)
    }

    // MARK: - Publish

    public func publish(repositoryId: UUID, generation: CloudGeneration) async throws {
        guard repositoryId == configuration.repositoryID else {
            throw CloudStoreError.invalidFormat("仓库 ID 与存储配置不匹配")
        }
        let lock = try await acquireRepositoryLock()
        defer { lock?.release() }
        try prepare()
        guard fileManager.fileExists(atPath: configuration.repositoryURL.path) else {
            throw CloudStoreError.invalidFormat("本地仓库不存在")
        }

        let manifestFiles = try repositoryFiles()
        var uniqueObjects: [String: (source: URL, size: Int64)] = [:]
        for file in manifestFiles {
            let source = configuration.repositoryURL.appendingPathComponent(file.relativePath)
            uniqueObjects[file.contentHash] = (source, file.size)
        }

        for (hash, object) in uniqueObjects {
            try await storeObject(hash: hash, source: object.source, size: object.size)
        }
        for hash in uniqueObjects.keys {
            try await configuration.uploadTracker.waitForUpload(objectURL(hash), timeout: configuration.uploadTimeout)
        }

        let integrity = ManifestIntegrity(
            fileCount: manifestFiles.count,
            totalBytes: manifestFiles.reduce(0) { $0 + $1.size },
            repositoryHash: Hashing.sha256Hex(try encoder.encode(manifestFiles))
        )
        let manifest = CloudManifest(
            formatVersion: formatVersion,
            repositoryId: configuration.repositoryID,
            generationId: generation.id,
            deviceId: configuration.deviceID,
            createdAt: generation.createdAt,
            sourceSnapshotIds: generation.snapshotIDs,
            repositoryFiles: manifestFiles,
            integrity: integrity
        )
        let manifestData = try encoder.encode(manifest)
        let masterKey = try configuration.masterKeyProvider.masterKey()
        let sealed = try CryptoBox.seal(
            manifestData,
            masterKey: masterKey,
            context: manifestContext(generationID: generation.id, repositoryID: configuration.repositoryID)
        )

        let commitURL = commitsURL.appendingPathComponent("\(generation.id.uuidString).ctm")
        guard !fileManager.fileExists(atPath: commitURL.path) else {
            throw CloudStoreError.invalidFormat("版本清单已存在，拒绝覆盖")
        }
        try CoordinatedIO.writeData(sealed, to: commitURL, coordinated: configuration.coordinatedIO)
        try await configuration.uploadTracker.waitForUpload(commitURL, timeout: configuration.uploadTimeout)

        try writeRecoveryInfo()
    }

    private func repositoryFiles() throws -> [ManifestFile] {
        let root = configuration.repositoryURL
        let rootPath = root.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw CloudStoreError.invalidFormat("无法读取本地仓库")
        }

        var files: [ManifestFile] = []
        var seenPaths = Set<String>()
        while let object = enumerator.nextObject() {
            guard let url = object as? URL else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            if values?.isSymbolicLink == true { continue }
            var relative = url.standardizedFileURL.path
            guard relative.hasPrefix(rootPath) else { continue }
            relative = String(relative.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty, !relative.hasSuffix(".tmp") else { continue }
            guard seenPaths.insert(relative).inserted else { continue }

            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate
            let hash: String
            if let cached = hashCache[relative], cached.size == size, cached.modifiedAt == modified {
                hash = cached.hash
            } else {
                hash = try Hashing.sha256Hex(fileURL: url)
                hashCache[relative] = CachedHash(size: size, modifiedAt: modified, hash: hash)
            }
            files.append(ManifestFile(relativePath: relative, contentHash: hash, size: size))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func storeObject(hash: String, source: URL, size: Int64) async throws {
        let target = objectURL(hash)
        if fileManager.fileExists(atPath: target.path) {
            let existingSize = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard Int64(existingSize) == size else {
                throw CloudStoreError.objectCorrupt(hash)
            }
            return
        }

        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: temp)
        defer { try? fileManager.removeItem(at: temp) }

        try CoordinatedIO.write(to: target, coordinated: configuration.coordinatedIO) { actualURL in
            if fileManager.fileExists(atPath: actualURL.path) {
                return
            }
            try fileManager.moveItem(at: temp, to: actualURL)
        }
    }

    // MARK: - Listing and manifests

    public func listGenerations(repositoryId: UUID) async throws -> [CloudGeneration] {
        try prepare()
        let urls = (try? fileManager.contentsOfDirectory(
            at: commitsURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var generations: [(generation: CloudGeneration, commitDate: Date)] = []
        for url in urls where url.pathExtension == "ctm" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            try? await UbiquitousFiles.ensureDownloaded(url)
            guard let manifest = try? loadManifest(generationID: id) else { continue }
            let hash = try? Hashing.sha256Hex(fileURL: url)
            let uniqueCount = Set(manifest.repositoryFiles.map(\.contentHash)).count
            let commitDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? manifest.createdAt
            generations.append((
                CloudGeneration(
                    id: id,
                    repositoryID: manifest.repositoryId,
                    deviceID: manifest.deviceId,
                    createdAt: manifest.createdAt,
                    publishedAt: commitDate,
                    state: .published,
                    manifestHash: hash ?? "",
                    objectCount: uniqueCount,
                    byteSize: manifest.integrity.totalBytes,
                    snapshotIDs: manifest.sourceSnapshotIds,
                    uploadedObjectCount: uniqueCount,
                    verifiedAt: nil
                ),
                commitDate
            ))
        }
        return generations.sorted { lhs, rhs in
            if lhs.generation.createdAt != rhs.generation.createdAt {
                return lhs.generation.createdAt > rhs.generation.createdAt
            }
            if lhs.commitDate != rhs.commitDate {
                return lhs.commitDate > rhs.commitDate
            }
            return lhs.generation.id.uuidString > rhs.generation.id.uuidString
        }.map(\.generation)
    }

    private func commitURL(_ generationID: UUID) -> URL {
        commitsURL.appendingPathComponent("\(generationID.uuidString).ctm")
    }

    private func loadManifest(generationID: UUID) throws -> CloudManifest {
        let commitURL = commitURL(generationID)
        guard fileManager.fileExists(atPath: commitURL.path) else {
            throw CloudStoreError.manifestUnavailable(generationID.uuidString)
        }
        let sealed = try Data(contentsOf: commitURL)
        let key = try configuration.masterKeyProvider.masterKey()
        let data: Data
        do {
            data = try CryptoBox.open(
                sealed,
                masterKey: key,
                context: manifestContext(generationID: generationID, repositoryID: configuration.repositoryID)
            )
        } catch {
            throw CloudStoreError.manifestCorrupt("无法解密清单（密钥不匹配或文件损坏）")
        }
        let manifest = try decoder.decode(CloudManifest.self, from: data)
        guard manifest.repositoryId == configuration.repositoryID,
              manifest.generationId == generationID,
              manifest.formatVersion == formatVersion else {
            throw CloudStoreError.manifestCorrupt("清单元数据不一致")
        }
        return manifest
    }

    // MARK: - Restore

    public func restoreRepository(generationId: UUID, destination: URL) async throws {
        try prepare()
        try? await UbiquitousFiles.ensureDownloaded(commitURL(generationId))
        let manifest = try loadManifest(generationID: generationId)
        let dest = destination.standardizedFileURL
        if fileManager.fileExists(atPath: dest.path) {
            let contents = try fileManager.contentsOfDirectory(atPath: dest.path)
            guard contents.isEmpty else {
                throw CodeTimeError.destinationExists(dest.path)
            }
        } else {
            try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        }

        for file in manifest.repositoryFiles {
            let relative = try Self.validatedRelativePath(file.relativePath)
            let object = objectURL(file.contentHash)
            guard fileManager.fileExists(atPath: object.path) else {
                throw CloudStoreError.objectMissing(file.contentHash)
            }
            try await UbiquitousFiles.ensureDownloaded(object)
            let size = (try object.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1
            guard Int64(size) == file.size else {
                throw CloudStoreError.objectCorrupt(file.contentHash)
            }
            let actual = try Hashing.sha256Hex(fileURL: object)
            guard actual == file.contentHash else {
                throw CloudStoreError.objectCorrupt(file.contentHash)
            }
            let target = dest.appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                throw CodeTimeError.destinationExists(target.path)
            }
            try fileManager.copyItem(at: object, to: target)
        }
    }

    // MARK: - Verification

    public func verifyGeneration(_ generationId: UUID) async throws -> VerificationResult {
        try prepare()
        try? await UbiquitousFiles.ensureDownloaded(commitURL(generationId))
        let manifest = try loadManifest(generationID: generationId)
        var bytes: Int64 = 0
        for file in manifest.repositoryFiles {
            let object = objectURL(file.contentHash)
            guard fileManager.fileExists(atPath: object.path) else {
                return VerificationResult(
                    generationID: generationId,
                    level: .cloudIntegrity,
                    outcome: .failed,
                    details: "对象缺失：\(file.contentHash)"
                )
            }
            try await UbiquitousFiles.ensureDownloaded(object)
            let size = (try? object.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            guard Int64(size) == file.size else {
                return VerificationResult(
                    generationID: generationId,
                    level: .cloudIntegrity,
                    outcome: .failed,
                    details: "对象大小不匹配：\(file.relativePath)"
                )
            }
            let hash = try Hashing.sha256Hex(fileURL: object)
            guard hash == file.contentHash else {
                return VerificationResult(
                    generationID: generationId,
                    level: .cloudIntegrity,
                    outcome: .failed,
                    details: "对象哈希不匹配：\(file.relativePath)"
                )
            }
            bytes += file.size
        }
        return VerificationResult(
            generationID: generationId,
            level: .cloudIntegrity,
            outcome: .passed,
            details: "校验 \(manifest.repositoryFiles.count) 个对象",
            bytesChecked: bytes
        )
    }

    public func storageSummary(repositoryId: UUID) async throws -> CloudStorageSummary {
        try prepare()
        let generations = try await listGenerations(repositoryId: repositoryId)
        let objects = (try? fileManager.contentsOfDirectory(
            at: objectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var count = 0
        var bytes: Int64 = 0
        for prefix in objects {
            guard (try? prefix.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let files = (try? fileManager.contentsOfDirectory(
                at: prefix,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where !file.lastPathComponent.hasPrefix(".tmp-") {
                count += 1
                bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return CloudStorageSummary(
            objectCount: count,
            byteSize: bytes,
            generationCount: generations.count,
            lastPublishedAt: generations.first?.createdAt,
            lastVerifiedAt: nil
        )
    }

    // MARK: - Cleanup

    public func cleanup(
        repositoryId: UUID,
        gracePeriod: TimeInterval,
        minimumGenerations: Int
    ) async throws -> CloudCleanupReport {
        let lock = try await acquireRepositoryLock()
        defer { lock?.release() }
        try prepare()
        let generations = try await listGenerations(repositoryId: repositoryId)
        let minimum = max(2, minimumGenerations)
        guard generations.count > 0 else {
            return CloudCleanupReport(skippedReason: "没有云端版本")
        }

        var manifests: [UUID: CloudManifest] = [:]
        for generation in generations {
            do {
                try? await UbiquitousFiles.ensureDownloaded(commitURL(generation.id))
                manifests[generation.id] = try loadManifest(generationID: generation.id)
            } catch {
                return CloudCleanupReport(
                    retainedGenerations: generations.count,
                    skippedReason: "存在无法读取的版本清单，清理已暂停"
                )
            }
        }

        let cutoff = Date().addingTimeInterval(-gracePeriod)
        var retained: [CloudGeneration] = []
        for (index, generation) in generations.enumerated() {
            if index < minimum || generation.createdAt > cutoff {
                retained.append(generation)
            }
        }
        let retainedIDs = Set(retained.map(\.id))
        var referenced = Set<String>()
        for generation in retained {
            guard let manifest = manifests[generation.id] else { continue }
            for file in manifest.repositoryFiles {
                referenced.insert(file.contentHash)
            }
        }

        for hash in referenced {
            if !fileManager.fileExists(atPath: objectURL(hash).path) {
                return CloudCleanupReport(
                    retainedGenerations: retained.count,
                    skippedReason: "保留版本仍引用缺失对象 \(hash)，清理已暂停"
                )
            }
        }

        var deletedObjects = 0
        var freedBytes: Int64 = 0
        let prefixes = (try? fileManager.contentsOfDirectory(
            at: objectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for prefix in prefixes {
            guard (try? prefix.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let files = (try? fileManager.contentsOfDirectory(
                at: prefix,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files {
                let hash = file.lastPathComponent
                if referenced.contains(hash) { continue }
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let modified = values?.contentModificationDate ?? Date()
                guard modified <= cutoff else { continue }
                let size = Int64(values?.fileSize ?? 0)
                if (try? fileManager.removeItem(at: file)) != nil {
                    deletedObjects += 1
                    freedBytes += size
                }
            }
        }

        for generation in generations where !retainedIDs.contains(generation.id) {
            guard generation.createdAt <= cutoff else { continue }
            let commit = commitsURL.appendingPathComponent("\(generation.id.uuidString).ctm")
            if (try? fileManager.removeItem(at: commit)) != nil {
                manifests.removeValue(forKey: generation.id)
            }
        }

        return CloudCleanupReport(
            deletedObjects: deletedObjects,
            freedBytes: freedBytes,
            retainedGenerations: retained.count
        )
    }

    // MARK: - Helpers

    private func acquireRepositoryLock() async throws -> ProcessFileLock? {
        guard let lockURL = configuration.lockURL else { return nil }
        let lock = ProcessFileLock(path: lockURL.path)
        try await lock.acquire(timeout: 600)
        return lock
    }

    private func objectURL(_ hash: String) -> URL {
        objectsURL
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    private func manifestContext(generationID: UUID, repositoryID: UUID) -> String {
        "manifest:\(repositoryID.uuidString):\(generationID.uuidString)"
    }

    private func recoveryContext(repositoryID: UUID) -> String {
        "recovery:\(repositoryID.uuidString)"
    }

    private static func validatedRelativePath(_ path: String) throws -> String {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            throw CloudStoreError.unsafePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw CloudStoreError.unsafePath(path)
        }
        return components.joined(separator: "/")
    }

    // MARK: - Recovery

    /// Cross-process lock; shared with the Kopia engine's repository lock.
    private final class ProcessFileLock: @unchecked Sendable {
        private let path: String
        private var descriptor: Int32 = -1

        init(path: String) { self.path = path }

        func acquire(timeout: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if tryAcquire() { return }
                if Date() >= deadline {
                    throw CodeTimeError.repositoryUnavailable("仓库正在被另一个任务使用")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        private func tryAcquire() -> Bool {
            let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return false }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                descriptor = fd
                return true
            }
            close(fd)
            return false
        }

        func release() {
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
                descriptor = -1
            }
        }
    }

    public static func recover(
        storageRoot: URL,
        recoveryKey: Data,
        repositoryID: UUID? = nil
    ) async throws -> RecoveredAccess {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let devices = storageRoot.appendingPathComponent("devices", isDirectory: true)
        let deviceDirs = (try? FileManager.default.contentsOfDirectory(
            at: devices,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for device in deviceDirs {
            let repositories = device.appendingPathComponent("repositories", isDirectory: true)
            let repos = (try? FileManager.default.contentsOfDirectory(
                at: repositories,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for repo in repos {
                if let repositoryID, repo.lastPathComponent != repositoryID.uuidString { continue }
                let infoURL = repo.appendingPathComponent("recovery-info.json")
                try? await UbiquitousFiles.ensureDownloaded(infoURL)
                guard let data = try? Data(contentsOf: infoURL),
                      let info = try? decoder.decode(RecoveryInfoFile.self, from: data) else { continue }
                if let repositoryID, info.repositoryId != repositoryID { continue }
                let payloadData = try CryptoBox.open(
                    info.payload,
                    masterKey: recoveryKey,
                    context: "recovery:\(info.repositoryId.uuidString)"
                )
                let payload = try decoder.decode(RecoveryPayload.self, from: payloadData)
                return RecoveredAccess(
                    repositoryID: info.repositoryId,
                    deviceID: info.deviceId,
                    repositoryPassword: payload.repositoryPassword,
                    createdAt: payload.createdAt
                )
            }
        }
        throw CloudStoreError.notFound("没有找到可用恢复凭据")
    }
}
