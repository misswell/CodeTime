import Foundation
import Darwin

/// Real iCloud container self-test for the signed app.
///
/// This runs inside `CodeTime.app`, so it uses the embedded provisioning profile
/// and the real iCloud entitlements — unlike an unsigned CLI probe. It writes one
/// tiny file, waits for the provider to confirm the upload, and removes it.
enum ICloudSelfTest {
    static let containerIdentifier = "iCloud.com.codetime.app"

    static func run() {
        Task.detached {
            let code = await execute()
            exit(code)
        }
        dispatchMain()
    }

    private static func execute() async -> Int32 {
        let fm = FileManager.default
        print("ubiquityIdentityToken=\(fm.ubiquityIdentityToken != nil)")
        guard let container = fm.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            print("ICLOUD_SELFTEST_BLOCKED reason=container-unavailable")
            return 3
        }
        print("container=\(container.path)")
        let root = container.appendingPathComponent("Documents/CodeTimeSelfTest", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("ICLOUD_SELFTEST_BLOCKED reason=create-directory error=\(error)")
            return 3
        }
        let url = root.appendingPathComponent("probe-\(UUID().uuidString).txt")
        do {
            try Data("codetime-icloud-selftest".utf8).write(to: url)
        } catch {
            print("ICLOUD_SELFTEST_BLOCKED reason=write error=\(error)")
            return 3
        }
        print("probe=\(url.path)")

        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemUploadingErrorKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        defer { try? fm.removeItem(at: url) }

        for attempt in 0..<60 {
            do {
                let values = try url.resourceValues(forKeys: keys)
                if let error = values.ubiquitousItemUploadingError {
                    let ns = error as NSError
                    print("ICLOUD_SELFTEST_BLOCKED reason=upload-error domain=\(ns.domain) code=\(ns.code) detail=\(error.localizedDescription)")
                    return 3
                }
                if values.isUbiquitousItem == true, values.ubiquitousItemIsUploaded == true {
                    print("ICLOUD_SELFTEST_READY attempt=\(attempt) uploaded=true")
                    return 0
                }
                if attempt % 5 == 0 {
                    print("waiting attempt=\(attempt) uploaded=\(String(describing: values.ubiquitousItemIsUploaded))")
                }
            } catch {
                print("ICLOUD_SELFTEST_BLOCKED reason=metadata error=\(error)")
                return 3
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("ICLOUD_SELFTEST_BLOCKED reason=upload-timeout")
        return 3
    }
}
