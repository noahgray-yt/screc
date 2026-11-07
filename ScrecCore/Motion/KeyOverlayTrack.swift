import Foundation

/// Settings of the keyboard-shortcut overlay (SPEC §5, Phase 5 item 1).
public struct KeyOverlayLook: Codable, Equatable, Sendable {
    public enum Position: String, Codable, Sendable, CaseIterable { case bottom, top }
    public enum Size: String, Codable, Sendable, CaseIterable {
        case small, medium, large
        /// Keycap height as a fraction of the output's short side.
        public var heightFraction: Double {
            switch self {
            case .small: 0.045
            case .medium: 0.06
            case .large: 0.08
            }
        }
    }

    public var enabled = false
    public var position: Position = .bottom
    public var size: Size = .medium

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? .bottom
        size = try c.decodeIfPresent(Size.self, forKey: .size) ?? .medium
    }
}

/// The key combinations shown on screen, in timeline time.
///
/// Shown: presses with ⌘, ⌃ or ⌥, and special keys (Return, Delete, Esc, Tab, arrows, F-keys, Space with a
/// modifier). Never shown: plain typing, Shift + letter, modifier keys on their own.
/// One badge at a time: a new combo ends the previous one. The same combo again within `repeatWindow` is merged
/// ("⌘Z ×3").
public struct KeyOverlayTrack: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// One keycap per token, e.g. ["⇧", "⌘", "Z"].
        public var tokens: [String]
        public var repeatCount: Int
        public var start: Double
        public var end: Double
        /// Time of the last merged press (for the repeat window).
        public var lastPress: Double
    }

    public static let minimumShow = 1.0
    public static let holdExtra = 0.4
    public static let repeatWindow = 1.0
    public static let fadeIn = 0.08
    public static let fadeOut = 0.2

    public private(set) var items: [Item]

    public init(events: [TelemetryEvent], timeMap: TimeMap) {
        // Key-up times per key code, to know how long a combo was held.
        var presses: [(t: Double, tokens: [String], held: Double)] = []
        var openDowns: [Int: (index: Int, source: Double)] = [:]
        for e in events {
            guard case let .key(s, phase, keyCode, chars, mods, key) = e else { continue }
            if phase == .down {
                guard let tokens = Self.tokens(keyCode: keyCode, chars: chars, mods: mods, key: key),
                      let t = timeMap.toTimeline(s) else { continue }
                presses.append((t, tokens, 0))
                openDowns[keyCode] = (presses.count - 1, s)
            } else if let open = openDowns.removeValue(forKey: keyCode) {
                presses[open.index].held = max(s - open.source, 0)
            }
        }

        var items: [Item] = []
        for p in presses {
            let end = p.t + max(Self.minimumShow, p.held + Self.holdExtra)
            if var last = items.last, last.tokens == p.tokens, p.t - last.lastPress <= Self.repeatWindow {
                last.repeatCount += 1
                last.lastPress = p.t
                last.end = max(last.end, end)
                items[items.count - 1] = last
                continue
            }
            if !items.isEmpty, items[items.count - 1].end > p.t { items[items.count - 1].end = p.t }
            items.append(Item(tokens: p.tokens, repeatCount: 1, start: p.t, end: end, lastPress: p.t))
        }
        self.items = items.map { var i = $0; i.end = min(i.end, timeMap.duration); return i }.filter { $0.end > $0.start }
    }

    /// The badge visible at timeline time `t`, with its opacity (fade in and out).
    public func active(at t: Double) -> (item: Item, opacity: Double)? {
        guard let item = items.last(where: { $0.start <= t && t < $0.end }) else { return nil }
        let fadeIn = min((t - item.start) / Self.fadeIn, 1)
        let fadeOut = min((item.end - t) / Self.fadeOut, 1)
        return (item, max(min(fadeIn, fadeOut), 0))
    }

    // MARK: Labels

    /// Keycap tokens for a key press, or nil if it is not shown.
    ///
    /// The letter comes from the user's keyboard layout, not from the key's position: on a German keyboard the key
    /// right of T is Z (it is Y on a US keyboard). Order: the recorded plain `key`; else the typed character when no ⌥/⌃
    /// changed it; else (older takes with ⌥/⌃) the US-layout name of the key code.
    public static func tokens(keyCode: Int, chars: String, mods: [String], key: String? = nil) -> [String]? {
        if modifierKeyCodes.contains(keyCode) { return nil }
        let strong = mods.contains("cmd") || mods.contains("ctrl") || mods.contains("opt")
        let special = specialKeys[keyCode]
        guard strong || special != nil else { return nil }
        if keyCode == 49 && !strong { return nil }                 // Space alone is typing
        var t: [String] = []
        // macOS order: ⌃ ⌥ ⇧ ⌘
        if mods.contains("ctrl") { t.append("⌃") }
        if mods.contains("opt") { t.append("⌥") }
        if mods.contains("shift") { t.append("⇧") }
        if mods.contains("cmd") { t.append("⌘") }
        func printable(_ s: String?) -> String? {
            guard let s, s.count == 1, let c = s.first, !c.isWhitespace,
                  !(c.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? true) else { return nil }
            return String(c).uppercased()
        }
        let altered = mods.contains("opt") || mods.contains("ctrl")
        if let special {
            t.append(special)
        } else if let k = printable(key) {
            t.append(k)
        } else if !altered, let c = printable(chars) {
            t.append(c)
        } else if let name = ansiKeys[keyCode] {
            t.append(name)
        } else {
            return nil
        }
        return t
    }

    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static let specialKeys: [Int: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// US-ANSI key names by key code (the physical key).
    static let ansiKeys: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]
}
