import Foundation

/// Reference-counted local-copy leases for iCloud items.
///
/// A reader holds a lease for the duration of the actual read; a writer holds an
/// exclusive lease until upload confirmation and the subsequent eviction. An
/// eviction only succeeds when no reader, writer or pin exists, so a file is
/// never removed underneath an active restore.
public actor LocalCopyLeaseManager {
    private struct State {
        var readers = 0
        var writer = false
        var pins = 0
        var waitingReaders: [CheckedContinuation<Void, Never>] = []
        var waitingWriters: [CheckedContinuation<Void, Never>] = []
    }

    private var states: [String: State] = [:]

    public init() {}

    /// Test/diagnostic view: idle entries must not accumulate for millions of
    /// one-shot iCloud URLs.
    public var trackedStateCount: Int { states.count }

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func removeIfIdle(_ key: String) {
        guard let state = states[key],
              !state.writer,
              state.readers == 0,
              state.pins == 0,
              state.waitingReaders.isEmpty,
              state.waitingWriters.isEmpty else { return }
        states.removeValue(forKey: key)
    }

    private func drainWriterIfPossible(_ key: String) {
        guard var state = states[key],
              !state.writer,
              state.readers == 0,
              !state.waitingWriters.isEmpty else {
            removeIfIdle(key)
            return
        }
        let next = state.waitingWriters.removeFirst()
        state.writer = true
        states[key] = state
        next.resume()
    }

    public func acquireRead(_ url: URL) async {
        let key = self.key(url)
        var state = states[key] ?? State()
        // Writer priority: a new reader must queue behind a waiting writer, or a
        // continuous read stream can starve eviction/upload forever.
        if state.writer || !state.waitingWriters.isEmpty {
            await withCheckedContinuation { continuation in
                state.waitingReaders.append(continuation)
                states[key] = state
            }
            return
        }
        state.readers += 1
        states[key] = state
    }

    public func releaseRead(_ url: URL) {
        let key = self.key(url)
        guard var state = states[key] else { return }
        state.readers = max(0, state.readers - 1)
        states[key] = state
        drainWriterIfPossible(key)
    }

    public func acquireWrite(_ url: URL) async {
        let key = self.key(url)
        var state = states[key] ?? State()
        if state.writer || state.readers > 0 {
            await withCheckedContinuation { continuation in
                state.waitingWriters.append(continuation)
                states[key] = state
            }
            return
        }
        state.writer = true
        states[key] = state
    }

    public func releaseWrite(_ url: URL) {
        let key = self.key(url)
        guard var state = states[key] else { return }
        state.writer = false
        // Writers first. Readers are batched only when no writer is waiting.
        if !state.waitingWriters.isEmpty {
            let next = state.waitingWriters.removeFirst()
            state.writer = true
            states[key] = state
            next.resume()
            return
        }
        if !state.waitingReaders.isEmpty {
            state.readers += state.waitingReaders.count
            let waiters = state.waitingReaders
            state.waitingReaders.removeAll()
            states[key] = state
            for waiter in waiters { waiter.resume() }
            return
        }
        states[key] = state
        removeIfIdle(key)
    }

    /// Non-blocking eviction claim. Returns false when a reader, writer or pin is
    /// active; the caller must keep the local copy.
    public func beginEviction(_ url: URL) -> Bool {
        let key = self.key(url)
        var state = states[key] ?? State()
        guard !state.writer,
              state.readers == 0,
              state.pins == 0,
              state.waitingReaders.isEmpty,
              state.waitingWriters.isEmpty else { return false }
        state.writer = true
        states[key] = state
        return true
    }

    public func endEviction(_ url: URL) {
        releaseWrite(url)
    }

    public func pin(_ url: URL) {
        let key = self.key(url)
        var state = states[key] ?? State()
        state.pins += 1
        states[key] = state
    }

    public func unpin(_ url: URL) {
        let key = self.key(url)
        guard var state = states[key] else { return }
        state.pins = max(0, state.pins - 1)
        states[key] = state
        drainWriterIfPossible(key)
    }

    public func isPinned(_ url: URL) -> Bool {
        (states[key(url)]?.pins ?? 0) > 0
    }
}
