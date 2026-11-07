import Foundation

/// Mouse button of a `down`/`up` event.
public enum MouseButton: String, Codable, Sendable {
    case left, right, other
}

/// Key phase of a `key` event. Modifier keys (⌘ ⌥ ⇧ ⌃ fn, caps lock) also produce down/up events.
public enum KeyPhase: String, Codable, Sendable {
    case down, up
}

/// System cursor shapes Screc can recognise (ARCHITECTURE §4.2).
public enum CursorShape: String, Codable, Sendable, CaseIterable {
    case arrow, iBeam, pointingHand, openHand, closedHand, resizeLeftRight, resizeUpDown
    case crosshair, notAllowed, contextMenu, dragCopy, dragLink, unknown
}

/// One line of `events.jsonl` after the header.
///
/// `t` is **source time** in seconds (paused time removed, 0 = first screen frame).
/// Positions are in **recording pixels** (top-left origin, same grid as `screen.mov`).
public enum TelemetryEvent: Equatable, Sendable {
    case pos(t: Double, x: Double, y: Double)
    case down(t: Double, button: MouseButton, x: Double, y: Double, clickCount: Int)
    case up(t: Double, button: MouseButton, x: Double, y: Double)
    case scroll(t: Double, dx: Double, dy: Double, x: Double, y: Double)
    /// `chars`: what was typed (with ⌥ a symbol, e.g. ⌥L → "@" on a German layout).
    /// `key`: the key's own character on the active keyboard layout, without modifiers ("l"); nil in older takes.
    case key(t: Double, phase: KeyPhase, keyCode: Int, chars: String, mods: [String], key: String? = nil)
    case cursor(t: Double, shape: CursorShape)
    /// Window capture only: the captured window's frame, in recording pixels of the display it is on.
    case frame(t: Double, rect: [Double])

    public var t: Double {
        switch self {
        case let .pos(t, _, _), let .down(t, _, _, _, _), let .up(t, _, _, _), let .scroll(t, _, _, _, _),
             let .key(t, _, _, _, _, _), let .cursor(t, _), let .frame(t, _):
            return t
        }
    }

    public var typeName: String {
        switch self {
        case .pos: "pos"
        case .down: "down"
        case .up: "up"
        case .scroll: "scroll"
        case .key: "key"
        case .cursor: "cursor"
        case .frame: "frame"
        }
    }
}

/// First line of `events.jsonl`.
public struct TelemetryHeader: Codable, Equatable, Sendable {
    public var type: String = "header"
    public var schema: Int
    public var t0HostSeconds: Double
    public var sampleHz: Double
    public var videoPixelSize: [Int]
    /// How `CGEventGetTimestamp` was interpreted on this machine: "nanoseconds" or "machTicks".
    public var eventTimestampUnit: String?

    public init(schema: Int = 1, t0HostSeconds: Double, sampleHz: Double, videoPixelSize: [Int], eventTimestampUnit: String? = nil) {
        self.schema = schema
        self.t0HostSeconds = t0HostSeconds
        self.sampleHz = sampleHz
        self.videoPixelSize = videoPixelSize
        self.eventTimestampUnit = eventTimestampUnit
    }
}
