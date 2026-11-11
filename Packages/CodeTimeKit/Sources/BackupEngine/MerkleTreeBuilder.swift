import Foundation
import SharedModels

/// One scanned file, ready to become a `FileNode`.
public struct ScannedFile: Sendable, Hashable {
    public var path: String
    public var kind: NodeKind
    public var size: Int64
    public var modifiedAt: Date?
    public var mode: UInt16?
    public var linkTarget: String?
    public var contentHash: String?
    public var chunks: [ChunkRef]
    public var identity: FileIdentity?

    public init(
        path: String,
        kind: NodeKind,
        size: Int64,
        modifiedAt: Date? = nil,
        mode: UInt16? = nil,
        linkTarget: String? = nil,
        contentHash: String? = nil,
        chunks: [ChunkRef] = [],
        identity: FileIdentity? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.mode = mode
        self.linkTarget = linkTarget
        self.contentHash = contentHash
        self.chunks = chunks
        self.identity = identity
    }
}

public struct BuiltTree: Sendable {
    /// Root directory node (path "").
    public var root: DirectoryNode
    /// Every directory node, deepest last (root excluded). Only these need
    /// uploading, and only when their ID is not already known remotely.
    public var directories: [DirectoryNode]
    /// File nodes in path order.
    public var files: [FileNode]

    public var nodeCount: Int { directories.count + 1 }
    public var fileCount: Int { root.fileCount }
    public var totalBytes: Int64 { root.totalBytes }

    /// All node IDs (root + directories) for a manifest's dependency list.
    public var nodeIDs: [String] { directories.map(\.nodeID) + [root.nodeID] }
}

/// Builds the immutable directory tree. Pure: same input always yields the same
/// node IDs, in any input order, so an unchanged subtree keeps its identity and
/// is never re-uploaded.
public struct MerkleTreeBuilder: Sendable {
    public init() {}

    public func build(
        files: [ScannedFile],
        directoryMetadata: [String: DirectoryMetadata] = [:]
    ) -> BuiltTree {
        var copy = files
        return buildInPlace(files: &copy, directoryMetadata: directoryMetadata)
    }

    /// In-place variant used by the backup engine: sorting and consuming the
    /// scanner output directly avoids a second full array of `ScannedFile`
    /// values while the tree is being constructed. The input array is empty on
    /// return; callers must not use it afterwards.
    public func buildInPlace(
        files: inout [ScannedFile],
        directoryMetadata: [String: DirectoryMetadata] = [:]
    ) -> BuiltTree {
        // Deterministic order and one node per path. Sorting in place is the
        // single largest memory saving for 100k+ file projects.
        files.sort { $0.path < $1.path }

        // Leaf nodes first.
        var fileNodesByParent: [String: [FileNode]] = [:]
        var allFiles: [FileNode] = []
        var childDirectories: [String: Set<String>] = [:]
        var allDirectoryPaths: Set<String> = [""]
        var previousPath: String?

        for scanned in files {
            guard !scanned.path.isEmpty else { continue }
            // One node per path; if a caller passes duplicates, keep the first.
            if scanned.path == previousPath { continue }
            previousPath = scanned.path

            let parent = Self.parentPath(of: scanned.path)
            if scanned.kind == .directory {
                // An explicitly scanned directory adds no leaf, only structure.
                childDirectories[parent, default: []].insert(Self.lastComponent(of: scanned.path))
                allDirectoryPaths.insert(scanned.path)
            } else {
                allDirectoryPaths.insert(parent)
            }

            var ancestor = parent
            while !ancestor.isEmpty {
                allDirectoryPaths.insert(ancestor)
                ancestor = Self.parentPath(of: ancestor)
            }

            if scanned.kind != .directory {
                let node = FileNode(
                    path: scanned.path,
                    kind: scanned.kind,
                    size: scanned.size,
                    modifiedAt: scanned.modifiedAt,
                    mode: scanned.mode,
                    linkTarget: scanned.linkTarget,
                    contentHash: scanned.contentHash,
                    chunks: scanned.chunks,
                    identity: scanned.identity
                ).withComputedID()
                fileNodesByParent[parent, default: []].append(node)
                allFiles.append(node)
            }
        }
        // The tree nodes own their chunk arrays; the scanner values are no longer
        // needed while directories are assembled.
        files.removeAll(keepingCapacity: false)

        for path in allDirectoryPaths where path != "" {
            childDirectories[Self.parentPath(of: path), default: []].insert(Self.lastComponent(of: path))
        }

        // Deepest first so children exist before their parents.
        let ordered = allDirectoryPaths.sorted { lhs, rhs in
            let leftDepth = lhs.isEmpty ? 0 : lhs.split(separator: "/").count
            let rightDepth = rhs.isEmpty ? 0 : rhs.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return lhs < rhs
        }

        var built: [String: DirectoryNode] = [:]
        for path in ordered {
            let files = (fileNodesByParent[path] ?? []).sorted { $0.path < $1.path }
            let entries = (childDirectories[path] ?? []).sorted().map { name -> DirectoryEntry in
                let childPath = path.isEmpty ? name : "\(path)/\(name)"
                let child = built[childPath]
                return DirectoryEntry(
                    name: name,
                    nodeID: child?.nodeID ?? "",
                    fileCount: child?.fileCount ?? 0,
                    totalBytes: child?.totalBytes ?? 0
                )
            }
            let node = DirectoryNode(
                path: path,
                files: files,
                directories: entries,
                mode: directoryMetadata[path]?.mode,
                modifiedAt: directoryMetadata[path]?.modifiedAt
            ).withComputedID()
            built[path] = node
        }

        let root = built[""] ?? DirectoryNode(path: "", files: [], directories: []).withComputedID()
        let directories = ordered
            .filter { !$0.isEmpty }
            .compactMap { built[$0] }
        return BuiltTree(root: root, directories: directories, files: allFiles)
    }

    static func parentPath(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[..<index])
    }

    static func lastComponent(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: index)...])
    }
}
