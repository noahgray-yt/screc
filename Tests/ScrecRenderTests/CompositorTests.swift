import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Testing
@testable import ScrecCore
@testable import ScrecRender

/// Renders real frames on the GPU (headless) and checks pixels.
@Suite("Compositor (ARCHITECTURE §9)", .serialized)
struct CompositorTests {
    let device = MTLCreateSystemDefaultDevice()!

    /// A 320×180 4:2:0 video-range frame filled with one grey level.
    func greyFrame(y: UInt8 = 180) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(b, 0)!
        memset(luma, Int32(y), CVPixelBufferGetBytesPerRowOfPlane(b, 0) * 180)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(b, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(b, 1) * 90)
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    func prepared(zoom: Bool = false, look edit: (inout Look) -> Void = { _ in }) -> PreparedProject {
        var project = Project.fresh(name: "test", duration: 4)
        project.look.background.kind = .color
        project.look.background.color = "#FF0000"
        project.look.frame.shadow.amount = 0
        project.look.frame.cornerRadius = 0
        project.look.cursor.clickEffect = .none
        project.look.animation.cursor = .none
        edit(&project.look)
        if zoom { project.zooms = [ZoomSegment(id: "Z", sourceStart: 0, sourceEnd: 4, scale: 2)] }
        let events: [TelemetryEvent] = stride(from: 0.0, to: 4.0, by: 1 / 60.0).map { .pos(t: $0, x: 160, y: 90) }
        return PreparedProject(project: project, recordingSize: CGSize(width: 320, height: 180), pointPixelScale: 1, events: events)
    }

    /// Renders at timeline time `t` and returns BGRA bytes plus the size.
    func render(_ p: PreparedProject, t: Double = 2) throws -> (bytes: [UInt8], w: Int, h: Int) {
        let compositor = try Compositor(device: device)
        let size = p.layout.outputSize(shortSide: 360)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = device.makeTexture(descriptor: d)!
        let queue = device.makeCommandQueue()!
        let cb = queue.makeCommandBuffer()!
        try compositor.render(p, frame: .init(t: t, frameInterval: 1 / 60, source: greyFrame(), bundle: nil), into: target, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
        target.getBytes(&bytes, bytesPerRow: target.width * 4, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        return (bytes, target.width, target.height)
    }

    func pixel(_ r: (bytes: [UInt8], w: Int, h: Int), _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let o = (y * r.w + x) * 4
        return (Int(r.bytes[o + 2]), Int(r.bytes[o + 1]), Int(r.bytes[o]))   // BGRA
    }

    @Test func backgroundScreenAndCursor() throws {
        let p = prepared()
        let img = try render(p)
        // Corner: the red background (linear 1, 0, 0).
        let corner = pixel(img, 3, 3)
        #expect(corner.r > 245 && corner.g < 10 && corner.b < 10, "corner \(corner)")
        // Inside the screen, away from the cursor: grey Y = 180 → R'G'B' 0.749 → linear ≈ 0.52 → 133.
        let rect = p.layout.screenRect
        let gx = Int((rect.minX + rect.width * 0.2) * Double(img.w)), gy = Int((rect.minY + rect.height * 0.2) * Double(img.h))
        let grey = pixel(img, gx, gy)
        #expect(abs(grey.r - 133) <= 4 && abs(grey.g - 133) <= 4 && abs(grey.b - 133) <= 4, "screen \(grey)")
        // Just below-right of the cursor hotspot (screen centre): the black arrow.
        let cx = Int(rect.midX * Double(img.w)), cy = Int(rect.midY * Double(img.h))
        let arrow = pixel(img, cx + 5, cy + 18)
        #expect(arrow.r < 40 && arrow.g < 40 && arrow.b < 40, "cursor \(arrow)")
    }

    @Test func sameInputsGiveIdenticalPixels() throws {
        let p = prepared { $0.background.kind = .wallpaper; $0.frame.shadow.amount = 0.6; $0.frame.cornerRadius = 16 }
        let a = try render(p), b = try render(p)
        #expect(a.bytes == b.bytes)
    }

    @Test func zoomScalesTheWholeComposition() throws {
        // At 2× around the screen centre, the corner shows the recording, no longer the background.
        let img = try render(prepared(zoom: true), t: 3)
        let corner = pixel(img, 3, 3)
        #expect(abs(corner.r - 133) <= 4 && abs(corner.g - 133) <= 4, "zoomed corner \(corner)")
    }

    @Test(arguments: CursorLook.Style.allCases)
    func everyCursorStyleRasterises(style: CursorLook.Style) throws {
        for shape in CursorShape.allCases {
            let r = try #require(CursorArt.raster(style: style, shape: shape, colorHex: "#FF5A36", pixelHeight: 48))
            #expect(r.image.height >= 48 && r.hotspot.x > 0 && r.hotspot.y > 0)
        }
    }
}

@Suite("Masks and slice overrides", .serialized)
struct MaskTests {
    let base = CompositorTests()

    @Test func hideMaskCoversItsRegion() throws {
        var p = base.prepared()
        var project = p.project
        project.masks = [Mask(id: "M1", sourceStart: 0, sourceEnd: 4, kind: .hide, rect: [0.0, 0.0, 0.3, 0.3])]
        p = p.with(project: project, events: [])
        let img = try base.render(p)
        let r = p.layout.screenRect
        let inside = base.pixel(img, Int((r.minX + r.width * 0.1) * Double(img.w)), Int((r.minY + r.height * 0.1) * Double(img.h)))
        let outside = base.pixel(img, Int((r.minX + r.width * 0.7) * Double(img.w)), Int((r.minY + r.height * 0.7) * Double(img.h)))
        #expect(inside.r < 20, "hidden \(inside)")
        #expect(abs(outside.r - 133) <= 4, "untouched \(outside)")
    }

    @Test func highlightDimsTheRest() throws {
        var p = base.prepared()
        var project = p.project
        project.masks = [Mask(id: "M1", sourceStart: 0, sourceEnd: 4, kind: .highlight, rect: [0.4, 0.4, 0.2, 0.2], strength: 0.7)]
        p = p.with(project: project, events: [])
        let img = try base.render(p)
        let r = p.layout.screenRect
        let centre = base.pixel(img, Int(r.midX * Double(img.w)), Int(r.midY * Double(img.h)))
        let edge = base.pixel(img, Int((r.minX + r.width * 0.1) * Double(img.w)), Int((r.minY + r.height * 0.1) * Double(img.h)))
        #expect(abs(centre.r - 133) <= 4)
        #expect(edge.r < 80, "dimmed \(edge)")
    }

    @Test func maskOutsideItsTimeRangeDoesNothing() throws {
        var p = base.prepared()
        var project = p.project
        project.masks = [Mask(id: "M1", sourceStart: 3, sourceEnd: 4, kind: .hide, rect: [0, 0, 1, 1])]
        p = p.with(project: project, events: [])
        let img = try base.render(p, t: 2)
        let r = p.layout.screenRect
        #expect(abs(base.pixel(img, Int(r.midX * Double(img.w)), Int(r.midY * Double(img.h))).r - 133) <= 4)
    }

    @Test func blurMaskRuns() throws {
        var p = base.prepared()
        var project = p.project
        project.masks = [Mask(id: "M1", sourceStart: 0, sourceEnd: 4, kind: .blur, rect: [0, 0, 1, 1], strength: 1)]
        p = p.with(project: project, events: [])
        let img = try base.render(p)
        // A uniform grey frame stays the same grey when blurred.
        let r = p.layout.screenRect
        #expect(abs(base.pixel(img, Int(r.midX * Double(img.w)), Int(r.midY * Double(img.h))).r - 133) <= 5)
    }

    @Test func sliceCursorOverrideApplies() throws {
        // The dot style draws a coloured dot centred on the hotspot.
        var p = base.prepared()
        var project = p.project
        project.timeline.slices[0].cursorOverride = CursorOverride(style: .dot)
        project.look.cursor.color = "#00FF00"
        let events: [TelemetryEvent] = stride(from: 0.0, to: 4.0, by: 1 / 60.0).map { .pos(t: $0, x: 160, y: 90) }
        p = p.with(project: project, events: events)
        let img = try base.render(p)
        let r = p.layout.screenRect
        let c = base.pixel(img, Int(r.midX * Double(img.w)), Int(r.midY * Double(img.h)))
        #expect(c.g > 200 && c.r < 60, "dot \(c)")
    }
}

@Suite("Keyboard-shortcut overlay rendering", .serialized)
struct KeyOverlayRenderTests {
    let base = CompositorTests()

    func prepared(enabled: Bool, zoom: Bool = false) -> PreparedProject {
        var p = base.prepared(zoom: zoom)
        var project = p.project
        project.look.keys.enabled = enabled
        let events: [TelemetryEvent] = stride(from: 0.0, to: 4.0, by: 1 / 60.0).map { .pos(t: $0, x: 160, y: 90) }
            + [.key(t: 1.5, phase: .down, keyCode: 8, chars: "c", mods: ["cmd"]), .key(t: 1.6, phase: .up, keyCode: 8, chars: "c", mods: ["cmd"])]
        p = p.with(project: project, events: events)
        return p
    }

    /// Brightest pixel in the bottom-centre strip where the badge goes (the keycaps are near-white).
    func badgeBrightness(_ img: (bytes: [UInt8], w: Int, h: Int)) -> Int {
        var best = 0
        for y in Int(Double(img.h) * 0.8)..<img.h {
            for x in (img.w / 2 - 40)..<(img.w / 2 + 40) { best = max(best, base.pixel(img, x, y).g) }
        }
        return best
    }

    @Test func badgeAppearsOnlyWhenEnabledAndWhileShown() throws {
        // The strip holds red background (green 0) and the grey recording (green 133); only the near-white
        // keycaps reach above 225.
        #expect(badgeBrightness(try base.render(prepared(enabled: true), t: 2.0)) > 225)
        #expect(badgeBrightness(try base.render(prepared(enabled: false), t: 2.0)) < 200)
        #expect(badgeBrightness(try base.render(prepared(enabled: true), t: 3.5)) < 200)     // shown 1 s only
    }

    @Test func badgeIsNotZoomed() throws {
        // Even at 2× zoom the badge sits in the same bottom strip (overlays are drawn after the camera).
        #expect(badgeBrightness(try base.render(prepared(enabled: true, zoom: true), t: 2.0)) > 225)
    }

    @Test func badgeArtHasOneKeycapPerToken() throws {
        let one = try #require(KeyBadgeArt.raster(tokens: ["⌘", "C"], repeatCount: 1, keyHeight: 40))
        let three = try #require(KeyBadgeArt.raster(tokens: ["⌃", "⇧", "⌘", "Z"], repeatCount: 3, keyHeight: 40))
        #expect(three.width > one.width)
        #expect(one.height == three.height)
    }
}

@Suite("Caption rendering", .serialized)
struct CaptionRenderTests {
    let base = CompositorTests()
    let transcript = Transcript(language: "en_US", source: "mic.m4a", words: [
        .init(text: "Hello", start: 1.0, end: 1.4), .init(text: "there", start: 1.5, end: 1.9),
        .init(text: "world.", start: 2.0, end: 2.5),
    ])

    func prepared(enabled: Bool, style: CaptionLook.Style = .classic, keys: Bool = false, center: [Double]? = nil) -> PreparedProject {
        let p = base.prepared()
        var project = p.project
        project.look.captions.enabled = enabled
        project.look.captions.center = center
        project.look.captions.style = style
        project.look.keys.enabled = keys
        let events: [TelemetryEvent] = stride(from: 0.0, to: 4.0, by: 1 / 60.0).map { .pos(t: $0, x: 160, y: 90) }
            + [.key(t: 1.9, phase: .down, keyCode: 8, chars: "c", mods: ["cmd"]), .key(t: 2.0, phase: .up, keyCode: 8, chars: "c", mods: ["cmd"])]
        return p.with(project: project, events: events, transcript: transcript)
    }

    /// Rows (from the top) in the lower 30 % (below the centred cursor) that hold near-white text pixels.
    func whiteRows(_ img: (bytes: [UInt8], w: Int, h: Int)) -> [Int] {
        (Int(Double(img.h) * 0.7)..<img.h).filter { y in
            (0..<img.w).contains { x in let c = base.pixel(img, x, y); return c.r > 225 && c.g > 225 && c.b > 225 }
        }
    }

    @Test func captionAppearsOnlyWhenEnabledAndWhileSpoken() throws {
        #expect(!whiteRows(try base.render(prepared(enabled: true), t: 2.2)).isEmpty)
        #expect(whiteRows(try base.render(prepared(enabled: false), t: 2.2)).isEmpty)
        #expect(whiteRows(try base.render(prepared(enabled: true), t: 0.5)).isEmpty)       // before the first word
    }

    @Test(arguments: CaptionLook.Style.allCases)
    func everyStyleRenders(style: CaptionLook.Style) throws {
        #expect(!whiteRows(try base.render(prepared(enabled: true, style: style), t: 2.2)).isEmpty)
    }

    @Test func highlightColoursTheSpokenWord() throws {
        let img = try base.render(prepared(enabled: true, style: .highlight), t: 2.2)
        let yellow = (Int(Double(img.h) * 0.7)..<img.h).contains { y in
            (0..<img.w).contains { x in let c = base.pixel(img, x, y); return c.r > 230 && c.g > 180 && c.g < 235 && c.b < 120 }
        }
        #expect(yellow)
    }

    @Test func keyBadgeMovesAboveABottomCaption() throws {
        let both = whiteRows(try base.render(prepared(enabled: true, keys: true), t: 2.2))
        let captionOnly = whiteRows(try base.render(prepared(enabled: true), t: 2.2))
        // With the badge, white starts higher, and the caption rows stay where they were.
        #expect(try #require(both.first) < (try #require(captionOnly.first)))
        #expect(Set(captionOnly).isSubset(of: Set(both)))
    }

    @Test func draggedCaptionMovesAndTheBadgeAvoidsIt() throws {
        let both = whiteRows(try base.render(prepared(enabled: true, keys: true), t: 2.2))
        // Dragged to the top: only the key badge is left in the bottom strip.
        let moved = whiteRows(try base.render(prepared(enabled: true, keys: true, center: [0.5, 0.2]), t: 2.2))
        #expect(!moved.isEmpty && moved.count < both.count)
        // Dragged onto the badge's spot: the badge moves above it, so both are still drawn.
        let overlap = whiteRows(try base.render(prepared(enabled: true, keys: true, center: [0.5, 0.92]), t: 2.2))
        #expect(overlap.count >= both.count - 2)
    }

    @Test func longLinesWrapToTheWidth() throws {
        let words = Array(repeating: "wordy", count: 12)
        let narrow = try #require(CaptionArt.raster(words: words, activeWord: nil, look: CaptionLook(), textHeight: 20, maxWidth: 200))
        let wide = try #require(CaptionArt.raster(words: words, activeWord: nil, look: CaptionLook(), textHeight: 20, maxWidth: 2000))
        #expect(narrow.width <= 204)
        #expect(narrow.height > wide.height)
    }

    @Test func textColourIsUsed() throws {
        let p = prepared(enabled: true)
        var project = p.project
        project.look.captions.textColor = "#00FF00"
        let img = try base.render(p.with(project: project, events: []), t: 2.2)
        let green = (Int(Double(img.h) * 0.7)..<img.h).contains { y in
            (0..<img.w).contains { x in let c = base.pixel(img, x, y); return c.g > 225 && c.r < 60 && c.b < 60 }
        }
        #expect(green)
        #expect(whiteRows(img).isEmpty)
    }

    @Test(arguments: ["system", "rounded", "serif", "mono", "Georgia", "No Such Font"])
    func everyFontChoiceRasterises(font: String) throws {
        var look = CaptionLook()
        look.font = font
        let image = try #require(CaptionArt.raster(words: ["Hello", "world"], activeWord: nil, look: look, textHeight: 30, maxWidth: 800))
        #expect(image.width > 60)
    }
}

@Suite("Webcam layouts", .serialized)
struct WebcamRenderTests {
    let base = CompositorTests()

    /// A 160×90 BGRA camera frame: left half green, right half blue (to see mirroring).
    func cameraFrame() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        let row = CVPixelBufferGetBytesPerRow(b)
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<90 { for x in 0..<160 {
            let o = y * row + x * 4
            p[o] = x < 80 ? 0 : 255; p[o + 1] = x < 80 ? 255 : 0; p[o + 2] = 0; p[o + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    func prepared(_ edit: (inout Project) -> Void = { _ in }) -> PreparedProject {
        let p = base.prepared()
        var project = p.project
        edit(&project)
        let events: [TelemetryEvent] = stride(from: 0.0, to: 4.0, by: 1 / 60.0).map { .pos(t: $0, x: 160, y: 90) }
        return PreparedProject(project: project, recordingSize: CGSize(width: 320, height: 180), pointPixelScale: 1, events: events, hasCamera: true)
    }

    func render(_ p: PreparedProject, camera: CVPixelBuffer?) throws -> (bytes: [UInt8], w: Int, h: Int) {
        let compositor = try Compositor(device: base.device)
        let size = p.layout.outputSize(shortSide: 360)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = base.device.makeTexture(descriptor: d)!
        let cb = base.device.makeCommandQueue()!.makeCommandBuffer()!
        try compositor.render(p, frame: .init(t: 2, frameInterval: 1 / 60, source: base.greyFrame(), bundle: nil, camera: camera), into: target, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
        target.getBytes(&bytes, bytesPerRow: target.width * 4, from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        return (bytes, target.width, target.height)
    }

    @Test func overlayBubbleInTheCorner() throws {
        let p = prepared { $0.look.webcam.avoidCursor = false }
        let img = try render(p, camera: cameraFrame())
        let b = p.layouts.state(at: 2).webcam
        let c = base.pixel(img, Int(b.midX * Double(img.w)), Int(b.midY * Double(img.h)))
        #expect(c.g > 200 || c.b > 200, "bubble centre \(c)")
        #expect(base.pixel(img, img.w / 2, img.h / 2).g < 200)                      // the screen is still in the middle
        #expect(try render(p, camera: nil).bytes == base.render(p).bytes)               // no frame, nothing drawn
    }

    @Test func fullCameraFillsTheCanvasMirrored() throws {
        let p = prepared { $0.look.webcam.layout = .camera }
        let img = try render(p, camera: cameraFrame())
        // Mirrored: the green (left) half of the picture shows on the right.
        let left = base.pixel(img, img.w / 5, img.h / 2), right = base.pixel(img, img.w * 4 / 5, img.h / 2)
        #expect(left.b > 200 && left.g < 60, "left \(left)")
        #expect(right.g > 200 && right.b < 60, "right \(right)")
        let unmirrored = try render(prepared { $0.look.webcam.layout = .camera; $0.look.webcam.mirror = false }, camera: cameraFrame())
        #expect(base.pixel(unmirrored, unmirrored.w / 5, unmirrored.h / 2).g > 200)
    }

    @Test func splitMovesTheScreen() throws {
        let p = prepared { $0.look.webcam.layout = .split }
        let img = try render(p, camera: cameraFrame())
        let s = p.layouts.state(at: 2)
        let screen = base.pixel(img, Int(s.screenRect.midX * Double(img.w)), Int(s.screenRect.midY * Double(img.h)))
        #expect(screen.r == screen.g && screen.g == screen.b && screen.r > 100, "screen \(screen)")   // the grey recording
        // A quarter into the card (its centre is the line between the picture's two halves).
        let cam = base.pixel(img, Int((s.webcam.minX + s.webcam.width / 4) * Double(img.w)), Int(s.webcam.midY * Double(img.h)))
        #expect(cam.g > 200 || cam.b > 200, "camera \(cam)")
        #expect(s.webcam.minX > s.screenRect.maxX)
    }
}
