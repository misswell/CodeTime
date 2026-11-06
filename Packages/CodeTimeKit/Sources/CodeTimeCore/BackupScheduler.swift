import Foundation
import SharedModels
import BackupEngine

/// Serialized background scheduler shared by the app and the LaunchAgent.
/// Leadership is a process-wide file lock so only one process creates snapshots.
public actor BackupScheduler {
    private let service: CodeTimeService
    private let lockPath: String
    private var leadership: RepositoryLock?
    private var loopTask: Task<Void, Never>?
    private var ticking = false
    private var pendingWakeCatchUp = false

    public init(service: CodeTimeService, lockPath: String) {
        self.service = service
        self.lockPath = lockPath
    }

    deinit {
        loopTask?.cancel()
        leadership?.release()
    }

    public func start(checkImmediately: Bool = true) {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            if checkImmediately {
                await self?.tick()
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        leadership?.release()
        leadership = nil
    }

    public func isLeader() -> Bool {
        leadership != nil
    }

    /// Runs one catch-up pass. Used by the agent's `--once` mode and after wake.
    public func runOnce(ignoreSchedule: Bool = false) async {
        guard acquireLeadership() else { return }
        do {
            let projects: [Project]
            if ignoreSchedule {
                projects = try await service.projects().filter(\.enabled)
            } else {
                projects = try await service.dueProjects()
            }
            for project in projects {
                _ = try? await service.createSnapshot(projectID: project.id, trigger: .scheduled)
            }
        } catch {
            // The service records failures in the activity log.
        }
    }

    public func handleWake() async {
        pendingWakeCatchUp = true
        await tick()
    }

    public func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        guard acquireLeadership() else { return }

        do {
            let settings = try await service.currentSettings()
            if settings.pauseOnBattery, ProcessInfo.processInfo.isLowPowerModeEnabled {
                return
            }
            let due = try await service.dueProjects()
            guard !due.isEmpty else {
                pendingWakeCatchUp = false
                return
            }
            let trigger: BackupTrigger = pendingWakeCatchUp ? .wakeCatchUp : .scheduled
            for project in due {
                _ = try? await service.createSnapshot(projectID: project.id, trigger: trigger)
            }
            pendingWakeCatchUp = false
        } catch {
            // Errors are stored by the service; scheduling continues.
        }
    }

    private func acquireLeadership() -> Bool {
        if leadership != nil { return true }
        let lock = RepositoryLock(path: lockPath)
        if lock.tryAcquire() {
            leadership = lock
            return true
        }
        return false
    }
}
