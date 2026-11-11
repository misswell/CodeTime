import Foundation
import SharedModels

/// Content-defined chunking (FastCDC) for Cloud Format v3.
///
/// Why not whole-file hashing: editing one line at the top of a 100 GB file would
/// otherwise re-upload the entire file. Chunk boundaries are chosen from the
/// *content* (a gear rolling hash), so an insertion or deletion only changes the
/// chunks around it; every other chunk keeps its identity and is reused.
///
/// The gear table is a fixed SplitMix64 sequence: chunk boundaries must be
/// identical on every machine and for every future version, otherwise dedup
/// silently degrades and a re-scan would re-upload everything.
public struct ChunkerConfig: Sendable, Hashable {
    /// No chunk is smaller than this (except the final tail).
    public var minSize: Int
    /// Target size; also the switch point between the two masks.
    public var avgSize: Int
    /// Hard upper bound — a chunk never exceeds this.
    public var maxSize: Int

    public init(
        minSize: Int = 256 * 1024,
        avgSize: Int = 1024 * 1024,
        maxSize: Int = 4 * 1024 * 1024
    ) {
        precondition(minSize > 0 && minSize <= avgSize && avgSize <= maxSize)
        self.minSize = minSize
        self.avgSize = avgSize
        self.maxSize = maxSize
    }

    public static let `default` = ChunkerConfig()
}

public struct Chunk: Sendable, Hashable {
    public let offset: Int64
    public let data: Data

    public init(offset: Int64, data: Data) {
        self.offset = offset
        self.data = data
    }

    public var size: Int { data.count }
}

public enum ChunkerError: Error, Sendable, Equatable {
    case readFailed(String)
    case cancelled
}

public struct FastCDCChunker: Sendable {
    public let config: ChunkerConfig

    /// 256-entry gear table, SplitMix64 from a fixed seed (0x9E37_79B9_7F4A_7C15).
    /// Never change this table: it defines where chunk boundaries fall forever.
    static let gear: [UInt64] = {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var table = [UInt64](repeating: 0, count: 256)
        for index in 0..<256 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            table[index] = z ^ (z >> 31)
        }
        return table
    }()

    public init(config: ChunkerConfig = .default) {
        self.config = config
    }

    /// Chunk patterns for the normalized-chunking level 2 split: below the target
    /// size the mask is harder (fewer, larger chunks), above it easier.
    private var masks: (small: UInt64, large: UInt64) {
        var bits = 0
        var value = config.avgSize
        while value > 1 { value >>= 1; bits += 1 }
        bits = max(bits, 1)
        let small = bits + 2 <= 62 ? (UInt64(1) << UInt64(bits + 2)) - 1 : UInt64.max
        let large = bits >= 3 ? (UInt64(1) << UInt64(bits - 2)) - 1 : UInt64(1)
        return (small, large)
    }

    // MARK: - In-memory

    public func chunks(in data: Data, isCancelled: () -> Bool = { false }) throws -> [Chunk] {
        var result: [Chunk] = []
        var served = false
        try forEachChunk(reader: {
            // One-shot reader: hand out everything once, then EOF.
            if served { return Data() }
            served = true
            return data
        }, isCancelled: isCancelled) { chunk in
            result.append(chunk)
        }
        return result
    }

    // MARK: - Streaming

    /// Streams a file. Only one chunk (≤ `maxSize`) is held in memory at a time.
    public func forEachChunk(
        ofFile url: URL,
        isCancelled: () -> Bool = { false },
        _ body: (Chunk) throws -> Void
    ) throws {
        guard var iterator = try? makeIterator(ofFile: url) else {
            throw ChunkerError.readFailed(url.lastPathComponent)
        }
        while let chunk = try iterator.next(isCancelled: isCancelled) {
            try body(chunk)
        }
    }

    /// Pull-based iteration. The caller decides when to consume the next chunk,
    /// so an async pipeline can do I/O between chunks without buffering the file.
    public func makeIterator(ofFile url: URL) throws -> ChunkIterator {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ChunkerError.readFailed(url.lastPathComponent)
        }
        return ChunkIterator(chunker: self, reader: {
            do {
                let data = try autoreleasepool {
                    try handle.read(upToCount: 1 << 20) ?? Data()
                }
                if data.isEmpty { try? handle.close() }
                return data
            } catch {
                throw ChunkerError.readFailed(error.localizedDescription)
            }
        })
    }

    /// Core loop for callers that already have a byte source. `reader` returns
    /// empty data at EOF.
    public func forEachChunk(
        reader: @escaping () throws -> Data,
        isCancelled: () -> Bool = { false },
        _ body: (Chunk) throws -> Void
    ) throws {
        var iterator = ChunkIterator(chunker: self, reader: reader)
        while let chunk = try iterator.next(isCancelled: isCancelled) {
            try body(chunk)
        }
    }

    // MARK: - Boundary

    func boundaryLength(in buffer: Data, from head: Int, available: Int) -> Int {
        let limit = min(available, config.maxSize)
        if limit <= config.minSize { return limit }

        let mask = masks
        var hash: UInt64 = 0
        let base = buffer.startIndex + head

        for index in 0..<config.minSize {
            hash = (hash &<< 1) &+ Self.gear[Int(buffer[base + index])]
        }

        let normal = min(config.avgSize, limit)
        var cursor = config.minSize
        while cursor < normal {
            hash = (hash &<< 1) &+ Self.gear[Int(buffer[base + cursor])]
            if hash & mask.small == 0 { return cursor + 1 }
            cursor += 1
        }
        while cursor < limit {
            hash = (hash &<< 1) &+ Self.gear[Int(buffer[base + cursor])]
            if hash & mask.large == 0 { return cursor + 1 }
            cursor += 1
        }
        return limit
    }
}

/// Synchronous pull iterator over content-defined chunks.
///
/// `next()` returns nil at end of stream. Only one chunk is materialised at a
/// time; the read window is `maxSize`, so a 10 GB file never becomes 10 GB of RAM.
public struct ChunkIterator {
    private let chunker: FastCDCChunker
    private let reader: () throws -> Data
    private var buffer = Data()
    private var head = 0
    private var offset: Int64 = 0
    private var eof = false
    private var finished = false

    init(chunker: FastCDCChunker, reader: @escaping () throws -> Data) {
        self.chunker = chunker
        self.reader = reader
    }

    public mutating func next(isCancelled: () -> Bool = { false }) throws -> Chunk? {
        if finished { return nil }
        if isCancelled() { throw ChunkerError.cancelled }
        while (buffer.count - head) < chunker.config.maxSize, !eof {
            let piece = try reader()
            if piece.isEmpty { eof = true; break }
            buffer.append(piece)
        }
        let available = buffer.count - head
        if available == 0 { finished = true; return nil }

        let length = chunker.boundaryLength(in: buffer, from: head, available: available)
        let start = buffer.index(buffer.startIndex, offsetBy: head)
        let end = buffer.index(start, offsetBy: length)
        let chunk = Chunk(offset: offset, data: Data(buffer[start..<end]))
        head += length
        offset += Int64(length)

        if head >= chunker.config.maxSize || head == buffer.count {
            // Rebuild instead of removeFirst: Data may retain the consumed prefix
            // in its backing store, which would grow to the whole file even though
            // `count` stays small.
            if head == buffer.count {
                buffer = Data()
            } else {
                let remainingStart = buffer.index(buffer.startIndex, offsetBy: head)
                buffer = Data(buffer[remainingStart...])
            }
            head = 0
        }
        return chunk
    }
}
