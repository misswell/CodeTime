import Foundation
import SharedModels

/// Stable identity of a file for change detection. Timestamps alone are not
/// trustworthy (a restore can set mtime old, a `touch` changes it with identical
/// content), so the scanner records device + inode + size + mtime together and
/// the engine re-checks content when the identity looks suspicious.
public struct FileIdentity: Codable, Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modified: Double

    public init(device: UInt64, inode: UInt64, size: Int64, modified: Double) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
    }

    public var isZero: Bool { device == 0 && inode == 0 && size == 0 && modified == 0 }
}

public struct ScannedEntry: Sendable, Hashable {
    public var path: String
    public var kind: NodeKind
    public var size: Int64
    public var modifiedAt: Date?
    public var mode: UInt16?
    public var linkTarget: String?
    public var identity: FileIdentity

    public init(
        path: String,
        kind: NodeKind,
        size: Int64,
        modifiedAt: Date?,
        mode: UInt16?,
        linkTarget: String?,
        identity: FileIdentity
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.mode = mode
        self.linkTarget = linkTarget
        self.identity = identity
    }
}

public struct ScanResult: Sendable {
    public var entries: [ScannedEntry]
    public var excludedCount: Int
    public var excludedBytes: Int64
    /// Paths the process could not read. A project with permission errors must be
    /// reported as incomplete, never silently treated as fully backed up.
    public var permissionErrors: [String]
    public var isComplete: Bool
    public var truncatedReason: String?

    public init(
        entries: [ScannedEntry] = [],
        excludedCount: Int = 0,
        excludedBytes: Int64 = 0,
        permissionErrors: [String] = [],
        isComplete: Bool = true,
        truncatedReason: String? = nil
    ) {
        self.entries = entries
        self.excludedCount = excludedCount
        self.excludedBytes = excludedBytes
        self.permissionErrors = permissionErrors
        self.isComplete = isComplete
        self.truncatedReason = truncatedReason
    }

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    public var fileCount: Int { entries.filter { $0.kind != .directory }.count }
}

public struct ScanOptions: Sendable {
    /// Versioned exclusion rules still apply; these only choose the broad mode.
    public var maxFiles: Int
    public var followSymlinks: Bool

    public init(maxFiles: Int = 1_000_000, followSymlinks: Bool = false) {
        self.maxFiles = maxFiles
        self.followSymlinks = followSymlinks
    }

    public static let `default` = ScanOptions()
}

/// Walks a project once and produces the metadata the chunker needs.
///
/// Deliberately boring: no content is read here, no network, no state. Symlinks
/// are recorded and never followed (a link into `~/.ssh` must not become part of
/// a backup), excluded paths are counted so the UI can say what was skipped.
public struct ProjectScanner: Sendable {
    public let matcher: ExclusionMatcher
    public let options: ScanOptions

    public init(matcher: ExclusionMatcher, options: ScanOptions = .default) {
        self.matcher = matcher
        self.options = options
    }

    public func scan(root: URL) -> ScanResult {
        let standardizedRoot = root.standardizedFileURL
        let rootPath = standardizedRoot.path
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
            .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
        ]

        var result = ScanResult()
        guard let enumerator = FileManager.default.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { url, _ in
                result.permissionErrors.append(url.path)
                result.isComplete = false
                return true // keep walking: one unreadable subtree must not hide the rest
            }
        ) else {
            result.isComplete = false
            result.permissionErrors.append(rootPath)
            result.truncatedReason = "无法读取项目目录"
            return result
        }

        var visited = 0
        while let object = enumerator.nextObject() {
            if visited >= options.maxFiles {
                result.isComplete = false
                result.truncatedReason = "已扫描 \(options.maxFiles) 项，扫描不完整"
                break
            }
            guard let url = object as? URL else { continue }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                result.permissionErrors.append(url.path)
                result.isComplete = false
                continue
            }

            var path = url.standardizedFileURL.path
            if path == rootPath { continue }
            guard path.hasPrefix(rootPath + "/") else { continue }
            path = String(path.dropFirst(rootPath.count + 1))
            guard !path.isEmpty else { continue }

            let isDirectory = values.isDirectory ?? false
            let isSymlink = values.isSymbolicLink ?? false

            if matcher.isExcluded(relativePath: path, isDirectory: isDirectory) {
                result.excludedCount += 1
                if !isDirectory {
                    result.excludedBytes += Int64(values.fileSize ?? 0)
                }
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            visited += 1
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate

            if isSymlink {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                let (rawIdentity, mode) = metadata(url: url, size: Int64(target.utf8.count), modified: nil)
                // A symlink's content IS its target string: mtime/size of whatever
                // it points at must not make it look "changed".
                let linkIdentity = FileIdentity(
                    device: rawIdentity.device,
                    inode: rawIdentity.inode,
                    size: Int64(target.utf8.count),
                    modified: 0
                )
                result.entries.append(
                    ScannedEntry(
                        path: path,
                        kind: .symlink,
                        size: Int64(target.utf8.count),
                        modifiedAt: modified,
                        mode: mode,
                        linkTarget: target,
                        identity: linkIdentity
                    )
                )
                continue
            }

            if isDirectory {
                // Directory entries are structural: they keep empty directories
                // restorable but carry no content.
                let (directoryIdentity, mode) = metadata(url: url, size: 0, modified: modified)
                result.entries.append(
                    ScannedEntry(
                        path: path,
                        kind: .directory,
                        size: 0,
                        modifiedAt: modified,
                        mode: mode,
                        linkTarget: nil,
                        identity: directoryIdentity
                    )
                )
                continue
            }

            let (fileIdentity, mode) = metadata(url: url, size: size, modified: modified)
            result.entries.append(
                ScannedEntry(
                    path: path,
                    kind: .file,
                    size: size,
                    modifiedAt: modified,
                    mode: mode,
                    linkTarget: nil,
                    identity: fileIdentity
                )
            )
        }

        result.entries.sort { $0.path < $1.path }
        return result
    }

    /// One stat per entry: identity (for change detection) plus POSIX mode (for
    /// a bit-for-bit restore).
    private func metadata(url: URL, size: Int64, modified: Date?) -> (FileIdentity, UInt16?) {
        var device: UInt64 = 0
        var inode: UInt64 = 0
        var mode: UInt16?
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            mode = (attributes[.posixPermissions] as? NSNumber)
                .map { UInt16(truncatingIfNeeded: $0.uint16Value) }
        }
        return (
            FileIdentity(
                device: device,
                inode: inode,
                size: size,
                modified: modified?.timeIntervalSince1970 ?? 0
            ),
            mode
        )
    }

    // MARK: - Incremental

    public struct ChangeSet: Sendable {
        /// Files whose identity differs from the previous index (need reading).
        public var changed: [ScannedEntry]
        /// Paths that disappeared since the last scan.
        public var removed: [String]
        /// Paths that look unchanged and may reuse their previous chunks.
        public var unchanged: [ScannedEntry]

        public init(changed: [ScannedEntry], removed: [String], unchanged: [ScannedEntry]) {
            self.changed = changed
            self.removed = removed
            self.unchanged = unchanged
        }

        public var requiresFullRescan: Bool { false }
    }

    /// Compares a fresh scan against the indexed identities.
    public func changeSet(
        scan: ScanResult,
        previousIdentities: [String: FileIdentity]
    ) -> ChangeSet {
        var changed: [ScannedEntry] = []
        var unchanged: [ScannedEntry] = []
        var seen = Set<String>()
        for entry in scan.entries where entry.kind != .directory {
            seen.insert(entry.path)
            if let previous = previousIdentities[entry.path], previous == entry.identity {
                unchanged.append(entry)
            } else {
                changed.append(entry)
            }
        }
        let removed = previousIdentities.keys.filter { !seen.contains($0) }.sorted()
        return ChangeSet(changed: changed, removed: removed, unchanged: unchanged)
    }

    // MARK: - Stability

    /// Re-stats a file after it was read. If the identity moved, the read cannot
    /// be trusted (the file changed while we streamed it) and the chunk set must
    /// be discarded rather than published as a consistent snapshot.
    public static func identity(of url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileIdentity(
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: size,
            modified: modified
        )
    }
}
