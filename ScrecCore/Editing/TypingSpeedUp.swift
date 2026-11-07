import Foundation

/// Speed-up typing (SPEC §5, Phase 5 item 2): finds long typing stretches and suggests a faster speed.
public enum TypingSpeedUp {
    public struct Stretch: Equatable, Sendable {
        /// Source time, including a small margin around the first and last key.
        public var sourceStart: Double
        public var sourceEnd: Double
        public var keyCount: Int
        public var suggestedSpeed: Double
        public var duration: Double { sourceEnd - sourceStart }
    }

    public struct Config: Equatable, Sendable {
        public var maxKeyGap = 1.0
        public var minDuration = 3.0
        public var minKeys = 10
        public var margin = 0.2
        public init() {}
    }

    /// Long stretches of real typing (characters, no ⌘/⌃ shortcuts), in source time.
    public static func stretches(events: [TelemetryEvent], recordingDuration d: Double, config c: Config = Config()) -> [Stretch] {
        var result: [Stretch] = []
        var keys: [Double] = []
        func close() {
            if keys.count >= c.minKeys, let first = keys.first, let last = keys.last, last - first >= c.minDuration {
                let a = max(first - c.margin, 0), b = min(last + c.margin, d)
                result.append(Stretch(sourceStart: a, sourceEnd: b, keyCount: keys.count, suggestedSpeed: suggestedSpeed(for: b - a)))
            }
            keys.removeAll()
        }
        for e in events {
            guard case let .key(t, phase, _, chars, mods, _) = e, phase == .down, !chars.isEmpty,
                  !mods.contains("cmd"), !mods.contains("ctrl") else { continue }
            if let last = keys.last, t - last > c.maxKeyGap { close() }
            keys.append(t)
        }
        close()
        return result
    }

    /// Longer stretches get more speed (from the slice speed presets).
    public static func suggestedSpeed(for duration: Double) -> Double {
        duration > 10 ? 3 : duration > 6 ? 2 : 1.6
    }
}

public extension Project {
    /// Plays the source range `[s0, s1)` at `speed`: slices are split at the range edges (unless an edge is
    /// within 0.1 s of a slice edge) and every slice inside gets the speed. Parts outside keep their speed.
    mutating func applySpeed(sourceStart s0: Double, sourceEnd s1: Double, speed: Double) throws {
        guard s1 > s0 else { return }
        for boundary in [s0, s1] {
            guard let i = timeline.slices.firstIndex(where: { $0.sourceStart < boundary && boundary < $0.sourceEnd }) else { continue }
            let slice = timeline.slices[i]
            guard boundary - slice.sourceStart >= Self.minSliceLength, slice.sourceEnd - boundary >= Self.minSliceLength else { continue }
            var right = slice
            right.id = newID("S")
            timeline.slices[i].sourceEnd = boundary
            right.sourceStart = boundary
            timeline.slices.insert(right, at: i + 1)
        }
        let v = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        for i in timeline.slices.indices {
            let s = timeline.slices[i]
            let overlap = min(s.sourceEnd, s1) - max(s.sourceStart, s0)
            if overlap > 0, overlap >= (s.sourceEnd - s.sourceStart) * 0.5 { timeline.slices[i].speed = v }
        }
    }
}
