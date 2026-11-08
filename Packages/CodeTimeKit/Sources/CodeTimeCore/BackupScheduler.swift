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

    /// Once false, no new tick may start. Set synchronously before draining so a
    /// tick cannot slip between "loop cancelled" and "drain finished".
    private var acceptingWork = true

    public func start(checkImmediately: Bool = true) {
        guard loopTask == nil else { return }
        acceptingWork = true
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

    /// Cancels acceptance of new work and WAITS for the producer loop to exit.
    /// Awaiting the cancelled loop is what closes the CT-101 gap: without it a
    /// tick could still be between two projects when `prepareForExit` runs.
    public func stopAcceptingNewWork() async {
        acceptingWork = false
        loopTask?.cancel()
        let task = loopTask
        loopTask = nil
        await task?.value
    }

    /// Releases leadership. Only call this AFTER the lifecycle coordinator
    /// reported `safeToExit` — the lock is what keeps a replacement process from
    /// scheduling while a child may still be writing.
    public func releaseLeadership() {
        leadership?.release()
        leadership = nil
    }

    /// CT-101/CT-113: cancels the loop and waits for every in-flight job to
    /// finish, delegating the "is it safe?" decision to LifecycleCoordinator.
    /// Returns the work kinds still running — callers must not release the
    /// process locks or exit while this is non-empty.
    public func stopAndDrain(timeout: TimeInterval = 30) async -> [String] {
        await stopAcceptingNewWork()
        let decision = await LifecycleCoordinator(service).prepareForExit(timeout: timeout)
        switch decision {
        case .safeToExit:
            releaseLeadership()
            return []
        case .unsafeToExit(let remaining):
            return remaining
        }
    }

    /// Non-draining stop, for `--once` runs that already awaited their work.
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
            let settings = try await service.currentSettings()
            // `ignoreSchedule` only bypasses per-project due time. A global pause
            // still applies to Agent --once.
            guard settings.scheduler.allowsScheduling else { return }
        } catch {
            await service.logger.error("读取调度设置失败：\(error.localizedDescription)")
            return
        }
        await processDueRetries()
        do {
            let projects: [Project]
            if ignoreSchedule {
                projects = try await service.projects().filter(\.isSchedulable)
            } else {
                projects = try await service.dueProjects()
            }
            for project in projects {
                do {
                    _ = try await service.createSnapshot(projectID: project.id, trigger: .scheduled)
                } catch {
                    await service.logger.warning(
                        "调度备份失败（\(project.name)）：\(error.localizedDescription)"
                    )
                }
            }
        } catch {
            await service.logger.error("调度轮询失败：\(error.localizedDescription)")
        }
        await runMaintenance()
    }

    public func handleWake() async {
        pendingWakeCatchUp = true
        await tick()
    }

    public func tick() async {
        guard acceptingWork else { return }
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        guard acquireLeadership() else { return }

        do {
            let settings = try await service.currentSettings()
            if settings.pauseOnBattery, ProcessInfo.processInfo.isLowPowerModeEnabled {
                return
            }
            guard settings.scheduler.allowsScheduling else { return }

            await processDueRetries()

            let due = try await service.dueProjects()
            if due.isEmpty {
                pendingWakeCatchUp = false
            } else {
                let trigger: BackupTrigger = pendingWakeCatchUp ? .wakeCatchUp : .scheduled
                for project in due {
                    guard acceptingWork, !Task.isCancelled else { return }
                    do {
                        _ = try await service.createSnapshot(projectID: project.id, trigger: trigger)
                    } catch {
                        await service.logger.warning(
                            "调度备份失败（\(project.name)）：\(error.localizedDescription)"
                        )
                    }
                }
                pendingWakeCatchUp = false
            }
        } catch {
            await service.logger.error("调度轮询失败：\(error.localizedDescription)")
        }

        await runMaintenance()
    }

    /// Retry jobs already had their backoff honored by `nextRetryAt`; the lease
    /// inside `createSnapshot` still guarantees only one process runs each job.
    private func processDueRetries() async {
        do {
            let jobs = try await service.dueRetryJobs()
            for job in jobs {
                switch job.type {
                case .backup:
                    do {
                        _ = try await service.createSnapshot(
                            projectID: job.projectID,
                            trigger: job.trigger,
                            retryJobID: job.id
                        )
                    } catch {
                        await service.logger.warning(
                            "重试备份失败（\(job.projectID.uuidString)）：\(error.localizedDescription)"
                        )
                    }
                case .upload:
                    _ = await service.retryCloudPublish(job: job)
                default:
                    continue
                }
            }
        } catch {
            await service.logger.error("读取待重试任务失败：\(error.localizedDescription)")
        }
    }

    private func runMaintenance() async {
        await service.runMaintenanceIfDue(.verify)
        await service.runMaintenanceIfDue(.cleanup)
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
