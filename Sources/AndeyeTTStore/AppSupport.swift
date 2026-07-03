import Foundation

/// The app's data home (`Application Support/andeye`), with the one-shot
/// rename migration from the pre-andeye `Ambitick/` dir. EVERY on-disk
/// consumer (journal, settings, API key) must resolve through here — the
/// 2026-07-02 "No API key yet" bug was APIKeyStore hardcoding the old folder
/// name and missing the migration.
public enum AppSupport {
    public static func directory() -> URL {
        directory(under: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// Pure function of `base` so checks exercise it against temp dirs.
    /// MOVE (never copy — dual dirs would fork the journal) the legacy dir
    /// when the new one is absent; an existing andeye dir always wins.
    public static func directory(under base: URL) -> URL {
        let dir = base.appendingPathComponent("andeye")
        let legacy = base.appendingPathComponent("Ambitick")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        return dir
    }
}
