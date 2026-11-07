import Foundation
import SharedModels
import CodeTimeSecurity

/// Copies that CodeTime makes before overwriting a live file during restore.
///
/// The old implementation used `recovery/<timestamp>/<project name>/…`, which
/// collided when two projects shared a name and could never be pruned by project.
/// Each copy now lives under the project UUID, carries a manifest with the source
/// hash, and is only reported as a protection copy after the copy's own hash
/// matches the source.
public enum ProtectedCopyStore {
    public struct Manifest: Codable, Sendable {
        public var id: UUID
        public var projectID: UUID
        public var createdAt: Date
        public var originalRoot: String
        public var originalPath: String
        public var sha256: String
        public var size: Int64
        public var isDirectory: Bool

        public init(
            id: UUID,
            projectID: UUID,
            createdAt: Date,
            originalRoot: String,
            originalPath: String,
            sha256: String,
            size: Int64,
            isDirectory: Bool
        ) {
            self.id = id
            self.projectID = projectID
            self.createdAt = createdAt
            self.originalRoot = originalRoot
            self.originalPath = originalPath
            self.sha256 = sha256
            self.size = size
            self.isDirectory = isDirectory
        }
    }

    public static let manifestName = "manifest.json"
    public static let maximumCopiesPerProject = 20
    public static let maximumBytesPerProject: Int64 = 2 * 1024 * 1024 * 1024

    /// Returns the directory that now holds the verified copy.
    @discardableResult
    public static func createCopy(
        target: URL,
        projectID: UUID,
        projectRoot: URL,
        recoveryRoot: URL
    ) throws -> URL {
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

        do {
            let sourceSize: Int64
            let sourceHash: String
            if isDirectory.boolValue {
                try fileManager.copyItem(at: source, to: payload)
                sourceSize = try directorySize(payload)
                sourceHash = try treeHash(payload)
            } else {
                try fileManager.createDirectory(
                    at: payload.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: payload)
                let values = try source.resourceValues(forKeys: [.fileSizeKey])
                sourceSize = Int64(values.fileSize ?? 0)
                sourceHash = try Hashing.sha256Hex(fileURL: source)
                let copiedHash = try Hashing.sha256Hex(fileURL: payload)
                guard copiedHash == sourceHash else {
                    throw CodeTimeError.integrityFailure("保护副本哈希与源文件不一致：\(source.lastPathComponent)")
                }
            }

            let manifest = Manifest(
                id: copyID,
                projectID: projectID,
                createdAt: Date(),
                originalRoot: projectRoot.standardizedFileURL.path,
                originalPath: source.path,
                sha256: sourceHash,
                size: sourceSize,
                isDirectory: isDirectory.boolValue
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: copyDirectory.appendingPathComponent(manifestName),
                options: .atomic
            )

            prune(projectDirectory: projectDirectory)
            return copyDirectory
        } catch {
            // A half-written copy must never be mistaken for a valid protection copy.
            do {
                try fileManager.removeItem(at: copyDirectory)
            } catch {
                // The original error is more useful; the leftover directory has no manifest.
            }
            throw error
        }
    }

    public static func listManifests(projectID: UUID, recoveryRoot: URL) -> [Manifest] {
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
        return entries.compactMap { url in
            let manifestURL = url.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            return try? decoder.decode(Manifest.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Keeps the newest `maximumCopiesPerProject` copies and trims from the oldest
    /// end until the project's total protection bytes are under the cap.
    public static func prune(projectDirectory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let sorted = entries.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l > r
        }
        var total: Int64 = 0
        var kept = 0
        for entry in sorted {
            let size = (try? directorySize(entry)) ?? 0
            kept += 1
            if kept > maximumCopiesPerProject || total + size > maximumBytesPerProject {
                do {
                    try fileManager.removeItem(at: entry)
                } catch {
                    continue
                }
            } else {
                total += size
            }
        }
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
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Deterministic hash over relative path + per-file hash, so a directory copy
    /// can be compared without trusting modification dates.
    private static func treeHash(_ root: URL) throws -> String {
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
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            let hash = try Hashing.sha256Hex(fileURL: file)
            entries.append("\(relative):\(hash)")
        }
        return Hashing.sha256Hex(Data(entries.sorted().joined(separator: "\n").utf8))
    }
}
