import Foundation
import Security

/// Simple Keychain wrapper for storing small blobs of sensitive data.
/// Uses kSecClassGenericPassword with a fixed service identifier.
enum Keychain {
    private static let service = "com.runalyzer.app"

    /// Save data to the Keychain, overwriting any existing entry for the key.
    @discardableResult
    static func save(_ data: Data, key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Load data from the Keychain. Returns nil if no entry exists.
    static func load(key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - Database Encryption Key

    private static let dbKeyAccount = "runalyzer_db_encryption_key"

    /// Returns the database encryption key, generating a 256-bit random key on first call.
    /// The key is stored in Keychain and persists across app reinstalls.
    static func databaseKey() -> Data {
        if let existing = load(key: dbKeyAccount) {
            return existing
        }
        var keyData = Data(count: 32)
        keyData.withUnsafeMutableBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, ptr)
        }
        save(keyData, key: dbKeyAccount)
        return keyData
    }

    /// Delete a Keychain entry. No-op if the entry does not exist.
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
