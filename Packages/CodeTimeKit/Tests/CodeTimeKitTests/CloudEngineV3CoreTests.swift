import XCTest
import Foundation
@testable import BackupEngine
@testable import CodeTimeSecurity
@testable import SharedModels

/// CT-147 … CT-149: Cloud Format v3 core — content-defined chunking, content
/// addressing and the encrypted object envelope.
final class CloudEngineV3CoreTests: XCTestCase {

    // MARK: - Helpers

    /// Deterministic pseudo-random bytes (xorshift64*), so chunk boundaries are
    /// reproducible while still looking like incompressible file content.
    private func pseudoRandomData(count: Int, seed: UInt64 = 0x2545_F491_4F6C_DD1D) -> Data {
        var state = seed
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let value = state &* 0x2545_F491_4F6C_DD1D
            for shift in stride(from: 0, to: 64, by: 8) {
                bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
                if bytes.count == count { break }
            }
        }
        return Data(bytes)
    }

    private func repetitiveData(_ size: Int) -> Data {
        var data = Data()
        while data.count < size {
            data.append(Data("codetime-cloud-first-backup-engine\n".utf8))
        }
        return data.prefix(size)
    }

    private var smallConfig: ChunkerConfig {
        ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024)
    }

    private func ids(_ chunks: [Chunk], hasher: ContentHasher) -> [String] {
        chunks.map { hasher.objectID(forChunk: $0.data) }
    }

    // MARK: - CT-147 FastCDC

    func testCT147_ChunkerIsContentDefinedAndStable() throws {
        let chunker = FastCDCChunker(config: smallConfig)
        let hasher = ContentHasher(masterKey: Data("master-key-for-tests".utf8))
        let payload = pseudoRandomData(count: 512 * 1024)

        let first = try chunker.chunks(in: payload)
        let second = try chunker.chunks(in: payload)
        XCTAssertEqual(ids(first, hasher: hasher), ids(second, hasher: hasher), "分块必须确定")
        XCTAssertGreaterThan(first.count, 4, "512KB 数据应被切成多块")
        XCTAssertEqual(first.reduce(0) { $0 + $1.size }, payload.count, "分块必须覆盖全部字节")
        XCTAssertEqual(first.first?.offset, 0)
        for (index, chunk) in first.enumerated() {
            XCTAssertLessThanOrEqual(chunk.size, smallConfig.maxSize)
            if index < first.count - 1 {
                XCTAssertGreaterThanOrEqual(chunk.size, smallConfig.minSize, "非末块不得小于最小块")
            }
            XCTAssertEqual(
                Int(chunk.offset),
                first.prefix(index).reduce(0) { $0 + $1.size },
                "偏移必须连续"
            )
        }

        // Appending must not disturb the chunks that were already complete: this
        // is the property that makes incremental upload possible at all.
        let appended = payload + pseudoRandomData(count: 256 * 1024, seed: 99)
        let appendedChunks = try chunker.chunks(in: appended)
        let before = Set(ids(first.dropLast(), hasher: hasher))
        let after = Set(ids(appendedChunks, hasher: hasher))
        XCTAssertTrue(before.isSubset(of: after), "追加内容不得改变已有完整数据块的边界")

        // Inserting at the head resyncs after a few chunks instead of changing
        // every chunk of the file.
        let inserted = pseudoRandomData(count: 100, seed: 7) + payload
        let insertedChunks = try chunker.chunks(in: inserted)
        let insertedIDs = Set(ids(insertedChunks, hasher: hasher))
        let completeChunks = Set(ids(first.dropLast(), hasher: hasher))
        let reused = insertedIDs.intersection(completeChunks).count
        XCTAssertGreaterThanOrEqual(
            reused,
            max(1, completeChunks.count / 2),
            "头部插入后必须复用至少一半的原有完整数据块（实际复用 \(reused)/\(completeChunks.count)）"
        )
    }

    func testCT147_ChunkerHandlesEdgeCasesAndCancellation() throws {
        let chunker = FastCDCChunker(config: smallConfig)
        XCTAssertTrue(try chunker.chunks(in: Data()).isEmpty, "空文件必须产生 0 个数据块")

        let tiny = Data("hello".utf8)
        let tinyChunks = try chunker.chunks(in: tiny)
        XCTAssertEqual(tinyChunks.count, 1, "小于最小块的文件整体成为一块")
        XCTAssertEqual(tinyChunks[0].data, tiny)

        let exactMin = pseudoRandomData(count: smallConfig.minSize)
        XCTAssertEqual(try chunker.chunks(in: exactMin).count, 1)

        // Cancellation must surface, not be swallowed.
        XCTAssertThrowsError(
            try chunker.chunks(in: pseudoRandomData(count: 64 * 1024), isCancelled: { true })
        ) { error in
            XCTAssertEqual(error as? ChunkerError, .cancelled)
        }
    }

    func testCT147_StreamingFileMatchesInMemoryChunking() throws {
        let chunker = FastCDCChunker(config: smallConfig)
        let hasher = ContentHasher(masterKey: Data("k".utf8))
        let payload = pseudoRandomData(count: 300 * 1024)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunker-\(UUID().uuidString).bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var streamed: [Chunk] = []
        try chunker.forEachChunk(ofFile: url) { streamed.append($0) }
        let memory = try chunker.chunks(in: payload)
        XCTAssertEqual(ids(streamed, hasher: hasher), ids(memory, hasher: hasher))
        XCTAssertEqual(streamed.reduce(0) { $0 + $1.size }, payload.count)
    }

    func testCT147_CompressibleAndRepetitiveContentStillChunks() throws {
        let chunker = FastCDCChunker(config: smallConfig)
        let payload = repetitiveData(200 * 1024)
        let chunks = try chunker.chunks(in: payload)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.size }, payload.count)
    }

    // MARK: - CT-148 Content addressing

    func testCT148_ObjectIdentityIsStableAndKeyScoped() throws {
        let chunk = pseudoRandomData(count: 4096)
        let hasherA = ContentHasher(masterKey: Data("repo-master-key-A".utf8))
        let hasherA2 = ContentHasher(masterKey: Data("repo-master-key-A".utf8))
        let hasherB = ContentHasher(masterKey: Data("repo-master-key-B".utf8))

        let idA = hasherA.objectID(forChunk: chunk)
        XCTAssertEqual(idA.count, 64, "对象 ID 必须是 64 位十六进制")
        XCTAssertTrue(idA.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(idA, hasherA2.objectID(forChunk: chunk), "同一密钥下相同内容必须得到相同 ID")
        XCTAssertEqual(idA, hasherA.objectID(forChunk: Data(chunk)), "内容相同即 ID 相同")
        XCTAssertNotEqual(idA, hasherB.objectID(forChunk: chunk), "不同仓库密钥必须产生不同 ID")

        let other = pseudoRandomData(count: 4096, seed: 12345)
        XCTAssertNotEqual(idA, hasherA.objectID(forChunk: other), "内容不同必须 ID 不同")
        XCTAssertEqual(hasherA.plaintextHash(forChunk: chunk), Hashing.sha256Hex(chunk))
    }

    // MARK: - CT-149 Object envelope

    func testCT149_EncryptedObjectRoundTrip() throws {
        let master = Data("unit-test-master-key".utf8)
        let encoder = ObjectEncoder(masterKey: master)

        // Compressible chunk: the envelope must actually compress and round-trip.
        let compressible = repetitiveData(200 * 1024)
        let encoded = try encoder.encode(chunk: compressible)
        XCTAssertTrue(encoded.wasCompressed, "可压缩数据必须启用压缩")
        XCTAssertLessThan(encoded.storedSize, encoded.originalSize)
        XCTAssertEqual(encoded.payload.prefix(4), ObjectEnvelope.magic)
        XCTAssertEqual(try encoder.decode(encoded.payload, objectID: encoded.objectID), compressible)
        XCTAssertEqual(encoded.objectID, encoder.objectID(for: compressible))

        // Incompressible chunk: stored raw, still round-trips.
        let noisy = pseudoRandomData(count: 64 * 1024)
        let noisyEncoded = try encoder.encode(chunk: noisy)
        XCTAssertFalse(noisyEncoded.wasCompressed, "不可压缩数据不应二次压缩")
        XCTAssertEqual(try encoder.decode(noisyEncoded.payload, objectID: noisyEncoded.objectID), noisy)

        // Empty chunk is legal.
        let empty = try encoder.encode(chunk: Data())
        XCTAssertEqual(try encoder.decode(empty.payload, objectID: empty.objectID), Data())

        // Two encodes of the same chunk differ on disk (fresh nonce) but carry the
        // same identity.
        let again = try encoder.encode(chunk: compressible)
        XCTAssertEqual(again.objectID, encoded.objectID)
        XCTAssertNotEqual(again.payload, encoded.payload, "相同内容每次加密必须使用新 nonce")
        XCTAssertEqual(try encoder.decode(again.payload, objectID: again.objectID), compressible)
    }

    func testCT149_TamperingAndWrongKeysAreRejected() throws {
        let encoder = ObjectEncoder(masterKey: Data("master-A".utf8))
        let chunk = repetitiveData(32 * 1024)
        let encoded = try encoder.encode(chunk: chunk)

        // Ciphertext bit flip.
        var flipped = encoded.payload
        let lastIndex = flipped.index(flipped.endIndex, offsetBy: -20)
        flipped[lastIndex] ^= 0x01
        XCTAssertThrowsError(try encoder.decode(flipped, objectID: encoded.objectID))

        // Header tamper (compression flag) — bound into the AAD.
        var headerTampered = encoded.payload
        headerTampered[headerTampered.startIndex + 5] = ObjectEnvelope.CompressionKind.none.rawValue
        XCTAssertThrowsError(try encoder.decode(headerTampered, objectID: encoded.objectID))

        // Object ID substitution.
        let otherID = encoder.objectID(for: pseudoRandomData(count: 16, seed: 5))
        XCTAssertThrowsError(try encoder.decode(encoded.payload, objectID: otherID))

        // Wrong repository key.
        let otherKey = ObjectEncoder(masterKey: Data("master-B".utf8))
        XCTAssertThrowsError(try otherKey.decode(encoded.payload, objectID: encoded.objectID))

        // Size expectation mismatch is an error, not a silent truncation.
        XCTAssertThrowsError(
            try encoder.decode(encoded.payload, objectID: encoded.objectID, expectingSize: chunk.count + 1)
        )

        // Truncation and bad magic are classified as corruption.
        XCTAssertThrowsError(try encoder.decode(encoded.payload.prefix(10), objectID: encoded.objectID)) { error in
            XCTAssertEqual(error as? ObjectCodecError, .tooShort(10))
        }
        var badMagic = encoded.payload
        badMagic[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try encoder.decode(badMagic, objectID: encoded.objectID)) { error in
            XCTAssertEqual(error as? ObjectCodecError, .badMagic)
        }
    }

    // MARK: - CT-150 Merkle tree

    private func scannedFile(_ path: String, bytes: Int64, chunkSeed: UInt64 = 1) -> ScannedFile {
        ScannedFile(
            path: path,
            kind: .file,
            size: bytes,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            mode: 0o644,
            contentHash: String(format: "%064lx", chunkSeed),
            chunks: [
                ChunkRef(
                    objectID: String(format: "%064lx", chunkSeed),
                    plaintextSize: Int(bytes),
                    storedSize: Int(bytes),
                    compression: 0
                )
            ]
        )
    }

    func testCT150_TreeIsDeterministicAndOrderIndependent() throws {
        let builder = MerkleTreeBuilder()
        let files = [
            scannedFile("README.md", bytes: 10, chunkSeed: 1),
            scannedFile("src/main.swift", bytes: 20, chunkSeed: 2),
            scannedFile("src/util/helpers.swift", bytes: 30, chunkSeed: 3),
            scannedFile("docs/guide.md", bytes: 40, chunkSeed: 4),
        ]
        let forward = builder.build(files: files)
        let reversed = builder.build(files: files.reversed())

        XCTAssertEqual(forward.root.nodeID, reversed.root.nodeID, "输入顺序不得影响树身份")
        XCTAssertEqual(forward.root.computedNodeID, forward.root.nodeID, "根节点 ID 必须自洽")
        XCTAssertEqual(forward.fileCount, 4)
        XCTAssertEqual(forward.totalBytes, 100)
        XCTAssertEqual(forward.root.directories.map(\.name), ["docs", "src"], "子目录必须有序")
        XCTAssertEqual(forward.root.files.map(\.path), ["README.md"])

        // Nested directory aggregates upward.
        let src = try XCTUnwrap(forward.directories.first { $0.path == "src" })
        XCTAssertEqual(src.fileCount, 2)
        XCTAssertEqual(src.totalBytes, 50)
        XCTAssertEqual(src.directories.map(\.name), ["util"])

        // Every node id is content-derived and self-consistent.
        for node in forward.directories {
            XCTAssertEqual(node.computedNodeID, node.nodeID, "\(node.path) 节点 ID 必须自洽")
        }
        XCTAssertEqual(Set(forward.nodeIDs).count, forward.nodeIDs.count, "节点 ID 不得重复")

        // Empty tree is legal and stable.
        let empty = builder.build(files: [])
        XCTAssertEqual(empty.root.nodeID, builder.build(files: []).root.nodeID)
        XCTAssertEqual(empty.fileCount, 0)
        XCTAssertEqual(empty.totalBytes, 0)
        XCTAssertNotEqual(empty.root.nodeID, forward.root.nodeID)
    }

    func testCT150_ChangePropagatesOnlyAlongThePath() throws {
        let builder = MerkleTreeBuilder()
        let base = [
            scannedFile("src/main.swift", bytes: 20, chunkSeed: 2),
            scannedFile("src/util/helpers.swift", bytes: 30, chunkSeed: 3),
            scannedFile("docs/guide.md", bytes: 40, chunkSeed: 4),
        ]
        let before = builder.build(files: base)

        // Modify one file deep in `src/util`.
        var changed = base
        let index = try XCTUnwrap(changed.firstIndex { $0.path == "src/util/helpers.swift" })
        changed[index] = scannedFile("src/util/helpers.swift", bytes: 31, chunkSeed: 99)
        let after = builder.build(files: changed)

        XCTAssertNotEqual(before.root.nodeID, after.root.nodeID, "根节点必须变化")

        func node(_ tree: BuiltTree, _ path: String) throws -> DirectoryNode {
            try XCTUnwrap(tree.directories.first { $0.path == path })
        }
        // Ancestors change…
        XCTAssertNotEqual(try node(before, "src").nodeID, try node(after, "src").nodeID)
        XCTAssertNotEqual(try node(before, "src/util").nodeID, try node(after, "src/util").nodeID)
        // …untouched sibling subtree does not.
        XCTAssertEqual(try node(before, "docs").nodeID, try node(after, "docs").nodeID, "无关子树不得改变")
        XCTAssertEqual(
            before.files.first { $0.path == "src/main.swift" }?.nodeID,
            after.files.first { $0.path == "src/main.swift" }?.nodeID,
            "未修改文件节点必须复用"
        )
    }

    func testCT150_AddingADeepFileTouchesOnlyItsAncestors() throws {
        let builder = MerkleTreeBuilder()
        var files = [
            scannedFile("a/one.txt", bytes: 1, chunkSeed: 11),
            scannedFile("b/two.txt", bytes: 2, chunkSeed: 12),
        ]
        let before = builder.build(files: files)
        files.append(scannedFile("a/deep/three.txt", bytes: 3, chunkSeed: 13))
        let after = builder.build(files: files)

        let bBefore = try XCTUnwrap(before.directories.first { $0.path == "b" })
        let bAfter = try XCTUnwrap(after.directories.first { $0.path == "b" })
        XCTAssertEqual(bBefore.nodeID, bAfter.nodeID, "新增文件不得影响其他一级目录")

        let aBefore = try XCTUnwrap(before.directories.first { $0.path == "a" })
        let aAfter = try XCTUnwrap(after.directories.first { $0.path == "a" })
        XCTAssertNotEqual(aBefore.nodeID, aAfter.nodeID, "祖先目录必须变化")
        XCTAssertEqual(after.directories.first { $0.path == "a/deep" }?.fileCount, 1)
        XCTAssertEqual(after.totalBytes, 6)
    }
}
