import Foundation

public enum OPURLParser {
    /// Extracts a work-package id from a URL on the given OP instance host,
    /// matching `/work_packages/<id>` anywhere in the path.
    public static func taskID(in urlString: String, instanceHost: String) -> Int? {
        guard let url = URL(string: urlString), url.host == instanceHost else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "work_packages"), i + 1 < parts.count,
              let id = Int(parts[i + 1]) else { return nil }
        return id
    }

    /// Fallback for surfaces with no readable URL (OP opened as a Chrome
    /// app/PWA): work-package pages put "#<id>" in the document title, which
    /// PWAs surface as window title or even application name.
    public static func taskID(inTitle title: String) -> Int? {
        guard title.contains("OpenProject") else { return nil }
        guard let range = title.range(of: "#[0-9]+", options: .regularExpression) else { return nil }
        return Int(title[range].dropFirst())
    }
}
