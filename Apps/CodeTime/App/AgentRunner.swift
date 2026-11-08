import Foundation
import AppKit
import CodeTimeCore
import BackupEngine

/// Runs the background agent inside the app executable. Sharing the exact same
/// signed binary keeps the Keychain item ACL valid for both the UI and the
/// LaunchAgent process.
enum AgentRunner {
    /// Held for the whole process lifetime: a duplicate LaunchAgent (manual start,
    /// stale registration, or a second copy of the app) must not run a second
    /// scheduler against the same database.
    private static var instanceLock: RepositoryLock?

    static func run() {
        Task.detached(priority: .utility) {
            await runAsync()
        }
        dispatchMain()
    }

    private static func runAsync() async {
        do {
            let paths = try AppPaths.standard()
            // CT-072: Acquire a shared lifecycle lock. Migration holds exclusive.
            let lifecycleLock = LifecycleLock(path: paths.lifecycleLockPath.path)
            guard lifecycleLock.tryAcquire(.shared) else {
                FileHandle.standardError.write(Data("生命周期锁被迁移持有，Agent 退出。\n".utf8))
                exit(0)
            }
            defer { lifecycleLock.release() }
            if DataMigrator.hasPendingRequest(target: paths.root) {
                FileHandle.standardError.write(Data("待处理的数据迁移请求，Agent 退出以避免占用迁移锁。\n".utf8))
                exit(0)
            }
            let service = try CodeTimeService(paths: paths)
            let lock = RepositoryLock(path: service.paths.agentLock.path)
            guard lock.tryAcquire() else {
                let owner = lock.currentOwner()
                let detail = owner.map { "（PID \($0.pid)）" } ?? ""
                FileHandle.standardError.write(Data("已有 CodeTimeAgent 实例在运行\(detail)，退出。\n".utf8))
                exit(0)
            }
            instanceLock = lock

            _ = try await service.bootstrap()
            let scheduler = BackupScheduler(service: service, lockPath: service.paths.schedulerLock.path)

            let runOnce = CommandLine.arguments.contains("--once")
            if runOnce {
                await scheduler.runOnce()
                // P2-2: an unsafe drain must NOT exit — a child may still write.
                let remaining = await scheduler.stopAndDrain(timeout: 30)
                guard remaining.isEmpty else {
                    FileHandle.standardError.write(Data(
                        "仍有任务未能退出（\(remaining.joined(separator: ","))），--once 拒绝退出。\n".utf8
                    ))
                    exit(1)
                }
                exit(0)
            }

            let signalQueue = DispatchQueue(label: "com.codetime.agent.signals")
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            for sig in [SIGTERM, SIGINT] {
                let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
                source.setEventHandler {
                    Task {
                        // CT-101: never exit while a Kopia child may still write.
                        await scheduler.stopAcceptingNewWork()
                        let decision = await LifecycleCoordinator(service).prepareForExit(timeout: 30)
                        switch decision {
                        case .safeToExit:
                            await scheduler.releaseLeadership()
                            instanceLock?.release()
                            lifecycleLock.release()
                            exit(0)
                        case .unsafeToExit(let remaining):
                            FileHandle.standardError.write(Data(
                                "仍有任务未能退出（\(remaining.joined(separator: ","))），保留锁并继续运行。\n".utf8
                            ))
                            return
                        }
                    }
                }
                source.resume()
            }

            let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { await scheduler.handleWake() }
            }
            _ = wakeObserver

            await scheduler.start()
            // CT-085/CT-101 agent stop protocol (the request file is the signal):
            //   1. stop accepting new tasks (scheduler loop cancelled),
            //   2. cancel every in-flight job and WAIT for it to persist its state,
            //   3. terminate any surviving Kopia process group and reap it,
            //   4. only when nothing is left running: release agent + lifecycle
            //      locks and exit.
            // If any step cannot prove completion, the locks are KEPT and the
            // agent keeps running — the migration then fails safely instead of
            // copying a repository a live writer still owns.
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard DataMigrator.hasPendingRequest(target: paths.root) else { continue }

                FileHandle.standardError.write(
                    Data("收到数据迁移请求：停止调度并等待进行中的任务退出…\n".utf8)
                )
                await scheduler.stopAcceptingNewWork()
                // ONE decision point: drain + orphan-child termination live in
                // LifecycleCoordinator, so the agent and the scheduler can never
                // disagree about what "safe to exit" means.
                let decision = await LifecycleCoordinator(service).prepareForExit(timeout: 30)
                switch decision {
                case .safeToExit:
                    FileHandle.standardError.write(Data("所有任务已退出，Agent 释放锁并退出。\n".utf8))
                    await scheduler.releaseLeadership()
                    instanceLock?.release()
                    lifecycleLock.release()
                    exit(0)
                case .unsafeToExit(let remaining):
                    FileHandle.standardError.write(Data(
                        "迁移请求未能安全停止（仍在运行：\(remaining.joined(separator: ","))），继续运行以保护数据。\n".utf8
                    ))
                    continue
                }
            }
        } catch {
            FileHandle.standardError.write(Data("CodeTimeAgent 启动失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
