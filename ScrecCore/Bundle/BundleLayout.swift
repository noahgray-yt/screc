import Foundation

/// File names inside a `.screc` bundle (ARCHITECTURE §4) and project naming (REC-11).
public enum BundleLayout {
    public static let fileExtension = "screc"
    public static let project = "project.json"
    public static let recording = "recording.json"
    public static let screen = "screen.mov"
    public static let camera = "camera.mov"
    public static let mic = "mic.m4a"
    public static let system = "system.m4a"
    public static let events = "events.jsonl"
    public static let cache = "cache"
    public static let lock = ".recording"

    /// Default folder for new recordings: `~/Movies/Screc`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Screc", isDirectory: true)
    }

    /// Project name = source app + local timestamp, e.g. `Safari 2026-10-16 23:23:42` (REC-11).
    public static func projectName(sourceApp: String, date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let app = sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(app.isEmpty ? "Recording" : app) \(f.string(from: date))"
    }

    /// Folder name for a project name. Finder shows `:` as `/`, so the time uses dots instead
    /// (like macOS screenshots: `Safari 2026-10-16 23.23.42.screc`). `project.json` keeps the real name.
    public static func folderName(forProjectName name: String) -> String {
        var cleaned = name.replacingOccurrences(of: ":", with: ".")
        cleaned = cleaned.replacingOccurrences(of: "/", with: "-")
        return cleaned + "." + fileExtension
    }

    /// A bundle URL in `directory` that does not exist yet ("… 2.screc", "… 3.screc" on clashes).
    public static func uniqueBundleURL(in directory: URL, projectName: String, fileManager: FileManager = .default) -> URL {
        let base = folderName(forProjectName: projectName)
        var url = directory.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            let stem = String(base.dropLast(fileExtension.count + 1))
            url = directory.appendingPathComponent("\(stem) \(n).\(fileExtension)", isDirectory: true)
            n += 1
        }
        return url
    }

    /// Bundles in `directory` that still have a lock file, i.e. takes interrupted by a crash (REC-06).
    public static func interruptedBundles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let items = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.pathExtension == fileExtension && fileManager.fileExists(atPath: $0.appendingPathComponent(lock).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
