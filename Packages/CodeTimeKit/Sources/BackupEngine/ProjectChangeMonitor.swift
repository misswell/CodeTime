import Foundation
import CoreServices

/// FSEvents-based change source (§7.1 / §12.1).
///
/// FSEvents is an optimization only: the scheduler still performs periodic full
/// scans, and every backup re-reads file identities, so a dropped event can delay
/// a backup but can never make one silently incomplete.
public final class ProjectChangeMonitor: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Kernel coalescing window.
        public var latency: TimeInterval
        /// Ignore bursts closer together than this.
        public var debounce: TimeInterval

        public init(latency: TimeInterval = 2.0, debounce: TimeInterval = 5.0) {
            self.latency = max(0.1, latency)
            self.debounce = max(0, debounce)
        }

        public static let `default` = Configuration()
    }

    private let root: URL
    private let configuration: Configuration
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.codetime.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var lastFire = Date.distantPast
    private let lock = NSLock()

    public init(
        root: URL,
        configuration: Configuration = .default,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.root = root
        self.configuration = configuration
        self.onChange = onChange
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return true }
        guard FileManager.default.fileExists(atPath: root.path) else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [root.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let monitor = Unmanaged<ProjectChangeMonitor>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                monitor.fire()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            configuration.latency,
            flags
        ) else {
            return false
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    private func fire() {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastFire) >= configuration.debounce else {
            lock.unlock()
            return
        }
        lastFire = now
        lock.unlock()
        onChange()
    }
}

/// Pure decision helper for file-activity backups, separate from FSEvents so the
/// policy (global pause, minimum change interval) is testable without a stream.
public struct FileActivityGate: Sendable {
    public var minimumInterval: TimeInterval
    public init(minimumInterval: TimeInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    public func shouldTrigger(lastBackupAt: Date?, now: Date = Date()) -> Bool {
        guard let lastBackupAt else { return true }
        return now.timeIntervalSince(lastBackupAt) >= minimumInterval
    }
}
