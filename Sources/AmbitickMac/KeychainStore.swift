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

    /// We prefer the data-protection keychain: unlike the legacy file keychain,
    /// it has NO per-application "allow / always allow" trust prompt, so a
    /// self-signed app (whose cert macOS can't anchor) stops being challenged
    /// for the password on every rebuild. We fall back to the legacy keychain
    /// only if the data-protection store is unavailable (errSecMissingEntitlement),
    /// so access can never break — at worst it behaves as before.
    private static func base(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public static func saveAPIKey(_ key: String) throws {
        for dataProtection in [true, false] {
            let q = base(dataProtection: dataProtection)
            SecItemDelete(q as CFDictionary)
            var attributes = q
            attributes[kSecValueData as String] = Data(key.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecSuccess { return }
            if status == errSecMissingEntitlement, dataProtection { continue }   // legacy fallback
            throw KeychainError(status: status)
        }
    }

    /// nil = absent. Reads the data-protection store first, then the legacy
    /// store (so a key saved by an older build is still found — re-save it once
    /// to migrate it and silence the prompt for good).
    public static func loadAPIKey() throws -> String? {
        for dataProtection in [true, false] {
            var query = base(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                let value = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
                // Found in the legacy store → copy it into the no-prompt
                // data-protection store so the next launch reads it there and
                // never challenges for the password again. Best-effort.
                if !dataProtection, let value { try? saveAPIKey(value) }
                return value
            case errSecItemNotFound, errSecMissingEntitlement:
                continue   // try the other store
            default:
                throw KeychainError(status: status)
            }
        }
        return nil
    }
}
