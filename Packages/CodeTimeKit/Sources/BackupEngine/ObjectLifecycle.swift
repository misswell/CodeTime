import Foundation
import SharedModels

/// Coordinates every object identity within one backup run.
///
/// The old registry put a `storedSize = 0` placeholder into the same dictionary
/// used for reusable chunks, so a second file could reference an object whose
/// upload had not finished. This state machine makes "uploading", "ready" and
/// "failed" distinct and makes waiters share the first writer's result.
actor ObjectRegistry {
    enum Acquire: Sendable {
        case ready(StoredObjectLocation)
        /// The caller owns the upload and must call `complete` or `fail`.
        case upload
    }

    private enum State {
        case idle
        case uploading([CheckedContinuation<StoredObjectLocation, Error>])
        case ready(StoredObjectLocation)
        case failed(String)
    }

    private var states: [String: State] = [:]

    init(known: [String: ChunkRecordV3]) {
        for (id, record) in known {
            guard record.storedSize > 0 || record.packID != nil else { continue }
            if let packID = record.packID {
                states[id] = .ready(StoredObjectLocation(
                    storedSize: record.storedSize,
                    packID: packID,
                    packOffset: record.packOffset
                ))
            } else {
                states[id] = .ready(StoredObjectLocation(storedSize: record.storedSize))
            }
        }
    }

    /// Non-blocking lookup used by the pack path. Only confirmed locations are
    /// returned; pending pack members are intentionally absent until flush.
    func readyLocation(_ id: String) -> StoredObjectLocation? {
        if case .ready(let location) = states[id] { return location }
        return nil
    }

    func isUploading(_ id: String) -> Bool {
        if case .uploading = states[id] { return true }
        return false
    }

    /// Returns a confirmed location, waits for the current writer, or claims the
    /// object for this caller. A failed object throws; a new backup run starts a
    /// fresh registry, which is the explicit retry boundary.
    func acquireStandalone(_ id: String) async throws -> Acquire {
        switch states[id] ?? .idle {
        case .ready(let location):
            return .ready(location)
        case .failed(let detail):
            throw CloudObjectLifecycleError.writerFailed(objectID: id, detail: detail)
        case .uploading(let waiters):
            let location = try await withCheckedThrowingContinuation { continuation in
                states[id] = .uploading(waiters + [continuation])
            }
            return .ready(location)
        case .idle:
            states[id] = .uploading([])
            return .upload
        }
    }

    /// Waits for a standalone writer without claiming the object (used by the
    /// small-object path before it decides to pack).
    func waitForReady(_ id: String) async throws -> StoredObjectLocation? {
        switch states[id] ?? .idle {
        case .ready(let location):
            return location
        case .failed(let detail):
            throw CloudObjectLifecycleError.writerFailed(objectID: id, detail: detail)
        case .uploading(let waiters):
            return try await withCheckedThrowingContinuation { continuation in
                states[id] = .uploading(waiters + [continuation])
            }
        case .idle:
            return nil
        }
    }

    func complete(_ id: String, location: StoredObjectLocation) {
        let waiters: [CheckedContinuation<StoredObjectLocation, Error>]
        if case .uploading(let current) = states[id] {
            waiters = current
        } else {
            waiters = []
        }
        states[id] = .ready(location)
        for waiter in waiters { waiter.resume(returning: location) }
    }

    func fail(_ id: String, error: Error) {
        // `states[id]` was overwritten by `.ready` above only in complete(); here
        // capture the waiters before replacing the state.
        let waiters: [CheckedContinuation<StoredObjectLocation, Error>]
        if case .uploading(let current) = states[id] {
            waiters = current
        } else {
            waiters = []
        }
        states[id] = .failed(String(describing: error))
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    /// Called by PackBuffer only after the whole pack containing the object has
    /// been confirmed uploaded. This is the point where a pack member becomes
    /// referenceable by other files.
    func rememberPacked(_ id: String, location: StoredObjectLocation) {
        if case .uploading(let waiters) = states[id] {
            for waiter in waiters { waiter.resume(returning: location) }
        }
        states[id] = .ready(location)
    }
}

struct PackLocation: Sendable, Equatable {
    var packID: String
    var offset: Int64
}

/// Accumulates small encrypted objects and flushes them into immutable packs.
///
/// Flush uses an immutable batch: new appends go to a fresh pending buffer while
/// the batch uploads. A failed batch is retained and retried; it is never
/// cleared by a concurrent `flush()` or by `finalize()`.
actor PackBuffer {
    struct FlushBatch: Sendable {
        let id: UUID
        let entries: [(objectID: String, payload: Data)]
        let createdAt: Date
    }

    private let threshold: Int
    private let sink: CloudObjectSink
    private let builder: ObjectPackBuilder
    private let registry: ObjectRegistry
    private var pending: [(objectID: String, payload: Data)] = []
    private var pendingBytes = 0
    private var inFlight: FlushBatch?
    private var inFlightTask: Task<[String: PackLocation], Error>?
    private var failedBatches: [FlushBatch] = []
    private var uploadedLocations: [String: PackLocation] = [:]
    private var stagedIDs: Set<String> = []
    private var uploadedPacks = 0

    init(
        threshold: Int,
        sink: CloudObjectSink,
        builder: ObjectPackBuilder,
        registry: ObjectRegistry
    ) {
        self.threshold = threshold
        self.sink = sink
        self.builder = builder
        self.registry = registry
    }

    /// Only confirmed pack locations are exposed. Pending/failed batch members
    /// are not referenceable until `finalize()` succeeds.
    var locations: [String: PackLocation] {
        uploadedLocations
    }

    var uploadedPackCount: Int {
        uploadedPacks
    }

    /// Returns true when this call staged the object, false when it was already
    /// uploaded or is pending in the same batch. The caller uses this for dedup
    /// accounting without treating a pending placeholder as uploaded.
    @discardableResult
    func append(objectID: String, payload: Data) async throws -> Bool {
        guard uploadedLocations[objectID] == nil else { return false }
        guard stagedIDs.insert(objectID).inserted else { return false }
        pending.append((objectID, payload))
        pendingBytes += payload.count
        if pendingBytes >= builder.options.targetBytes {
            try await flush()
        }
        return true
    }

    /// Starts (or joins) a flush. Multiple callers share one in-flight batch; a
    /// new append during the upload lands in the next batch, not in a discarded
    /// one.
    func flush() async throws {
        if let inFlightTask {
            _ = try await inFlightTask.value
            return
        }
        // Retry failed batches before accepting a newer one, so a transient
        // failure cannot be starved by a continuous stream of small objects.
        if !failedBatches.isEmpty {
            let batch = failedBatches.removeFirst()
            // `start` records the failed batch itself; do not insert it twice.
            _ = try await start(batch)
            if !pending.isEmpty { try await flush() }
            return
        }
        guard !pending.isEmpty else { return }
        let batch = FlushBatch(id: UUID(), entries: pending, createdAt: Date())
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        // `start` records the failed batch itself; do not append it twice.
        _ = try await start(batch)
    }

    private func start(_ batch: FlushBatch) async throws -> [String: PackLocation] {
        inFlight = batch
        let task = Task { [self] in
            do {
                let locations = try await perform(batch)
                await finish(batch, locations: locations)
                return locations
            } catch {
                await recordFailure(batch)
                throw error
            }
        }
        inFlightTask = task
        defer {
            inFlight = nil
            inFlightTask = nil
        }
        return try await task.value
    }

    private func perform(_ batch: FlushBatch) async throws -> [String: PackLocation] {
        let packs = try builder.build(batch.entries)
        var result: [String: PackLocation] = [:]
        for pack in packs {
            _ = try await sink.putPack(pack.payload, packID: pack.packID)
            uploadedPacks += 1
            for entry in pack.entries {
                let location = PackLocation(packID: pack.packID, offset: Int64(entry.offset))
                result[entry.objectID] = location
                uploadedLocations[entry.objectID] = location
                // A member becomes referenceable only after its whole pack was
                // confirmed by the upload layer.
                await registry.rememberPacked(
                    entry.objectID,
                    location: StoredObjectLocation(
                        storedSize: entry.length,
                        packID: pack.packID,
                        packOffset: Int64(entry.offset)
                    )
                )
            }
        }
        return result
    }

    private func finish(_ batch: FlushBatch, locations: [String: PackLocation]) {
        for entry in batch.entries {
            stagedIDs.remove(entry.objectID)
        }
        inFlight = nil
    }

    private func recordFailure(_ batch: FlushBatch) {
        // Keep every entry staged and retain the immutable payload. A later flush
        // (or the next backup run, via the durable spool) retries the same batch.
        if !failedBatches.contains(where: { $0.id == batch.id }) {
            failedBatches.append(batch)
        }
        inFlight = nil
    }

    /// Waits for in-flight, failed and pending batches. Any failure is propagated
    /// to the engine, which then refuses to publish a manifest/commit.
    func finalize() async throws -> [String: PackLocation] {
        while true {
            if let inFlightTask {
                _ = try await inFlightTask.value
                continue
            }
            if !failedBatches.isEmpty {
                try await flush()
                continue
            }
            if !pending.isEmpty {
                try await flush()
                continue
            }
            return uploadedLocations
        }
    }
}
