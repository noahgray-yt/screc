import Foundation

/// `project.json`, schema v1 (ARCHITECTURE §5.1).
///
/// Phase 1 only needs the parts a fresh recording has: the name and one slice covering the whole take.
/// Later phases add `look`, `audio`, `camera`, … . Missing keys decode to defaults, so files written now
/// stay readable.
public struct Project: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var name: String
    public var timeline: Timeline
    public var zooms: [ZoomSegment] = []
    public var masks: [Mask] = []
    /// Camera layouts per time range (Phase 5).
    public var layouts: [LayoutSegment] = []
    public var look = Look()
    /// Set once zooms were generated automatically on first open (SPEC §3.3), so they are not re-added
    /// after the user deletes them.
    public var autoZoomDone = false
    public var export = ExportSettings()
    /// Background music (Phase 5).
    public var music = BackgroundMusic()
    /// Voice processing (Phase 5).
    public var voice = VoiceSettings()

    public init(name: String, timeline: Timeline) {
        self.name = name
        self.timeline = timeline
    }

    /// A new project for a finished take: one slice `[0, duration)` at 1×.
    public static func fresh(name: String, duration: Double) -> Project {
        Project(name: name, timeline: Timeline(slices: [Slice(id: "S1", sourceStart: 0, sourceEnd: duration)]))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        name = try c.decode(String.self, forKey: .name)
        timeline = try c.decode(Timeline.self, forKey: .timeline)
        zooms = try c.decodeIfPresent([ZoomSegment].self, forKey: .zooms) ?? []
        masks = try c.decodeIfPresent([Mask].self, forKey: .masks) ?? []
        layouts = try c.decodeIfPresent([LayoutSegment].self, forKey: .layouts) ?? []
        look = try c.decodeIfPresent(Look.self, forKey: .look) ?? Look()
        autoZoomDone = try c.decodeIfPresent(Bool.self, forKey: .autoZoomDone) ?? false
        export = try c.decodeIfPresent(ExportSettings.self, forKey: .export) ?? ExportSettings()
        music = try c.decodeIfPresent(BackgroundMusic.self, forKey: .music) ?? BackgroundMusic()
        voice = try c.decodeIfPresent(VoiceSettings.self, forKey: .voice) ?? VoiceSettings()
        migrateLegacyMusic(fileDuration: 0)              // music loops, so its file length is not needed
    }

    public func encoded() throws -> Data { try JSONCoding.encoder.encode(self) }
    public static func decode(from data: Data) throws -> Project { try JSONCoding.decoder.decode(Project.self, from: data) }
}

public struct Timeline: Codable, Equatable, Sendable {
    public var slices: [Slice]
    public init(slices: [Slice]) { self.slices = slices }
}

public struct Slice: Codable, Equatable, Sendable {
    public var id: String
    public var sourceStart: Double
    public var sourceEnd: Double
    /// 0.25…16 (UI presets 1 / 1.2 / 1.4 / 1.6 / 1.8 / 2 / 3).
    public var speed: Double = 1.0
    /// Master volume for this slice.
    public var volume: Double = 1.0
    /// "External-device audio" = microphone.
    public var micVolume: Double = 1.0
    public var systemVolume: Double = 1.0
    /// false = "Disable smooth mouse movement".
    public var smoothMouse: Bool = true
    public var hideCursor: Bool = false
    /// Per-slice cursor settings that replace the project's (ED-05).
    public var cursorOverride: CursorOverride?

    public init(id: String, sourceStart: Double, sourceEnd: Double) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceStart = try c.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try c.decode(Double.self, forKey: .sourceEnd)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1
        systemVolume = try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 1
        smoothMouse = try c.decodeIfPresent(Bool.self, forKey: .smoothMouse) ?? true
        hideCursor = try c.decodeIfPresent(Bool.self, forKey: .hideCursor) ?? false
        cursorOverride = try c.decodeIfPresent(CursorOverride.self, forKey: .cursorOverride)
    }
}

/// The cursor settings a slice may override; nil fields keep the project's value.
public struct CursorOverride: Codable, Equatable, Sendable {
    public var style: CursorLook.Style?
    public var size: Double?
    public var clickEffect: CursorLook.ClickEffect?

    public init(style: CursorLook.Style? = nil, size: Double? = nil, clickEffect: CursorLook.ClickEffect? = nil) {
        self.style = style
        self.size = size
        self.clickEffect = clickEffect
    }

    public var isEmpty: Bool { style == nil && size == nil && clickEffect == nil }

    public func applied(to look: CursorLook) -> CursorLook {
        var l = look
        if let style { l.style = style }
        if let size { l.size = size }
        if let clickEffect { l.clickEffect = clickEffect }
        return l
    }
}

/// A zoom block, anchored to recording (source) time so cuts and speed changes keep it on its content (ED-08).
public struct ZoomSegment: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case auto, manual }
    public enum Origin: String, Codable, Sendable { case generated, user }

    public var id: String
    public var sourceStart: Double
    public var sourceEnd: Double
    /// 1.25…4.
    public var scale: Double
    public var mode: Mode
    /// Manual mode: zoom point in 0…1 recording coordinates.
    public var manualCenter: [Double]?
    public var origin: Origin

    public init(id: String, sourceStart: Double, sourceEnd: Double, scale: Double = 2, mode: Mode = .auto,
                manualCenter: [Double]? = nil, origin: Origin = .user) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.scale = scale
        self.mode = mode
        self.manualCenter = manualCenter
        self.origin = origin
    }
}

/// A mask (SPEC §3.1 tool palette): a rectangle in recording coordinates with a time range in source time,
/// so it stays on the content while zoomed and when the timeline is edited.
public struct Mask: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Blur the region.
        case blur
        /// Cover the region with a solid fill.
        case hide
        /// Keep the region, dim everything else.
        case highlight
    }

    public var id: String
    public var sourceStart: Double
    public var sourceEnd: Double
    public var kind: Kind
    /// Normalised recording rect `[x, y, w, h]` (top-left origin).
    public var rect: [Double]
    /// Blur: 0…1 strength. Highlight: 0…1 dimming. Hide: unused.
    public var strength: Double

    public init(id: String, sourceStart: Double, sourceEnd: Double, kind: Kind, rect: [Double], strength: Double = 0.7) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.kind = kind
        self.rect = rect
        self.strength = strength
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceStart = try c.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try c.decode(Double.self, forKey: .sourceEnd)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .blur
        rect = try c.decodeIfPresent([Double].self, forKey: .rect) ?? [0.4, 0.4, 0.2, 0.2]
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0.7
    }
}
