import Foundation
import SharedModels

/// iCloud local-copy eviction.
///
/// `FileManager.evictUbiquitousItem` only drops the local copy — the file stays in
/// iCloud. Two safety rules:
/// 1. Never evict something that is not confirmed uploaded. An evicted file that
///    only existed locally is gone.
/// 2. Never report a failed eviction as success. macOS may refuse temporarily; the
///    UI must then say "云端已备份，本地空间等待释放" and retry later.
public protocol UbiquitousItemProbing: Sendable {
    func isUploaded(_ url: URL) async -> Bool
    func evict(_ url: URL) async throws
    func isUbiquitous(_ url: URL) async -> Bool
}

public struct FileManagerUbiquitousProbe: UbiquitousItemProbing {
    public init() {}

    public func isUbiquitous(_ url: URL) async -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }

    public func isUploaded(_ url: URL) async -> Bool {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey])
        return values?.ubiquitousItemIsUploaded ?? false
    }

    public func evict(_ url: URL) async throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}

public struct EvictionOutcome: Sendable, Equatable {
    public var evicted: Int
    public var skippedNotUploaded: [URL]
    public var failed: [URL]

    public init(evicted: Int = 0, skippedNotUploaded: [URL] = [], failed: [URL] = []) {
        self.evicted = evicted
        self.skippedNotUploaded = skippedNotUploaded
        self.failed = failed
    }

    /// True only when everything we intended to release was released.
    public var isComplete: Bool { failed.isEmpty && skippedNotUploaded.isEmpty }
}

public struct ICloudEvictionManager: Sendable {
    private let probe: UbiquitousItemProbing

    public init(probe: UbiquitousItemProbing = FileManagerUbiquitousProbe()) {
        self.probe = probe
    }

    /// Evicts the local copies of the given urls, but only after the provider
    /// confirms each one is uploaded.
    public func evictLocalCopies(of urls: [URL]) async -> EvictionOutcome {
        var outcome = EvictionOutcome()
        for url in urls {
            guard await probe.isUbiquitous(url) else {
                // A plain local file has no cloud copy: evicting it would delete
                // the only copy.
                outcome.skippedNotUploaded.append(url)
                continue
            }
            guard await probe.isUploaded(url) else {
                outcome.skippedNotUploaded.append(url)
                continue
            }
            do {
                try await probe.evict(url)
                outcome.evicted += 1
            } catch {
                outcome.failed.append(url)
            }
        }
        return outcome
    }
}
