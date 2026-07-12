import Foundation

/// The app's data home (`Application Support/andeye`). EVERY on-disk
/// consumer (journal, settings, API key) must resolve through here, so a
/// single place owns the folder name.
/// Public solely because `PhoneController.init`'s default argument (the iOS
/// companion seam) references `AppSupport.directory()` — a public default value
/// may only name public symbols.
public enum AppSupport {
    public static func directory() -> URL {
        directory(under: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// Pure function of `base` so checks exercise it against temp dirs.
    package static func directory(under base: URL) -> URL {
        base.appendingPathComponent("andeye")
    }
}
