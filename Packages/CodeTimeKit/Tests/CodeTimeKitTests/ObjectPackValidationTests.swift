import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-220…CT-226: Pack parsing and validation reject truncation, overflow,
/// duplicate/overlapping ranges and corrupted encrypted members.
final class ObjectPackValidationTests: XCTestCase {
    private let idA = String(repeating: "11", count: 32)
    private let idB = String(repeating: "22", count: 32)

    private func pack(_ objects: [(String, Data)], target: Int = 1 << 20) throws -> ObjectPackBuilder.Built {
        let built = try ObjectPackBuilder(options: .init(targetBytes: target)).build(objects)
        return try XCTUnwrap(built.first)
    }

    private func overwriteID(_ payload: inout Data, entryIndex: Int, with id: String) throws {
        let start = ObjectPackFormat.headerSize + entryIndex * ObjectPackFormat.entrySize
        let bytes = try XCTUnwrap(ObjectPackBuilder.rawObjectID(id))
        payload.replaceSubrange(start..<(start + 32), with: bytes)
    }

    private func writeUInt64(_ value: UInt64, at offset: Int, in payload: inout Data) {
        for index in 0..<8 {
            payload[offset + index] = UInt8((value >> UInt64(56 - index * 8)) & 0xFF)
        }
    }

    func testCT220_PackIDMismatchRejected() throws {
        let built = try pack([(idA, Data("a".utf8))])
        XCTAssertThrowsError(
            try ObjectPackValidator.validate(
                payload: built.payload,
                packID: String(repeating: "00", count: 32)
            )
        ) { error in
            XCTAssertEqual(error as? ObjectPackError, .badMagic)
        }
    }

    func testCT221_DuplicateObjectIDRejected() throws {
        var built = try pack([(idA, Data("a".utf8)), (idB, Data("b".utf8))])
        try overwriteID(&built.payload, entryIndex: 1, with: idA)
        XCTAssertThrowsError(
            try ObjectPackValidator.validate(payload: built.payload)
        ) { error in
            XCTAssertEqual(error as? ObjectPackError, .duplicateObject(idA))
        }
    }

    func testCT222_OverlappingRangesRejected() throws {
        var built = try pack([(idA, Data("aaaa".utf8)), (idB, Data("bbbb".utf8))])
        let secondStart = ObjectPackFormat.headerSize + ObjectPackFormat.entrySize
        let firstOffset = built.entries[0].offset
        writeUInt64(UInt64(firstOffset), at: secondStart + 32, in: &built.payload)
        XCTAssertThrowsError(
            try ObjectPackValidator.validate(payload: built.payload)
        ) { error in
            XCTAssertEqual(error as? ObjectPackError, .invalidRange(objectID: "overlap"))
        }
    }

    func testCT223_IntegerOverflowIsRejectedWithoutCrashing() throws {
        var payload = Data()
        payload.append(ObjectPackFormat.magic)
        payload.append(ObjectPackFormat.version)
        payload.append(0)
        payload.append(contentsOf: [0, 0, 0, 1]) // count = 1
        payload.append(ObjectPackBuilder.rawObjectID(idA)!)
        payload.append(Data(repeating: 0, count: 8))
        writeUInt64(UInt64.max, at: payload.count - 8, in: &payload)
        payload.append(contentsOf: [0, 0, 0, 1]) // length = 1
        XCTAssertThrowsError(try ObjectPackReader().entries(in: payload)) { error in
            XCTAssertEqual(error as? ObjectPackError, .invalidRange(objectID: idA))
        }
    }

    func testCT224_TruncatedIndexRejected() throws {
        var payload = Data()
        payload.append(ObjectPackFormat.magic)
        payload.append(ObjectPackFormat.version)
        payload.append(0)
        payload.append(contentsOf: [0, 0, 0, 2]) // claims two entries
        payload.append(Data(repeating: 0, count: ObjectPackFormat.entrySize)) // only one
        XCTAssertThrowsError(try ObjectPackReader().entries(in: payload)) { error in
            XCTAssertEqual(error as? ObjectPackError, .truncatedEntry)
        }
    }

    func testCT225_CorruptedEncryptedMemberRejectedByObjectValidator() throws {
        let encoder = ObjectEncoder(masterKey: Data("pack-validation-key".utf8))
        let plaintext = Data(repeating: 0x5A, count: 4096)
        let id = encoder.objectID(for: plaintext)
        let encoded = try encoder.encode(chunk: plaintext)
        let built = try pack([(id, encoded.payload)])
        var corrupted = built.payload
        let entry = try XCTUnwrap(built.entries.first)
        let mutation = entry.offset + entry.length / 2
        corrupted[mutation] ^= 0xFF
        XCTAssertThrowsError(
            try ObjectPackValidator.validate(
                payload: corrupted,
                packID: CanonicalHashing.sha256Hex(corrupted),
                objectValidator: { payload, objectID in
                    (try? encoder.decode(payload, objectID: objectID)) != nil
                }
            )
        )
    }

    func testCT226_InvalidOriginalSizeAndDecompressionLimitRejected() throws {
        var header = Data()
        header.append(ObjectEnvelope.magic)
        header.append(ObjectEnvelope.formatVersion)
        header.append(ObjectEnvelope.CompressionKind.none.rawValue)
        header.append(contentsOf: [UInt8(0), UInt8(1)]) // keyVersion
        let huge = UInt64(Int.max)
        for shift in stride(from: 56, through: 0, by: -8) {
            header.append(UInt8((huge >> UInt64(shift)) & 0xFF))
        }
        header.append(Data(repeating: 0, count: 12)) // nonce
        header.append(Data(repeating: 0, count: 16)) // tag
        let encoder = ObjectEncoder(masterKey: Data("limit-key".utf8))
        XCTAssertThrowsError(
            try encoder.decode(header, objectID: String(repeating: "aa", count: 32))
        ) { error in
            guard case .sizeLimitExceeded = error as? ObjectCodecError else {
                return XCTFail("期望 sizeLimitExceeded，实际 \(error)")
            }
        }

        let compressible = Data(repeating: 0x41, count: 4096)
        let id = encoder.objectID(for: compressible)
        let encoded = try encoder.encode(chunk: compressible)
        let limited = ObjectEncoder(
            masterKey: Data("limit-key".utf8),
            limits: .init(maxObjectBytes: 2_000_000, maxDecompressedBytes: 1024)
        )
        XCTAssertThrowsError(try limited.decode(encoded.payload, objectID: id)) { error in
            guard case .sizeLimitExceeded = error as? ObjectCodecError else {
                return XCTFail("期望 sizeLimitExceeded，实际 \(error)")
            }
        }
    }
}
