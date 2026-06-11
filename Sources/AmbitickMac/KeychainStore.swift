import Foundation
import Security

/// OP API key storage in the user's login Keychain.
/// Fixed account name: keying by URL string orphaned the item on any URL edit.
public enum KeychainStore {
    static let service = "org.example.ambitick.op-api-key"
    public static let account = "openproject"

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain: \(message)"
        }
    }

    public static func saveAPIKey(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// nil = absent; throws when the Keychain refuses access (e.g. the item
    /// belongs to a previous ad-hoc-signed build and access was denied).
    public static func loadAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }
}
