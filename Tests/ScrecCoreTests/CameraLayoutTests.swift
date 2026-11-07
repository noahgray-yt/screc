import CoreGraphics
import Foundation
import Testing
@testable import ScrecCore

@Suite("Camera layouts (Phase 5)")
struct CameraLayoutTests {
    func prepared(_ edit: (inout Project) throws -> Void = { _ in }, events: [TelemetryEvent]? = nil, camera: Bool = true) throws -> PreparedProject {
        var p = Project.fresh(name: "t", duration: 20)
        try edit(&p)
        let ev = events ?? stride(from: 0.0, to: 20, by: 1 / 60.0).map { .pos(t: $0, x: 400, y: 300) }
        return PreparedProject(project: p, recordingSize: CGSize(width: 1600, height: 1000), pointPixelScale: 1, events: ev, hasCamera: camera)
    }

    @Test func noCameraMeansScreenOnly() throws {
        let p = try prepared(camera: false)
        let s = p.layouts.state(at: 5)
        #expect(s.opacity == 0)
        #expect(s.screenRect == p.layout.screenRect)
    }

    @Test func defaultOverlayBubbleSitsInTheCorner() throws {
        let p = try prepared()
        let s = p.layouts.state(at: 5)
        #expect(s.opacity == 1 && s.radius == 0.5)
        #expect(s.webcam.maxX > 0.9 && s.webcam.maxY > 0.9)
        // A square in pixels.
        #expect(abs(s.webcam.width * p.layout.canvasAspect - s.webcam.height) < 1e-9)
    }

    @Test func blocksSwitchLayoutsWithATransition() throws {
        let p = try prepared { p in
            try p.addLayout(.split, atTimeline: 5, length: 5)
            try p.addLayout(.camera, atTimeline: 12, length: 3)
        }
        #expect(p.layouts.kind(at: 2) == .overlay && p.layouts.kind(at: 7) == .split && p.layouts.kind(at: 13) == .camera)
        let split = p.layouts.state(at: 7)
        #expect(split.webcam.minX > split.screenRect.maxX)                              // side by side
        #expect(abs(split.webcam.height - split.screenRect.height) < 1e-9)             // same height
        let full = p.layouts.state(at: 14)
        #expect(full.webcam == CGRect(x: 0, y: 0, width: 1, height: 1))
        let mid = p.layouts.state(at: 5 + CameraLayoutTrack.transition / 2)          // halfway into split
        #expect(mid.screenRect.width < p.layout.screenRect.width && mid.screenRect.width > split.screenRect.width)
    }

    @Test func layoutBlocksNeverOverlap() throws {
        var p = Project.fresh(name: "t", duration: 20)
        let a = try p.addLayout(.split, atTimeline: 2, length: 4)
        try p.addLayout(.camera, atTimeline: 10, length: 4)
        #expect(throws: EditError.noRoom) { try p.addLayout(.screen, atTimeline: 3) }
        try p.moveLayout(a, toTimelineStart: 9)
        #expect(abs(p.layouts[0].sourceStart - 6) < 1e-9)                             // stops before the next block
    }

    @Test func bubbleMovesAwayFromTheCursor() throws {
        // Cursor parked in the bottom-right corner of the recording from 5 s on.
        let events: [TelemetryEvent] = stride(from: 0.0, to: 20, by: 1 / 60.0).map { t in t < 5 ? .pos(t: t, x: 400, y: 300) : .pos(t: t, x: 1590, y: 990) }
        let p = try prepared(events: events)
        #expect(p.layouts.cornerChanges.first?.corner == .bottomLeft)
        #expect(p.layouts.state(at: 12).webcam.minX < 0.1)
        var look = Project.fresh(name: "t", duration: 20)
        look.look.webcam.avoidCursor = false
        let fixed = PreparedProject(project: look, recordingSize: CGSize(width: 1600, height: 1000), pointPixelScale: 1, events: events, hasCamera: true)
        #expect(fixed.layouts.cornerChanges.isEmpty)
    }

    @Test func portraitSplitStacks() throws {
        let p = try prepared { p in
            p.look.aspect = .vertical
            try p.addLayout(.split, atTimeline: 0, length: 20)
        }
        let s = p.layouts.state(at: 5)
        #expect(s.webcam.minY > s.screenRect.maxY)                                      // stacked
        #expect(abs(s.webcam.width - s.screenRect.width) < 1e-9)
    }
}

@Suite("Reframing (fill the frame)")
struct ReframingTests {
    func prepared(fill: Bool, zooms: [ZoomSegment] = [], cursorX: Double = 1500) -> PreparedProject {
        var p = Project.fresh(name: "t", duration: 10)
        p.look.aspect = .vertical
        p.look.fillFrame = fill
        p.zooms = zooms
        let events: [TelemetryEvent] = stride(from: 0.0, to: 10, by: 1 / 60.0).map { .pos(t: $0, x: cursorX, y: 500) }
        return PreparedProject(project: p, recordingSize: CGSize(width: 1600, height: 1000), pointPixelScale: 1, events: events)
    }

    @Test func fillCoversTheCanvasWithTheScreen() {
        let off = prepared(fill: false).camera.state(at: 5)
        #expect(off.scale == 1)
        let p = prepared(fill: true)
        let s = p.camera.state(at: 5)
        let r = p.layout.screenRect
        #expect(abs(s.scale - CameraTrack.fillScale(r)) < 1e-6)
        // The visible area stays inside the screen: no background shows.
        let h = 0.5 / s.scale
        #expect(s.center.x - h >= r.minX - 1e-9 && s.center.x + h <= r.maxX + 1e-9)
        #expect(s.center.y - h >= r.minY - 1e-9 && s.center.y + h <= r.maxY + 1e-9)
    }

    @Test func fillFollowsTheCursor() {
        let right = prepared(fill: true, cursorX: 1500).camera.state(at: 5).center.x
        let left = prepared(fill: true, cursorX: 100).camera.state(at: 5).center.x
        #expect(right > left + 0.2)
    }

    @Test func zoomsGoDeeperFromTheFilledFrame() {
        let p = prepared(fill: true, zooms: [ZoomSegment(id: "Z", sourceStart: 2, sourceEnd: 8, scale: 2)])
        let fill = CameraTrack.fillScale(p.layout.screenRect)
        #expect(abs(p.camera.state(at: 6).scale - fill * 1.5) < 0.01)
        #expect(abs(p.camera.state(at: 0.5).scale - fill) < 1e-6)
    }
}
