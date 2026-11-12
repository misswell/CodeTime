import Foundation

/// Explicit lifecycle of a content-addressed object. `hasObject == true` is not
/// enough: a file name can exist locally while iCloud has not accepted the bytes,
/// or while another process is still writing it.
public enum CloudObjectState: Sendable, Equatable {
    case absent
    /// Present only in the local spool/journal; not yet durable in the cloud.
    case staged
    /// A local mirror file is durable on disk but has not been confirmed as an
    /// iCloud upload. It is never reusable for a cloud snapshot.
    case localDurable
    /// A writer owns the object (upload or pack) and other callers must wait.
    case uploading
    case uploaded(storedSize: Int)
    case packed(packID: String, offset: Int64, storedSize: Int)
    /// A previous real remote read/decrypt succeeded.
    case verified(storedSize: Int)
    case failed(String)
    /// The backend could not be read; this is never equivalent to `.absent`.
    case inaccessible(String)
}

/// A validated location for a chunk. A packed object must be read through its
/// pack; it does not exist as a standalone cloud item.
public struct StoredObjectLocation: Sendable, Equatable {
    public var storedSize: Int
    public var packID: String?
    public var packOffset: Int64?

    public init(storedSize: Int, packID: String? = nil, packOffset: Int64? = nil) {
        self.storedSize = storedSize
        self.packID = packID
        self.packOffset = packOffset
    }
}

public enum CloudObjectLifecycleError: Error, Sendable, Equatable {
    case uploadNotConfirmed(objectID: String, detail: String)
    case corruptExistingObject(objectID: String, detail: String)
    case stateUnavailable(objectID: String, detail: String)
    case writerFailed(objectID: String, detail: String)
}

/// Extension of the write seam with an explicit object lifecycle. Default
/// implementations preserve compatibility for in-memory test doubles; production
/// stores override them with durable state.
public extension CloudObjectSink {
    func objectState(_ objectID: String) async throws -> CloudObjectState {
        do {
            return try await hasObject(objectID) ? .uploaded(storedSize: 0) : .absent
        } catch {
            throw CloudObjectLifecycleError.stateUnavailable(
                objectID: objectID,
                detail: error.localizedDescription
            )
        }
    }

    /// Ensures an object is durable and returns its validated location. The
    /// default implementation is only safe for simple/test sinks; UploadQueue and
    /// CloudObjectStoreV3 override it with strict confirmation and corruption
    /// handling.
    func ensureObjectReady(
        _ objectID: String,
        payload: Data,
        storedSize: Int
    ) async throws -> StoredObjectLocation {
        let state = try await objectState(objectID)
        switch state {
        case .uploaded(let size), .verified(let size):
            return StoredObjectLocation(storedSize: size > 0 ? size : storedSize)
        case .packed(let packID, let offset, let size):
            return StoredObjectLocation(storedSize: size, packID: packID, packOffset: offset)
        case .absent:
            _ = try await putObject(payload, objectID: objectID)
            return StoredObjectLocation(storedSize: storedSize)
        case .staged, .localDurable, .uploading:
            throw CloudObjectLifecycleError.uploadNotConfirmed(
                objectID: objectID,
                detail: "对象仍在上传，不能发布引用"
            )
        case .failed(let detail):
            throw CloudObjectLifecycleError.writerFailed(objectID: objectID, detail: detail)
        case .inaccessible(let detail):
            throw CloudObjectLifecycleError.stateUnavailable(objectID: objectID, detail: detail)
        }
    }
}

public extension CloudObjectState {
    /// True only for states that may be referenced by a published snapshot.
    var isDurablyPresent: Bool {
        switch self {
        case .uploaded, .verified, .packed:
            return true
        case .absent, .staged, .localDurable, .uploading, .failed, .inaccessible:
            return false
        }
    }
}

public extension CloudObjectSink {
    /// Pack state defaults to existence for simple sinks; production stores
    /// override it with upload-confirmation semantics.
    func packState(_ packID: String) async throws -> CloudObjectState {
        try await hasPack(packID) ? .uploaded(storedSize: 0) : .absent
    }
}
