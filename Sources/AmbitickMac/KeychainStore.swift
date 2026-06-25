import Foundation

/// OP API key storage.
///
/// This WAS the login Keychain, but a self-signed / no-Apple-team app cannot
/// read its own keychain item without macOS prompting for the login password
/// on every launch — and "Always Allow" never sticks, because the system won't
/// trust an unanchored signature across rebuilds (confirmed 2026-06-24). The
/// data-protection keychain (which has no such prompt) needs an entitlement a
/// teamless app can't get either.
///
/// So the key now lives in an owner-only (0600) file in the app's support
/// folder, beside the journal and settings — which are already plaintext in the
/// same directory, so this matches the existing on-disk posture. No keychain,
/// no prompt. (Type name kept for call-site stability; it is no longer a
/// keychain.)
public enum KeychainStore {
    private static func fileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ambitick")
            .appendingPathComponent("op-api-key")
    }

    public static func saveAPIKey(_ key: String) throws {
        let url = fileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(key.utf8).write(to: url, options: .atomic)
        // Readable only by your own account.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    /// nil = absent (no key set yet).
    public static func loadAPIKey() throws -> String? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
