import Foundation
import Security
import SharedModels

public struct SecretBootstrap: Sendable {
    public var masterKey: Data
    public var recoveryKeyText: String
    public var repositoryPassword: String
    public var isNew: Bool

    public init(masterKey: Data, recoveryKeyText: String, repositoryPassword: String, isNew: Bool) {
        self.masterKey = masterKey
        self.recoveryKeyText = recoveryKeyText
        self.repositoryPassword = repositoryPassword
        self.isNew = isNew
    }
}

public final class KeychainStore: MasterKeyProviding, RepositoryPasswordProviding, @unchecked Sendable {
    public static let shared = KeychainStore()

    public let service: String

    private enum Account {
        static let masterKey = "master-key"
        static let repositoryPassword = "repository-password"
        static let recoveryAcknowledged = "recovery-acknowledged"
    }

    public init(service: String = "com.codetime.app") {
        self.service = service
    }

    public func masterKey() throws -> Data {
        let (data, status) = loadResult(account: Account.masterKey)
        if status == errSecItemNotFound {
            throw SecurityError.missingSecret("master-key")
        }
        guard status == errSecSuccess, let data, data.count == 32 else {
            throw status == errSecSuccess
                ? SecurityError.missingSecret("master-key")
                : SecurityError.keychain(status)
        }
        return data
    }

    public func repositoryPassword() throws -> String {
        let (data, status) = loadResult(account: Account.repositoryPassword)
        if status == errSecItemNotFound {
            throw SecurityError.missingSecret("repository-password")
        }
        guard status == errSecSuccess,
              let data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            throw status == errSecSuccess
                ? SecurityError.missingSecret("repository-password")
                : SecurityError.keychain(status)
        }
        return password
    }

    public func recoveryKeyText() throws -> String {
        RecoveryKey.format(try masterKey())
    }

    /// Creates application secrets on first launch and returns the recovery key so the
    /// user can store it offline. Existing secrets are never regenerated silently.
    public func ensureSecrets(allowCreation: Bool = true) throws -> SecretBootstrap {
        var isNew = false
        let master: Data
        let (masterData, masterStatus) = loadResult(account: Account.masterKey)
        switch masterStatus {
        case errSecSuccess:
            guard let existing = masterData, existing.count == 32 else {
                throw SecurityError.missingSecret("master-key")
            }
            master = existing
        case errSecItemNotFound:
            guard allowCreation else {
                throw SecurityError.missingSecret("master-key（已有仓库，拒绝自动生成新密钥）")
            }
            master = try RecoveryKey.generate()
            try save(master, account: Account.masterKey)
            isNew = true
        default:
            throw SecurityError.keychain(masterStatus)
        }

        let password: String
        let (passwordData, passwordStatus) = loadResult(account: Account.repositoryPassword)
        switch passwordStatus {
        case errSecSuccess:
            guard let data = passwordData,
                  let existing = String(data: data, encoding: .utf8),
                  !existing.isEmpty else {
                throw SecurityError.missingSecret("repository-password")
            }
            password = existing
        case errSecItemNotFound:
            guard allowCreation else {
                throw SecurityError.missingSecret("repository-password（已有仓库，拒绝自动生成新密码）")
            }
            password = try Self.randomPassword()
            try save(Data(password.utf8), account: Account.repositoryPassword)
            isNew = true
        default:
            throw SecurityError.keychain(passwordStatus)
        }

        return SecretBootstrap(
            masterKey: master,
            recoveryKeyText: RecoveryKey.format(master),
            repositoryPassword: password,
            isNew: isNew
        )
    }

    /// Used when restoring a repository on a new Mac. The caller must first decrypt the
    /// cloud recovery payload with the same key.
    public func installSecrets(masterKey: Data, repositoryPassword: String) throws {
        guard masterKey.count == 32 else { throw SecurityError.invalidRecoveryKey }
        try save(masterKey, account: Account.masterKey)
        try save(Data(repositoryPassword.utf8), account: Account.repositoryPassword)
    }

    public func deleteAllSecrets() {
        delete(account: Account.masterKey)
        delete(account: Account.repositoryPassword)
    }

    public func markRecoveryKeyAcknowledged() {
        try? save(Data("1".utf8), account: Account.recoveryAcknowledged)
    }

    public var recoveryKeyAcknowledged: Bool {
        load(account: Account.recoveryAcknowledged) != nil
    }

    // MARK: - Keychain primitives

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func loadResult(account: String) -> (Data?, OSStatus) {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (nil, status)
        }
        return (data, status)
    }

    private func load(account: String) -> Data? {
        let (data, status) = loadResult(account: account)
        return status == errSecSuccess ? data : nil
    }

    private func save(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw SecurityError.keychain(updateStatus)
        }
        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecurityError.keychain(addStatus)
        }
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func randomPassword() throws -> String {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard status == errSecSuccess else {
            throw SecurityError.randomGenerationFailed(status)
        }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
