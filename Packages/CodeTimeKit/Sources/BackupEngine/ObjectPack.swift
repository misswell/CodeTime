import Foundation
import SharedModels

/// Immutable pack format for Cloud Format v3 (CT-157).
///
/// iCloud Drive is slow at syncing thousands of tiny files, and a project with
/// many small files would otherwise create one iCloud item per chunk. A pack is a
/// single immutable file holding several *already encrypted* object payloads.
///
/// Layout (big-endian):
///
///     "CTP3" | version u8 | reserved u8 | count u32
///     entries[count]: objectID 32 raw bytes | offset u64 | length u32
///     blobs...
///
/// Object IDs are stored as raw bytes, never as text: the index stays small and
/// the pack never contains a plaintext hash or a path.
///
/// Packs are immutable: an existing pack is never appended to, so a pack ID can
/// be trusted forever, and a chunk that is still referenced by any version keeps
/// its whole pack.
public enum ObjectPackFormat {
    public static let magic = Data("CTP3".utf8)
    public static let version: UInt8 = 1
    public static let headerSize = 4 + 1 + 1 + 4
    public static let entrySize = 32 + 8 + 4

    public struct Entry: Sendable, Equatable {
        public var objectID: String
        public var offset: Int
        public var length: Int

        public init(objectID: String, offset: Int, length: Int) {
            self.objectID = objectID
            self.offset = offset
            self.length = length
        }
    }
}

public enum ObjectPackError: Error, Sendable, Equatable {
    case tooShort
    case badMagic
    case unsupportedVersion(UInt8)
    case truncatedEntry
    case objectNotFound(String)
    case invalidRange(objectID: String)
    case duplicateObject(String)
}

/// Deliverable name from the task book; the builder emits immutable packs.
public typealias ObjectPackWriter = ObjectPackBuilder

public struct ObjectPackBuilder: Sendable {
    public struct Options: Sendable {
        /// Flush a pack once it reaches this size (before compression/formatting
        /// overhead). 8MB keeps individual iCloud items reasonable.
        public var targetBytes: Int
        /// Hard ceiling; an object larger than this is never packed.
        public var maxBytes: Int

        public init(targetBytes: Int = 8 * 1024 * 1024, maxBytes: Int = 16 * 1024 * 1024) {
            self.targetBytes = max(1, targetBytes)
            self.maxBytes = max(self.targetBytes, maxBytes)
        }

        public static let `default` = Options()
    }

    public struct Built: Sendable, Equatable {
        public var packID: String
        public var payload: Data
        public var entries: [ObjectPackFormat.Entry]
    }

    public let options: Options
    public init(options: Options = .default) { self.options = options }

    /// Packs payloads greedily in input order. Objects beyond `maxBytes` are
    /// rejected rather than silently split: an encrypted object is indivisible.
    public func build(_ objects: [(objectID: String, payload: Data)]) throws -> [Built] {
        var packs: [Built] = []
        var current: [(String, Data)] = []
        var currentSize = ObjectPackFormat.headerSize

        func flush() throws {
            guard !current.isEmpty else { return }
            packs.append(try Self.assemble(current))
            current.removeAll(keepingCapacity: true)
            currentSize = ObjectPackFormat.headerSize
        }

        var seen = Set<String>()
        for object in objects {
            guard object.objectID.count == 64 else { throw ObjectPackError.truncatedEntry }
            guard seen.insert(object.objectID).inserted else {
                throw ObjectPackError.duplicateObject(object.objectID)
            }
            guard object.payload.count <= options.maxBytes else {
                // Callers must upload such an object standalone.
                throw ObjectPackError.invalidRange(objectID: object.objectID)
            }
            let entryCost = ObjectPackFormat.entrySize + object.payload.count
            if !current.isEmpty && currentSize + entryCost > options.targetBytes {
                try flush()
            }
            current.append((object.objectID, object.payload))
            currentSize += entryCost
        }
        try flush()
        return packs
    }

    static func assemble(_ objects: [(String, Data)]) throws -> Built {
        var indexSize = ObjectPackFormat.headerSize + objects.count * ObjectPackFormat.entrySize
        // Align blobs to 8 bytes so a reader can memory-map safely.
        indexSize = (indexSize + 7) & ~7

        var header = Data()
        header.append(ObjectPackFormat.magic)
        header.append(ObjectPackFormat.version)
        header.append(0)
        header.append(contentsOf: Self.uint32(UInt32(objects.count)))

        var offsets: [Int] = []
        var offset = indexSize
        for (_, payload) in objects {
            offsets.append(offset)
            offset += payload.count
        }

        var index = Data()
        for (position, object) in objects.enumerated() {
            guard let rawID = Self.rawObjectID(object.0) else { throw ObjectPackError.truncatedEntry }
            index.append(contentsOf: rawID)
            index.append(contentsOf: Self.uint64(UInt64(offsets[position])))
            index.append(contentsOf: Self.uint32(UInt32(object.1.count)))
        }

        var payload = header
        payload.append(index)
        if payload.count < indexSize {
            payload.append(Data(repeating: 0, count: indexSize - payload.count))
        }
        for (_, data) in objects {
            payload.append(data)
        }
        return Built(packID: CanonicalHashing.sha256Hex(payload), payload: payload, entries: objects.enumerated().map { position, object in
            ObjectPackFormat.Entry(
                objectID: object.0,
                offset: offsets[position],
                length: object.1.count
            )
        })
    }

    static func rawObjectID(_ objectID: String) -> Data? {
        guard objectID.count == 64 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = objectID.startIndex
        while index < objectID.endIndex {
            let next = objectID.index(index, offsetBy: 2)
            guard let byte = UInt8(objectID[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    static func uint32(_ value: UInt32) -> [UInt8] {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        return bytes
    }

    static func uint64(_ value: UInt64) -> [UInt8] {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        return bytes
    }
}

public struct ObjectPackReader: Sendable {
    public init() {}

    public func entries(in payload: Data) throws -> [ObjectPackFormat.Entry] {
        guard payload.count >= ObjectPackFormat.headerSize else { throw ObjectPackError.tooShort }
        guard payload.prefix(4) == ObjectPackFormat.magic else { throw ObjectPackError.badMagic }
        let base = payload.startIndex
        let version = payload[base + 4]
        guard version == ObjectPackFormat.version else {
            throw ObjectPackError.unsupportedVersion(version)
        }
        let count = Int(Self.readUInt32(payload, at: base + 6))
        let indexEnd = ObjectPackFormat.headerSize + count * ObjectPackFormat.entrySize
        guard payload.count >= indexEnd else { throw ObjectPackError.truncatedEntry }

        var result: [ObjectPackFormat.Entry] = []
        result.reserveCapacity(count)
        for position in 0..<count {
            let start = base + ObjectPackFormat.headerSize + position * ObjectPackFormat.entrySize
            let rawID = payload.subdata(in: start..<(start + 32))
            let objectID = rawID.map { String(format: "%02x", $0) }.joined()
            let offset = Int(Self.readUInt64(payload, at: start + 32))
            let length = Int(Self.readUInt32(payload, at: start + 40))
            result.append(ObjectPackFormat.Entry(objectID: objectID, offset: offset, length: length))
        }
        return result
    }

    /// Slices exactly one encrypted object out of the pack.
    public func object(_ objectID: String, in payload: Data) throws -> Data {
        let entries = try entries(in: payload)
        guard let entry = entries.first(where: { $0.objectID == objectID }) else {
            throw ObjectPackError.objectNotFound(objectID)
        }
        let base = payload.startIndex
        guard entry.offset >= ObjectPackFormat.headerSize,
              entry.length > 0,
              base + entry.offset + entry.length <= payload.endIndex else {
            throw ObjectPackError.invalidRange(objectID: objectID)
        }
        return payload.subdata(in: (base + entry.offset)..<(base + entry.offset + entry.length))
    }

    static func readUInt32(_ data: Data, at index: Data.Index) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 { value = (value << 8) | UInt32(data[index + offset]) }
        return value
    }

    static func readUInt64(_ data: Data, at index: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 { value = (value << 8) | UInt64(data[index + offset]) }
        return value
    }
}
