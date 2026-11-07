import CoreGraphics
import Foundation
import Testing
@testable import ScrecCore

@Suite("Export settings")
struct ExportSettingsTests {
    @Test func shortSideAndVertical() {
        var look = Look()
        look.aspect = .wide
        var s = ExportSettings()
        #expect(s.outputSize(layout: Layout(recordingSize: CGSize(width: 2560, height: 1440), look: look)) == CGSize(width: 1920, height: 1080))
        look.aspect = .vertical
        s.resolution = .p2160
        // EX-01: the short side of a vertical video is the resolution.
        #expect(s.outputSize(layout: Layout(recordingSize: CGSize(width: 2560, height: 1440), look: look)) == CGSize(width: 2160, height: 3840))
        s.format = .gif
        s.gifShortSide = 4000
        #expect(s.outputSize(layout: Layout(recordingSize: CGSize(width: 2560, height: 1440), look: look)).width == 1080)   // GIF ≤ 1080
        #expect(s.outputFPS == 15)
    }

    @Test func oldProjectsGetDefaults() throws {
        let p = try Project.decode(from: Data(#"{"name":"x","timeline":{"slices":[]}}"#.utf8))
        #expect(p.export == ExportSettings())
        #expect(p.export.fps == 60 && p.export.codec == .hevc)
    }

    @Test func uniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screc-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = ExportNaming.uniqueURL(in: dir, projectName: "Safari 2026-10-16 23:23:42", ext: "mp4")
        #expect(a.lastPathComponent == "Safari 2026-10-16 23.23.42.mp4")
        FileManager.default.createFile(atPath: a.path, contents: Data())
        #expect(ExportNaming.uniqueURL(in: dir, projectName: "Safari 2026-10-16 23:23:42", ext: "mp4").lastPathComponent == "Safari 2026-10-16 23.23.42 2.mp4")
    }
}

@Suite("GIF quantiser")
struct GIFQuantizerTests {
    /// A horizontal gradient from blue to orange, 256 × 64.
    func gradient() -> [UInt8] {
        var px = [UInt8](repeating: 255, count: 256 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<256 {
                let o = (y * 256 + x) * 4
                px[o] = UInt8(40 + x * 200 / 255); px[o + 1] = UInt8(80 + x / 4); px[o + 2] = UInt8(220 - x * 180 / 255)
            }
        }
        return px
    }

    @Test func fewColoursAreKeptExactly() {
        var px = [UInt8](repeating: 255, count: 16 * 16 * 4)
        for i in 0..<(16 * 16) {
            let c: [UInt8] = i % 3 == 0 ? [255, 0, 0] : i % 3 == 1 ? [0, 128, 255] : [20, 20, 20]
            px[i * 4] = c[0]; px[i * 4 + 1] = c[1]; px[i * 4 + 2] = c[2]
        }
        let r = px.withUnsafeBytes { GIFQuantizer.quantize($0, width: 16, height: 16, bytesPerRow: 64, dither: 0) }
        #expect(r.colorCount == 3)
        // Every pixel maps back to (within one 5-bit step of) its colour.
        for i in 0..<(16 * 16) {
            let p = Int(r.indices[i])
            for ch in 0..<3 { #expect(abs(Int(r.palette[p * 3 + ch]) - Int(px[i * 4 + ch])) <= 8) }
        }
    }

    @Test func gradientUsesThePaletteAndStaysClose() {
        let px = gradient()
        let r = px.withUnsafeBytes { GIFQuantizer.quantize($0, width: 256, height: 64, bytesPerRow: 1024, maxColors: 64) }
        #expect(r.colorCount <= 64 && r.colorCount > 32)
        var err = 0.0
        for i in 0..<(256 * 64) {
            let p = Int(r.indices[i])
            for ch in 0..<3 { err += abs(Double(r.palette[p * 3 + ch]) - Double(px[i * 4 + ch])) }
        }
        #expect(err / Double(256 * 64 * 3) < 6, "mean error \(err / Double(256 * 64 * 3))")
    }

    @Test func deterministic() {
        let px = gradient()
        let a = px.withUnsafeBytes { GIFQuantizer.quantize($0, width: 256, height: 64, bytesPerRow: 1024) }
        let b = px.withUnsafeBytes { GIFQuantizer.quantize($0, width: 256, height: 64, bytesPerRow: 1024) }
        #expect(a.palette == b.palette && a.indices == b.indices)
    }
}

@Suite("GIF timing")
struct GIFTimingTests {
    @Test(arguments: [10, 15, 20, 24, 30])
    func totalDurationStaysExact(fps: Int) {
        let n = 349
        let total = (0..<n).map { GIFTiming.delayHundredths(frame: $0, fps: fps) }.reduce(0, +)
        #expect(abs(Double(total) / 100 - Double(n) / Double(fps)) <= 0.005)
        #expect((0..<n).allSatisfy { GIFTiming.delayHundredths(frame: $0, fps: fps) >= 2 })
    }
}

@Suite("Native export size")
struct NativeExportTests {
    @Test(arguments: [Look.Aspect.auto, .wide, .vertical, .square])
    func screenIsOneToOne(aspect: Look.Aspect) {
        var look = Look()
        look.aspect = aspect
        let layout = Layout(recordingSize: CGSize(width: 2560, height: 1440), look: look)
        var s = ExportSettings()
        s.resolution = .native
        let out = s.outputSize(layout: layout)
        let screenPx = layout.screenRect.height * out.height
        #expect(abs(screenPx - 1440) <= 2, "\(aspect): screen \(screenPx) px in \(out)")
        #expect(Int(out.width) % 2 == 0 && Int(out.height) % 2 == 0)
        #expect(max(out.width, out.height) <= 8192)
    }
}
