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
}
