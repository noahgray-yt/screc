import Foundation

/// Timeline edit operations (ARCHITECTURE §8.3). Each one keeps the invariants
///
///     0 ≤ a₀,  aᵢ < bᵢ,  bᵢ ≤ aᵢ₊₁,  bₙ₋₁ ≤ D,  vᵢ ∈ [0.25, 16]
///
/// or throws `EditError` and leaves the project unchanged. `D` is the recording duration.
public enum EditError: LocalizedError, Equatable {
    case unknownSlice
    case tooCloseToEdge
    case lastSlice
    case noNeighbour
    case unknownZoom
    case unknownMask
    case unknownClip
    case unknownLayout
    case noRoom

    public var errorDescription: String? {
        switch self {
        case .unknownSlice: "That slice no longer exists."
        case .tooCloseToEdge: "Too close to the edge of a slice to split (at least 0.1 s on each side)."
        case .lastSlice: "The last slice cannot be removed."
        case .noNeighbour: "There is no slice to merge with."
        case .unknownZoom: "That zoom no longer exists."
        case .unknownMask: "That mask no longer exists."
        case .unknownClip: "That audio clip no longer exists."
        case .unknownLayout: "That layout no longer exists."
        case .noRoom: "There is no free room on that lane here."
        }
    }
}

public extension Project {
    static let minSliceLength = 0.1
    static let speedRange = 0.25...16.0
    static let speedPresets: [Double] = [1, 1.2, 1.4, 1.6, 1.8, 2, 3]

    // MARK: Invariants

    /// True if the slices satisfy every invariant for a recording of duration `d`.
    func isValid(recordingDuration d: Double) -> Bool {
        let s = timeline.slices
        guard !s.isEmpty, s[0].sourceStart >= 0 else { return false }
        for (i, x) in s.enumerated() {
            guard x.sourceStart < x.sourceEnd, Self.speedRange.contains(x.speed) else { return false }
            if i + 1 < s.count, x.sourceEnd > s[i + 1].sourceStart + 1e-9 { return false }
        }
        return s[s.count - 1].sourceEnd <= d + 1e-9
    }

    func sliceIndex(_ id: String) throws -> Int {
        guard let i = timeline.slices.firstIndex(where: { $0.id == id }) else { throw EditError.unknownSlice }
        return i
    }

    /// A new unique id with the given prefix ("S", "Z", "M").
    func newID(_ prefix: String) -> String {
        let used = Set(timeline.slices.map(\.id) + zooms.map(\.id) + masks.map(\.id))
        var n = 1
        while used.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    // MARK: Slices

    /// Splits the slice playing at timeline time `t`. Both halves keep speed, volumes and overrides.
    /// Returns the ids of the two halves.
    @discardableResult
    mutating func split(atTimeline t: Double) throws -> (left: String, right: String) {
        let map = TimeMap(slices: timeline.slices)
        guard let e = map.entryIndex(atTimeline: t) else { throw EditError.unknownSlice }
        let s = map.toSource(t)
        let i = try sliceIndex(map.entries[e].sliceID)
        var left = timeline.slices[i]
        guard s - left.sourceStart >= Self.minSliceLength, left.sourceEnd - s >= Self.minSliceLength else { throw EditError.tooCloseToEdge }
        var right = left
        right.id = newID("S")
        left.sourceEnd = s
        right.sourceStart = s
        timeline.slices[i] = left
        timeline.slices.insert(right, at: i + 1)
        return (left.id, right.id)
    }

    /// Moves the start of a slice, within `[previous end (or 0), end − 0.1]`.
    mutating func trimStart(sliceID: String, toSource s: Double) throws {
        let i = try sliceIndex(sliceID)
        let lower = i > 0 ? timeline.slices[i - 1].sourceEnd : 0
        let upper = timeline.slices[i].sourceEnd - Self.minSliceLength
        timeline.slices[i].sourceStart = min(max(s, lower), upper)
    }

    /// Moves the end of a slice, within `[start + 0.1, next start (or D)]`.
    mutating func trimEnd(sliceID: String, toSource s: Double, recordingDuration d: Double) throws {
        let i = try sliceIndex(sliceID)
        let lower = timeline.slices[i].sourceStart + Self.minSliceLength
        let upper = i + 1 < timeline.slices.count ? timeline.slices[i + 1].sourceStart : d
        timeline.slices[i].sourceEnd = max(min(s, upper), lower)
    }

    /// Removes a slice; a cut badge appears in its place automatically.
    mutating func removeSlice(_ id: String) throws {
        let i = try sliceIndex(id)
        guard timeline.slices.count > 1 else { throw EditError.lastSlice }
        timeline.slices.remove(at: i)
    }

    mutating func setSpeed(_ id: String, _ speed: Double) throws {
        let i = try sliceIndex(id)
        timeline.slices[i].speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    mutating func applySpeedToAll(from id: String) throws {
        let v = timeline.slices[try sliceIndex(id)].speed
        for i in timeline.slices.indices { timeline.slices[i].speed = v }
    }

    /// Extends a slice back to its neighbours (or to 0 / D).
    mutating func resetTrim(_ id: String, recordingDuration d: Double) throws {
        let i = try sliceIndex(id)
        timeline.slices[i].sourceStart = i > 0 ? timeline.slices[i - 1].sourceEnd : 0
        timeline.slices[i].sourceEnd = i + 1 < timeline.slices.count ? timeline.slices[i + 1].sourceStart : d
    }

    /// Joins a slice with the next one: `[aᵢ, bᵢ₊₁)` with this slice's speed and overrides.
    /// Any cut between them is restored (SPEC §3.2).
    mutating func mergeWithNext(_ id: String) throws {
        let i = try sliceIndex(id)
        guard i + 1 < timeline.slices.count else { throw EditError.noNeighbour }
        timeline.slices[i].sourceEnd = timeline.slices[i + 1].sourceEnd
        timeline.slices.remove(at: i + 1)
    }

    mutating func mergeWithPrevious(_ id: String) throws {
        let i = try sliceIndex(id)
        guard i > 0 else { throw EditError.noNeighbour }
        // The left slice's speed and overrides win.
        try mergeWithNext(timeline.slices[i - 1].id)
    }

    /// `a₀ = 0`, `bₙ₋₁ = D`, every gap closes. Splits, speeds and overrides stay.
    mutating func resetAllTrimsAndCuts(recordingDuration d: Double) {
        guard !timeline.slices.isEmpty else { return }
        timeline.slices[0].sourceStart = 0
        for i in timeline.slices.indices.dropLast() { timeline.slices[i].sourceEnd = timeline.slices[i + 1].sourceStart }
        timeline.slices[timeline.slices.count - 1].sourceEnd = d
    }

    mutating func updateSlice(_ id: String, _ change: (inout Slice) -> Void) throws {
        let i = try sliceIndex(id)
        change(&timeline.slices[i])
        timeline.slices[i].speed = min(max(timeline.slices[i].speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    // MARK: Zooms and masks (anchored to source time, edited in timeline time)

    /// The free timeline room around a zoom: the end of the zoom before it and the start of the one after.
    /// Zooms never overlap (two zooms at once look like one, but are confusing to edit).
    func zoomRoom(_ id: String, map: TimeMap) -> ClosedRange<Double> {
        func span(_ z: ZoomSegment) -> ClosedRange<Double>? {
            let iv = map.timelineIntervals(sourceStart: z.sourceStart, sourceEnd: z.sourceEnd)
            guard let a = iv.first?.lowerBound, let b = iv.last?.upperBound else { return nil }
            return a...b
        }
        let mine = zooms.first { $0.id == id }.flatMap(span)?.lowerBound ?? 0
        var lo = 0.0, hi = map.duration
        for z in zooms where z.id != id {
            guard let r = span(z) else { continue }
            if r.lowerBound < mine || (r.lowerBound == mine && z.id < id) { lo = max(lo, r.upperBound) } else { hi = min(hi, r.lowerBound) }
        }
        return lo...max(hi, lo)
    }

    /// Free timeline room at `t` for a new zoom, or nil if `t` is inside a zoom.
    func zoomGap(at t: Double, map: TimeMap) -> ClosedRange<Double>? {
        var lo = 0.0, hi = map.duration
        for z in zooms {
            let iv = map.timelineIntervals(sourceStart: z.sourceStart, sourceEnd: z.sourceEnd)
            guard let a = iv.first?.lowerBound, let b = iv.last?.upperBound else { continue }
            if a <= t && t < b { return nil }
            if b <= t { lo = max(lo, b) } else { hi = min(hi, a) }
        }
        return lo...hi
    }

    /// Moves a zoom so its first visible part starts at timeline time `t`; its timeline length stays.
    /// It stops at its neighbours.
    mutating func moveZoom(_ id: String, toTimelineStart t: Double) throws {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { throw EditError.unknownZoom }
        let map = TimeMap(slices: timeline.slices)
        let current = map.timelineIntervals(sourceStart: zooms[i].sourceStart, sourceEnd: zooms[i].sourceEnd)
        let room = zoomRoom(id, map: map)
        let length = min(current.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }, room.upperBound - room.lowerBound)
        let start = min(max(t, room.lowerBound), max(room.upperBound - length, room.lowerBound))
        zooms[i].sourceStart = map.toSource(start)
        zooms[i].sourceEnd = max(map.toSource(start + max(length, 0.1)), zooms[i].sourceStart + 0.05)
    }

    /// Moves one edge of a zoom to timeline time `t` (the block keeps at least 0.25 s and stops at its neighbours).
    mutating func resizeZoom(_ id: String, start: Bool, toTimeline t: Double) throws {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { throw EditError.unknownZoom }
        let map = TimeMap(slices: timeline.slices)
        let room = zoomRoom(id, map: map)
        let s = map.toSource(min(max(t, room.lowerBound), room.upperBound))
        if start {
            zooms[i].sourceStart = min(s, zooms[i].sourceEnd - 0.25)
        } else {
            zooms[i].sourceEnd = max(s, zooms[i].sourceStart + 0.25)
        }
        if zooms[i].origin == .generated { zooms[i].origin = .user }   // edited by hand → kept on re-generation
    }

    mutating func moveMask(_ id: String, toTimelineStart t: Double) throws {
        guard let i = masks.firstIndex(where: { $0.id == id }) else { throw EditError.unknownMask }
        let map = TimeMap(slices: timeline.slices)
        let length = map.timelineIntervals(sourceStart: masks[i].sourceStart, sourceEnd: masks[i].sourceEnd)
            .reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        let start = min(max(t, 0), max(map.duration - length, 0))
        masks[i].sourceStart = map.toSource(start)
        masks[i].sourceEnd = max(map.toSource(start + max(length, 0.1)), masks[i].sourceStart + 0.05)
    }

    mutating func resizeMask(_ id: String, start: Bool, toTimeline t: Double) throws {
        guard let i = masks.firstIndex(where: { $0.id == id }) else { throw EditError.unknownMask }
        let map = TimeMap(slices: timeline.slices)
        let s = map.toSource(min(max(t, 0), map.duration))
        if start {
            masks[i].sourceStart = min(s, masks[i].sourceEnd - 0.25)
        } else {
            masks[i].sourceEnd = max(s, masks[i].sourceStart + 0.25)
        }
    }
}
