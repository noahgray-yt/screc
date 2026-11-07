import Foundation

/// A saved look (ARCHITECTURE §5.4): background, frame, cursor and animation. Aspect ratio and crop are left
/// out because they belong to one recording.
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public struct Content: Codable, Equatable, Sendable {
        public var background: Background
        public var frame: FrameStyle
        public var cursor: CursorLook
        public var animation: AnimationLook
    }

    public var schemaVersion = 1
    public var name: String
    public var look: Content
    public var id: String { name }

    public init(name: String, from look: Look) {
        self.name = name
        self.look = Content(background: look.background, frame: look.frame, cursor: look.cursor, animation: look.animation)
    }

    /// The preset applied to a look; aspect and crop stay.
    public func applied(to look: Look) -> Look {
        var l = look
        l.background = self.look.background
        l.frame = self.look.frame
        l.cursor = self.look.cursor
        l.animation = self.look.animation
        return l
    }
}

/// Presets as JSON files in `~/Library/Application Support/Screc/Presets/<name>.json`.
public struct PresetStore: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screc/Presets", isDirectory: true)
    }

    public init(directory: URL = PresetStore.defaultDirectory) { self.directory = directory }

    public func list() -> [Preset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONCoding.decoder.decode(Preset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves (or replaces) a preset with this name.
    public func save(_ preset: Preset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(preset).write(to: url(for: preset.name), options: .atomic)
    }

    public func delete(name: String) throws {
        try FileManager.default.removeItem(at: url(for: name))
    }

    public func rename(_ name: String, to newName: String) throws {
        guard var p = list().first(where: { $0.name == name }) else { return }
        p.name = newName
        try save(p)
        if Self.fileName(name) != Self.fileName(newName) { try delete(name: name) }
    }

    func url(for name: String) -> URL { directory.appendingPathComponent(Self.fileName(name) + ".json") }

    static func fileName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        let s = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Preset" : s
    }
}
