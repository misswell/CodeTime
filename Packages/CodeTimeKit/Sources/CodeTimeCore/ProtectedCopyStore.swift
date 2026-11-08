import Foundation
import SharedModels
import CodeTimeSecurity

/// Copies that CodeTime makes before overwriting a live file during restore.
///
/// Each copy lives under the project UUID, carries a manifest with the source
/// hash, and is only reported as a protection copy after the copy's own hash
/// matches the source (files: SHA-256; directories: a deterministic tree
/// digest that also covers relative paths, file sizes and symlinks).
///
/// CT-117…CT-122 invariants (seventh round):
/// 1. The copy being created is registered as *active* and can never be
///    deleted by `prune` — not by its own prune, not by a concurrent one.
/// 2. A single copy larger than the per-project budget is always KEPT. The
///    budget is soft: the project may temporarily exceed it and the overage
///    is reported through `CopyReceipt.overBudget` / `status(projectID:)`.
///    Deleting the newest valid protection copy to satisfy a quota is a
///    data-loss bug, never a policy.
/// 3. `prune` never removes the newest valid copy of a project, so a project
///    always keeps at least one protection copy as long as one existed.
/// 4. `createCopy` re-checks that the manifest and payload really exist
///    before returning; it never returns a URL that was reclaimed.
/// 5. Copies have a lifecycle (`verifying → verified`, or `invalid`). A copy
///    whose hash was never confirmed never lists as a valid protection copy.
public enum ProtectedCopyStore {
    public enum LifecycleStatus: String, Codable, Sendable {
        /// Copy started, source/copy hashes not yet confirmed.
        case verifying
        /// Hashes confirmed; the copy is a trustworthy protection copy.
        case verified
        /// Verification failed (payload missing, corrupt, or tampered).
        case invalid
    }

    public struct Manifest: Codable, Sendable {
        public var id: UUID
        public var projectID: UUID
        public var createdAt: Date
        public var originalRoot: String
        public var originalPath: String
        public var sha256: String
        public var size: Int64
        public var isDirectory: Bool
        /// Lifecycle state. `nil` = legacy manifest written by an older build;
        /// those were written only after verification and are treated as
        /// `.verified`.
        public var status: LifecycleStatus?
        /// Number of regular files + symlinks covered by the tree digest.
        /// `nil` = legacy manifest (tree digest v1, no symlink entries).
        public var fileCount: Int?
        /// Tree-digest algorithm version. `nil`/1 = legacy (no symlinks, no
        /// sizes); 2 = relative path + size + content hash + symlink targets.
        public var digestVersion: Int?

        public init(
            id: UUID,
            projectID: UUID,
            createdAt: Date,
            originalRoot: String,
            originalPath: String,
            sha256: String,
            size: Int64,
            isDirectory: Bool,
            status: LifecycleStatus? = nil,
            fileCount: Int? = nil,
            digestVersion: Int? = nil
        ) {
            self.id = id
            self.projectID = projectID
            self.createdAt = createdAt
            self.originalRoot = originalRoot
            self.originalPath = originalPath
            self.sha256 = sha256
            self.size = size
            self.isDirectory = isDirectory
            self.status = status
            self.fileCount = fileCount
            self.digestVersion = digestVersion
        }
    }

    /// What `createCopy` hands back to the caller: the copy that now holds the
    /// verified data plus the capacity state the UI should surface.
    public struct CopyReceipt: Sendable {
        public let directory: URL
        public let manifest: Manifest
        public let sizeBytes: Int64
        /// True when the project's protection copies now exceed the soft
        /// budget because an oversized copy was deliberately kept.
        public let overBudget: Bool
        /// What this create's prune pass removed (reason + size each).
        public let removals: [Removal]
    }

    public struct Removal: Sendable {
        public enum Reason: String, Sendable {
            case overCount
            case overBudget
            case invalid
        }

        public let directory: URL
        public let bytes: Int64
        public let reason: Reason
    }

    public struct ProjectStatus: Sendable {
        public let copies: Int
        public let totalBytes: Int64
        public let budgetBytes: Int64
        public var overBudget: Bool { totalBytes > budgetBytes }
        public let newestCopyAt: Date?
    }

    public enum CopyVerification: Sendable {
        case valid(Manifest)
        case invalid(reason: String)
    }

    public static let manifestName = "manifest.json"
    public static let maximumCopiesPerProject = 20
    public static let maximumBytesPerProject: Int64 = 2 * 1024 * 1024 * 1024

    /// Test/diagnostic override for the per-project byte budget. Production
    /// code must leave it nil.
    public nonisolated(unsafe) static var maximumBytesPerProjectOverride: Int64?
    /// Test/diagnostic override for the per-project copy count. Production
    /// code must leave it nil.
    public nonisolated(unsafe) static var maximumCopiesPerProjectOverride: Int?
    /// Test seam replacing the payload `copyItem` so tests can simulate a
    /// source that changes mid-copy (CT-119). Production code must leave nil.
    public nonisolated(unsafe) static var payloadCopyHandler: ((URL, URL) throws -> Void)?

    static var effectiveByteBudget: Int64 { maximumBytesPerProjectOverride ?? maximumBytesPerProject }
    static var effectiveCopyBudget: Int { maximumCopiesPerProjectOverride ?? maximumCopiesPerProject }

    // MARK: - Active-copy registry

    /// Copies currently referenced by a live operation (a create in flight, or
    /// an overwrite restore that may still need the copy). `prune` never
    /// deletes anything registered here.
    private static let registryLock = NSLock()
    private static var activeCopyPaths: Set<String> = []

    public static func registerActiveCopy(_ directory: URL) {
        registryLock.lock()
        defer { registryLock.unlock() }
        activeCopyPaths.insert(directory.standardizedFileURL.path)
    }

    public static func unregisterActiveCopy(_ directory: URL) {
        registryLock.lock()
        defer { registryLock.unlock() }
        activeCopyPaths.remove(directory.standardizedFileURL.path)
    }

    public static func activeCopies() -> [String] {
        registryLock.lock()
        defer { registryLock.unlock() }
        return activeCopyPaths.sorted()
    }

    private static func isActive(_ directory: URL) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        return activeCopyPaths.contains(directory.standardizedFileURL.path)
    }

    // MARK: - Create

    /// Copies `target` into the project's recovery area, verifies the copy
    /// against the source, and only then reports it as a protection copy.
    @discardableResult
    public static func createCopy(
        target: URL,
        projectID: UUID,
        projectRoot: URL,
        recoveryRoot: URL
    ) throws -> CopyReceipt {
        let fileManager = FileManager.default
        let source = target.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw CodeTimeError.unsupported("要保护的文件已不存在：\(source.path)")
        }

        let projectDirectory = recoveryRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let copyID = UUID()
        let copyDirectory = projectDirectory.appendingPathComponent(copyIdentifier(copyID), isDirectory: true)
        try fileManager.createDirectory(at: copyDirectory, withIntermediateDirectories: false)
        let payload = copyDirectory.appendingPathComponent("payload", isDirectory: true)

        // CT-121/CT-122: from this moment the copy is protected against every
        // prune — its own and any concurrent one — until this call returns.
        registerActiveCopy(copyDirectory)
        defer { unregisterActiveCopy(copyDirectory) }

        do {
            // Write the manifest first with status .verifying: if this process
            // dies mid-copy, the half-made copy can never list as a valid
            // protection copy (CT-119/二.5).
            let pending = Manifest(
                id: copyID,
                projectID: projectID,
                createdAt: Date(),
                originalRoot: projectRoot.standardizedFileURL.path,
                originalPath: source.path,
                sha256: "",
                size: 0,
                isDirectory: isDirectory.boolValue,
                status: .verifying
            )
            try writeManifest(pending, to: copyDirectory)

            // Copy + verify with the stamp bracketing the COPY, retried once
            // when the source itself moved during the copy. A source that keeps
            // changing aborts the restore — an unstable snapshot must never be
            // reported as protected.
            var digest = try copyAndVerifyOnce(
                source: source,
                payload: payload,
                isDirectory: isDirectory.boolValue
            )
            if digest == nil {
                try removePayload(payload)
                digest = try copyAndVerifyOnce(
                    source: source,
                    payload: payload,
                    isDirectory: isDirectory.boolValue
                )
                guard digest != nil else {
                    throw CodeTimeError.integrityFailure(
                        "源内容在保护期间持续变化，已中止覆盖恢复：\(source.lastPathComponent)"
                    )
                }
            }
            let confirmed = digest!

            let manifest = Manifest(
                id: copyID,
                projectID: projectID,
                createdAt: pending.createdAt,
                originalRoot: pending.originalRoot,
                originalPath: source.path,
                sha256: confirmed.hash,
                size: confirmed.totalBytes,
                isDirectory: isDirectory.boolValue,
                status: .verified,
                fileCount: confirmed.fileCount,
                digestVersion: isDirectory.boolValue ? 2 : nil
            )
            try writeManifest(manifest, to: copyDirectory)

            // Capacity policy. The copy we just made is registered and the
            // newest valid copy is always kept, so this can never reclaim the
            // protection we just made (CT-117/CT-121).
            let removals = prune(projectDirectory: projectDirectory, protectedURLs: [copyDirectory])

            // CT-117: never hand back a URL that prune (or anything else) made
            // disappear — the caller would overwrite an unprotected file.
            let manifestURL = copyDirectory.appendingPathComponent(manifestName)
            guard fileManager.fileExists(atPath: copyDirectory.path),
                  fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: payload.path)
            else {
                throw CodeTimeError.integrityFailure(
                    "保护副本在清理后丢失，已中止覆盖恢复：\(copyDirectory.lastPathComponent)"
                )
            }

            let total = (try? directorySize(projectDirectory)) ?? 0
            return CopyReceipt(
                directory: copyDirectory,
                manifest: manifest,
                sizeBytes: confirmed.totalBytes,
                overBudget: total > effectiveByteBudget,
                removals: removals
            )
        } catch {
            // A half-written copy must never be mistaken for a valid protection copy.
            do {
                try fileManager.removeItem(at: copyDirectory)
            } catch {
                // The original error is more useful; the leftover directory has no
                // verified manifest and lists as invalid.
            }
            throw error
        }
    }

    // MARK: - Listing & status

    /// Lists manifests that are actually usable protection copies: manifest
    /// decodable, payload present with the recorded type, and lifecycle state
    /// not `invalid`/`verifying`. JSON decoding alone is never enough (二.6).
    public static func listManifests(
        projectID: UUID,
        recoveryRoot: URL,
        includeInvalid: Bool = false
    ) -> [Manifest] {
        let fileManager = FileManager.default
        let projectDirectory = recoveryRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries.compactMap { url -> Manifest? in
            guard let manifest = try? decodeManifest(at: url.appendingPathComponent(manifestName), decoder: decoder) else {
                return nil
            }
            if includeInvalid { return manifest }
            return isValidEnough(manifest, copyDirectory: url) ? manifest : nil
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Capacity/lifecycle state for the UI. The budget is soft: `overBudget`
    /// means oversized copies were deliberately kept (CT-118).
    public static func status(projectID: UUID, recoveryRoot: URL) -> ProjectStatus {
        let fileManager = FileManager.default
        let projectDirectory = recoveryRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ProjectStatus(copies: 0, totalBytes: 0, budgetBytes: effectiveByteBudget, newestCopyAt: nil)
        }
        var total: Int64 = 0
        var newest: Date?
        for entry in entries {
            total += (try? directorySize(entry)) ?? 0
            if let manifest = try? decodeManifest(
                at: entry.appendingPathComponent(manifestName),
                decoder: Self.decoder
            ) {
                if newest == nil || manifest.createdAt > newest! {
                    newest = manifest.createdAt
                }
            }
        }
        return ProjectStatus(
            copies: entries.count,
            totalBytes: total,
            budgetBytes: effectiveByteBudget,
            newestCopyAt: newest
        )
    }

    // MARK: - Verification

    /// Full verification of one copy: manifest identity, payload existence and
    /// type, recorded size, and content hash (SHA-256 for files, tree digest
    /// for directories). Marks the manifest `.invalid` on disk when it fails,
    /// unless the copy is registered as active.
    @discardableResult
    public static func verifyCopy(directory: URL) -> CopyVerification {
        let fileManager = FileManager.default
        guard let manifest = try? decodeManifest(at: directory.appendingPathComponent(manifestName), decoder: Self.decoder) else {
            return .invalid(reason: "manifest 缺失或无法解码")
        }

        func fail(_ reason: String) -> CopyVerification {
            if !isActive(directory) {
                var marked = manifest
                marked.status = .invalid
                try? writeManifest(marked, to: directory)
            }
            return .invalid(reason: reason)
        }

        // Manifest identity must match its location (四.1/四.2 of the task).
        guard manifest.projectID.uuidString == directory.deletingLastPathComponent().lastPathComponent else {
            return fail("manifest.projectID 与目录不一致")
        }
        guard manifest.id.uuidString.prefix(8) == directory.lastPathComponent.suffix(8) else {
            return fail("manifest.id 与目录名称不一致")
        }

        let payload = directory.appendingPathComponent("payload", isDirectory: true)
        var payloadIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: payload.path, isDirectory: &payloadIsDirectory) else {
            return fail("payload 缺失")
        }
        guard payloadIsDirectory.boolValue == manifest.isDirectory else {
            return fail("payload 类型与 manifest 不一致")
        }

        if manifest.status == .invalid {
            return .invalid(reason: "副本已被标记为无效")
        }
        if manifest.status == .verifying && isActive(directory) {
            // A create in flight; not a failure, just not ready.
            return .invalid(reason: "副本正在创建中")
        }

        if manifest.isDirectory {
            let actualSize = (try? directorySize(payload)) ?? -1
            guard actualSize == manifest.size else {
                let entryCount = (try? fileManager.contentsOfDirectory(atPath: payload.path).count) ?? -1
                return fail("payload 大小不一致（记录 \(manifest.size)，实际 \(actualSize)，条目 \(entryCount)）")
            }
            let expectedHash: String
            if manifest.digestVersion == nil {
                expectedHash = (try? legacyTreeHash(payload)) ?? ""
            } else {
                expectedHash = (try? treeDigest(payload))?.hash ?? ""
            }
            guard !expectedHash.isEmpty, expectedHash == manifest.sha256 else {
                return fail("payload 目录哈希与 manifest 不一致")
            }
        } else {
            guard let size = try? Int64(payload.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1),
                  size == manifest.size else {
                return fail("payload 大小不一致")
            }
            guard let actualHash = try? Hashing.sha256Hex(fileURL: payload), actualHash == manifest.sha256 else {
                return fail("payload SHA-256 与 manifest 不一致")
            }
        }
        return .valid(manifest)
    }

    /// Audits every copy of a project (periodic verification, 二.7). Returns
    /// the failures; each failed copy is marked `.invalid` on disk.
    public static func auditProject(projectID: UUID, recoveryRoot: URL) -> [(directory: URL, reason: String)] {
        let fileManager = FileManager.default
        let projectDirectory = recoveryRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var failures: [(URL, String)] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard isActive(entry) else {
                if case .invalid(let reason) = verifyCopy(directory: entry) {
                    failures.append((entry, reason))
                }
                continue
            }
            // Active copies are mid-create or referenced by a live restore;
            // verifying them now would race the writer.
            continue
        }
        return failures
    }

    // MARK: - Prune

    /// Capacity policy for a project's protection copies.
    ///
    /// - Never removes copies registered as active or listed in `protectedURLs`.
    /// - Never removes the newest valid copy (a project keeps at least one).
    /// - Removes invalid copies first, then trims oldest-first over the soft
    ///   count/byte budgets. An oversized single copy is kept and the project
    ///   simply reports over-budget.
    @discardableResult
    public static func prune(projectDirectory: URL, protectedURLs: Set<URL> = []) -> [Removal] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
        let sorted = entries.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l > r
        }
        let decoder = Self.decoder
        var kept = 0
        var total: Int64 = 0
        var removals: [Removal] = []
        for (index, entry) in sorted.enumerated() {
            let manifest = try? decodeManifest(at: entry.appendingPathComponent(manifestName), decoder: decoder)
            let valid = manifest != nil && isValidEnough(manifest!, copyDirectory: entry)

            if isActive(entry) || protectedPaths.contains(entry.standardizedFileURL.path) {
                // CT-121/CT-122: a live operation may still need this copy.
                if valid {
                    kept += 1
                    total += (try? directorySize(entry)) ?? 0
                }
                continue
            }

            if manifest?.status == .verifying {
                // The registry is per-process; a sibling CodeTime process may
                // be mid-create. Give young .verifying copies a grace window
                // instead of judging them from another process.
                let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(mtime) < 3_600 { continue }
            }

            if !valid {
                // Unreadable manifest, missing payload or marked invalid: not a
                // protection copy, reclaim it regardless of policy.
                removals.append(Removal(directory: entry, bytes: (try? directorySize(entry)) ?? 0, reason: .invalid))
                try? fileManager.removeItem(at: entry)
                continue
            }

            if index == 0 {
                // The newest valid copy always survives — even when it alone
                // busts the budget (CT-117/CT-118).
                kept += 1
                total += (try? directorySize(entry)) ?? 0
                continue
            }

            let size = (try? directorySize(entry)) ?? 0
            if kept + 1 > effectiveCopyBudget {
                removals.append(Removal(directory: entry, bytes: size, reason: .overCount))
                try? fileManager.removeItem(at: entry)
            } else if total + size > effectiveByteBudget {
                removals.append(Removal(directory: entry, bytes: size, reason: .overBudget))
                try? fileManager.removeItem(at: entry)
            } else {
                kept += 1
                total += size
            }
        }
        return removals
    }

    // MARK: - Internals

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Copies the source to `payload`, which must not exist yet — `copyItem`
    /// then creates it as a faithful clone of the source (directories included).
    private static func copyPayload(source: URL, payload: URL, isDirectory: Bool) throws {
        _ = isDirectory
        if let handler = payloadCopyHandler {
            try handler(source, payload)
        } else {
            try FileManager.default.copyItem(at: source, to: payload)
        }
    }

    private static func removePayload(_ payload: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: payload.path) {
            try fileManager.removeItem(at: payload)
        }
    }

    /// One copy+verify pass. The verification window is fully bracketed: a
    /// directory source is digested BEFORE the copy and again AFTER (a
    /// directory node's own stamp is useless — appending inside an existing
    /// file doesn't touch the parent's mtime/size); a file source keeps its
    /// attribute stamp. Returns the confirmed digest, or nil when the SOURCE
    /// changed under us (caller decides whether to retry).
    private static func copyAndVerifyOnce(
        source: URL,
        payload: URL,
        isDirectory: Bool
    ) throws -> TreeDigest? {
        let sourceDigestBefore = isDirectory ? try treeDigest(source) : nil
        let sourceStampBefore = isDirectory ? nil : (try? FileManager.default.attributesOfItem(atPath: source.path))

        try copyPayload(source: source, payload: payload, isDirectory: isDirectory)

        if isDirectory {
            let sourceDigestAfter = try treeDigest(source)
            let payloadDigest = try treeDigest(payload)
            guard payloadDigest.hash == sourceDigestAfter.hash else {
                if sourceDigestBefore!.hash != sourceDigestAfter.hash { return nil }
                throw CodeTimeError.integrityFailure("保护副本目录哈希与源目录不一致：\(source.lastPathComponent)")
            }
            if sourceDigestBefore!.hash != sourceDigestAfter.hash { return nil }
            return sourceDigestAfter
        } else {
            let sourceHash = try Hashing.sha256Hex(fileURL: source)
            let copiedHash = try Hashing.sha256Hex(fileURL: payload)
            guard copiedHash == sourceHash else {
                throw CodeTimeError.integrityFailure("保护副本哈希与源文件不一致：\(source.lastPathComponent)")
            }
            if sourceChanged(since: sourceStampBefore, source: source) { return nil }
            let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            return TreeDigest(hash: sourceHash, fileCount: 1, totalBytes: size)
        }
    }

    private static func sourceChanged(since stamp: [FileAttributeKey: Any]?, source: URL) -> Bool {
        guard let stamp else { return false }
        let fileManager = FileManager.default
        guard let current = try? fileManager.attributesOfItem(atPath: source.path) else { return true }
        let sizeBefore = (stamp[.size] as? Int) ?? (stamp[.size] as? NSNumber)?.intValue
        let sizeNow = (current[.size] as? Int) ?? (current[.size] as? NSNumber)?.intValue
        if sizeBefore != sizeNow { return true }
        let dateBefore = stamp[.modificationDate] as? Date
        let dateNow = current[.modificationDate] as? Date
        if let before = dateBefore, let now = dateNow, before != now { return true }
        return false
    }

    private static func writeManifest(_ manifest: Manifest, to copyDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: copyDirectory.appendingPathComponent(manifestName),
            options: .atomic
        )
    }

    private static func decodeManifest(at url: URL, decoder: JSONDecoder) throws -> Manifest {
        let data = try Data(contentsOf: url)
        return try decoder.decode(Manifest.self, from: data)
    }

    /// Cheap validity gate used by listing and pruning: status is usable and
    /// the payload exists with the recorded type. Full hash verification lives
    /// in `verifyCopy` / `auditProject`.
    private static func isValidEnough(_ manifest: Manifest, copyDirectory: URL) -> Bool {
        if manifest.status == .invalid || manifest.status == .verifying { return false }
        let payload = copyDirectory.appendingPathComponent("payload", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: payload.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue == manifest.isDirectory
    }

    private static func copyIdentifier(_ id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(id.uuidString.prefix(8))"
    }

    private static func directorySize(_ url: URL) throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isDirectory == true { continue }
            // A symlink's st_size is the length of its target path, not data;
            // treeDigest/manifest sizes count regular files only.
            if values.isSymbolicLink == true { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private struct TreeDigest: Equatable {
        var hash: String
        var fileCount: Int
        var totalBytes: Int64
    }

    /// Deterministic digest over relative path + size + per-file content hash,
    /// plus one entry per symlink (relative path → destination), so a
    /// directory copy can be compared without trusting modification dates and
    /// so swapping a symlink for a file (or retargeting it) changes the hash.
    private static func treeDigest(_ root: URL) throws -> TreeDigest {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
            ]
        ) as? FileManager.DirectoryEnumerator else {
            throw CodeTimeError.integrityFailure("无法读取目录：\(root.lastPathComponent)")
        }
        var entries: [String] = []
        var totalBytes: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [
                .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
            ])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                let relative = try relativePath(of: file, under: root)
                let destination = (try? fileManager.destinationOfSymbolicLink(atPath: file.path)) ?? ""
                entries.append("\(relative) -> \(destination)")
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            let relative = try relativePath(of: file, under: root)
            let hash = try Hashing.sha256Hex(fileURL: file)
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            entries.append("\(relative)#\(size)#\(hash)")
        }
        let hash = Hashing.sha256Hex(Data(entries.sorted().joined(separator: "\n").utf8))
        return TreeDigest(hash: hash, fileCount: entries.count, totalBytes: totalBytes)
    }

    private static func relativePath(of file: URL, under root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw CodeTimeError.integrityFailure("目录枚举逃逸：\(filePath)")
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    /// Legacy tree digest (treeHash v1): relative path + content hash only,
    /// no sizes and no symlink entries. Kept so `verifyCopy` can still check
    /// manifests written before digestVersion existed.
    private static func legacyTreeHash(_ root: URL) throws -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        ) else {
            throw CodeTimeError.integrityFailure("无法读取保护副本目录")
        }
        var entries: [String] = []
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let relative = try relativePath(of: file, under: root)
            let hash = try Hashing.sha256Hex(fileURL: file)
            entries.append("\(relative):\(hash)")
        }
        return Hashing.sha256Hex(Data(entries.sorted().joined(separator: "\n").utf8))
    }
}
