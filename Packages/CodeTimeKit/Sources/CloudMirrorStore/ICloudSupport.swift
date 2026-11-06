import Foundation
import SharedModels

public struct NoopUploadTracker: CloudUploadTracking {
    public init() {}
    public func waitForUpload(_ url: URL, timeout: TimeInterval) async throws {}
}

public struct UbiquitousUploadTracker: CloudUploadTracking {
    public init() {}

    public func waitForUpload(_ url: URL, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let values = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemUploadingErrorKey,
            ])
            guard let values, values.isUbiquitousItem == true else { return }
            if let error = values.ubiquitousItemUploadingError {
                throw CodeTimeError.cloudPublishIncomplete(error.localizedDescription)
            }
            if values.ubiquitousItemIsUploaded == true { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw CodeTimeError.cloudPublishIncomplete("iCloud 未确认上传：\(url.lastPathComponent)")
    }
}

public enum UbiquitousFiles {
    public static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 300) async throws {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus == .current
            || values.ubiquitousItemDownloadingStatus == .downloaded {
            return
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = try? url.resourceValues(forKeys: keys)
            if let error = current?.ubiquitousItemDownloadingError {
                throw CodeTimeError.cloudPublishIncomplete(error.localizedDescription)
            }
            if current?.ubiquitousItemDownloadingStatus == .current
                || current?.ubiquitousItemDownloadingStatus == .downloaded {
                return
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw CodeTimeError.cloudPublishIncomplete("iCloud 文件未能下载：\(url.lastPathComponent)")
    }
}

enum CoordinatedIO {
    static func write(to url: URL, coordinated: Bool, _ body: (URL) throws -> Void) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard coordinated else {
            try body(url)
            return
        }
        var coordinatorError: NSError?
        var innerError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { actualURL in
            do { try body(actualURL) }
            catch { innerError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let innerError { throw innerError }
    }

    static func writeData(_ data: Data, to url: URL, coordinated: Bool) throws {
        try write(to: url, coordinated: coordinated) { actualURL in
            try data.write(to: actualURL, options: .atomic)
        }
    }
}
