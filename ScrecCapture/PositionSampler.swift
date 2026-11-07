import AppKit
import ScrecCore
import QuartzCore

/// Writes the cursor position (and cursor shape changes) at the display refresh rate (REC-13).
///
/// It runs on the display link of the captured screen, so on a ProMotion display it samples at 120 Hz.
/// Each tick reads `NSEvent.mouseLocation` and stamps it with the host time **at the moment of reading**
/// (not the display link's frame timestamp, which describes the previous frame).
@MainActor
public final class PositionSampler: NSObject {
    private let screen: NSScreen
    private let clock: RecordingClock
    private let writer: TelemetryWriter
    private let mapper: MapperBox
    private let shapes = CursorShapeDetector()
    private var link: CADisplayLink?
    private var lastShape: CursorShape?
    private var lastCursorKey: CursorShapeDetector.Key?

    public private(set) var ticks = 0

    public init(screen: NSScreen, clock: RecordingClock, writer: TelemetryWriter, mapper: MapperBox) {
        self.screen = screen
        self.clock = clock
        self.writer = writer
        self.mapper = mapper
    }

    /// Nominal sample rate: the screen's refresh rate.
    public var sampleHz: Double { Double(max(screen.maximumFramesPerSecond, 60)) }

    public func start() {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    public func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let host = HostTime.now
        guard let t = clock.sourceTime(host: host) else { return }
        ticks += 1
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cg = CoordinateMapper.cgPoint(fromAppKit: NSEvent.mouseLocation, mainDisplayHeight: mainHeight)
        let p = mapper.mapper.recordingPixels(fromCG: cg)
        writer.append(.pos(t: t, x: Double(p.x), y: Double(p.y)))

        // Cursor shape: only look closer when the system cursor's hotspot or size changed.
        guard let cursor = NSCursor.currentSystem else { return }
        let key = CursorShapeDetector.Key(cursor)
        if key != lastCursorKey {
            lastCursorKey = key
            let shape = shapes.shape(of: cursor, key: key)
            if shape != lastShape {
                lastShape = shape
                writer.append(.cursor(t: t, shape: shape))
            }
        }
    }
}

/// Recognises the system cursor by comparing it with AppKit's standard cursors:
/// first by hotspot and image size, then by a tiny 8×8 alpha thumbnail when several candidates match.
@MainActor
final class CursorShapeDetector {
    struct Key: Hashable {
        var hotX: Int, hotY: Int, w: Int, h: Int
        init(_ c: NSCursor) {
            hotX = Int(c.hotSpot.x.rounded())
            hotY = Int(c.hotSpot.y.rounded())
            w = Int(c.image.size.width.rounded())
            h = Int(c.image.size.height.rounded())
        }
    }

    private struct Reference {
        var shape: CursorShape
        var key: Key
        var thumb: [UInt8]
    }

    private lazy var references: [Reference] = {
        let list: [(CursorShape, NSCursor)] = [
            (.arrow, .arrow), (.iBeam, .iBeam), (.pointingHand, .pointingHand), (.openHand, .openHand),
            (.closedHand, .closedHand), (.resizeLeftRight, .resizeLeftRight), (.resizeUpDown, .resizeUpDown),
            (.crosshair, .crosshair), (.notAllowed, .operationNotAllowed), (.contextMenu, .contextualMenu),
            (.dragCopy, .dragCopy), (.dragLink, .dragLink),
        ]
        return list.map { Reference(shape: $0.0, key: Key($0.1), thumb: Self.thumbnail($0.1.image)) }
    }()

    private var cache: [Key: CursorShape] = [:]

    func shape(of cursor: NSCursor, key: Key) -> CursorShape {
        if let cached = cache[key] { return cached }
        let candidates = references.filter { $0.key == key }
        let result: CursorShape
        switch candidates.count {
        case 0: result = .unknown
        case 1: result = candidates[0].shape
        default:
            let thumb = Self.thumbnail(cursor.image)
            result = candidates.min { Self.distance($0.thumb, thumb) < Self.distance($1.thumb, thumb) }!.shape
        }
        cache[key] = result
        return result
    }

    private static func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }

    private static func thumbnail(_ image: NSImage) -> [UInt8] {
        let n = 8
        var pixels = [UInt8](repeating: 0, count: n * n)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return pixels
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        return pixels
    }
}

/// Window capture: polls the captured window's frame 10× per second. When it moves or resizes, the
/// mapping is updated and a `frame` event is written (window frame in global points × scale).
@MainActor
public final class WindowFrameTracker {
    private let windowID: CGWindowID
    private let clock: RecordingClock
    private let writer: TelemetryWriter
    private let mapper: MapperBox
    private let pointPixelScale: Double
    private var timer: Timer?
    private var lastFrame: CGRect?

    public init(windowID: CGWindowID, clock: RecordingClock, writer: TelemetryWriter, mapper: MapperBox, pointPixelScale: Double) {
        self.windowID = windowID
        self.clock = clock
        self.writer = writer
        self.mapper = mapper
        self.pointPixelScale = pointPixelScale
    }

    public func start() {
        lastFrame = mapper.mapper.captureRect
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public static func currentFrame(of windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    private func poll() {
        guard let frame = Self.currentFrame(of: windowID), frame != lastFrame else { return }
        lastFrame = frame
        mapper.update { $0.captureRect = frame }
        guard let t = clock.sourceTime(host: HostTime.now) else { return }
        let s = pointPixelScale
        writer.append(.frame(t: t, rect: [frame.minX * s, frame.minY * s, frame.width * s, frame.height * s].map { Double($0) }))
    }
}
