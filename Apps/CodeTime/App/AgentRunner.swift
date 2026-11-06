import Foundation
import AppKit
import CodeTimeCore

/// Runs the background agent inside the app executable. Sharing the exact same
/// signed binary keeps the Keychain item ACL valid for both the UI and the
/// LaunchAgent process.
enum AgentRunner {
    static func run() {
        Task.detached(priority: .utility) {
            await runAsync()
        }
        dispatchMain()
    }

    private static func runAsync() async {
        do {
            let service = try CodeTimeService()
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
            while true {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        } catch {
            FileHandle.standardError.write(Data("CodeTimeAgent 启动失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
