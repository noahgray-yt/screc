import Foundation

/// Maps between **timeline time** (the edited result) and **source time** (the recording), ARCHITECTURE §8.
///
/// Slices are ordered by source time and never overlap. Each slice `i` covers source `[aᵢ, bᵢ)` at speed `vᵢ`
/// and lasts `dᵢ = (bᵢ − aᵢ) / vᵢ` on the timeline. Durations are rounded once to ticks of 1/60 000 s and
/// the slice starts `Tᵢ` are prefix sums of the *rounded* values, so the AVComposition and the compositor,
/// which both use this one map, can never disagree by a rounding step (§8.2).
public struct TimeMap: Equatable, Sendable {
    public static let ticksPerSecond: Int64 = 60_000

    public struct Entry: Equatable, Sendable {
        public var sliceID: String
        public var sourceStart: Double
        public var sourceEnd: Double
        public var speed: Double
        public var timelineStartTicks: Int64
        public var timelineDurationTicks: Int64

        public var timelineStart: Double { Double(timelineStartTicks) / Double(TimeMap.ticksPerSecond) }
        public var timelineDuration: Double { Double(timelineDurationTicks) / Double(TimeMap.ticksPerSecond) }
        public var timelineEnd: Double { timelineStart + timelineDuration }
    }

    public private(set) var entries: [Entry]
    public private(set) var durationTicks: Int64

    public init(slices: [Slice]) {
        var t: Int64 = 0
        var entries: [Entry] = []
        for s in slices.sorted(by: { $0.sourceStart < $1.sourceStart }) where s.sourceEnd > s.sourceStart && s.speed > 0 {
            let d = Int64(((s.sourceEnd - s.sourceStart) / s.speed * Double(Self.ticksPerSecond)).rounded())
            entries.append(Entry(sliceID: s.id, sourceStart: s.sourceStart, sourceEnd: s.sourceEnd, speed: s.speed,
                                 timelineStartTicks: t, timelineDurationTicks: d))
            t += d
        }
        self.entries = entries
        durationTicks = t
    }

    /// Total timeline duration `T` in seconds.
    public var duration: Double { Double(durationTicks) / Double(Self.ticksPerSecond) }

    /// Index of the slice playing at timeline time `t` (clamped to the first/last slice).
    public func entryIndex(atTimeline t: Double) -> Int? {
        guard !entries.isEmpty else { return nil }
        // Binary search for the last entry with Tᵢ ≤ t.
        var lo = 0, hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if entries[mid].timelineStart <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Timeline → source. Clamped to the timeline; at `t = T` it returns the last slice's end.
    public func toSource(_ t: Double) -> Double {
        guard let i = entryIndex(atTimeline: t) else { return 0 }
        let e = entries[i]
        let local = min(max(t - e.timelineStart, 0), e.timelineDuration)
        return min(e.sourceStart + local * e.speed, e.sourceEnd)
    }

    /// Source → timeline, or nil if `s` lies in a cut or trimmed part.
    public func toTimeline(_ s: Double) -> Double? {
        for e in entries where s >= e.sourceStart && s < e.sourceEnd {
            return e.timelineStart + (s - e.sourceStart) / e.speed
        }
        if let last = entries.last, s == last.sourceEnd { return last.timelineEnd }
        return nil
    }

    /// The slice containing source time `s`, if any.
    public func entry(containingSource s: Double) -> Entry? {
        entries.first { s >= $0.sourceStart && s < $0.sourceEnd }
    }

    /// Maps a source interval (zoom, mask, caption) to timeline intervals, one per slice it overlaps (§8.1).
    public func timelineIntervals(sourceStart: Double, sourceEnd: Double) -> [ClosedRange<Double>] {
        guard sourceEnd > sourceStart else { return [] }
        var result: [ClosedRange<Double>] = []
        for e in entries {
            let a = max(sourceStart, e.sourceStart), b = min(sourceEnd, e.sourceEnd)
            guard b > a else { continue }
            let ta = e.timelineStart + (a - e.sourceStart) / e.speed
            let tb = e.timelineStart + (b - e.sourceStart) / e.speed
            result.append(ta...tb)
        }
        return result
    }

    /// Output frame count for a frame rate (§8.2: `N = round(T · fps)`).
    public func frameCount(fps: Int) -> Int { Int((duration * Double(fps)).rounded()) }
}
