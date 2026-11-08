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
        public var deviceName: String?
        public var masterKeyProvider: any MasterKeyProviding
        public var passwordProvider: any RepositoryPasswordProviding
        public var uploadTracker: any CloudUploadTracking
        public var coordinatedIO: Bool
        public var uploadTimeout: TimeInterval
        public var lockURL: URL?
        /// Separate from `lockURL`: local snapshots only need the Kopia repository
        /// lock, while uploads may wait for iCloud for a long time. GC takes this
        /// lock so it cannot sweep objects that are still being published.
        public var publishLockURL: URL?
        /// Non-fatal diagnostics from post-commit metadata repair.
        public var warningHandler: (@Sendable (String) -> Void)?
        public var journalStore: any GCJournalProviding
        public var indexStore: any CloudObjectIndexProviding
        public var hashCacheStore: any ObjectHashCacheProviding
        /// Minimum delay between tombstoning and object sweeping. Generation
        /// retention uses the caller's grace period; this protects in-flight
        /// uploads from other devices.
        public var sweepGrace: TimeInterval
        public var maxScannedFiles: Int
        /// Bounded concurrency for object copy/verify and hashing during publish.
        public var uploadParallelism: Int

        public init(
            storageRoot: URL,
            repositoryID: UUID,
            repositoryURL: URL,
            deviceID: UUID,
            deviceName: String? = nil,
            masterKeyProvider: any MasterKeyProviding,
            passwordProvider: any RepositoryPasswordProviding,
            uploadTracker: any CloudUploadTracking = NoopUploadTracker(),
            coordinatedIO: Bool = false,
            uploadTimeout: TimeInterval = 900,
            lockURL: URL? = nil,
            publishLockURL: URL? = nil,
            warningHandler: (@Sendable (String) -> Void)? = nil,
            journalStore: any GCJournalProviding = NoopGCJournalStore(),
            indexStore: any CloudObjectIndexProviding = NoopObjectIndexStore(),
            hashCacheStore: any ObjectHashCacheProviding = NoopHashCacheStore(),
            sweepGrace: TimeInterval = 3_600,
            maxScannedFiles: Int = 2_000_000,
            uploadParallelism: Int = 4
        ) {
            self.storageRoot = storageRoot
            self.repositoryID = repositoryID
            self.repositoryURL = repositoryURL
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.masterKeyProvider = masterKeyProvider
            self.passwordProvider = passwordProvider
            self.uploadTracker = uploadTracker
            self.coordinatedIO = coordinatedIO
            self.uploadTimeout = uploadTimeout
            self.lockURL = lockURL
            self.publishLockURL = publishLockURL
            self.warningHandler = warningHandler
            self.journalStore = journalStore

            self.indexStore = indexStore
            self.hashCacheStore = hashCacheStore
            self.sweepGrace = sweepGrace
            self.maxScannedFiles = maxScannedFiles
            self.uploadParallelism = max(1, uploadParallelism)
        }
    }

    /// Stabilized file identity used by the hash cache and by the scan-to-upload
    /// consistency check.
    private struct FileStamp: Hashable {
        var identity: String
        var size: Int64
        var modifiedAt: Date
        var changedAt: Date
    }

    private struct ScanItem {
        var relativePath: String
        var url: URL
        var stamp: FileStamp
        var hash: String
    }

    private let configuration: Configuration
    private let fileManager = FileManager.default
    private let access: any CloudFileAccess
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let formatName = "codetime-cloud-format"
    private let formatVersion = 2
    private let objectAlgorithm = "sha256"

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.access = configuration.coordinatedIO
            ? ICloudCoordinatedFileAccess()
            : LocalFileAccess()
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
    private var quarantineURL: URL { objectsURL.appendingPathComponent("quarantine", isDirectory: true) }
    private var commitsURL: URL { deviceRepositoryURL.appendingPathComponent("commits", isDirectory: true) }
    private var tombstonesURL: URL { commitsURL.appendingPathComponent("tombstones", isDirectory: true) }
    private var recoveryInfoURL: URL { deviceRepositoryURL.appendingPathComponent("recovery-info.json") }

    // MARK: - Format

    private func prepare() async throws {
        try await access.ensureDirectory(baseURL)
        let formatURL = baseURL.appendingPathComponent("format.json")
        if fileManager.fileExists(atPath: formatURL.path) {
            let data: Data
            do { data = try await access.read(formatURL) }
            catch { throw CloudStoreError.invalidFormat("无法读取格式文件：\(error.localizedDescription)") }
            let format = try decoder.decode(CloudFormatFile.self, from: data)
            guard format.format == formatName else {
                throw CloudStoreError.invalidFormat("不是 CodeTime 云端目录")
            }
            guard format.version <= formatVersion else {
                throw CloudStoreError.unsupportedFormat("版本 \(format.version)")
            }
        } else {
            let format = CloudFormatFile(
                format: formatName,
                version: formatVersion,
                objectAlgorithm: objectAlgorithm,
                createdAt: Date()
            )
            try await access.writeAtomically(try encoder.encode(format), to: formatURL)
        }
        try await access.ensureDirectory(objectsURL)
        try await access.ensureDirectory(commitsURL)
        try await writeDeviceRegistryEntry()
        if !fileManager.fileExists(atPath: recoveryInfoURL.path) {
            try await writeRecoveryInfo()
        } else {
            _ = try await readRecoveryInfo()
        }
    }

    /// CT-089: persistent per-device registry entry. Every device that publishes
    /// to this storage root records its identity and last-seen time under
    /// `devices/<deviceID>/device-info.json`. GC NEVER deletes a device that has
    /// not provably retired — the registry makes "another device exists"
    /// independent of whether that device happens to be online right now, and
    /// gives the multi-device guard durable evidence even before the other
    /// device has synced any repository data.
    private func writeDeviceRegistryEntry() async {
        let deviceDir = baseURL.appendingPathComponent(
            "devices/\(configuration.deviceID.uuidString)", isDirectory: true
        )
        do {
            try await access.ensureDirectory(deviceDir)
            let info: [String: String] = [
                "deviceID": configuration.deviceID.uuidString,
                "deviceName": configuration.deviceName ?? "未知设备",
                "lastSeenAt": ISO8601DateFormatter().string(from: Date()),
            ]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try await access.writeAtomically(
                try encoder.encode(info),
                to: deviceDir.appendingPathComponent("device-info.json")
            )
        } catch {
            // The registry is safety-relevant metadata, not a publish dependency:
            // a write failure must not break uploads, but it is reported loudly.
            configuration.warningHandler?("无法写入设备注册信息：\(error.localizedDescription)")
        }
    }

    private func writeRecoveryInfo() async throws {
        let masterKey = try configuration.masterKeyProvider.masterKey()
        let payload = RecoveryPayload(
            repositoryId: configuration.repositoryID,
            repositoryPassword: try configuration.passwordProvider.repositoryPassword(),
            formatVersion: formatVersion,
            createdAt: Date(),
            keyFingerprint: Self.keyFingerprint(masterKey)
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
            deviceName: configuration.deviceName,
            createdAt: Date(),
            keyFingerprint: Self.keyFingerprint(masterKey),
            payload: sealed
        )
        try await access.writeAtomically(try encoder.encode(info), to: recoveryInfoURL)
    }

    private func readRecoveryInfo() async throws -> RecoveryInfoFile {
        let data = try await access.read(recoveryInfoURL)
        let info = try decoder.decode(RecoveryInfoFile.self, from: data)
        // A recovery file sealed by a different key must be surfaced, not ignored.
        guard info.repositoryId == configuration.repositoryID else {
            throw CloudStoreError.invalidFormat("recovery-info 仓库不匹配")
        }
        let masterKey = try configuration.masterKeyProvider.masterKey()
        guard info.keyFingerprint == Self.keyFingerprint(masterKey) else {
            throw CloudStoreError.invalidFormat("recovery-info 与当前密钥不匹配")
        }
        let plaintext = try CryptoBox.open(
            info.payload,
            masterKey: masterKey,
            context: recoveryContext(repositoryID: info.repositoryId)
        )
        let payload = try decoder.decode(RecoveryPayload.self, from: plaintext)
        guard payload.repositoryId == info.repositoryId,
              payload.keyFingerprint == info.keyFingerprint else {
            throw CloudStoreError.invalidFormat("recovery-info 内部数据不一致")
        }
        return info
    }

    private static func keyFingerprint(_ masterKey: Data) -> String {
        String(Hashing.sha256Hex(masterKey).prefix(24))
    }

    // MARK: - Publish

    public func publish(repositoryId: UUID, generation: CloudGeneration) async throws {
        guard repositoryId == configuration.repositoryID else {
            throw CloudStoreError.invalidFormat("仓库 ID 与存储配置不匹配")
        }
        // Publish lock is held for the whole upload, but the Kopia repository
        // lock is released as soon as local objects have been copied. A slow
        // iCloud upload must not block the next local snapshot.
        let publishLock = try await acquirePublishLock()
        defer { publishLock?.release() }
        var repositoryLock = try await acquireRepositoryLock()
        defer { repositoryLock?.release() }
        try await prepare()
        guard fileManager.fileExists(atPath: configuration.repositoryURL.path) else {
            throw CloudStoreError.invalidFormat("本地仓库不存在")
        }
        let commit = commitURL(generation.id)
        if fileManager.fileExists(atPath: commit.path) {
            // A previous attempt committed the manifest but failed afterwards.
            // Confirm the existing generation instead of creating a second one.
            try await access.download(commit, timeout: 120)
            let existing = try await loadManifest(generationID: generation.id)
            guard existing.repositoryId == configuration.repositoryID else {
                throw CloudStoreError.manifestExists(generation.id.uuidString)
            }
            repositoryLock?.release()
            repositoryLock = nil
            try await configuration.uploadTracker.waitForUpload(commit, timeout: configuration.uploadTimeout)
            return
        }

        let scan = try await scanRepository(previousEntries: nil)
        guard scan.result.isComplete else {
            throw CloudStoreError.objectCorrupt(
                "仓库扫描不完整（\(scan.result.errorCount) 个错误），拒绝发布：\(scan.result.skippedPaths.prefix(3).joined(separator: "、"))"
            )
        }

        var uniqueObjects: [String: ScanItem] = [:]
        for item in scan.items {
            uniqueObjects[item.hash] = item
        }

        // 1. Copy every missing object and verify content on arrival.
        let objectList = Array(uniqueObjects.values)
        try await forEachConcurrently(objectList) { item in
            try await self.storeObject(hash: item.hash, source: item.url, expected: item.stamp)
        }
        // Local object copies are complete. Keep the publish lock (so GC cannot
        // sweep uncommitted objects), but let the next snapshot take the
        // repository lock while iCloud finishes uploading.
        repositoryLock?.release()
        repositoryLock = nil
        // 2. Wait for the provider to confirm every object.
        try await forEachConcurrently(Array(uniqueObjects.keys)) { hash in
            try await self.configuration.uploadTracker.waitForUpload(
                self.objectURL(hash),
                timeout: self.configuration.uploadTimeout
            )
        }
        // 3. Independently re-verify size and SHA-256 before committing the manifest.
        try await forEachConcurrently(objectList) { item in
            try await self.verifyStoredObject(hash: item.hash, expectedSize: item.stamp.size)
        }

        let manifestFiles = scan.items
            .map { ManifestFile(relativePath: $0.relativePath, contentHash: $0.hash, size: $0.stamp.size, fileIdentity: $0.stamp.identity) }
            .sorted { $0.relativePath < $1.relativePath }
        let integrity = ManifestIntegrity(
            fileCount: manifestFiles.count,
            uniqueObjectCount: uniqueObjects.count,
            totalBytes: manifestFiles.reduce(0) { $0 + $1.size },
            repositoryHash: try ManifestIntegrityHasher.hash(files: manifestFiles)
        )
        let manifest = CloudManifest(
            formatVersion: formatVersion,
            repositoryId: configuration.repositoryID,
            generationId: generation.id,
            deviceId: configuration.deviceID,
            deviceName: configuration.deviceName,
            createdAt: generation.createdAt,
            sourceSnapshotIds: generation.snapshotIDs,
            repositoryFiles: manifestFiles,
            integrity: integrity,
            objectAlgorithm: objectAlgorithm
        )
        try validate(manifest: manifest)

        let masterKey = try configuration.masterKeyProvider.masterKey()
        let sealed = try CryptoBox.seal(
            try encoder.encode(manifest),
            masterKey: masterKey,
            context: manifestContext(generationID: generation.id)
        )

        guard !fileManager.fileExists(atPath: commit.path) else {
            throw CloudStoreError.manifestExists(generation.id.uuidString)
        }
        let temp = commitsURL.appendingPathComponent(".tmp-\(generation.id.uuidString)")
        try await access.writeAtomically(sealed, to: temp)
        do {
            try await access.move(temp, to: commit)
            try await configuration.uploadTracker.waitForUpload(commit, timeout: configuration.uploadTimeout)
            // The manifest is the transaction commit point: it only counts as
            // published once it can be read back and decrypted.
            let readBack = try await loadManifest(generationID: generation.id)
            guard readBack.generationId == generation.id,
                  readBack.uniqueObjectHashes == Set(uniqueObjects.keys) else {
                throw CloudStoreError.manifestCorrupt("清单回读不一致")
            }
        } catch {
            let publishError = error
            if fileManager.fileExists(atPath: commit.path) {
                do {
                    try await access.remove(commit)
                } catch {
                    // A manifest that failed read-back must not remain visible as a
                    // published generation; if it cannot be removed, say so loudly.
                    throw CloudStoreError.manifestCorrupt(
                        "发布失败且无法移除未验证清单：\(error.localizedDescription)；原始错误：\(publishError.localizedDescription)"
                    )
                }
            }
            try? await access.remove(temp)
            throw publishError
        }

        // The manifest is committed. Recovery-info and the object index are
        // rebuildable metadata: a failure here must not turn a published
        // generation into a failed one.
        do {
            try await writeRecoveryInfo()
        } catch {
            configuration.warningHandler?("已发布清单，但 recovery-info 写入失败：\(error.localizedDescription)")
        }
        do {
            try await configuration.indexStore.saveObjectIndex(
                scan.result.entries,
                repositoryID: configuration.repositoryID
            )
        } catch {
            configuration.warningHandler?("已发布清单，但对象索引写入失败：\(error.localizedDescription)")
        }
    }

    /// True only when the manifest exists, downloads, decrypts and is confirmed by
    /// the upload tracker. Used to turn a post-commit failure into idempotent success.
    public func confirmPublished(generationId: UUID) async -> Bool {
        let commit = commitURL(generationId)
        guard fileManager.fileExists(atPath: commit.path) else { return false }
        do {
            try await access.download(commit, timeout: 120)
            _ = try await loadManifest(generationID: generationId)
            try await configuration.uploadTracker.waitForUpload(
                commit,
                timeout: configuration.uploadTimeout
            )
            return true
        } catch {
            return false
        }
    }

    /// Bounded fan-out. Publish touches thousands of small objects; doing that
    /// strictly serially wastes the provider's parallel upload capacity, while
    /// unbounded tasks exhaust file descriptors.
    private func forEachConcurrently<T: Sendable>(
        _ items: [T],
        limit: Int? = nil,
        _ body: @Sendable @escaping (T) async throws -> Void
    ) async throws {
        guard !items.isEmpty else { return }
        let width = max(1, min(limit ?? configuration.uploadParallelism, items.count))
        try await withThrowingTaskGroup(of: Void.self) { group in
            var index = 0
            for _ in 0..<width {
                let item = items[index]
                index += 1
                group.addTask { try await body(item) }
            }
            while let _ = try await group.next() {
                if index < items.count {
                    let item = items[index]
                    index += 1
                    group.addTask { try await body(item) }
                }
            }
        }
    }

    /// Enforces the publish invariants before the manifest becomes visible.
    private func validate(manifest: CloudManifest) throws {
        guard manifest.formatVersion == formatVersion else {
            throw CloudStoreError.manifestCorrupt("清单格式版本 \(manifest.formatVersion)")
        }
        // Verify aggregate integrity: repositoryHash pins the exact sorted file
        // list, totalBytes pins the total payload size.
        let recomputedHash = try ManifestIntegrityHasher.hash(files: manifest.repositoryFiles)
        guard manifest.integrity.repositoryHash == recomputedHash else {
            throw CloudStoreError.manifestCorrupt("repositoryHash 不匹配")
        }
        let recomputedBytes = manifest.repositoryFiles.reduce(Int64(0)) { $0 + $1.size }
        guard manifest.integrity.totalBytes == recomputedBytes else {
            throw CloudStoreError.manifestCorrupt("totalBytes 不匹配")
        }
        guard manifest.objectAlgorithm == objectAlgorithm else {
            throw CloudStoreError.manifestCorrupt("对象算法 \(manifest.objectAlgorithm)")
        }
        guard manifest.integrity.fileCount == manifest.repositoryFiles.count else {
            throw CloudStoreError.manifestCorrupt("文件数量不一致")
        }
        let unique = manifest.uniqueObjectHashes
        guard unique.count == manifest.integrity.uniqueObjectCount else {
            throw CloudStoreError.manifestCorrupt("对象数量不一致")
        }
        guard !manifest.repositoryFiles.isEmpty else {
            throw CloudStoreError.manifestCorrupt("清单为空")
        }
        var seen = Set<String>()
        for file in manifest.repositoryFiles {
            _ = try Self.validatedRelativePath(file.relativePath)
            guard seen.insert(file.relativePath).inserted else {
                throw CloudStoreError.manifestCorrupt("重复路径 \(file.relativePath)")
            }
            guard file.size >= 0 else {
                throw CloudStoreError.manifestCorrupt("非法大小 \(file.relativePath)")
            }
        }
    }

    // MARK: - Repository scan and object storage

    private func scanRepository(previousEntries: [CloudObjectIndexEntry]?) async throws -> (result: RepositoryScanResult, items: [ScanItem]) {
        let root = configuration.repositoryURL.standardizedFileURL
        let rootPath = root.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]

        var index: [String: CloudObjectIndexEntry] = [:]
        if let previousEntries {
            for entry in previousEntries { index[entry.relativePath] = entry }
        } else {
            for entry in (try? await configuration.indexStore.loadObjectIndex(repositoryID: configuration.repositoryID)) ?? [] {
                index[entry.relativePath] = entry
            }
        }

        var enumerationErrors: [String] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                enumerationErrors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                return true
            }
        ) else {
            throw CloudStoreError.objectCorrupt("无法读取本地仓库目录")
        }

        var items: [ScanItem] = []
        while let object = enumerator.nextObject() {
            if items.count >= configuration.maxScannedFiles {
                enumerationErrors.append("扫描文件数超过上限 \(configuration.maxScannedFiles)")
                break
            }
            guard let url = object as? URL else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            if values?.isSymbolicLink == true { continue }
            var relative = url.standardizedFileURL.path
            guard relative.hasPrefix(rootPath) else { continue }
            relative = String(relative.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty, !relative.hasSuffix(".tmp") else { continue }
            guard !relative.split(separator: "/").contains(".tmp") else { continue }

            guard let stamp = Self.stamp(of: url) else {
                enumerationErrors.append("\(relative)：无法读取文件属性")
                continue
            }

            var hash: String?
            if let cached = index[relative],
               cached.matches(
                   identity: stamp.identity,
                   size: stamp.size,
                   modifiedAt: stamp.modifiedAt,
                   changedAt: stamp.changedAt
               ) {
                hash = cached.sha256
            }
            if hash == nil,
               let cached = try? await configuration.hashCacheStore.loadHashCache(
                   repositoryID: configuration.repositoryID,
                   paths: [relative]
               )[relative],
               cached.matches(
                   identity: stamp.identity,
                   size: stamp.size,
                   modifiedAt: stamp.modifiedAt,
                   changedAt: stamp.changedAt
               ) {
                hash = cached.contentHash
            }
            if hash == nil {
                hash = try await hashStable(url: url, initial: stamp, relativePath: relative)
            }
            items.append(ScanItem(relativePath: relative, url: url, stamp: stamp, hash: hash!))
        }

        let entries = items.map { item in
            CloudObjectIndexEntry(
                relativePath: item.relativePath,
                size: item.stamp.size,
                modifiedAt: item.stamp.modifiedAt,
                changedAt: item.stamp.changedAt,
                fileIdentity: item.stamp.identity,
                sha256: item.hash,
                lastVerifiedAt: Date(),
                uploadState: .pending
            )
        }
        try? await configuration.hashCacheStore.saveHashCache(
            items.map { item in
                ObjectHashCacheEntry(
                    relativePath: item.relativePath,
                    fileIdentity: item.stamp.identity,
                    size: item.stamp.size,
                    modifiedAt: item.stamp.modifiedAt,
                    changedAt: item.stamp.changedAt,
                    contentHash: item.hash,
                    verifiedAt: Date()
                )
            },
            repositoryID: configuration.repositoryID
        )
        let result = RepositoryScanResult(
            entries: entries,
            isComplete: enumerationErrors.isEmpty,
            skippedPaths: enumerationErrors,
            errorCount: enumerationErrors.count,
            scannedAt: Date()
        )
        return (result, items)
    }

    /// Hashes a file and fails if the file changes while it is being read.
    private func hashStable(url: URL, initial: FileStamp, relativePath: String) async throws -> String {
        let first = try await access.hash(url)
        guard let after = Self.stamp(of: url) else {
            throw CloudStoreError.objectCorrupt("文件在哈希期间消失：\(relativePath)")
        }
        if after != initial {
            let second = try await access.hash(url)
            guard let final = Self.stamp(of: url), final == after else {
                throw CloudStoreError.objectCorrupt("文件在哈希期间持续变化：\(relativePath)")
            }
            return second
        }
        return first
    }

    private func storeObject(hash: String, source: URL, expected: FileStamp) async throws {
        let target = objectURL(hash)
        if fileManager.fileExists(atPath: target.path) {
            let existing: String
            do {
                existing = try await access.hash(target)
            } catch {
                // An unverifiable existing object is preserved in quarantine and
                // reported, never overwritten or silently accepted.
                try await quarantine(objectHash: hash)
                throw CloudStoreError.objectCorrupt("无法校验已存在对象 \(hash)：\(error.localizedDescription)")
            }
            if existing == hash { return }
            try await quarantine(objectHash: hash)
            throw CloudStoreError.objectQuarantined(hash)
        }

        try await access.ensureDirectory(target.deletingLastPathComponent())
        let temp = target.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try await access.copy(source, to: temp)
            let tempHash = try await access.hash(temp)
            guard tempHash == hash else {
                throw CloudStoreError.objectCorrupt("源文件在复制期间变化：\(hash)")
            }
            guard let current = Self.stamp(of: source), current == expected else {
                throw CloudStoreError.objectCorrupt("源文件在复制期间变化：\(hash)")
            }
            if fileManager.fileExists(atPath: target.path) {
                // Another writer won the race; keep the verified copy only if it matches.
                let existing: String
                do {
                    existing = try await access.hash(target)
                } catch {
                    try await quarantine(objectHash: hash)
                    throw CloudStoreError.objectCorrupt("无法校验并发写入对象 \(hash)：\(error.localizedDescription)")
                }
                if existing == hash {
                    try? await access.remove(temp)
                    return
                }
                try await quarantine(objectHash: hash)
                throw CloudStoreError.objectQuarantined(hash)
            }
            try await access.move(temp, to: target)
        } catch {
            try? await access.remove(temp)
            throw error
        }
    }

    private func quarantine(objectHash: String) async throws {
        let target = objectURL(objectHash)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try await access.ensureDirectory(quarantineURL)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let destination = quarantineURL.appendingPathComponent("\(objectHash)-\(stamp)")
        try await access.move(target, to: destination)
    }

    private func verifyStoredObject(hash: String, expectedSize: Int64) async throws {
        let url = objectURL(hash)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CloudStoreError.objectMissing(hash)
        }
        // A dataless iCloud placeholder can report an incomplete size; download it
        // before the size/hash checks so eviction is not reported as corruption.
        try await access.download(url, timeout: 300)
        guard let stamp = Self.stamp(of: url), stamp.size == expectedSize else {
            throw CloudStoreError.objectCorrupt(hash)
        }
        let actual = try await access.hash(url)
        guard actual == hash else {
            throw CloudStoreError.objectCorrupt(hash)
        }
    }

    private static func stamp(of url: URL) -> FileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let seconds = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        let changed = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
        return FileStamp(
            identity: "\(info.st_dev):\(info.st_ino)",
            size: Int64(info.st_size),
            modifiedAt: Date(timeIntervalSince1970: seconds),
            changedAt: Date(timeIntervalSince1970: changed)
        )
    }

    // MARK: - Listing and manifests

    /// Full enumeration. A listing failure is an error, never an empty result.
    private func manifestURLs() async throws -> [URL] {
        try await access.list(commitsURL, keys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "ctm" }
    }

    private func tombstoneURLs() async throws -> [URL] {
        // A missing tombstones directory simply means no GC has tombstoned yet.
        guard fileManager.fileExists(atPath: tombstonesURL.path) else { return [] }
        return try await access.list(tombstonesURL, keys: [.isRegularFileKey]).filter { $0.pathExtension == "ctm" }
    }

    public func listGenerationEntries(repositoryId: UUID) async throws -> [CloudGenerationEntry] {
        try await prepare()
        var entries: [CloudGenerationEntry] = []
        for url in try await manifestURLs() {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                continue
            }
            let commitDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let state = Self.unreadableState(of: url), state != .current {
                if state == .notDownloaded || state == .downloading {
                    do {
                        try await access.download(url, timeout: 120)
                    } catch {
                        entries.append(CloudGenerationEntry(
                            id: id,
                            readState: .notDownloaded,
                            detail: error.localizedDescription,
                            manifestPath: url.path,
                            manifestModifiedAt: commitDate
                        ))
                        continue
                    }
                } else if case .unavailable(let detail) = state {
                    entries.append(CloudGenerationEntry(
                        id: id,
                        readState: .unreadable,
                        detail: detail,
                        manifestPath: url.path,
                        manifestModifiedAt: commitDate
                    ))
                    continue
                }
            }
            do {
                let manifest = try await loadManifest(generationID: id)
                let hash: String
                let hashDetail: String?
                do {
                    hash = try await access.hash(url)
                    hashDetail = nil
                } catch {
                    // The generation is decryptable, but its bytes could not be
                    // re-read for verification. Report that instead of pretending
                    // an empty hash is a real digest.
                    hash = ""
                    hashDetail = "无法计算清单哈希：\(error.localizedDescription)"
                }
                let publishedAt = commitDate ?? manifest.createdAt
                let generation = CloudGeneration(
                    id: id,
                    repositoryID: manifest.repositoryId,
                    deviceID: manifest.deviceId,
                    createdAt: manifest.createdAt,
                    publishedAt: publishedAt,
                    state: .published,
                    manifestHash: hash,
                    objectCount: manifest.integrity.uniqueObjectCount,
                    byteSize: manifest.integrity.totalBytes,
                    snapshotIDs: manifest.sourceSnapshotIds,
                    uploadedObjectCount: manifest.integrity.uniqueObjectCount,
                    verifiedAt: nil
                )
                entries.append(CloudGenerationEntry(
                    id: id,
                    generation: generation,
                    readState: .valid,
                    detail: hashDetail,
                    manifestPath: url.path,
                    manifestModifiedAt: publishedAt
                ))
            } catch let error as CloudStoreError {
                let state: GenerationReadState
                switch error {
                case .manifestNotDownloaded: state = .notDownloaded
                case .unsupportedFormat: state = .unsupportedVersion
                default: state = .corrupted
                }
                entries.append(CloudGenerationEntry(
                    id: id,
                    readState: state,
                    detail: error.localizedDescription,
                    manifestPath: url.path,
                    manifestModifiedAt: commitDate
                ))
            } catch {
                entries.append(CloudGenerationEntry(
                    id: id,
                    readState: .corrupted,
                    detail: error.localizedDescription,
                    manifestPath: url.path,
                    manifestModifiedAt: commitDate
                ))
            }
        }
        // Manifest timestamps are ISO-8601 with second precision, so two versions
        // published in the same second tie. Commit-file modification time is the
        // real publication order and breaks the tie deterministically.
        return entries.sorted {
            let left = $0.generation
            let right = $1.generation
            let leftDate = $0.manifestModifiedAt ?? left?.publishedAt ?? left?.createdAt ?? .distantPast
            let rightDate = $1.manifestModifiedAt ?? right?.publishedAt ?? right?.createdAt ?? .distantPast
            if leftDate == rightDate { return $0.id.uuidString > $1.id.uuidString }
            return leftDate > rightDate
        }
    }

    public func listGenerations(repositoryId: UUID) async throws -> [CloudGeneration] {
        try await listGenerationEntries(repositoryId: repositoryId)
            .compactMap(\.generation)
            .sorted {
                let leftDate = $0.publishedAt ?? $0.createdAt
                let rightDate = $1.publishedAt ?? $1.createdAt
                if leftDate == rightDate { return $0.id.uuidString > $1.id.uuidString }
                return leftDate > rightDate
            }
    }

    private func commitModificationDate(_ id: UUID) -> Date? {
        (try? commitURL(id).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func unreadableState(of url: URL) -> CloudItemState? {
        let state = UbiquitousFiles.state(of: url)
        switch state {
        case .local, .current: return .current
        default: return state
        }
    }

    private func commitURL(_ generationID: UUID) -> URL {
        commitsURL.appendingPathComponent("\(generationID.uuidString).ctm")
    }

    private func loadManifest(generationID: UUID) async throws -> CloudManifest {
        let commit = commitURL(generationID)
        guard fileManager.fileExists(atPath: commit.path) else {
            throw CloudStoreError.manifestUnavailable(generationID.uuidString)
        }
        switch UbiquitousFiles.state(of: commit) {
        case .notDownloaded, .downloading:
            do { try await access.download(commit, timeout: 120) }
            catch { throw CloudStoreError.manifestNotDownloaded(generationID.uuidString) }
        case .unavailable(let detail):
            throw CloudStoreError.manifestUnavailable(detail)
        default:
            break
        }
        let sealed: Data
        do { sealed = try await access.read(commit) }
        catch { throw CloudStoreError.manifestUnavailable(error.localizedDescription) }

        let key = try configuration.masterKeyProvider.masterKey()
        let data: Data
        do {
            data = try CryptoBox.open(
                sealed,
                masterKey: key,
                context: manifestContext(generationID: generationID)
            )
        } catch {
            throw CloudStoreError.manifestCorrupt("无法解密清单（密钥不匹配或文件损坏）")
        }
        let manifest: CloudManifest
        do { manifest = try decoder.decode(CloudManifest.self, from: data) }
        catch { throw CloudStoreError.manifestCorrupt("清单无法解析") }

        guard manifest.formatVersion == formatVersion else {
            throw CloudStoreError.unsupportedFormat("清单版本 \(manifest.formatVersion)")
        }
        guard manifest.repositoryId == configuration.repositoryID,
              manifest.generationId == generationID else {
            throw CloudStoreError.manifestCorrupt("清单元数据不一致")
        }
        return manifest
    }

    // MARK: - Restore

    public struct RestoreProgress: Sendable {
        public var totalFiles: Int
        public var completedFiles: Int
        public var totalBytes: Int64
        public var completedBytes: Int64
        public var currentPath: String?
    }

    /// Protocol entry point: no resume, no progress reporting.
    public func restoreRepository(generationId: UUID, destination: URL) async throws {
        try await restoreRepository(
            generationId: generationId,
            destination: destination,
            allowResume: false,
            progress: nil
        )
    }

    /// Restores into a staging directory. Existing files inside the destination are
    /// re-verified and reused, which makes an interrupted restore resumable without
    /// trusting unverified content.
    public func restoreRepository(
        generationId: UUID,
        destination: URL,
        allowResume: Bool = false,
        progress: (@Sendable (RestoreProgress) async -> Void)? = nil
    ) async throws {
        try await prepare()
        let manifest = try await loadManifest(generationID: generationId)
        try validate(manifest: manifest)

        let dest = destination.standardizedFileURL
        if fileManager.fileExists(atPath: dest.path) {
            let contents = try fileManager.contentsOfDirectory(atPath: dest.path)
            if !contents.isEmpty && !allowResume {
                throw CodeTimeError.destinationExists(dest.path)
            }
            if allowResume {
                // A previous process may have died while writing a staging file.
                // These temp files are never part of the manifest.
                removeRestoreTemps(in: dest)
            }
        } else {
            try await access.ensureDirectory(dest)
        }

        let total = manifest.repositoryFiles.count
        var completed = 0
        var completedBytes: Int64 = 0
        await progress?(RestoreProgress(
            totalFiles: total,
            completedFiles: 0,
            totalBytes: manifest.integrity.totalBytes,
            completedBytes: 0,
            currentPath: nil
        ))

        for file in manifest.repositoryFiles {
            try Task.checkCancellation()
            let relative = try Self.validatedRelativePath(file.relativePath)
            let object = objectURL(file.contentHash)
            guard fileManager.fileExists(atPath: object.path) else {
                throw CloudStoreError.objectMissing(file.contentHash)
            }
            switch UbiquitousFiles.state(of: object) {
            case .notDownloaded, .downloading:
                do { try await access.download(object, timeout: 300) }
                catch { throw CloudStoreError.notDownloaded(file.contentHash) }
            case .unavailable(let detail):
                throw CloudStoreError.notDownloaded(detail)
            default:
                break
            }

            let target = dest.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: target.path) {
                if allowResume {
                    let kind = try target.resourceValues(forKeys: [.isDirectoryKey])
                    guard kind.isDirectory != true else {
                        throw CodeTimeError.destinationExists(target.path)
                    }
                    if let existingHash = try? await access.hash(target), existingHash == file.contentHash {
                        completed += 1
                        completedBytes += file.size
                        await progress?(RestoreProgress(
                            totalFiles: total,
                            completedFiles: completed,
                            totalBytes: manifest.integrity.totalBytes,
                            completedBytes: completedBytes,
                            currentPath: relative
                        ))
                        continue
                    }
                    // A partial or damaged file from an interrupted copy is not a
                    // reason to give up: the verified temp file replaces it below.
                } else {
                    throw CodeTimeError.destinationExists(target.path)
                }
            }

            try await verifyStoredObject(hash: file.contentHash, expectedSize: file.size)
            try await installObjectAtomically(
                object: object,
                target: target,
                contentHash: file.contentHash,
                size: file.size,
                relativePath: relative
            )
            completed += 1
            completedBytes += file.size
            await progress?(RestoreProgress(
                totalFiles: total,
                completedFiles: completed,
                totalBytes: manifest.integrity.totalBytes,
                completedBytes: completedBytes,
                currentPath: relative
            ))
        }
    }

    private func removeRestoreTemps(in destination: URL) {
        guard let enumerator = fileManager.enumerator(at: destination, includingPropertiesForKeys: nil) else {
            return
        }
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix(".ctrestore-") {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Copy to a sibling temp file, verify it, then atomically move it into place.
    /// A crash can therefore leave only an ignorable temp file, never a target that
    /// looks complete but contains partial bytes.
    private func installObjectAtomically(
        object: URL,
        target: URL,
        contentHash: String,
        size: Int64,
        relativePath: String
    ) async throws {
        try await access.ensureDirectory(target.deletingLastPathComponent())
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".ctrestore-\(UUID().uuidString)")
        do {
            try await access.copy(object, to: temp)
            guard let stamp = Self.stamp(of: temp), stamp.size == size else {
                throw CloudStoreError.restoreInterrupted("复制后大小不一致：\(relativePath)")
            }
            let copiedHash = try await access.hash(temp)
            guard copiedHash == contentHash else {
                throw CloudStoreError.restoreInterrupted("复制后哈希不一致：\(relativePath)")
            }
            if fileManager.fileExists(atPath: target.path) {
                try await access.remove(target)
            }
            try await access.move(temp, to: target)
        } catch {
            try? await access.remove(temp)
            if error is CloudStoreError { throw error }
            throw CloudStoreError.restoreInterrupted("\(relativePath)：\(error.localizedDescription)")
        }
    }

    // MARK: - Verification

    public func verifyGeneration(_ generationId: UUID) async throws -> VerificationResult {
        try await prepare()
        let manifest: CloudManifest
        do {
            manifest = try await loadManifest(generationID: generationId)
            try validate(manifest: manifest)
        } catch {
            return VerificationResult(
                generationID: generationId,
                level: .cloudIntegrity,
                outcome: .failed,
                details: "清单不可用：\(error.localizedDescription)"
            )
        }
        var bytes: Int64 = 0
        var verified = 0
        var failures: [String] = []
        for file in manifest.repositoryFiles {
            do {
                try await verifyStoredObject(hash: file.contentHash, expectedSize: file.size)
                verified += 1
                bytes += file.size
            } catch {
                failures.append("\(file.relativePath)：\(error.localizedDescription)")
            }
        }
        let complete = failures.isEmpty && verified == manifest.repositoryFiles.count && !manifest.repositoryFiles.isEmpty
        return VerificationResult(
            generationID: generationId,
            level: .cloudIntegrity,
            outcome: complete ? .passed : .failed,
            details: complete
                ? "校验 \(manifest.repositoryFiles.count) 个对象、\(manifest.integrity.uniqueObjectCount) 个唯一哈希"
                : "校验失败（\(failures.count) 项）：\(failures.prefix(3).joined(separator: "；"))",
            bytesChecked: bytes
        )
    }

    public func storageSummary(repositoryId: UUID) async throws -> CloudStorageSummary {
        try await prepare()
        let generations = try await listGenerations(repositoryId: repositoryId)
        var count = 0
        var bytes: Int64 = 0
        for prefix in try await accessingObjectPrefixes() {
            let files = try await access.list(prefix, keys: [.fileSizeKey])
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

    private func accessingObjectPrefixes() async throws -> [URL] {
        let entries = try await access.list(objectsURL, keys: [.isDirectoryKey])
        return entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && url.lastPathComponent != quarantineURL.lastPathComponent
        }
    }

    // MARK: - Garbage collection (§3.7)

    /// CT-105: pure read-only GC preview used when physical deletion is disabled.
    /// Computes the retention decision and the object set that WOULD be deleted.
    /// Any unreadable manifest fails safe (nothing is reported as deletable).
    private func cleanupPreview(
        repositoryId: UUID,
        gracePeriod: TimeInterval,
        minimumGenerations: Int
    ) async throws -> CloudCleanupReport {
        let urls: [URL]
        do {
            urls = try await manifestURLs().filter {
                UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
            }
        } catch {
            return CloudCleanupReport(
                retainedGenerations: 0,
                skippedReason: "无法枚举云端清单（\(error.localizedDescription)），GC 仅保留数据"
            )
        }
        var entries: [(url: URL, manifest: CloudManifest)] = []
        for url in urls {
            do {
                let manifest = try await loadManifestFromURL(url)
                entries.append((url, manifest))
            } catch {
                return CloudCleanupReport(
                    retainedGenerations: 0,
                    skippedReason: "存在不可读清单（\(url.lastPathComponent)），无法证明删除安全，已保留全部对象"
                )
            }
        }
        entries.sort { $0.manifest.createdAt > $1.manifest.createdAt }
        let cutoff = Date().addingTimeInterval(-max(0, gracePeriod))
        let protectedCount = max(2, minimumGenerations)
        var protectedHashes = Set<String>()
        var doomedHashes: [String] = []
        var doomedGenerations = 0
        for (index, entry) in entries.enumerated() {
            let isProtected = index < protectedCount || entry.manifest.createdAt > cutoff
            if isProtected {
                protectedHashes.formUnion(entry.manifest.repositoryFiles.map(\.contentHash))
            } else {
                doomedGenerations += 1
                doomedHashes.append(contentsOf: entry.manifest.repositoryFiles.map(\.contentHash))
            }
        }
        let planned = Set(doomedHashes).subtracting(protectedHashes)
        var plannedBytes: Int64 = 0
        for hash in planned {
            if let values = try? objectURL(hash).resourceValues(forKeys: [.fileSizeKey]) {
                plannedBytes += Int64(values.fileSize ?? 0)
            }
        }
        _ = plannedBytes
        return CloudCleanupReport(
            deletedObjects: 0,
            freedBytes: 0,
            retainedGenerations: entries.count,
            skippedReason: "安全策略：iCloud 模式默认只生成待清理列表，不执行物理删除（可在“立即清理”中显式确认）",
            plannedDeletes: planned.count,
            plannedGenerationDeletes: doomedGenerations
        )
    }

    private func loadManifestFromURL(_ url: URL) async throws -> CloudManifest {
        guard let generationID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
            throw CloudStoreError.invalidFormat(url.lastPathComponent)
        }
        let data: Data
        do {
            data = try await access.read(url)
        } catch {
            throw CloudStoreError.manifestUnavailable(error.localizedDescription)
        }
        do {
            let plaintext = try CryptoBox.open(
                data,
                masterKey: try configuration.masterKeyProvider.masterKey(),
                context: manifestContext(generationID: generationID)
            )
            return try decoder.decode(CloudManifest.self, from: plaintext)
        } catch {
            throw CloudStoreError.manifestCorrupt(url.lastPathComponent)
        }
    }

    /// CT-105: explicit device retirement. Only a deliberate user action writes
    /// this record; a device is never retired because it is offline or old.
    public func retireDevice(_ deviceID: UUID, reason: String) async throws {
        guard deviceID != configuration.deviceID else {
            throw CloudStoreError.invalidFormat("不能退役当前设备")
        }
        let directory = baseURL.appendingPathComponent("devices/\(deviceID.uuidString)", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CloudStoreError.objectMissing("设备目录不存在：\(deviceID.uuidString)")
        }
        let record: [String: String] = [
            "deviceID": deviceID.uuidString,
            "retiredAt": ISO8601DateFormatter().string(from: Date()),
            "retiredBy": configuration.deviceID.uuidString,
            "reason": reason,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await access.writeAtomically(
            try encoder.encode(record),
            to: directory.appendingPathComponent("retired.json")
        )
    }

    /// `CloudStore` conformance: same as the explicit policy overload with the
    /// safest default (report-only for iCloud).
    public func cleanup(
        repositoryId: UUID,
        gracePeriod: TimeInterval,
        minimumGenerations: Int
    ) async throws -> CloudCleanupReport {
        try await cleanup(
            repositoryId: repositoryId,
            gracePeriod: gracePeriod,
            minimumGenerations: minimumGenerations,
            allowPhysicalDelete: false
        )
    }

    /// CT-105: iCloud has no cross-device deletion acknowledgement, so physical
    /// deletion is REPORT-ONLY by default for coordinated (iCloud) storage. Only
    /// an explicit user action passes `allowPhysicalDelete: true`; automatic
    /// maintenance never does. Non-coordinated (local mirror) stores keep the
    /// previous behaviour.
    public func cleanup(
        repositoryId: UUID,
        gracePeriod: TimeInterval,
        minimumGenerations: Int,
        allowPhysicalDelete: Bool
    ) async throws -> CloudCleanupReport {
        guard repositoryId == configuration.repositoryID else {
            throw CloudStoreError.invalidFormat("仓库 ID 与存储配置不匹配")
        }
        // GC only touches cloud objects/manifests. It must not hold the local
        // Kopia repository lock while scanning a large cloud tree; the publish
        // lock is the synchronization point with an in-flight upload.
        let publishLock = try await acquirePublishLock()
        defer { publishLock?.release() }

        // Cross-Mac safety FIRST (CT-087/CT-089, before any prepare side
        // effects): skip physical deletion if other devices exist, and fail
        // closed when the device directory itself cannot be read.
        let devicesDir = baseURL.appendingPathComponent("devices", isDirectory: true)
        let allDevices: [URL]
        do {
            // CT-105: coordinated access — the device list is iCloud state, so it
            // must not bypass NSFileCoordinator with a raw FileManager read.
            allDevices = try await access.list(
                devicesDir,
                keys: [.isDirectoryKey, .isRegularFileKey]
            )
        } catch {
            return CloudCleanupReport(
                retainedGenerations: 0,
                skippedReason: "无法读取设备目录（\(error.localizedDescription)），GC 已暂停"
            )
        }
        let otherDevices = allDevices.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir, url.lastPathComponent != configuration.deviceID.uuidString else { return false }
            // CT-105: only an EXPLICIT retirement record lets GC ignore a device.
            // A device that is merely offline / not yet synced is never retired.
            let retired = url.appendingPathComponent("retired.json")
            return !fileManager.fileExists(atPath: retired.path)
        }
        if !otherDevices.isEmpty {
            return CloudCleanupReport(
                retainedGenerations: 0,
                skippedReason: "检测到 \(otherDevices.count) 台其他设备的仓库；多设备 GC 需要分布式协调，已跳过物理删除"
            )
        }

        try await prepare()

        // CT-105: report-only mode. Compute what would be deleted, tombstone
        // nothing, delete nothing. This runs before any journal side effect so a
        // preview can never leave the store in a half-GC state.
        let physicalDeletionAllowed = allowPhysicalDelete || !configuration.coordinatedIO
        if !physicalDeletionAllowed {
            let reportOnly = try await cleanupPreview(
                repositoryId: repositoryId,
                gracePeriod: gracePeriod,
                minimumGenerations: minimumGenerations
            )
            return reportOnly
        }

        let now = Date()
        let loadedJournal: GCJournal?
        do {
            loadedJournal = try await configuration.journalStore.loadUnfinishedGCJournal(repositoryID: repositoryId)
        } catch {
            // Starting over would forget which manifests were already tombstoned
            // and which objects were already deleted, so this must fail closed.
            throw CloudStoreError.gcJournalCorrupted("无法读取清理日志：\(error.localizedDescription)")
        }
        var gc: GCJournal
        if let loaded = loadedJournal, loaded.phase == .aborted {
            // An aborted journal may have left tombstones that were never restored.
            // They are valid history until proven otherwise; restore them before a
            // fresh run, or block GC if that is not possible.
            do {
                try await restoreTombstones()
            } catch {
                throw CloudStoreError.gcBlocked(
                    "上一次清理中止且墓碑清单无法恢复：\(error.localizedDescription)"
                )
            }
            do {
                try await configuration.journalStore.deleteGCJournal(id: loaded.id)
            } catch {
                throw CloudStoreError.gcJournalCorrupted(
                    "无法清理已中止的 GC 日志：\(error.localizedDescription)"
                )
            }
            gc = GCJournal(repositoryID: repositoryId, startedAt: now)
        } else {
            gc = loadedJournal ?? GCJournal(repositoryID: repositoryId, startedAt: now)
        }
        // `gracePeriod` is the user retention window for generations. The delay
        // before deleting objects is the separate synchronization grace: it must
        // never shrink to zero just because the user chose a zero-day retention.
        let sweepGrace = max(0, configuration.sweepGrace)
        let cutoff = now.addingTimeInterval(-max(0, gracePeriod))

        func persist(_ phase: GCPhase, error: String? = nil) async throws {
            gc.phase = phase
            gc.updatedAt = Date()
            gc.lastError = error
            do {
                try await configuration.journalStore.saveGCJournal(gc)
            } catch {
                throw CloudStoreError.gcJournalCorrupted(
                    "无法保存清理日志（\(phase.rawValue)）：\(error.localizedDescription)"
                )
            }
        }

        // Phase 1: complete enumeration. Any unreadable manifest aborts the run;
        // we never operate on a filtered "visible" list.
        if gc.phase == .enumerating || gc.phase == .marking || gc.protectedGenerations.isEmpty {
            var manifests: [UUID: CloudManifest] = [:]
            var failure: String?
            for url in try await manifestURLs() {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    failure = "无法识别的清单文件名：\(url.lastPathComponent)"
                    break
                }
                do { manifests[id] = try await loadManifest(generationID: id) }
                catch {
                    failure = "清单 \(id.uuidString) 无法读取：\(error.localizedDescription)"
                    break
                }
            }
            if let failure {
                try await persist(.aborted, error: failure)
                return CloudCleanupReport(retainedGenerations: manifests.count, skippedReason: failure)
            }
            try await persist(.marking)

            let ordered = manifests.keys.sorted { lhs, rhs in
                let leftCreated = manifests[lhs]?.createdAt ?? .distantPast
                let rightCreated = manifests[rhs]?.createdAt ?? .distantPast
                if leftCreated != rightCreated { return leftCreated > rightCreated }
                let leftCommit = commitModificationDate(lhs) ?? .distantPast
                let rightCommit = commitModificationDate(rhs) ?? .distantPast
                if leftCommit != rightCommit { return leftCommit > rightCommit }
                return lhs.uuidString > rhs.uuidString
            }
            let minimum = max(2, minimumGenerations)
            var protected: [UUID] = []
            for (index, id) in ordered.enumerated() {
                if index < minimum { protected.append(id); continue }
                guard let createdAt = manifests[id]?.createdAt else { continue }
                if createdAt > cutoff { protected.append(id) }
            }
            let deleteIDs = ordered.filter { !protected.contains($0) }
            gc.protectedGenerations = protected
            gc.plannedManifestDeletes = deleteIDs

            // Every protected generation must be complete before we touch anything.
            for id in protected {
                guard let manifest = manifests[id] else {
                    let message = "保留版本 \(id.uuidString) 清单不可用"
                    try await persist(.aborted, error: message)
                    return CloudCleanupReport(retainedGenerations: protected.count, skippedReason: message)
                }
                for file in manifest.repositoryFiles {
                    guard fileManager.fileExists(atPath: objectURL(file.contentHash).path) else {
                        let message = "保留版本引用缺失对象 \(file.contentHash)，清理已暂停"
                        try await persist(.aborted, error: message)
                        return CloudCleanupReport(retainedGenerations: protected.count, skippedReason: message)
                    }
                }
            }

            // Objects referenced by protected generations, plus every object that a
            // tombstoned manifest still points at, are never candidates yet.
            var protectedObjects = Set<String>()
            for id in protected {
                for file in manifests[id]?.repositoryFiles ?? [] { protectedObjects.insert(file.contentHash) }
            }
            for url in try await tombstoneURLs() {
                let name = url.deletingPathExtension().lastPathComponent
                let idPart = name.split(separator: ".").first.map(String.init) ?? ""
                guard let id = UUID(uuidString: idPart) else {
                    let message = "无法识别的墓碑文件名：\(url.lastPathComponent)，清理已暂停"
                    try await persist(.aborted, error: message)
                    return CloudCleanupReport(retainedGenerations: protected.count, skippedReason: message)
                }
                do {
                    let manifest = try await loadManifestFromTombstone(id: id, url: url)
                    for file in manifest.repositoryFiles { protectedObjects.insert(file.contentHash) }
                } catch {
                    // The tombstoned manifest may still reference objects; without
                    // reading it we cannot prove any object is unreferenced.
                    let message = "墓碑清单 \(id.uuidString) 无法读取：\(error.localizedDescription)，清理已暂停"
                    try await persist(.aborted, error: message)
                    return CloudCleanupReport(retainedGenerations: protected.count, skippedReason: message)
                }
            }
            var referencedByDeleted = Set<String>()
            for id in deleteIDs {
                for file in manifests[id]?.repositoryFiles ?? [] {
                    if !protectedObjects.contains(file.contentHash) { referencedByDeleted.insert(file.contentHash) }
                }
            }
            gc.plannedObjectDeletes = Array(referencedByDeleted)
            gc.updatedAt = Date()
            try await persist(.tombstoning)

            // Phase 2: tombstone manifests atomically, then enter the grace period.
            try await access.ensureDirectory(tombstonesURL)
            for id in gc.plannedManifestDeletes {
                let source = commitURL(id)
                guard fileManager.fileExists(atPath: source.path) else {
                    if !gc.completedManifestDeletes.contains(id) { gc.completedManifestDeletes.append(id) }
                    continue
                }
                let stamp = Int(Date().timeIntervalSince1970 * 1000)
                let destination = tombstonesURL.appendingPathComponent("\(id.uuidString).\(stamp).ctm")
                try await access.move(source, to: destination)
                if !gc.completedManifestDeletes.contains(id) { gc.completedManifestDeletes.append(id) }
                gc.updatedAt = Date()
                try await persist(.tombstoning)
            }
            gc.graceDeadline = Date().addingTimeInterval(sweepGrace)
            gc.updatedAt = Date()
            try await persist(.gracePeriod)
        }

        if gc.phase == .tombstoning {
            // A crash can interrupt the move loop. Finish every planned move
            // instead of entering the grace period with manifests still visible.
            try await access.ensureDirectory(tombstonesURL)
            for id in gc.plannedManifestDeletes {
                let source = commitURL(id)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let stamp = Int(Date().timeIntervalSince1970 * 1000)
                let destination = tombstonesURL.appendingPathComponent("\(id.uuidString).\(stamp).ctm")
                try await access.move(source, to: destination)
                if !gc.completedManifestDeletes.contains(id) { gc.completedManifestDeletes.append(id) }
                gc.updatedAt = Date()
                try await persist(.tombstoning)
            }
            gc.graceDeadline = gc.graceDeadline ?? Date().addingTimeInterval(sweepGrace)
            gc.updatedAt = Date()
            try await persist(.gracePeriod)
        } else if gc.phase == .deletingManifests || gc.phase == .awaitingSync {
            gc.graceDeadline = gc.graceDeadline ?? Date().addingTimeInterval(sweepGrace)
            gc.updatedAt = Date()
            try await persist(.gracePeriod)
        }

        if gc.phase == .gracePeriod {
            let deadline = gc.graceDeadline ?? Date()
            guard Date() >= deadline else {
                gc.updatedAt = Date()
                try await persist(.gracePeriod)
                return CloudCleanupReport(
                    deletedObjects: gc.completedObjectDeletes.count,
                    freedBytes: gc.freedBytes,
                    retainedGenerations: gc.protectedGenerations.count,
                    skippedReason: "等待宽限期结束（\(Int(deadline.timeIntervalSinceNow)) 秒）"
                )
            }
            gc.updatedAt = Date()
            try await persist(.revalidating)
        }

        // Phase 3: revalidate from scratch. Tombstones are restored on any doubt.
        if gc.phase == .revalidating || gc.phase == .sweepingObjects {
            var validObjects = Set<String>()
            var failure: String?
            for url in try await manifestURLs() {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    failure = "重新验证时发现无法识别的清单文件名：\(url.lastPathComponent)"
                    break
                }
                do {
                    let manifest = try await loadManifest(generationID: id)
                    for file in manifest.repositoryFiles { validObjects.insert(file.contentHash) }
                } catch {
                    failure = "重新验证时清单 \(id.uuidString) 不可读：\(error.localizedDescription)"
                    break
                }
            }
            if failure == nil {
                // Tombstones are still valid history until their grace period ends.
                // Their objects must stay protected even when the tombstone belongs
                // to an earlier, aborted GC run.
                for url in try await tombstoneURLs() {
                    let name = url.deletingPathExtension().lastPathComponent
                    let idPart = name.split(separator: ".").first.map(String.init) ?? ""
                    guard let id = UUID(uuidString: idPart) else {
                        failure = "重新验证时发现无法识别的墓碑文件名：\(url.lastPathComponent)"
                        break
                    }
                    // Tombstones planned by the current journal are already being
                    // deleted by this run; only unresolved tombstones (from a
                    // different/aborted plan) need extra object protection.
                    if gc.plannedManifestDeletes.contains(id)
                        || gc.completedManifestDeletes.contains(id) {
                        continue
                    }
                    do {
                        let manifest = try await loadManifestFromTombstone(id: id, url: url)
                        for file in manifest.repositoryFiles { validObjects.insert(file.contentHash) }
                    } catch {
                        failure = "重新验证时墓碑清单 \(id.uuidString) 不可读：\(error.localizedDescription)"
                        break
                    }
                }
            }
            if let failure {
                do {
                    try await restoreTombstones()
                } catch {
                    let message = "\(failure)；恢复墓碑清单失败：\(error.localizedDescription)"
                    try await persist(.aborted, error: message)
                    throw CloudStoreError.gcBlocked(message)
                }
                try await persist(.aborted, error: failure)
                return CloudCleanupReport(
                    retainedGenerations: gc.protectedGenerations.count,
                    skippedReason: failure
                )
            }
            try await persist(.sweepingObjects)

            var deleted = gc.completedObjectDeletes
            var freed = gc.freedBytes
            let sweepCutoff = Date().addingTimeInterval(-max(0, sweepGrace))
            for prefix in try await accessingObjectPrefixes() {
                for file in try await access.list(prefix, keys: [.fileSizeKey, .contentModificationDateKey]) {
                    let hash = file.lastPathComponent
                    if hash.hasPrefix(".tmp-") {
                        // Incomplete writes from a crashed upload are only removed
                        // after the grace period.
                        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? Date()
                        if modified <= sweepCutoff {
                            do { try await access.remove(file) }
                            catch { gc.lastError = "临时对象 \(file.lastPathComponent) 删除失败：\(error.localizedDescription)" }
                        }
                        continue
                    }
                    guard UUID(uuidString: hash) != nil || hash.count == 64 else { continue }
                    if validObjects.contains(hash) { continue }
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? Date()
                    guard modified <= sweepCutoff else { continue }
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    do {
                        try await access.remove(file)
                    } catch {
                        gc.lastError = "对象 \(hash) 删除失败：\(error.localizedDescription)"
                        continue
                    }
                    deleted.append(hash)
                    freed += size
                    gc.completedObjectDeletes = deleted
                    gc.freedBytes = freed
                    gc.updatedAt = Date()
                    try await persist(.sweepingObjects, error: gc.lastError)
                }
            }

            // Tombstoned manifests may only be removed once their grace period has
            // elapsed; the objects they referenced were already unreferenced above.
            for url in try await tombstoneURLs() {
                if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   modified <= sweepCutoff {
                    do { try await access.remove(url) }
                    catch { gc.lastError = "墓碑清单 \(url.lastPathComponent) 删除失败：\(error.localizedDescription)" }
                }
            }

            // Quarantined objects are preserved for forensic recovery, but they
            // must not grow forever. Keep them for at least 30 days after the
            // synchronization grace period.
            let quarantineCutoff = Date().addingTimeInterval(-max(sweepGrace, 30 * 86_400))
            if let enumerator = fileManager.enumerator(
                at: quarantineURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
            ) {
                for case let file as URL in enumerator {
                    guard let values = try? file.resourceValues(
                        forKeys: [.contentModificationDateKey, .isRegularFileKey]
                    ), values.isRegularFile == true,
                          let modified = values.contentModificationDate,
                          modified <= quarantineCutoff else { continue }
                    do { try await access.remove(file) }
                    catch { gc.lastError = "隔离对象 \(file.lastPathComponent) 清理失败：\(error.localizedDescription)" }
                }
            }

            gc.completedAt = Date()
            try await persist(.completed, error: gc.lastError)
            return CloudCleanupReport(
                deletedObjects: deleted.count,
                freedBytes: freed,
                retainedGenerations: gc.protectedGenerations.count
            )
        }

        if gc.phase == .completed {
            return CloudCleanupReport(
                deletedObjects: gc.completedObjectDeletes.count,
                freedBytes: gc.freedBytes,
                retainedGenerations: gc.protectedGenerations.count,
                skippedReason: "清理已完成"
            )
        }

        return CloudCleanupReport(
            deletedObjects: gc.completedObjectDeletes.count,
            freedBytes: gc.freedBytes,
            retainedGenerations: gc.protectedGenerations.count,
            skippedReason: gc.lastError ?? "清理已中止"
        )
    }

    private func loadManifestFromTombstone(id: UUID, url: URL) async throws -> CloudManifest {
        let data = try await access.read(url)
        let key = try configuration.masterKeyProvider.masterKey()
        let plaintext = try CryptoBox.open(data, masterKey: key, context: manifestContext(generationID: id))
        return try decoder.decode(CloudManifest.self, from: plaintext)
    }

    private func restoreTombstones() async throws {
        for url in try await tombstoneURLs() {
            let name = url.deletingPathExtension().lastPathComponent
            guard let idPart = name.split(separator: ".").first, UUID(uuidString: String(idPart)) != nil else { continue }
            let destination = commitsURL.appendingPathComponent("\(idPart).ctm")
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try await access.move(url, to: destination)
        }
    }

    // MARK: - Helpers

    private func acquireRepositoryLock() async throws -> ProcessFileLock? {
        guard let lockURL = configuration.lockURL else { return nil }
        let lock = ProcessFileLock(path: lockURL.path)
        try await lock.acquire(timeout: 600)
        return lock
    }

    private func acquirePublishLock() async throws -> ProcessFileLock? {
        guard let lockURL = configuration.publishLockURL else { return nil }
        let lock = ProcessFileLock(path: lockURL.path)
        try await lock.acquire(timeout: 600)
        return lock
    }

    private func objectURL(_ hash: String) -> URL {
        objectsURL
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    private func manifestContext(generationID: UUID) -> String {
        "manifest:\(configuration.repositoryID.uuidString):\(generationID.uuidString)"
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

    // MARK: - Cross-process lock

    private final class ProcessFileLock: @unchecked Sendable {
        private let path: String
        private var descriptor: Int32 = -1

        init(path: String) { self.path = path }

        func acquire(timeout: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if tryAcquire() { return }
                if Date() >= deadline {
                    throw CodeTimeError.repositoryBusy("仓库正在被另一个任务使用")
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

    // MARK: - Recovery (§4.3)

    /// Enumerates every device/repository, validates and decrypts each recovery
    /// payload, and returns all candidates instead of relying on directory order.
    public static func recoverCandidates(
        storageRoot: URL,
        recoveryKey: Data
    ) async throws -> [RecoveryCandidate] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let devices = storageRoot.appendingPathComponent("devices", isDirectory: true)
        let deviceDirs: [URL]
        do {
            deviceDirs = try FileManager.default.contentsOfDirectory(
                at: devices,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            if Self.isMissingFileError(error) {
                throw CloudStoreError.notFound("没有找到云端设备目录")
            }
            throw CloudStoreError.metadataUnavailable("无法列出云端设备目录：\(error.localizedDescription)")
        }

        var candidates: [RecoveryCandidate] = []
        for device in deviceDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Only directories we published are recovery sources; an unrelated
            // entry must not be turned into a candidate with a made-up identity.
            guard let directoryDeviceID = UUID(uuidString: device.lastPathComponent) else { continue }
            let repositories = device.appendingPathComponent("repositories", isDirectory: true)
            let repos: [URL]
            do {
                repos = try FileManager.default.contentsOfDirectory(
                    at: repositories,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                if Self.isMissingFileError(error) { continue }
                throw CloudStoreError.metadataUnavailable(
                    "无法列出设备 \(device.lastPathComponent) 的仓库：\(error.localizedDescription)"
                )
            }
            for repo in repos.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let repositoryID = UUID(uuidString: repo.lastPathComponent) else { continue }
                let infoURL = repo.appendingPathComponent("recovery-info.json")
                guard FileManager.default.fileExists(atPath: infoURL.path) else { continue }
                do { try await UbiquitousFiles.ensureDownloaded(infoURL) }
                catch {
                    candidates.append(RecoveryCandidate(
                        repositoryID: repositoryID,
                        deviceID: directoryDeviceID,
                        deviceName: device.lastPathComponent,
                        blockedReason: "恢复信息无法下载：\(error.localizedDescription)",
                        recoveryInfoPath: infoURL.path
                    ))
                    continue
                }
                guard let data = try? Data(contentsOf: infoURL),
                      let info = try? decoder.decode(RecoveryInfoFile.self, from: data),
                      info.repositoryId == repositoryID else {
                    candidates.append(RecoveryCandidate(
                        repositoryID: repositoryID,
                        deviceID: directoryDeviceID,
                        deviceName: device.lastPathComponent,
                        blockedReason: "恢复信息格式无效",
                        recoveryInfoPath: infoURL.path
                    ))
                    continue
                }
                if info.keyFingerprint != Self.keyFingerprint(recoveryKey) {
                    candidates.append(RecoveryCandidate(
                        repositoryID: repositoryID,
                        deviceID: info.deviceId,
                        deviceName: info.deviceName ?? device.lastPathComponent,
                        blockedReason: "恢复密钥与该设备不匹配",
                        recoveryInfoPath: infoURL.path
                    ))
                    continue
                }
                do {
                    let plaintext = try CryptoBox.open(
                        info.payload,
                        masterKey: recoveryKey,
                        context: "recovery:\(info.repositoryId.uuidString)"
                    )
                    _ = try decoder.decode(RecoveryPayload.self, from: plaintext)
                } catch {
                    candidates.append(RecoveryCandidate(
                        repositoryID: repositoryID,
                        deviceID: info.deviceId,
                        deviceName: info.deviceName ?? device.lastPathComponent,
                        blockedReason: "无法解密恢复信息：\(error.localizedDescription)",
                        recoveryInfoPath: infoURL.path
                    ))
                    continue
                }

                // Validate generations without ever trusting a partial parse.
                let commits = repo.appendingPathComponent("commits", isDirectory: true)
                let manifestURLs: [URL]
                do {
                    manifestURLs = try FileManager.default.contentsOfDirectory(
                        at: commits,
                        includingPropertiesForKeys: [.fileSizeKey],
                        options: [.skipsHiddenFiles]
                    ).filter { $0.pathExtension == "ctm" }
                } catch {
                    if Self.isMissingFileError(error) {
                        manifestURLs = []
                    } else {
                        candidates.append(RecoveryCandidate(
                            repositoryID: repositoryID,
                            deviceID: info.deviceId,
                            deviceName: info.deviceName ?? device.lastPathComponent,
                            blockedReason: "无法列出云端版本：\(error.localizedDescription)",
                            recoveryInfoPath: infoURL.path
                        ))
                        continue
                    }
                }
                var readable = 0
                var latest: CloudManifest?
                var latestCommitDate: Date?
                var blocked: String?
                for url in manifestURLs {
                    guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                    do {
                        try await UbiquitousFiles.ensureDownloaded(url)
                        let sealed = try Data(contentsOf: url)
                        let plaintext = try CryptoBox.open(
                            sealed,
                            masterKey: recoveryKey,
                            context: "manifest:\(repositoryID.uuidString):\(id.uuidString)"
                        )
                        let manifest = try decoder.decode(CloudManifest.self, from: plaintext)
                        guard manifest.repositoryId == repositoryID,
                              manifest.generationId == id,
                              manifest.deviceId == info.deviceId else {
                            throw CloudStoreError.manifestCorrupt("清单与设备/仓库/版本标识不一致")
                        }
                        readable += 1
                        let commitDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? .distantPast
                        let isNewer: Bool
                        if let current = latest {
                            if manifest.createdAt != current.createdAt {
                                isNewer = manifest.createdAt > current.createdAt
                            } else {
                                isNewer = commitDate > (latestCommitDate ?? .distantPast)
                            }
                        } else {
                            isNewer = true
                        }
                        if isNewer {
                            latest = manifest
                            latestCommitDate = commitDate
                        }
                    } catch {
                        blocked = blocked ?? "云端版本 \(id.uuidString) 不可读取"
                    }
                }
                // A decryptable manifest is not proof that its repository can be
                // restored. At minimum every object of the selected generation must
                // exist before the candidate is offered as restorable.
                if let latest {
                    let objects = repo.appendingPathComponent("objects", isDirectory: true)
                    for file in latest.repositoryFiles {
                        let object = objects
                            .appendingPathComponent(String(file.contentHash.prefix(2)), isDirectory: true)
                            .appendingPathComponent(file.contentHash)
                        guard FileManager.default.fileExists(atPath: object.path) else {
                            blocked = blocked ?? "最新版本缺少对象 \(file.contentHash)"
                            break
                        }
                    }
                }
                let bytes = (try? Self.directorySize(commits)) ?? 0
                let objectsBytes = (try? Self.directorySize(repo.appendingPathComponent("objects", isDirectory: true))) ?? 0
                candidates.append(RecoveryCandidate(
                    repositoryID: repositoryID,
                    deviceID: info.deviceId,
                    deviceName: info.deviceName ?? device.lastPathComponent,
                    latestGenerationID: latest?.generationId,
                    latestBackupAt: latest?.createdAt,
                    generationCount: manifestURLs.count,
                    readableGenerationCount: readable,
                    repositoryBytes: max(bytes, objectsBytes),
                    integrityOK: blocked == nil,
                    kopiaVersion: nil,
                    blockedReason: blocked,
                    recoveryInfoPath: infoURL.path
                ))
            }
        }

        guard !candidates.isEmpty else {
            throw CloudStoreError.notFound("没有找到可用恢复凭据")
        }
        return candidates.sorted { ($0.latestBackupAt ?? .distantPast) > ($1.latestBackupAt ?? .distantPast) }
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
    }

    private static func directorySize(_ url: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Backwards-compatible single-candidate recovery. Prefers a fully readable,
    /// newest candidate and throws when none qualifies.
    public static func recover(
        storageRoot: URL,
        recoveryKey: Data,
        repositoryID: UUID? = nil,
        deviceID: UUID? = nil
    ) async throws -> RecoveredAccess {
        var candidates = try await recoverCandidates(storageRoot: storageRoot, recoveryKey: recoveryKey)
        if let repositoryID {
            candidates = candidates.filter { $0.repositoryID == repositoryID }
        }
        if let deviceID {
            candidates = candidates.filter { $0.deviceID == deviceID }
        }
        guard let chosen = candidates.first(where: { $0.integrityOK && $0.latestGenerationID != nil }) ?? candidates.first,
              chosen.blockedReason == nil,
              chosen.latestGenerationID != nil else {
            throw CloudStoreError.notFound("没有完整可恢复的云端版本")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let devices = storageRoot.appendingPathComponent("devices", isDirectory: true)
        let deviceDirs = try FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)
        for device in deviceDirs {
            let infoURL = device
                .appendingPathComponent("repositories", isDirectory: true)
                .appendingPathComponent(chosen.repositoryID.uuidString, isDirectory: true)
                .appendingPathComponent("recovery-info.json")
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? decoder.decode(RecoveryInfoFile.self, from: data),
                  info.repositoryId == chosen.repositoryID,
                  // Several devices can hold the same repository ID; only the
                  // candidate's own device proves the key matches.
                  info.deviceId == chosen.deviceID else { continue }
            do {
                try await UbiquitousFiles.ensureDownloaded(infoURL)
                let plaintext = try CryptoBox.open(
                    info.payload,
                    masterKey: recoveryKey,
                    context: "recovery:\(info.repositoryId.uuidString)"
                )
                let payload = try decoder.decode(RecoveryPayload.self, from: plaintext)
                guard payload.repositoryId == info.repositoryId,
                      payload.keyFingerprint == info.keyFingerprint else {
                    throw CloudStoreError.invalidFormat("恢复凭据内部信息不一致")
                }
                return RecoveredAccess(
                    repositoryID: info.repositoryId,
                    deviceID: info.deviceId,
                    repositoryPassword: payload.repositoryPassword,
                    createdAt: payload.createdAt
                )
            } catch {
                // A different device's recovery file may still be encrypted with
                // another key; continue instead of aborting the whole recovery.
                continue
            }
        }
        throw CloudStoreError.notFound("恢复信息不完整")
    }
}
