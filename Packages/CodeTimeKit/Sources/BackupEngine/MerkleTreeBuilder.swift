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

    public init(
        path: String,
        kind: NodeKind,
        size: Int64,
        modifiedAt: Date? = nil,
        mode: UInt16? = nil,
        linkTarget: String? = nil,
        contentHash: String? = nil,
        chunks: [ChunkRef] = []
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.mode = mode
        self.linkTarget = linkTarget
        self.contentHash = contentHash
        self.chunks = chunks
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

    public func build(files: [ScannedFile]) -> BuiltTree {
        // Deterministic order and one node per path.
        var byPath: [String: ScannedFile] = [:]
        for file in files where !file.path.isEmpty {
            byPath[file.path] = file
        }
        let sorted = byPath.values.sorted { $0.path < $1.path }

        // Leaf nodes first.
        var fileNodesByParent: [String: [FileNode]] = [:]
        var allFiles: [FileNode] = []
        var childDirectories: [String: Set<String>] = [:]

        for scanned in sorted {
            let parent = Self.parentPath(of: scanned.path)
            if scanned.kind == .directory {
                // An explicitly scanned directory adds no leaf, only structure.
                childDirectories[parent, default: []].insert(Self.lastComponent(of: scanned.path))
                continue
            }
            let node = FileNode(
                path: scanned.path,
                kind: scanned.kind,
                size: scanned.size,
                modifiedAt: scanned.modifiedAt,
                mode: scanned.mode,
                linkTarget: scanned.linkTarget,
                contentHash: scanned.contentHash,
                chunks: scanned.chunks
            ).withComputedID()
            fileNodesByParent[parent, default: []].append(node)
            allFiles.append(node)
        }

        // Every ancestor directory must exist, even when empty.
        var allDirectoryPaths: Set<String> = [""]
        for scanned in sorted {
            if scanned.kind == .directory {
                // An empty directory has no file beneath it to introduce its path
                // — without this it would be referenced with an empty node ID.
                allDirectoryPaths.insert(scanned.path)
            }
            var parent = Self.parentPath(of: scanned.path)
            if scanned.kind != .directory {
                allDirectoryPaths.insert(parent)
            }
            while !parent.isEmpty {
                allDirectoryPaths.insert(parent)
                parent = Self.parentPath(of: parent)
            }
        }
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
            let node = DirectoryNode(path: path, files: files, directories: entries).withComputedID()
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
