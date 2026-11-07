import CoreGraphics
import Foundation

/// How the webcam and the screen share the canvas (Phase 5 item 7).
public enum LayoutKind: String, Codable, Sendable, CaseIterable {
    /// The screen, with the webcam in a corner bubble.
    case overlay
    /// Screen on one side, webcam on the other.
    case split
    /// The webcam fills the canvas.
    case camera
    /// The screen only.
    case screen
}

/// A layout for a time range, anchored to **source** time like zooms, so it follows edits.
public struct LayoutSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sourceStart: Double
    public var sourceEnd: Double
    public var kind: LayoutKind

    public init(id: String, sourceStart: Double, sourceEnd: Double, kind: LayoutKind) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.kind = kind
    }
}

/// Webcam settings (part of the look).
public struct WebcamLook: Codable, Equatable, Sendable {
    public enum Shape: String, Codable, Sendable, CaseIterable { case circle, rounded }
    public enum Corner: String, Codable, Sendable, CaseIterable { case bottomRight, bottomLeft, topRight, topLeft }

    /// The layout wherever no layout block is set.
    public var layout: LayoutKind = .overlay
    public var shape: Shape = .circle
    public var corner: Corner = .bottomRight
    /// Bubble size as a fraction of the canvas' short side.
    public var size = 0.26
    /// Show the webcam like a mirror (as people see themselves in video calls).
    public var mirror = true
    /// Move the bubble to another corner while the cursor is under it.
    public var avoidCursor = true
    public var shadow = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WebcamLook()
        layout = try c.decodeIfPresent(LayoutKind.self, forKey: .layout) ?? d.layout
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? d.shape
        corner = try c.decodeIfPresent(Corner.self, forKey: .corner) ?? d.corner
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? d.mirror
        avoidCursor = try c.decodeIfPresent(Bool.self, forKey: .avoidCursor) ?? d.avoidCursor
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? d.shadow
    }
}

/// Where the screen and the webcam are at each moment, with animated changes between layouts and corners.
public struct CameraLayoutTrack: Equatable, Sendable {
    public struct State: Equatable, Sendable {
        /// The (cropped) recording on the canvas, normalised.
        public var screenRect: CGRect
        /// The webcam on the canvas, normalised (the picture fills it, cropped as needed).
        public var webcam: CGRect
        /// Corner radius as a fraction of the webcam rectangle's shorter side in pixels (0.5 = circle).
        public var radius: Double
        public var opacity: Double
    }

    public static let transition = 0.5
    public static let cornerMove = 0.4

    public let hasCamera: Bool
    private let base: Layout
    private let look: WebcamLook
    private let padding: Double
    /// Timeline spans with their layout, covering the whole timeline.
    public private(set) var spans: [(start: Double, end: Double, kind: LayoutKind)] = []
    /// Times where the bubble moves to another corner.
    public private(set) var cornerChanges: [(t: Double, corner: WebcamLook.Corner)] = []

    public static func == (a: Self, b: Self) -> Bool {
        a.hasCamera == b.hasCamera && a.base == b.base && a.look == b.look && a.padding == b.padding
            && a.spans.elementsEqual(b.spans) { $0 == $1 } && a.cornerChanges.elementsEqual(b.cornerChanges) { $0 == $1 }
    }

    public init(project: Project, timeMap: TimeMap, layout: Layout, cursor: CursorTrack, camera: CameraTrack, hasCamera: Bool) {
        self.hasCamera = hasCamera
        base = layout
        look = project.look.webcam
        padding = project.look.frame.padding
        guard hasCamera else { return }

        // Layout blocks in timeline time, gaps filled with the default layout.
        var blocks: [(Double, Double, LayoutKind)] = []
        for s in project.layouts {
            for r in timeMap.timelineIntervals(sourceStart: s.sourceStart, sourceEnd: s.sourceEnd) { blocks.append((r.lowerBound, r.upperBound, s.kind)) }
        }
        blocks.sort { $0.0 < $1.0 }
        var t = 0.0
        for (a, b, k) in blocks where b > t {
            if a > t + 1e-6 { spans.append((t, a, look.layout)) }
            spans.append((max(a, t), b, k))
            t = b
        }
        if t < timeMap.duration || spans.isEmpty { spans.append((t, max(timeMap.duration, t), look.layout)) }

        // Corner changes: while the cursor (as seen after zooming) is under the bubble, use another corner.
        guard look.avoidCursor else { return }
        var corner = look.corner
        var lastChange = -10.0
        var time = 0.0
        while time < timeMap.duration {
            let c = cursor.sample(at: time)
            if c.opacity > 0.5, kind(at: time) == .overlay {
                let cam = camera.state(at: time)
                let p = layout.canvasPoint(fromRecordingPixels: CGPoint(x: c.x, y: c.y))
                let seen = CGPoint(x: (p.x - cam.center.x) * cam.scale + 0.5, y: (p.y - cam.center.y) * cam.scale + 0.5)
                let guardBand = 0.05
                if bubble(corner).insetBy(dx: -guardBand, dy: -guardBand * layout.canvasAspect).contains(seen), time - lastChange > 1.5 {
                    let options = [Self.flipped(corner, horizontal: true), Self.flipped(corner, horizontal: false)]
                    if let free = options.first(where: { !bubble($0).insetBy(dx: -guardBand, dy: -guardBand).contains(seen) }) {
                        corner = free
                        cornerChanges.append((time, corner))
                        lastChange = time
                    }
                } else if corner != look.corner, time - lastChange > 3, !bubble(look.corner).insetBy(dx: -guardBand, dy: -guardBand).contains(seen) {
                    corner = look.corner                   // back home once the cursor has left
                    cornerChanges.append((time, corner))
                    lastChange = time
                }
            }
            time += 0.1
        }
    }

    static func flipped(_ c: WebcamLook.Corner, horizontal: Bool) -> WebcamLook.Corner {
        switch (c, horizontal) {
        case (.bottomRight, true): .bottomLeft
        case (.bottomLeft, true): .bottomRight
        case (.topRight, true): .topLeft
        case (.topLeft, true): .topRight
        case (.bottomRight, false): .topRight
        case (.bottomLeft, false): .topLeft
        case (.topRight, false): .bottomRight
        case (.topLeft, false): .bottomLeft
        }
    }

    public func kind(at t: Double) -> LayoutKind {
        guard hasCamera else { return .screen }
        return spans.last { $0.start <= t }?.kind ?? look.layout
    }

    // MARK: Targets (canvas units: width = aspect, height = 1; returned normalised)

    private func normalised(_ r: CGRect) -> CGRect {
        let a = base.canvasAspect
        return CGRect(x: r.minX / a, y: r.minY, width: r.width / a, height: r.height)
    }

    /// The overlay bubble at a corner.
    func bubble(_ corner: WebcamLook.Corner) -> CGRect {
        let a = base.canvasAspect, short = min(a, 1)
        let s = min(max(look.size, 0.08), 0.6) * short, m = 0.04 * short
        let right = corner == .bottomRight || corner == .topRight, bottom = corner == .bottomRight || corner == .bottomLeft
        return normalised(CGRect(x: right ? a - m - s : m, y: bottom ? 1 - m - s : m, width: s, height: s))
    }

    /// Split screen: the screen and the webcam side by side (stacked when the canvas is portrait). The screen
    /// gets up to 64 % of the room; the webcam card matches its height (or width) and the pair is centred.
    func split() -> (screen: CGRect, webcam: CGRect) {
        let a = base.canvasAspect, short = min(a, 1)
        let pad = max(min(max(padding, 0), 0.4), 0.04) * short, gap = pad * 0.6
        let cw = max(Double(base.recordingSize.width * base.crop.width), 1), ch = max(Double(base.recordingSize.height * base.crop.height), 1)
        if a >= 1 {
            let availW = a - 2 * pad - gap, availH = 1 - 2 * pad
            let f = min(availW * 0.64 / cw, availH / ch)
            let sw = cw * f, sh = ch * f
            let camW = min(availW - sw, sh * 0.8)
            let x0 = (a - (sw + gap + camW)) / 2, y0 = (1 - sh) / 2
            return (normalised(CGRect(x: x0, y: y0, width: sw, height: sh)),
                    normalised(CGRect(x: x0 + sw + gap, y: y0, width: camW, height: sh)))
        }
        let availW = a - 2 * pad, availH = 1 - 2 * pad - gap
        let f = min(availW / cw, availH * 0.6 / ch)
        let sw = cw * f, sh = ch * f
        let camH = min(availH - sh, sw * 0.8)
        let x0 = (a - sw) / 2, y0 = (1 - (sh + gap + camH)) / 2
        return (normalised(CGRect(x: x0, y: y0, width: sw, height: sh)),
                normalised(CGRect(x: x0, y: y0 + sh + gap, width: sw, height: camH)))
    }

    func target(_ kind: LayoutKind, corner: WebcamLook.Corner) -> State {
        let bubbleRadius = look.shape == .circle ? 0.5 : 0.2
        switch kind {
        case .overlay:
            return State(screenRect: base.screenRect, webcam: bubble(corner), radius: bubbleRadius, opacity: 1)
        case .screen:
            let b = bubble(corner)
            return State(screenRect: base.screenRect, webcam: b.insetBy(dx: b.width * 0.3, dy: b.height * 0.3), radius: bubbleRadius, opacity: 0)
        case .camera:
            return State(screenRect: base.screenRect, webcam: CGRect(x: 0, y: 0, width: 1, height: 1), radius: 0, opacity: 1)
        case .split:
            let s = split()
            return State(screenRect: s.screen, webcam: s.webcam, radius: 0.06, opacity: 1)
        }
    }

    // MARK: State

    static func ease(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

    static func mix(_ a: State, _ b: State, _ k: Double) -> State {
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        func r(_ x: CGRect, _ y: CGRect) -> CGRect {
            CGRect(x: l(x.minX, y.minX), y: l(x.minY, y.minY), width: l(x.width, y.width), height: l(x.height, y.height))
        }
        return State(screenRect: r(a.screenRect, b.screenRect), webcam: r(a.webcam, b.webcam), radius: l(a.radius, b.radius), opacity: l(a.opacity, b.opacity))
    }

    /// The bubble's corner at `t`, eased between corners.
    private func overlay(at t: Double, kind: LayoutKind) -> State {
        guard let i = cornerChanges.lastIndex(where: { $0.t <= t }) else { return target(kind, corner: look.corner) }
        let from = i > 0 ? cornerChanges[i - 1].corner : look.corner
        let k = Self.ease((t - cornerChanges[i].t) / Self.cornerMove)
        return Self.mix(target(kind, corner: from), target(kind, corner: cornerChanges[i].corner), k)
    }

    public func state(at t: Double) -> State {
        guard hasCamera, let i = spans.lastIndex(where: { $0.start <= t }) ?? (spans.isEmpty ? nil : 0) else {
            return State(screenRect: base.screenRect, webcam: .zero, radius: 0, opacity: 0)
        }
        let now = overlay(at: t, kind: spans[i].kind)
        guard i > 0, spans[i - 1].kind != spans[i].kind, t - spans[i].start < Self.transition else { return now }
        let before = overlay(at: t, kind: spans[i - 1].kind)
        return Self.mix(before, now, Self.ease((t - spans[i].start) / Self.transition))
    }
}

public extension Project {
    /// A new unique layout id ("L1", "L2", …).
    func newLayoutID() -> String {
        let used = Set(layouts.map(\.id))
        var n = 1
        while used.contains("L\(n)") { n += 1 }
        return "L\(n)"
    }

    private func layoutSpan(_ s: LayoutSegment, _ map: TimeMap) -> ClosedRange<Double>? {
        let iv = map.timelineIntervals(sourceStart: s.sourceStart, sourceEnd: s.sourceEnd)
        guard let a = iv.first?.lowerBound, let b = iv.last?.upperBound else { return nil }
        return a...b
    }

    /// Free timeline room around a layout block (blocks never overlap).
    func layoutRoom(_ id: String, map: TimeMap) -> ClosedRange<Double> {
        let mine = layouts.first { $0.id == id }.flatMap { layoutSpan($0, map) }?.lowerBound ?? 0
        var lo = 0.0, hi = map.duration
        for s in layouts where s.id != id {
            guard let r = layoutSpan(s, map) else { continue }
            if r.lowerBound < mine || (r.lowerBound == mine && s.id < id) { lo = max(lo, r.upperBound) } else { hi = min(hi, r.lowerBound) }
        }
        return lo...max(hi, lo)
    }

    /// Adds a layout block at timeline time `t` (up to `length` seconds, fitted into the free room).
    @discardableResult
    mutating func addLayout(_ kind: LayoutKind, atTimeline t: Double, length: Double = 4) throws -> String {
        let map = TimeMap(slices: timeline.slices)
        var lo = 0.0, hi = map.duration
        for s in layouts {
            guard let r = layoutSpan(s, map) else { continue }
            if r.lowerBound <= t && t < r.upperBound { throw EditError.noRoom }
            if r.upperBound <= t { lo = max(lo, r.upperBound) } else { hi = min(hi, r.lowerBound) }
        }
        let start = min(max(t, lo), hi)
        let end = min(start + length, hi)
        guard end - start >= 0.25 else { throw EditError.noRoom }
        let id = newLayoutID()
        layouts.append(LayoutSegment(id: id, sourceStart: map.toSource(start), sourceEnd: map.toSource(end), kind: kind))
        return id
    }

    mutating func moveLayout(_ id: String, toTimelineStart t: Double) throws {
        guard let i = layouts.firstIndex(where: { $0.id == id }) else { throw EditError.unknownLayout }
        let map = TimeMap(slices: timeline.slices)
        let room = layoutRoom(id, map: map)
        let length = min(map.timelineIntervals(sourceStart: layouts[i].sourceStart, sourceEnd: layouts[i].sourceEnd)
            .reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }, room.upperBound - room.lowerBound)
        let start = min(max(t, room.lowerBound), max(room.upperBound - length, room.lowerBound))
        layouts[i].sourceStart = map.toSource(start)
        layouts[i].sourceEnd = max(map.toSource(start + max(length, 0.1)), layouts[i].sourceStart + 0.05)
    }

    mutating func resizeLayout(_ id: String, start: Bool, toTimeline t: Double) throws {
        guard let i = layouts.firstIndex(where: { $0.id == id }) else { throw EditError.unknownLayout }
        let map = TimeMap(slices: timeline.slices)
        let room = layoutRoom(id, map: map)
        let s = map.toSource(min(max(t, room.lowerBound), room.upperBound))
        if start {
            layouts[i].sourceStart = min(s, layouts[i].sourceEnd - 0.25)
        } else {
            layouts[i].sourceEnd = max(s, layouts[i].sourceStart + 0.25)
        }
    }
}

public extension PreparedProject {
    /// The layout actually used at timeline time `t`: camera layouts can move the screen (split screen).
    func effectiveLayout(at t: Double) -> Layout {
        var l = layout
        l.screenRect = layouts.state(at: t).screenRect
        return l
    }

    /// A zoom camera state moved along with the screen when a camera layout moves it, so zooms still aim at
    /// the same part of the recording.
    func adjusted(_ c: CameraTrack.State, at t: Double) -> CameraTrack.State {
        let from = layout.screenRect, to = layouts.state(at: t).screenRect
        guard from != to, from.width > 0, from.height > 0 else { return c }
        var out = c
        // Split screen already resizes the screen: the fill-the-frame zoom fades out as the screen moves aside.
        if camera.base > 1 {
            let splitWidth = layouts.split().screen.width
            let k = min(max((from.width - to.width) / max(from.width - splitWidth, 1e-6), 0), 1)
            out.scale = max(c.scale / pow(camera.base, k), 1)
        }
        let x = to.minX + (c.center.x - from.minX) * to.width / from.width
        let y = to.minY + (c.center.y - from.minY) * to.height / from.height
        let h = 0.5 / max(out.scale, 1)
        out.center = CGPoint(x: min(max(x, h), 1 - h), y: min(max(y, h), 1 - h))
        return out
    }
}
