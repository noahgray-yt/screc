import CoreGraphics
import Foundation
import Testing
@testable import ScrecCore

@Suite("Alignment proof maths (ARCHITECTURE §6.4)")
struct AlignmentTests {
    let rect = CGRect(x: 0, y: 0, width: 2880, height: 1800)

    /// Events at 120 Hz along the calibration path; video frames at 60 Hz showing the path shifted by `lag`
    /// (positive lag = video behind), plus a constant hotspot offset and a little detection noise.
    func synthetic(lag: Double, noise: Double = 0.8) -> (video: [AlignmentEstimator.Sample], events: [AlignmentEstimator.Sample]) {
        var rng = SystemRandomNumberGenerator()
        let events = (0..<(20 * 120)).map { i -> AlignmentEstimator.Sample in
            let t = Double(i) / 120
            let p = CalibrationPath.position(at: t, in: rect)
            return .init(t: t, x: p.x, y: p.y)
        }
        let video = (0..<(20 * 60)).map { i -> AlignmentEstimator.Sample in
            let t = Double(i) / 60
            let p = CalibrationPath.position(at: t - lag, in: rect)
            let nx = Double.random(in: -noise...noise, using: &rng), ny = Double.random(in: -noise...noise, using: &rng)
            return .init(t: t, x: p.x + 7 + nx, y: p.y + 11 + ny)
        }
        return (video, events)
    }

    @Test(arguments: [0.0, 0.004, -0.0123, 0.025, -0.050])
    func recoversKnownShift(lag: Double) throws {
        let (video, events) = synthetic(lag: lag)
        let r = try AlignmentEstimator.estimate(video: video, events: events)
        #expect(abs(r.offset - (-lag)) < 0.001, "offset \(r.offset) for lag \(lag)")
        #expect(r.rmsError < 2)
        #expect(abs(r.meanOffset.x - 7) < 1 && abs(r.meanOffset.y - 11) < 1)
    }

    @Test func rejectsStillCursor() {
        let still = (0..<600).map { AlignmentEstimator.Sample(t: Double($0) / 60, x: 100, y: 100) }
        #expect(throws: AlignmentEstimator.Failure.noMotion) {
            try AlignmentEstimator.estimate(video: still, events: still)
        }
    }

    @Test func cursorLocatorFindsBlob() throws {
        let w = 200, h = 100, bpr = w * 4
        var bytes = [UInt8](repeating: 128, count: bpr * h)
        for y in 40..<50 { for x in 60..<66 { let o = y * bpr + x * 4; bytes[o] = 0; bytes[o + 1] = 0; bytes[o + 2] = 0 } }
        let found = bytes.withUnsafeBytes { buf -> CursorLocator.Found? in
            let bg = CursorLocator.dominantColor(bgra: buf, width: w, height: h, bytesPerRow: bpr)
            return CursorLocator.locate(bgra: buf, width: w, height: h, bytesPerRow: bpr, background: bg, stride: 1)
        }
        let f = try #require(found)
        #expect(abs(f.x - 62.5) < 0.01 && abs(f.y - 44.5) < 0.01)
    }

    @Test func cursorLocatorSkipsLargeAreas() {
        // A 120×60 "dialog" on the backdrop is not a cursor when the limit is 64 px.
        let w = 400, h = 200, bpr = w * 4
        var bytes = [UInt8](repeating: 128, count: bpr * h)
        for y in 20..<80 { for x in 20..<140 { let o = y * bpr + x * 4; bytes[o] = 250; bytes[o + 1] = 250; bytes[o + 2] = 250 } }
        let found = bytes.withUnsafeBytes {
            CursorLocator.locate(bgra: $0, width: w, height: h, bytesPerRow: bpr, background: (128, 128, 128),
                                 stride: 1, maxFraction: 1, maxExtent: 64)
        }
        #expect(found == nil)
    }

    @Test func cursorLocatorIgnoresStrayPixels() throws {
        let w = 400, h = 200, bpr = w * 4
        var bytes = [UInt8](repeating: 128, count: bpr * h)
        func dot(_ x: Int, _ y: Int) { let o = y * bpr + x * 4; bytes[o] = 0; bytes[o + 1] = 0; bytes[o + 2] = 0 }
        for y in 100..<110 { for x in 200..<206 { dot(x, y) } }     // the cursor
        dot(1, 1); dot(398, 1); dot(398, 2)                           // corner specks
        let found = bytes.withUnsafeBytes {
            CursorLocator.locate(bgra: $0, width: w, height: h, bytesPerRow: bpr, background: (128, 128, 128), stride: 1, maxExtent: 64)
        }
        let f = try #require(found)
        #expect(abs(f.x - 202.5) < 0.01 && abs(f.y - 104.5) < 0.01)
    }
}
