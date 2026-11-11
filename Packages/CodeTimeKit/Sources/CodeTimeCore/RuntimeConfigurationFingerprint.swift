import Foundation
import SharedModels
import CodeTimeSecurity

/// Everything that changes the meaning of a cached v3 runtime instance. When the
/// fingerprint moves, Store/Queue/Source/Adapter from the old configuration must
/// not be reused: a queue pointed at the old spool root must never be mixed with a
/// store pointed at the new container.
public struct RuntimeConfigurationFingerprint: Hashable, Sendable {
    public var storageMode: String
    public var engineMode: String
    public var containerIdentifier: String?
    public var localMirrorPath: String?
    public var bookmarkHash: String?
    public var deviceID: String
    public var cacheBudget: Int64
    public var spoolBudget: Int64

    public init(
        storageMode: String,
        engineMode: String,
        containerIdentifier: String?,
        localMirrorPath: String?,
        bookmarkHash: String?,
        deviceID: String,
        cacheBudget: Int64,
        spoolBudget: Int64
    ) {
        self.storageMode = storageMode
        self.engineMode = engineMode
        self.containerIdentifier = containerIdentifier
        self.localMirrorPath = localMirrorPath
        self.bookmarkHash = bookmarkHash
        self.deviceID = deviceID
        self.cacheBudget = cacheBudget
        self.spoolBudget = spoolBudget
    }

    public init(settings: AppSettings, deviceID: String) {
        let storageMode: String
        if settings.iCloudEnabled {
            storageMode = "icloud"
        } else if settings.localMirrorPath != nil {
            storageMode = "localMirror"
        } else {
            storageMode = "none"
        }
        self.init(
            storageMode: storageMode,
            engineMode: settings.engineMode.rawValue,
            containerIdentifier: settings.iCloudEnabled ? CloudFormatV3.folderName : nil,
            localMirrorPath: settings.iCloudEnabled ? nil : settings.localMirrorPath,
            bookmarkHash: Self.hash(settings.localMirrorBookmark),
            deviceID: deviceID,
            cacheBudget: settings.effectiveCacheBytes,
            spoolBudget: settings.spoolSoftLimitBytes
        )
    }

    /// The bookmark is opaque security-scoped data; only its hash belongs in a
    /// fingerprint (and in logs).
    private static func hash(_ bookmark: Data?) -> String? {
        guard let bookmark else { return nil }
        return CanonicalHashing.sha256Hex(bookmark)
    }
}
