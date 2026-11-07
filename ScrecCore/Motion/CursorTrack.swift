import Foundation

/// The cursor as it is drawn: position, opacity, tilt and shape for every timeline moment (ARCHITECTURE §7.1).
///
/// Computed once per project change and sampled at `simHz`; rendering interpolates between samples.
/// It depends only on the telemetry and the project, never on frame rate, scrubbing or the wall clock.
public struct CursorTrack: Sendable {
    public static let simHz = 240.0

    public struct Sample: Equatable, Sendable {
        /// Position in recording pixels.
        public var x: Double
        public var y: Double
        /// 0…1.
        public var opacity: Double
        /// Tilt in degrees (positive = clockwise).
        public var angle: Double
        public var shape: CursorShape
    }

    public struct Click: Equatable, Sendable {
        /// Timeline time of the mouse-down.
        public var t: Double
        public var x: Double
        public var y: Double
    }

    public private(set) var samples: [Sample]
    public private(set) var clicks: [Click]
    public let duration: Double

    /// Tuning constants (SPEC §3.5).
    public static let clickLockWindow = 0.06
    public static let idleDelay = 1.5
    public static let fadeOutDuration = 0.3
    public static let fadeInDuration = 0.15
    public static let loopDuration = 1.0
    /// Horizontal speed (recording px/s) that gives the full rotation.
    public static let rotationFullSpeed = 1500.0
    public static let rotationOmega = 12.0

    public init(events: [TelemetryEvent], timeMap: TimeMap, slices: [Slice], look: Look) {
        duration = timeMap.duration
        let dt = 1 / Self.simHz
        let count = max(Int((duration * Self.simHz).rounded(.up)) + 1, 1)

        // 1. Raw path in timeline time; events inside cuts are dropped.
        var rawT: [Double] = [], rawX: [Double] = [], rawY: [Double] = []
        var shapes: [(t: Double, shape: CursorShape)] = []
        var clicks: [Click] = []
        for e in events {
            switch e {
            case let .pos(s, x, y), let .up(s, _, x, y):
                if let t = timeMap.toTimeline(s) { rawT.append(t); rawX.append(x); rawY.append(y) }
            case let .down(s, _, x, y, _):
                if let t = timeMap.toTimeline(s) {
                    rawT.append(t); rawX.append(x); rawY.append(y)
                    clicks.append(Click(t: t, x: x, y: y))
                }
            case let .cursor(s, shape):
                // A shape change inside a cut takes effect where the recording continues.
                if let t = timeMap.toTimeline(s) ?? timeMap.timelineAtOrAfter(source: s) { shapes.append((t, shape)) }
            default:
                break
            }
        }
        // Stable sort by time (events from different sources can interleave).
        let order = rawT.indices.sorted { rawT[$0] == rawT[$1] ? $0 < $1 : rawT[$0] < rawT[$1] }
        rawT = order.map { rawT[$0] }; rawX = order.map { rawX[$0] }; rawY = order.map { rawY[$0] }
        shapes.sort { $0.t < $1.t }
        clicks.sort { $0.t < $1.t }
        self.clicks = clicks

        func raw(at t: Double) -> (Double, Double) {
            guard let first = rawT.first else { return (0, 0) }
            if t <= first { return (rawX[0], rawY[0]) }
            if t >= rawT[rawT.count - 1] { return (rawX[rawX.count - 1], rawY[rawY.count - 1]) }
            var lo = 0, hi = rawT.count - 1
            while hi - lo > 1 {
                let m = (lo + hi) / 2
                if rawT[m] <= t { lo = m } else { hi = m }
            }
            let span = rawT[hi] - rawT[lo]
            let w = span > 0 ? (t - rawT[lo]) / span : 0
            return (rawX[lo] + (rawX[hi] - rawX[lo]) * w, rawY[lo] + (rawY[hi] - rawY[lo]) * w)
        }

        // 2. Smoothing with a critically damped spring, per slice switchable.
        let omega = look.cursor.smoothingOverride ?? look.animation.cursor.omega
        let start = raw(at: 0)
        var follower = SpringFollower2D(omega: omega ?? 1, x: start.0, y: start.1)
        var xs = [Double](repeating: 0, count: count), ys = [Double](repeating: 0, count: count)
        var rawXs = xs, rawYs = ys
        var hiddenBySlice = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let t = Double(i) * dt
            let r = raw(at: t)
            rawXs[i] = r.0; rawYs[i] = r.1
            let slice = timeMap.entryIndex(atTimeline: t).flatMap { idx in slices.first { $0.id == timeMap.entries[idx].sliceID } }
            hiddenBySlice[i] = slice?.hideCursor ?? false
            if omega == nil || slice?.smoothMouse == false {
                follower.reset(x: r.0, y: r.1)
            } else if i > 0 {
                follower.advance(towardX: r.0, y: r.1, dt: dt)
            }
            xs[i] = follower.x; ys[i] = follower.y
        }

        // 3. Click lock: around each mouse-down the cursor sits exactly on the click point. The blend window
        //    grows with the smoothing lag (2/ω), so a soft cursor glides onto the click instead of jumping.
        let w = max(Self.clickLockWindow, omega.map { 2 / $0 } ?? 0)
        for c in clicks {
            let a = max(Int(((c.t - w) * Self.simHz).rounded(.down)), 0)
            let b = min(Int(((c.t + w) * Self.simHz).rounded(.up)), count - 1)
            guard a <= b else { continue }
            for i in a...b {
                let d = abs(Double(i) * dt - c.t)
                guard d < w else { continue }
                let k = 0.5 * (1 + cos(Double.pi * d / w))
                xs[i] += (c.x - xs[i]) * k
                ys[i] += (c.y - ys[i]) * k
            }
        }

        // 4. Loop: in the last second glide back to the start position (cubic ease).
        if look.cursor.loop, duration > Self.loopDuration {
            let from = Int(((duration - Self.loopDuration) * Self.simHz).rounded(.down))
            for i in max(from, 0)..<count {
                let u = min(max((Double(i) * dt - (duration - Self.loopDuration)) / Self.loopDuration, 0), 1)
                let e = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
                xs[i] += (xs[0] - xs[i]) * e
                ys[i] += (ys[0] - ys[i]) * e
            }
        }

        // 5. Opacity: hidden, hidden per slice, or fade out when idle.
        var opacity = [Double](repeating: 1, count: count)
        var current = 1.0
        var lastMove = 0.0
        var clickIndex = 0
        for i in 0..<count {
            let t = Double(i) * dt
            if i > 0, abs(rawXs[i] - rawXs[i - 1]) + abs(rawYs[i] - rawYs[i - 1]) > 0.5 { lastMove = t }
            while clickIndex < clicks.count, clicks[clickIndex].t <= t {
                lastMove = max(lastMove, clicks[clickIndex].t)
                clickIndex += 1
            }
            var target = 1.0
            if look.cursor.hideWhenIdle, t - lastMove > Self.idleDelay { target = 0 }
            if target < current { current = max(target, current - dt / Self.fadeOutDuration) }
            if target > current { current = min(target, current + dt / Self.fadeInDuration) }
            opacity[i] = (look.cursor.hidden || hiddenBySlice[i]) ? 0 : current
        }

        // 6. Rotation: tilt towards the horizontal movement, through its own spring.
        var angles = [Double](repeating: 0, count: count)
        if look.cursor.rotation.enabled, count > 1 {
            let spring = CriticalSpring(omega: Self.rotationOmega)
            var a = 0.0, v = 0.0
            let maxDeg = look.cursor.rotation.maxDegrees
            for i in 1..<count {
                let vx = (xs[i] - xs[i - 1]) / dt
                let target = min(max(vx / Self.rotationFullSpeed, -1), 1) * maxDeg
                (a, v) = spring.step(from: a, velocity: v, to: target, after: dt)
                angles[i] = a
            }
        }

        // 7. Shape.
        var result: [Sample] = []
        result.reserveCapacity(count)
        var shapeIndex = 0
        var shape: CursorShape = shapes.first?.shape ?? .arrow
        for i in 0..<count {
            let t = Double(i) * dt
            while shapeIndex < shapes.count, shapes[shapeIndex].t <= t {
                shape = shapes[shapeIndex].shape
                shapeIndex += 1
            }
            result.append(Sample(x: xs[i], y: ys[i], opacity: opacity[i], angle: angles[i],
                                 shape: look.cursor.alwaysPointer ? .arrow : shape))
        }
        samples = result
    }

    /// The cursor at timeline time `t` (linear interpolation; shape from the earlier sample).
    public func sample(at t: Double) -> Sample {
        guard samples.count > 1 else { return samples.first ?? Sample(x: 0, y: 0, opacity: 0, angle: 0, shape: .arrow) }
        let f = min(max(t, 0), duration) * Self.simHz
        let i = min(Int(f), samples.count - 2)
        let w = min(max(f - Double(i), 0), 1)
        let a = samples[i], b = samples[i + 1]
        return Sample(x: a.x + (b.x - a.x) * w, y: a.y + (b.y - a.y) * w, opacity: a.opacity + (b.opacity - a.opacity) * w,
                      angle: a.angle + (b.angle - a.angle) * w, shape: a.shape)
    }
}

extension TimeMap {
    /// Timeline time of the first visible source time at or after `s` (for things that happen inside a cut).
    public func timelineAtOrAfter(source s: Double) -> Double? {
        if let t = toTimeline(s) { return t }
        return entries.first { $0.sourceStart >= s }?.timelineStart
    }
}
