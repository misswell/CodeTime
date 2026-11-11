import XCTest
import Foundation
@testable import CodeTimeCore
@testable import SharedModels
@testable import CodeTimeSecurity

/// CT-171: a cached runtime is bound to exactly the configuration that produced it.
final class RuntimeConfigurationTests: XCTestCase {
    private var workspace: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-fingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        keychain = KeychainStore(service: "com.codetime.test.ct171.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        keychain.deleteAllSecrets()
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    func testCT173_EveryRelevantSettingChangesTheFingerprint() {
        let base = AppSettings(
            iCloudEnabled: false,
            localMirrorPath: "/tmp/mirror",
            engineMode: .cloudFirst,
            cachePreset: .custom,
            cacheBudgetBytes: 128 * 1024 * 1024,
            spoolSoftLimitBytes: 2 * 1024 * 1024 * 1024
        )
        let original = RuntimeConfigurationFingerprint(settings: base, deviceID: "device-A")
        XCTAssertEqual(
            original,
            RuntimeConfigurationFingerprint(settings: base, deviceID: "device-A")
        )

        var otherDevice = base
        XCTAssertNotEqual(
            original,
            RuntimeConfigurationFingerprint(settings: otherDevice, deviceID: "device-B")
        )

        otherDevice = base
        otherDevice.engineMode = .kopia
        XCTAssertNotEqual(original, RuntimeConfigurationFingerprint(settings: otherDevice, deviceID: "device-A"))

        otherDevice = base
        otherDevice.spoolSoftLimitBytes += 1
        XCTAssertNotEqual(original, RuntimeConfigurationFingerprint(settings: otherDevice, deviceID: "device-A"))

        otherDevice = base
        otherDevice.cacheBudgetBytes = 64 * 1024 * 1024
        XCTAssertNotEqual(original, RuntimeConfigurationFingerprint(settings: otherDevice, deviceID: "device-A"))

        otherDevice = base
        otherDevice.localMirrorPath = "/tmp/other-mirror"
        XCTAssertNotEqual(original, RuntimeConfigurationFingerprint(settings: otherDevice, deviceID: "device-A"))

        otherDevice = base
        otherDevice.localMirrorBookmark = Data("bookmark-one".utf8)
        XCTAssertNotEqual(original, RuntimeConfigurationFingerprint(settings: otherDevice, deviceID: "device-A"))

        otherDevice = base
        otherDevice.iCloudEnabled = true
        let cloud = RuntimeConfigurationFingerprint(settings: otherDevice, deviceID: "device-A")
        XCTAssertEqual(cloud.storageMode, "icloud")
        XCTAssertNotEqual(original, cloud)
    }

    func testCT174_ServiceReportsNewFingerprintAfterSettingsChange() async throws {
        let service = try CodeTimeService(
            paths: AppPaths(root: workspace.appendingPathComponent("data", isDirectory: true)),
            keychain: keychain,
            hardwareUUIDProvider: { "hw-runtime-test" }
        )
        _ = try await service.bootstrap()
        var settings = try await service.currentSettings()
        settings.engineMode = .cloudFirst
        settings.iCloudEnabled = false
        settings.localMirrorPath = workspace.appendingPathComponent("mirror").path
        settings.cachePreset = .custom
        settings.cacheBudgetBytes = 128 * 1024 * 1024
        settings.spoolSoftLimitBytes = 2 * 1024 * 1024 * 1024
        settings = try await service.saveSettings(settings)

        let first = try await service.currentRuntimeFingerprint()
        XCTAssertEqual(first.cacheBudget, 128 * 1024 * 1024)
        XCTAssertEqual(first.spoolBudget, 2 * 1024 * 1024 * 1024)

        settings.spoolSoftLimitBytes = 512 * 1024 * 1024
        settings = try await service.saveSettings(settings)
        let second = try await service.currentRuntimeFingerprint()
        XCTAssertNotEqual(first, second, "spool 预算变化必须使旧 Runtime 失效")
        XCTAssertEqual(second.spoolBudget, 512 * 1024 * 1024)

        // The store must still be usable after the runtime was rebuilt.
        _ = try await service.currentV3Store()
        let third = try await service.currentRuntimeFingerprint()
        XCTAssertEqual(second, third)
    }
}
