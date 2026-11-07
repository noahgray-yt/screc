import Foundation

/// All auto-zoom parameters in one place (SPEC §3.3).
public struct AutoZoomConfig: Equatable, Sendable {
    /// The zoom starts this long before the first action.
    public var leadTime = 0.5
    /// One click keeps the zoom open this long after its mouse-up.
    public var clickHold = 1.0
    /// Max gap between keys inside one typing burst.
    public var typingKeyGap = 1.0
    /// Keys needed for a typing burst to count.
    public var typingMinKeys = 4
    /// Hold time after the last key of a burst.
    public var typingHold = 1.0
    /// Segments closer than this merge into one (lower bound 1.4 s).
    public var mergeGap = 1.5
    /// Shorter segments are extended to this.
    public var minDuration = 2.0
    /// Zoom factor of generated segments.
    public var defaultScale = 2.0
    /// Actions this close to the start/end are ignored (the stop click etc.).
    public var ignoreEdges = 0.3

    public init() {}
}

/// Generates zoom segments from telemetry (ARCHITECTURE §7.3). A pure function, all in source time:
///
/// 1. actions = clicks (mouse-down … mouse-up) + typing bursts; drop actions near the start/end
/// 2. click → [down − lead, up + clickHold],  burst → [first − lead, last + typingHold]
/// 3. sort, merge intervals whose gap < mergeGap
/// 4. extend intervals shorter than minDuration (to the right, else to the left)
/// 5. clamp to [0, D]; scale = defaultScale; mode = auto; origin = generated
/// 6. keep zooms with origin = user; drop generated ones that overlap them
public enum AutoZoom {
    public static func generate(events: [TelemetryEvent], recordingDuration d: Double, config c: AutoZoomConfig = AutoZoomConfig(),
                                existing: [ZoomSegment] = []) -> [ZoomSegment] {
        var intervals: [(Double, Double)] = []
        func inside(_ t: Double) -> Bool { t >= c.ignoreEdges && t <= d - c.ignoreEdges }

        // Clicks: pair each mouse-down with the next mouse-up of the same button (a drag holds the zoom).
        var openDowns: [MouseButton: Double] = [:]
        for e in events {
            switch e {
            case let .down(t, button, _, _, _):
                if let pending = openDowns[button], inside(pending) { intervals.append((pending - c.leadTime, pending + c.clickHold)) }
                openDowns[button] = t
            case let .up(t, button, _, _):
                if let down = openDowns.removeValue(forKey: button), inside(down) {
                    intervals.append((down - c.leadTime, max(t, down) + c.clickHold))
                }
            default:
                break
            }
        }
        for (_, down) in openDowns where inside(down) { intervals.append((down - c.leadTime, down + c.clickHold)) }

        // Typing bursts: real key presses (with characters, no ⌘/⌃ shortcuts), gaps ≤ typingKeyGap.
        var burst: [Double] = []
        func closeBurst() {
            if burst.count >= c.typingMinKeys, let first = burst.first, let last = burst.last, inside(first) {
                intervals.append((first - c.leadTime, last + c.typingHold))
            }
            burst.removeAll()
        }
        for e in events {
            guard case let .key(t, phase, _, chars, mods, _) = e, phase == .down, !chars.isEmpty,
                  !mods.contains("cmd"), !mods.contains("ctrl") else { continue }
            if let last = burst.last, t - last > c.typingKeyGap { closeBurst() }
            burst.append(t)
        }
        closeBurst()

        // Merge, extend, merge again (extension can create new overlaps), clamp.
        func merge(_ list: [(Double, Double)]) -> [(Double, Double)] {
            var out: [(Double, Double)] = []
            for iv in list.sorted(by: { $0.0 < $1.0 }) {
                if let last = out.last, iv.0 - last.1 < c.mergeGap {
                    out[out.count - 1].1 = max(last.1, iv.1)
                } else {
                    out.append(iv)
                }
            }
            return out
        }
        var merged = merge(intervals).map { iv -> (Double, Double) in
            var (a, b) = (max(iv.0, 0), min(iv.1, d))
            if b - a < c.minDuration {
                if a + c.minDuration <= d { b = a + c.minDuration } else { a = max(d - c.minDuration, 0); b = d }
            }
            return (a, b)
        }
        merged = merge(merged).map { (max($0.0, 0), min($0.1, d)) }.filter { $0.1 > $0.0 }

        // Keep the user's zooms; generated ones must not overlap them.
        let user = existing.filter { $0.origin == .user }
        var result = user
        var n = 1
        for (a, b) in merged where !user.contains(where: { $0.sourceStart < b && a < $0.sourceEnd }) {
            var id = "A\(n)"
            while result.contains(where: { $0.id == id }) { n += 1; id = "A\(n)" }
            result.append(ZoomSegment(id: id, sourceStart: a, sourceEnd: b, scale: c.defaultScale, mode: .auto, origin: .generated))
            n += 1
        }
        return result.sorted { $0.sourceStart < $1.sourceStart }
    }
}
