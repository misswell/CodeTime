import XCTest
@testable import SharedModels
@testable import CodeTimeSecurity

final class SmokeTests: XCTestCase {
    func testRecoveryKeyRoundTrip() throws {
        let key = try RecoveryKey.generate()
        let text = RecoveryKey.format(key)
        XCTAssertEqual(try RecoveryKey.parse(text), key)
    }

    func testRecoveryKeyBodyMayContainPrefix() throws {
        var found = false
        for _ in 0..<20_000 {
            let key = try RecoveryKey.generate()
            let text = RecoveryKey.format(key)
            let body = text.replacingOccurrences(of: "-", with: "").dropFirst(3)
            if body.contains("CT1") {
                XCTAssertEqual(try RecoveryKey.parse(text), key)
                found = true
                break
            }
        }
        XCTAssertTrue(found, "未生成包含 CT1 的测试密钥")
    }

    func testKeychainRefusesCreationWhenRepositoryExists() throws {
        let store = KeychainStore(service: "com.codetime.test.\(UUID().uuidString)")
        store.deleteAllSecrets()
        XCTAssertThrowsError(try store.ensureSecrets(allowCreation: false))
    }

    func testCryptoBoxRoundTrip() throws {
        let key = try RecoveryKey.generate()
        let plaintext = Data("hello codetime".utf8)
        let sealed = try CryptoBox.seal(plaintext, masterKey: key, context: "generation-1")
        XCTAssertEqual(try CryptoBox.open(sealed, masterKey: key, context: "generation-1"), plaintext)
        XCTAssertThrowsError(try CryptoBox.open(sealed, masterKey: key, context: "generation-2"))
    }
}
