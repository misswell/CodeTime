import Foundation
import SharedModels
import CodeTimeSecurity

// MARK: - Upload tracking (§3.4)

public struct NoopUploadTracker: CloudUploadTracking {
    public init() {}
    public func waitForUpload(_ url: URL, timeout: TimeInterval) async throws {}
}

/// Strict iCloud upload tracker.
///
/// Every uncertainty is an error: missing metadata, a non-ubiquitous file, a
/// container mismatch or a timeout can never be interpreted as "uploaded".
public struct UbiquitousUploadTracker: CloudUploadTracking {
    private let containerURL: URL?

    public init(containerURL: URL? = nil) {
        self.containerURL = containerURL?.standardizedFileURL
    }

    public func waitForUpload(_ url: URL, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var confirmedAt: Date?
        while Date() < deadline {
            try Task.checkCancellation()
            let values = try Self.values(of: url)
            guard values.isUbiquitousItem == true else {
                // A missing item has no metadata at all; reporting "not in iCloud"
                // would hide the real failure from the caller.
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw CloudStoreError.metadataUnavailable("\(url.lastPathComponent)：文件不存在，无法确认上传")
                }
                throw CloudStoreError.notICloudItem(url.lastPathComponent)
            }
            if let containerURL, !url.standardizedFileURL.path.hasPrefix(containerURL.path) {
                throw CloudStoreError.cloudContainerMismatch(url.path)
            }
            if let uploadError = values.ubiquitousItemUploadingError {
                throw CloudStoreError.uploadIncomplete("\(url.lastPathComponent)：\(uploadError.localizedDescription)")
            }
            if values.ubiquitousItemIsUploaded == true {
                // Re-confirm after a short interval so a transient "uploaded"
                // observation is not trusted on its own.
                if let first = confirmedAt, Date().timeIntervalSince(first) >= 0.2 {
                    try Task.checkCancellation()
                    let again = try Self.values(of: url)
                    guard again.isUbiquitousItem == true, again.ubiquitousItemIsUploaded == true else {
                        if let uploadError = again.ubiquitousItemUploadingError {
                            throw CloudStoreError.uploadIncomplete("\(url.lastPathComponent)：\(uploadError.localizedDescription)")
                        }
                        confirmedAt = nil
                        try await Task.sleep(nanoseconds: 200_000_000)
                        continue
                    }
                    if let containerURL, !url.standardizedFileURL.path.hasPrefix(containerURL.path) {
                        throw CloudStoreError.cloudContainerMismatch(url.path)
                    }
                    return
                }
                confirmedAt = confirmedAt ?? Date()
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw CloudStoreError.uploadNotConfirmed(url.lastPathComponent)
    }

    /// Metadata errors are surfaced, never swallowed.
    static func values(of url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemUploadingErrorKey,
                .ubiquitousItemContainerDisplayNameKey,
            ])
        } catch {
            throw CloudStoreError.metadataUnavailable("\(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }
}

// MARK: - iCloud file state

public enum CloudItemState: Sendable, Equatable {
    case local
    case current
    case notDownloaded
    case downloading
    case unavailable(String)
}

public enum UbiquitousFiles {
    /// Returns a precise download state. A metadata read failure is reported as
    /// `.unavailable`, never treated as a missing file.
    public static func state(of url: URL) -> CloudItemState {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey,
        ]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            return .unavailable(error.localizedDescription)
        }
        guard values.isUbiquitousItem == true else {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .unavailable("文件不存在：\(url.lastPathComponent)")
            }
            return .local
        }
        if let error = values.ubiquitousItemDownloadingError {
            return .unavailable(error.localizedDescription)
        }
        switch values.ubiquitousItemDownloadingStatus {
        case .current, .downloaded:
            return .current
        case .notDownloaded:
            return .notDownloaded
        default:
            return .downloading
        }
    }

    public static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 300) async throws {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey,
        ]
        let initial: URLResourceValues
        do {
            initial = try url.resourceValues(forKeys: keys)
        } catch {
            throw CloudStoreError.metadataUnavailable("\(url.lastPathComponent)：\(error.localizedDescription)")
        }
        guard initial.isUbiquitousItem == true else {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CloudStoreError.metadataUnavailable("\(url.lastPathComponent)：文件不存在")
            }
            return
        }
        if initial.ubiquitousItemDownloadingStatus == .current
            || initial.ubiquitousItemDownloadingStatus == .downloaded {
            return
        }
        if let error = initial.ubiquitousItemDownloadingError {
            throw CloudStoreError.notDownloaded("\(url.lastPathComponent)：\(error.localizedDescription)")
        }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw CloudStoreError.notDownloaded("\(url.lastPathComponent)：\(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let current: URLResourceValues
            do {
                current = try url.resourceValues(forKeys: keys)
            } catch {
                throw CloudStoreError.metadataUnavailable("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
            if let error = current.ubiquitousItemDownloadingError {
                throw CloudStoreError.notDownloaded("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
            if current.ubiquitousItemDownloadingStatus == .current
                || current.ubiquitousItemDownloadingStatus == .downloaded {
                return
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw CloudStoreError.notDownloaded(url.lastPathComponent)
    }
}

// MARK: - Coordinated file access (§3.5)

public protocol CloudFileAccess: Sendable {
    func read(_ url: URL) async throws -> Data
    func writeAtomically(_ data: Data, to url: URL) async throws
    func move(_ source: URL, to destination: URL) async throws
    func copy(_ source: URL, to destination: URL) async throws
    func remove(_ url: URL) async throws
    func list(_ url: URL, keys: [URLResourceKey]) async throws -> [URL]
    func ensureDirectory(_ url: URL) async throws
    func download(_ url: URL, timeout: TimeInterval) async throws
    func hash(_ url: URL) async throws -> String
}

public struct LocalFileAccess: CloudFileAccess {
    public init() {}

    public func read(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
    }

    public func writeAtomically(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func move(_ source: URL, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func copy(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }

    public func remove(_ url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    public func list(_ url: URL, keys: [URLResourceKey]) async throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
    }

    public func ensureDirectory(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func download(_ url: URL, timeout: TimeInterval) async throws {
        try await UbiquitousFiles.ensureDownloaded(url, timeout: timeout)
    }

    public func hash(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try Hashing.sha256Hex(fileURL: url) }.value
    }
}

/// Every iCloud access goes through `NSFileCoordinator`. Coordination failures and
/// inner errors are both surfaced; the coordinated URL is used inside the block.
public struct ICloudCoordinatedFileAccess: CloudFileAccess {
    public init() {}

    public func read(_ url: URL) async throws -> Data {
        try coordinateReading(url) { actual in try Data(contentsOf: actual) }
    }

    public func writeAtomically(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinateWriting(url) { actual in
            try data.write(to: actual, options: .atomic)
        }
    }

    public func move(_ source: URL, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinatorError: NSError?
        var innerError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinatorError
        ) { actualSource, actualDestination in
            do { try FileManager.default.moveItem(at: actualSource, to: actualDestination) }
            catch { innerError = error }
        }
        if let coordinatorError { throw CloudStoreError.coordinationFailed(coordinatorError.localizedDescription) }
        if let innerError { throw innerError }
    }

    public func copy(_ source: URL, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinatorError: NSError?
        var innerError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source,
            options: [],
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinatorError
        ) { actualSource, actualDestination in
            do { try FileManager.default.copyItem(at: actualSource, to: actualDestination) }
            catch { innerError = error }
        }
        if let coordinatorError { throw CloudStoreError.coordinationFailed(coordinatorError.localizedDescription) }
        if let innerError { throw innerError }
    }

    public func remove(_ url: URL) async throws {
        try coordinateWriting(url) { actual in
            try FileManager.default.removeItem(at: actual)
        }
    }

    public func list(_ url: URL, keys: [URLResourceKey]) async throws -> [URL] {
        try coordinateReading(url) { actual in
            try FileManager.default.contentsOfDirectory(
                at: actual,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        }
    }

    public func ensureDirectory(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func download(_ url: URL, timeout: TimeInterval) async throws {
        try await UbiquitousFiles.ensureDownloaded(url, timeout: timeout)
    }

    public func hash(_ url: URL) async throws -> String {
        try await download(url, timeout: 300)
        return try coordinateReading(url) { actual in
            try Hashing.sha256Hex(fileURL: actual)
        }
    }

    private func coordinateReading<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinatorError: NSError?
        var innerError: Error?
        var result: T?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinatorError) { actual in
            do { result = try body(actual) }
            catch { innerError = error }
        }
        if let coordinatorError { throw CloudStoreError.coordinationFailed(coordinatorError.localizedDescription) }
        if let innerError { throw innerError }
        guard let result else { throw CloudStoreError.coordinationFailed("协调读取未返回结果：\(url.lastPathComponent)") }
        return result
    }

    private func coordinateWriting<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinatorError: NSError?
        var innerError: Error?
        var result: T?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinatorError) { actual in
            do { result = try body(actual) }
            catch { innerError = error }
        }
        if let coordinatorError { throw CloudStoreError.coordinationFailed(coordinatorError.localizedDescription) }
        if let innerError { throw innerError }
        guard let result else { throw CloudStoreError.coordinationFailed("协调写入未返回结果：\(url.lastPathComponent)") }
        return result
    }
}
