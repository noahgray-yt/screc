import CoreGraphics
import Foundation
import Testing
@testable import ScrecCore

@Suite("Bundle naming, recording.json, project.json")
struct BundleTests {
    @Test func projectNameIsAppPlusTimestamp() {
        let date = Date(timeIntervalSince1970: 1_792_185_822)   // 2026-10-16 21:23:42 UTC
        let name = BundleLayout.projectName(sourceApp: "Safari", date: date, timeZone: TimeZone(identifier: "Europe/Zurich")!)
        #expect(name == "Safari 2026-10-16 23:23:42")
        #expect(BundleLayout.folderName(forProjectName: name) == "Safari 2026-10-16 23.23.42.screc")
        #expect(BundleLayout.projectName(sourceApp: "  ", date: date, timeZone: .gmt).hasPrefix("Recording "))
    }

    @Test func uniqueURLAndInterruptedDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = BundleLayout.uniqueBundleURL(in: dir, projectName: "A 2026-01-01 10:00:00")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = BundleLayout.uniqueBundleURL(in: dir, projectName: "A 2026-01-01 10:00:00")
        #expect(second.lastPathComponent == "A 2026-01-01 10.00.00 2.screc")

        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: second.appendingPathComponent(BundleLayout.lock).path, contents: Data())
        #expect(BundleLayout.interruptedBundles(in: dir).map(\.lastPathComponent) == [second.lastPathComponent])
    }

    @Test func recordingInfoRoundTrip() throws {
        var info = RecordingInfo(startedAt: Date(timeIntervalSince1970: 1_792_185_822), sourceApp: "Safari",
                                 capture: .init(kind: .window, displayID: 1, displayPixelSize: [3456, 2234], pointPixelScale: 2,
                                                contentRectPoints: [120, 80, 1440, 900], videoPixelSize: [2880, 1800], fps: 60, windowID: 42),
                                 tracks: .init(mic: BundleLayout.mic))
        info.clock.t0HostSeconds = 81234.123456
        info.pauses = [.init(atSource: 12.4, pausedFor: 7.92)]
        info.duration = 42.317
        info.finalised = true
        let back = try RecordingInfo.decode(from: info.encoded())
        #expect(back == info)
        let text = String(decoding: try info.encoded(), as: UTF8.self)
        #expect(text.contains("\"kind\" : \"window\""))
    }

    @Test func freshProjectHasOneSlice() throws {
        let p = Project.fresh(name: "Safari 2026-10-16 23:23:42", duration: 42.317)
        #expect(p.timeline.slices.count == 1)
        #expect(p.timeline.slices[0].sourceEnd == 42.317)
        #expect(try Project.decode(from: p.encoded()) == p)
        // Missing optional sections decode to defaults (backward compatibility).
        let minimal = #"{"name":"x","timeline":{"slices":[]}}"#
        #expect(try Project.decode(from: Data(minimal.utf8)).zooms.isEmpty)
    }
}

@Suite("Coordinates")
struct GeometryTests {
    @Test func cgPointToRecordingPixels() {
        // A 1440×900-point window at (120, 80), recorded at 2× → 2880×1800 pixels.
        let m = CoordinateMapper(captureRect: CGRect(x: 120, y: 80, width: 1440, height: 900),
                                 videoPixelSize: CGSize(width: 2880, height: 1800))
        #expect(m.recordingPixels(fromCG: CGPoint(x: 120, y: 80)) == .zero)
        #expect(m.recordingPixels(fromCG: CGPoint(x: 820, y: 530)) == CGPoint(x: 1400, y: 900))
        // Outside points are kept, not clamped.
        #expect(m.recordingPixels(fromCG: CGPoint(x: 100, y: 80)) == CGPoint(x: -40, y: 0))
    }

    @Test func appKitToCG() {
        #expect(CoordinateMapper.cgPoint(fromAppKit: CGPoint(x: 10, y: 1000), mainDisplayHeight: 1117) == CGPoint(x: 10, y: 117))
    }
}
