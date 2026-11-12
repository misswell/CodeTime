import Foundation
import SharedModels
import CodeTimeSecurity

public enum RemoteObjectState: Sendable, Equatable {
    case absent
    case presentVerified(size: Int)
    case presentUnverified
    case inaccessible(String)
    case corrupted(String)
}

public enum RemoteIntegrityError: Error, Sendable, Equatable {
    case absent(String)
    case inaccessible(String, String)
    case corrupted(String, String)
    case identityMismatch(String, String)

    public var diagnosticCode: String {
        switch self {
        case .absent: return "remote_object_missing"
        case .inaccessible: return "icloud_download_failed"
        case .corrupted, .identityMismatch: return "remote_object_corrupted"
        }
    }
}

/// Validates the on-wire Pack format, not just the index reader's successful parse.
public enum ObjectPackValidator {
    public static func validate(
        payload: Data,
        packID: String? = nil,
        objectValidator: ((Data, String) -> Bool)? = nil
    ) throws -> [ObjectPackFormat.Entry] {
        if let packID, CanonicalHashing.sha256Hex(payload) != packID {
            throw ObjectPackError.badMagic
        }
        let entries = try ObjectPackReader().entries(in: payload)
        var seen = Set<String>()
        var ranges: [(Int, Int)] = []
        for entry in entries {
            guard seen.insert(entry.objectID).inserted else {
                throw ObjectPackError.duplicateObject(entry.objectID)
            }
            let (end, overflow) = entry.offset.addingReportingOverflow(entry.length)
            guard !overflow,
                  entry.offset >= ObjectPackFormat.headerSize,
                  entry.length > 0,
                  end <= payload.count else {
                throw ObjectPackError.invalidRange(objectID: entry.objectID)
            }
            ranges.append((entry.offset, end))
        }
        ranges.sort { $0.0 < $1.0 }
        for index in 1..<max(1, ranges.count) where ranges.count > 1 {
            if ranges[index].0 < ranges[index - 1].1 {
                throw ObjectPackError.invalidRange(objectID: "overlap")
            }
        }
        if let objectValidator {
            for entry in entries {
                let encoded = payload.subdata(in: entry.offset..<(entry.offset + entry.length))
                guard objectValidator(encoded, entry.objectID) else {
                    throw ObjectPackError.objectNotFound(entry.objectID)
                }
            }
        }
        return entries
    }
}

/// Reads and cryptographically verifies actual remote bytes. It never consults a
/// local download cache, so a cache hit cannot make a deleted/corrupt cloud object
/// look healthy.
public struct RemoteIntegrityVerifier: Sendable {
    private let masterKey: Data
    private let source: CloudObjectSource
    private let encoder: ObjectEncoder
    private let packCache: ValidatedPackCache

    public init(masterKey: Data, source: CloudObjectSource, keyVersion: UInt16 = 1) {
        self.masterKey = masterKey
        self.source = source
        self.encoder = ObjectEncoder(masterKey: masterKey, keyVersion: keyVersion)
        self.packCache = ValidatedPackCache(limit: 3)
    }

    public func inspectObject(
        objectID: String,
        expectedPlaintextSize: Int? = nil
    ) async -> RemoteObjectState {
        do {
            guard let payload = try await source.readObjectIfPresent(objectID) else {
                return .absent
            }
            let plaintext = try encoder.decode(
                payload, objectID: objectID, expectingSize: expectedPlaintextSize
            )
            return .presentVerified(size: plaintext.count)
        } catch let error as ObjectCodecError {
            return .corrupted("\(objectID)：\(error)")
        } catch let error as ObjectPackError {
            return .corrupted("\(objectID)：\(error)")
        } catch {
            return .inaccessible("\(objectID)：\(error)")
        }
    }

    public func inspectPack(packID: String) async -> RemoteObjectState {
        do {
            let validated = try await validatedPack(packID)
            // Every object in a retained pack must decrypt and match its identity.
            for entry in validated.entries {
                let encoded = validated.payload.subdata(
                    in: entry.offset..<(entry.offset + entry.length)
                )
                _ = try encoder.decode(encoded, objectID: entry.objectID)
            }
            return .presentVerified(size: validated.payload.count)
        } catch let error as RemoteIntegrityError {
            switch error {
            case .absent: return .absent
            case .inaccessible(_, let detail): return .inaccessible("\(packID)：\(detail)")
            case .corrupted(_, let detail): return .corrupted("\(packID)：\(detail)")
            case .identityMismatch(_, let detail): return .corrupted("\(packID)：\(detail)")
            }
        } catch let error as ObjectCodecError {
            return .corrupted("\(packID)：\(error)")
        } catch let error as ObjectPackError {
            return .corrupted("\(packID)：\(error)")
        } catch {
            return .inaccessible("\(packID)：\(error)")
        }
    }

    private func validatedPack(_ packID: String) async throws -> ValidatedPack {
        if let cached = packCache.get(packID) { return cached }
        let payload: Data
        do {
            guard let data = try await source.readPackIfPresent(packID) else {
                throw RemoteIntegrityError.absent(packID)
            }
            payload = data
        } catch let error as RemoteIntegrityError {
            throw error
        } catch {
            throw RemoteIntegrityError.inaccessible(packID, "\(error)")
        }
        let entries: [ObjectPackFormat.Entry]
        do {
            entries = try ObjectPackValidator.validate(payload: payload, packID: packID)
        } catch let error as ObjectPackError {
            throw RemoteIntegrityError.corrupted(packID, "\(error)")
        }
        let validated = ValidatedPack(payload: payload, entries: entries)
        packCache.put(packID, validated)
        return validated
    }

    /// Downloads exactly the object/pack needed and returns verified plaintext.
    public func verifiedChunk(_ chunk: ChunkRef) async throws -> Data {
        if let packID = chunk.packID {
            do {
                let validated = try await validatedPack(packID)
                guard let entry = validated.entries.first(where: { $0.objectID == chunk.objectID }) else {
                    throw RemoteIntegrityError.absent(chunk.objectID)
                }
                let encoded = validated.payload.subdata(
                    in: entry.offset..<(entry.offset + entry.length)
                )
                return try encoder.decode(
                    encoded,
                    objectID: chunk.objectID,
                    expectingSize: Int(chunk.plaintextSize)
                )
            } catch let error as RemoteIntegrityError {
                throw error
            } catch {
                throw RemoteIntegrityError.corrupted(chunk.objectID, "\(error)")
            }
        }
        do {
            guard let payload = try await source.readObjectIfPresent(chunk.objectID) else {
                throw RemoteIntegrityError.absent(chunk.objectID)
            }
            return try encoder.decode(
                payload,
                objectID: chunk.objectID,
                expectingSize: Int(chunk.plaintextSize)
            )
        } catch let error as RemoteIntegrityError {
            throw error
        } catch let error as ObjectCodecError {
            throw RemoteIntegrityError.corrupted(chunk.objectID, "\(error)")
        } catch {
            throw RemoteIntegrityError.inaccessible(chunk.objectID, "\(error)")
        }
    }
}


struct ValidatedPack {
    var payload: Data
    var entries: [ObjectPackFormat.Entry]
}

final class ValidatedPackCache: @unchecked Sendable {
    private let limit: Int
    private var storage: [String: ValidatedPack] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    init(limit: Int) { self.limit = max(1, limit) }

    func get(_ key: String) -> ValidatedPack? {
        lock.lock(); defer { lock.unlock() }
        guard let value = storage[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    func put(_ key: String, _ value: ValidatedPack) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            storage.removeValue(forKey: order.removeFirst())
        }
    }
}
