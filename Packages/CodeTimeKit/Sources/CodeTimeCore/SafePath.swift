import Foundation

/// CT-086: Unified safe-path validation for restore staging and every high-risk
/// filesystem operation that takes a path from persisted state.
///
/// Design rules (Goal §3.1):
/// 1. Reject empty paths, NUL characters and non-absolute paths.
/// 2. Reject `..` traversal before any standardization hides it.
/// 3. Containment is checked component-wise on the standardized path AND on the
///    symlink-resolved real path — never with a plain `hasPrefix` (which matches
///    sibling directories such as `/root` vs `/root-evil`).
/// 4. Staging directories are derived deterministically from the repository ID
///    and restore job ID; a persisted stagingPath must match the recomputed
///    value (legacy `restore-<8hex>` rows are reconciled on resume).
/// 5. Before destructive operations the caller can assert the path is a real
///    directory and not a symlink swap (O_NOFOLLOW probe).
public enum SafePath {

    public enum SafePathError: Error, Equatable {
        case empty
        case containsNUL
        case notAbsolute
        case traversal
        case outsideRoot(path: String, root: String)
        case notDirectChild(path: String, root: String)
        case notADirectory(path: String)
        case isSymlink(path: String)
        case derivationMismatch(expected: String, actual: String)
        /// A restore/write target equals, contains, or lives inside an original
        /// project. CodeTime treats source projects as permanently read-only.
        case overlapsSource(path: String, source: String)
        /// A write target overlaps CodeTime's own data roots in either direction.
        case overlapsProtectedRoot(path: String, root: String)
    }

    // MARK: - Raw validation

    /// Validates a raw path string: non-empty, no NUL, absolute.
    public static func validateRaw(_ path: String) throws {
        if path.isEmpty { throw SafePathError.empty }
        if path.contains("\0") { throw SafePathError.containsNUL }
        guard path.hasPrefix("/") else { throw SafePathError.notAbsolute }
    }

    /// Standardizes and resolves symlinks. Components that do not exist yet are
    /// standardized lexically; existing components are resolved to their real path.
    public static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Component-wise containment

    /// Returns the resolved path components without the leading "/".
    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// True when `path` (already resolved) lies inside `root` (already resolved).
    /// Component-wise: `/root` does NOT match `/root-evil/x`.
    public static func isContained(_ resolvedPath: String, within resolvedRoot: String) -> Bool {
        let p = components(of: resolvedPath)
        let r = components(of: resolvedRoot)
        guard p.count > r.count else { return false }
        return Array(p.prefix(r.count)) == r
    }

    /// True when `path` is an immediate child of `root` (both resolved).
    public static func isDirectChild(_ resolvedPath: String, of resolvedRoot: String) -> Bool {
        let p = components(of: resolvedPath)
        let r = components(of: resolvedRoot)
        guard p.count == r.count + 1 else { return false }
        return Array(p.prefix(r.count)) == r
    }

    /// True when the two paths are equal, or either one contains the other.
    /// This is deliberately bidirectional: restoring into an ancestor of a
    /// source project is just as destructive as restoring into the project.
    ///
    /// Comparison is case-insensitive because macOS volumes are case-insensitive
    /// by default. Rejecting a case-only sibling on a case-sensitive volume is a
    /// safe false positive; missing a case-variant source path would permit a
    /// write into the original project.
    public static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = resolved(lhs).path.lowercased()
        let right = resolved(rhs).path.lowercased()
        return left == right
            || isContained(left, within: right)
            || isContained(right, within: left)
    }

    /// Full validation of a persisted path against a root:
    /// raw checks → `..` rejection → containment on standardized path →
    /// containment on symlink-resolved path. Returns the resolved URL.
    @discardableResult
    public static func contained(_ rawPath: String, within root: URL) throws -> URL {
        try validateRaw(rawPath)
        let raw = URL(fileURLWithPath: rawPath, isDirectory: true)
        // Reject explicit traversal before standardization can silently fold it.
        if components(of: rawPath).contains("..") { throw SafePathError.traversal }

        let standardized = raw.standardizedFileURL
        let resolvedRoot = resolved(root)
        if !isContained(standardized.path, within: resolvedRoot.path) {
            throw SafePathError.outsideRoot(path: rawPath, root: resolvedRoot.path)
        }
        let real = resolved(raw)
        // A symlink chain that escapes the root is caught here even when the
        // lexical standardization stayed inside.
        if !isContained(real.path, within: resolvedRoot.path) {
            throw SafePathError.outsideRoot(path: rawPath, root: resolvedRoot.path)
        }
        return real
    }

    /// Containment plus direct-child requirement (the staging directory must be
    /// an immediate child of the repository root, never nested deeper).
    @discardableResult
    public static func containedDirectChild(_ rawPath: String, within root: URL) throws -> URL {
        let real = try contained(rawPath, within: root)
        let resolvedRoot = resolved(root)
        guard isDirectChild(real.path, of: resolvedRoot.path) else {
            throw SafePathError.notDirectChild(path: rawPath, root: resolvedRoot.path)
        }
        return real
    }

    // MARK: - Deterministic staging derivation

    /// Prefix shared by every restore staging directory under
    /// `paths.repositories/<repositoryID>/`.
    public static let stagingPrefix = "restore-"

    /// Deterministic staging directory for a restore job:
    /// `<root>/restore-<repositoryID prefix 8>-<jobID prefix 8>`.
    public static func stagingURL(in root: URL, repositoryID: UUID, jobID: UUID) -> URL {
        root.appendingPathComponent(
            "\(stagingPrefix)\(repositoryID.uuidString.prefix(8))-\(jobID.uuidString.prefix(8))",
            isDirectory: true
        )
    }

    /// Whether a directory name was produced by `stagingURL` (legacy
    /// `restore-<8hex>` names return false and are reconciled on resume).
    public static func isDerivedStagingName(_ name: String, repositoryID: UUID, jobID: UUID) -> Bool {
        name == "\(stagingPrefix)\(repositoryID.uuidString.prefix(8))-\(jobID.uuidString.prefix(8))"
    }

    /// True for any staging-style name (`restore-…`), including legacy rows.
    public static func isStagingName(_ name: String) -> Bool {
        name.hasPrefix(stagingPrefix)
    }

    // MARK: - Symlink-swap probe (TOCTOU mitigation)

    /// Opens the path with O_NOFOLLOW|O_DIRECTORY: throws when the final
    /// component is a symlink or not a directory. This is the last check before
    /// destructive operations (commit move, recursive cleanup).
    public static func assertRealDirectoryNotSymlink(_ path: String) throws {
        try validateRaw(path)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            // O_NOFOLLOW on a symlink reports ENOTDIR on macOS; lstat gives the
            // precise reason for the caller (and for the audit log).
            var info = stat()
            if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw SafePathError.isSymlink(path: path)
            }
            if errno == ELOOP { throw SafePathError.isSymlink(path: path) }
            throw SafePathError.notADirectory(path: path)
        }
        close(fd)
    }

    /// Validates a restore destination chosen by the user (`.copy` /
    /// `.wholeProject`): raw-valid, no traversal, and completely disjoint from
    /// both CodeTime's internal roots and every original project root.
    ///
    /// The source check is bidirectional (equal / inside / ancestor). A restore
    /// must never be able to write into an original project, replace one, or
    /// stage temporary files inside one. Returns the resolved URL.
    @discardableResult
    public static func validateRestoreDestination(
        _ destination: URL,
        protectedRoots: [URL],
        sourceRoots: [URL] = []
    ) throws -> URL {
        try validateRaw(destination.path)
        if components(of: destination.path).contains("..") { throw SafePathError.traversal }
        let real = resolved(destination)
        for protected in protectedRoots where overlaps(real, protected) {
            throw SafePathError.overlapsProtectedRoot(
                path: destination.path,
                root: resolved(protected).path
            )
        }
        for source in sourceRoots where overlaps(real, source) {
            throw SafePathError.overlapsSource(
                path: destination.path,
                source: resolved(source).path
            )
        }
        return real
    }
}
