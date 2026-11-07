import CoreGraphics
import Foundation

/// The camera (zoom transform) for every timeline moment (ARCHITECTURE §7.2).
///
/// - **Scale** follows the zoom blocks with critically damped spring steps (SPEC §3.3), evaluated in closed
///   form: at each change of target the current value *and* velocity carry over. If a zoom ends and the next
///   one starts before the zoom-out could settle, the camera goes straight to the next zoom.
/// - **Center** (normalised canvas coordinates) aims at the cursor when a zoom starts, then follows it with a
///   dead zone; manual zooms aim at their fixed point. It is spring-smoothed and simulated at `simHz`.
/// - The visible region always stays inside the canvas: `c ∈ [1/(2z), 1 − 1/(2z)]`.
/// - **Fill the frame** (reframing): the resting scale is `fill`, just enough for the screen to cover the canvas,
///   the view follows the cursor, and stays inside the screen (no background shows). Zoom blocks go deeper from
///   there: `fill × (1 + (z − 1) / 2)`.
public struct CameraTrack: Sendable {
    public static let simHz = 240.0

    public struct Config: Equatable, Sendable {
        /// Central fraction of the zoomed view where cursor movement does not pan (SPEC §3.3, range 0.3–0.5).
        public var followDeadZone = 0.4
        /// The cursor is kept at least this far (fraction of the view) from the view edge. With the dead zone at
        /// 0.4 the settled cursor is always ≥ 0.3 from the edge, so this only matters for dead zones above 0.8.
        public var followEdgeMargin = 0.1
        /// Auto zooms first aim where the cursor is this long after the block starts (≈ the click, leadTime).
        public var aimDelay = 0.5
        public init() {}
    }

    public struct State: Equatable, Sendable {
        public var scale: Double
        public var center: CGPoint
    }

    struct Block: Equatable {
        var start: Double
        var end: Double
        var scale: Double
        var manualCenter: CGPoint?    // canvas coordinates
    }

    /// Target-scale breakpoints with the spring state at each one.
    struct Breakpoint {
        var time: Double
        var target: Double
        var x: Double
        var v: Double
    }

    public let duration: Double
    public let spring: CriticalSpring
    /// Resting scale (1, or the fill scale when reframing).
    public let base: Double
    /// Where the view must stay when reframing (the screen on the canvas); nil = the whole canvas.
    let bounds: CGRect?
    private let blocks: [Block]
    private let breakpoints: [Breakpoint]
    private let centersX: [Double]
    private let centersY: [Double]

    public init(zooms: [ZoomSegment], timeMap: TimeMap, cursor: CursorTrack, layout: Layout,
                style: AnimationLook.Screen, config: Config = Config(), fillFrame: Bool = false) {
        duration = timeMap.duration
        spring = CriticalSpring(omega: style.zoomOmega)
        let r = layout.screenRect
        let fill = fillFrame ? Self.fillScale(r) : 1
        base = fill
        bounds = fillFrame && fill > 1.0001 ? r : nil
        let bounds = self.bounds

        // Zoom blocks in timeline time. A zoom across a cut becomes several blocks.
        var blocks: [Block] = []
        for z in zooms {
            let manual: CGPoint? = (z.mode == .manual && z.manualCenter?.count == 2)
                ? layout.canvasPoint(fromRecordingPixels: CGPoint(x: z.manualCenter![0] * Double(layout.recordingSize.width),
                                                                  y: z.manualCenter![1] * Double(layout.recordingSize.height)))
                : nil
            for r in timeMap.timelineIntervals(sourceStart: z.sourceStart, sourceEnd: z.sourceEnd) where r.upperBound > r.lowerBound {
                let zoom = max(z.scale, 1)
                let scale = fillFrame ? min(fill * (1 + (zoom - 1) / 2), 8) : zoom
                blocks.append(Block(start: r.lowerBound, end: r.upperBound, scale: scale, manualCenter: manual))
            }
        }
        blocks.sort { $0.start < $1.start }
        self.blocks = blocks

        // Target-scale breakpoints. Gaps shorter than the settle time do not zoom out in between.
        var points: [(Double, Double)] = []
        for (i, b) in blocks.enumerated() {
            points.append((b.start, b.scale))
            let next = i + 1 < blocks.count ? blocks[i + 1] : nil
            if let next, next.start - b.end < spring.settleTime { continue }
            points.append((b.end, fill))
        }
        var bps: [Breakpoint] = [Breakpoint(time: 0, target: fill, x: fill, v: 0)]
        var x = fill, v = 0.0, target = fill, lastTime = 0.0
        for (time, newTarget) in points {
            (x, v) = spring.step(from: x, velocity: v, to: target, after: max(time - lastTime, 0))
            bps.append(Breakpoint(time: time, target: newTarget, x: x, v: v))
            target = newTarget
            lastTime = time
        }
        breakpoints = bps

        // Center simulation.
        let dt = 1 / Self.simHz
        let count = max(Int((duration * Self.simHz).rounded(.up)) + 1, 1)
        var cx = [Double](repeating: 0.5, count: count), cy = cx
        var follower = SpringFollower2D(omega: style.panOmega, x: 0.5, y: 0.5)
        var aim: CGPoint?
        var activeBlock: Int?
        for i in 0..<count {
            let t = Double(i) * dt
            let blockIndex = blocks.lastIndex { $0.start <= t && t < $0.end }
            let targetScale = Self.targetScale(at: t, breakpoints: bps)
            var goal = bounds.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 0.5, y: 0.5)
            if targetScale > 1.0001 {
                // While zoomed (also in a short gap between chained zooms) keep framing the last block.
                let b = blockIndex.map { blocks[$0] } ?? activeBlock.map { blocks[$0] }
                let h = 0.5 / targetScale
                if let manual = b?.manualCenter {
                    goal = manual
                } else {
                    let cs = cursor.sample(at: t)
                    let p = layout.canvasPoint(fromRecordingPixels: CGPoint(x: cs.x, y: cs.y))
                    if blockIndex != activeBlock || aim == nil, let bi = blockIndex {
                        // Entering a block: aim where the cursor will be at about the click.
                        let at = min(blocks[bi].start + config.aimDelay, blocks[bi].end)
                        let ac = cursor.sample(at: at)
                        aim = layout.canvasPoint(fromRecordingPixels: CGPoint(x: ac.x, y: ac.y))
                    }
                    var a = aim ?? p
                    // Dead zone: move the aim only as far as needed to bring the cursor back inside it.
                    let dz = min(config.followDeadZone, 1 - 2 * config.followEdgeMargin) * h
                    let dx = Double(p.x - a.x), dy = Double(p.y - a.y)
                    if abs(dx) > dz { a.x = p.x - (dx > 0 ? dz : -dz) }
                    if abs(dy) > dz { a.y = p.y - (dy > 0 ? dz : -dz) }
                    aim = a
                    goal = a
                }
                goal = Self.clamp(goal, half: h, bounds: bounds)
                if let blockIndex { activeBlock = blockIndex }
            } else {
                aim = nil
                activeBlock = nil
            }
            if i > 0 { follower.advance(towardX: Double(goal.x), y: Double(goal.y), dt: dt) }
            cx[i] = follower.x
            cy[i] = follower.y
        }
        centersX = cx
        centersY = cy
    }

    static func targetScale(at t: Double, breakpoints: [Breakpoint]) -> Double {
        breakpoints.last { $0.time <= t }?.target ?? 1
    }

    /// The scale at which the screen rectangle covers the whole canvas.
    public static func fillScale(_ r: CGRect) -> Double {
        guard r.width > 0, r.height > 0 else { return 1 }
        return min(max(1 / r.width, 1 / r.height, 1), 8)
    }

    /// Keeps a view of half-size `h` inside the canvas and, when reframing, inside the screen.
    static func clamp(_ p: CGPoint, half h: Double, bounds: CGRect?) -> CGPoint {
        var x = min(max(p.x, h), 1 - h), y = min(max(p.y, h), 1 - h)
        if let b = bounds {
            x = b.width >= 2 * h ? min(max(x, b.minX + h), b.maxX - h) : b.midX
            y = b.height >= 2 * h ? min(max(y, b.minY + h), b.maxY - h) : b.midY
        }
        return CGPoint(x: x, y: y)
    }

    /// Scale at timeline time `t` (closed form).
    public func scale(at t: Double) -> Double {
        guard let i = breakpoints.lastIndex(where: { $0.time <= t }) else { return base }
        let b = breakpoints[i]
        return spring.step(from: b.x, velocity: b.v, to: b.target, after: t - b.time).x
    }

    /// Camera at timeline time `t`. The center is clamped so the view never leaves the canvas.
    public func state(at t: Double) -> State {
        let z = max(scale(at: t), 1)
        let f = min(max(t, 0), duration) * Self.simHz
        let i = min(Int(f), max(centersX.count - 2, 0))
        let w = centersX.count > 1 ? min(max(f - Double(i), 0), 1) : 0
        let j = min(i + 1, centersX.count - 1)
        let x = centersX[i] + (centersX[j] - centersX[i]) * w
        let y = centersY[i] + (centersY[j] - centersY[i]) * w
        return State(scale: z, center: Self.clamp(CGPoint(x: x, y: y), half: 0.5 / z, bounds: bounds))
    }
}
