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
                await scheduler.stop()
                exit(0)
            }

            let signalQueue = DispatchQueue(label: "com.codetime.agent.signals")
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            for sig in [SIGTERM, SIGINT] {
                let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
                source.setEventHandler {
                    Task {
                        await scheduler.stop()
                        exit(0)
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
            // CT-085 (§4.1 agent stop protocol): the persisted migration request
            // doubles as the stop signal. The agent polls it every 30s; on request
            // it stops accepting NEW tasks and exits. A task already in flight is
            // NOT awaited here — instead its Kopia repository lock stays held by
            // the running child, and the migration's source-side lockSource()
            // re-check refuses to start (or the post-copy verification fails on a
            // torn pack), so a mid-flight migration fails safely and can be
            // retried once the task finishes. The migration never replaces data
            // under a live writer.
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if DataMigrator.hasPendingRequest(target: paths.root) {
                    FileHandle.standardError.write(
                        Data("收到数据迁移请求：Agent 停止调度并退出。\n".utf8)
                    )
                    await scheduler.stop()
                    instanceLock?.release()
                    lifecycleLock.release()
                    exit(0)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("CodeTimeAgent 启动失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
