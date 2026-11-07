import Foundation
import Testing
@testable import ScrecCore

@Suite("Edit operations (ARCHITECTURE §8.3)")
struct EditOpsTests {
    let d = 30.0
    func fresh() -> Project { Project.fresh(name: "p", duration: 30) }

    @Test func splitKeepsSettingsAndInvariants() throws {
        var p = fresh()
        try p.setSpeed("S1", 1.5)
        let (l, r) = try p.split(atTimeline: 4)          // timeline 4 at 1.5× = source 6
        #expect(p.timeline.slices.map(\.id) == [l, r])
        #expect(p.timeline.slices[0].sourceEnd == 6 && p.timeline.slices[1].sourceStart == 6)
        #expect(p.timeline.slices[1].speed == 1.5)
        #expect(p.isValid(recordingDuration: d))
        #expect(throws: EditError.tooCloseToEdge) { try p.split(atTimeline: 0.03) }
    }

    @Test func removeTrimAndCutBadge() throws {
        var p = fresh()
        try p.split(atTimeline: 10)
        try p.split(atTimeline: 20)
        let middle = p.timeline.slices[1].id
        try p.removeSlice(middle)
        let map = TimeMap(slices: p.timeline.slices)
        #expect(map.duration == 20)                       // 10 s cut away
        #expect(p.timeline.slices[1].sourceStart - p.timeline.slices[0].sourceEnd == 10)  // gap → "10s ✂"
        // Trimming cannot overlap a neighbour: the second slice can grow back only to the first one's end (10)…
        try p.trimStart(sliceID: p.timeline.slices[1].id, toSource: 5)
        #expect(p.timeline.slices[1].sourceStart == 10)
        // …and then the first slice cannot grow past it.
        try p.trimEnd(sliceID: p.timeline.slices[0].id, toSource: 50, recordingDuration: d)
        #expect(p.timeline.slices[0].sourceEnd == 10)
        #expect(p.isValid(recordingDuration: d))
    }

    @Test func lastSliceCannotBeRemoved() {
        var p = fresh()
        #expect(throws: EditError.lastSlice) { try p.removeSlice("S1") }
    }

    @Test func mergeRestoresTheCutAndLeftWins() throws {
        var p = fresh()
        try p.split(atTimeline: 10)
        let right = p.timeline.slices[1].id
        try p.setSpeed(right, 2)
        try p.trimStart(sliceID: right, toSource: 14)      // cut 10…14
        try p.mergeWithPrevious(right)
        #expect(p.timeline.slices.count == 1)
        #expect(p.timeline.slices[0].sourceStart == 0 && p.timeline.slices[0].sourceEnd == 30)
        #expect(p.timeline.slices[0].speed == 1)          // left slice's speed
        #expect(throws: EditError.noNeighbour) { try p.mergeWithNext(p.timeline.slices[0].id) }
    }

    @Test func resetAllTrimsAndCutsKeepsSplitsAndSpeeds() throws {
        var p = fresh()
        try p.split(atTimeline: 10)
        let b = p.timeline.slices[1].id
        try p.setSpeed(b, 3)
        try p.trimStart(sliceID: b, toSource: 12)
        try p.trimEnd(sliceID: b, toSource: 25, recordingDuration: d)
        try p.trimStart(sliceID: p.timeline.slices[0].id, toSource: 2)
        p.resetAllTrimsAndCuts(recordingDuration: d)
        #expect(p.timeline.slices.map(\.sourceStart) == [0, 12])
        #expect(p.timeline.slices.map(\.sourceEnd) == [12, 30])
        #expect(p.timeline.slices[1].speed == 3)
    }

    @Test func speedIsClamped() throws {
        var p = fresh()
        try p.setSpeed("S1", 100)
        #expect(p.timeline.slices[0].speed == 16)
        try p.split(atTimeline: 1)
        try p.applySpeedToAll(from: "S1")
        #expect(p.timeline.slices.allSatisfy { $0.speed == 16 })
    }

    @Test func zoomStaysOnItsContentWhenSpeedChanges() throws {
        var p = fresh()
        p.zooms = [ZoomSegment(id: "Z1", sourceStart: 20, sourceEnd: 24)]
        try p.split(atTimeline: 10)
        try p.setSpeed("S1", 2)                           // first 10 s now take 5 s
        let map = TimeMap(slices: p.timeline.slices)
        // ED-08: the zoom still covers source 20…24, now at timeline 15…19.
        #expect(map.timelineIntervals(sourceStart: 20, sourceEnd: 24) == [15...19])
        // Drag to timeline 2…6: 2…5 is in the 2× slice (source 4…10), 5…6 in the 1× slice (source 10…11).
        try p.moveZoom("Z1", toTimelineStart: 2)
        #expect(abs(p.zooms[0].sourceStart - 4) < 1e-9 && abs(p.zooms[0].sourceEnd - 11) < 1e-9)
    }

    /// Property test: random edit sequences never break the invariants.
    @Test func randomEditsKeepInvariants() {
        var rng = SeededRNG(seed: 42)
        for _ in 0..<200 {
            var p = fresh()
            for _ in 0..<25 {
                let ids = p.timeline.slices.map(\.id)
                let id = ids[Int.random(in: 0..<ids.count, using: &rng)]
                let dur = TimeMap(slices: p.timeline.slices).duration
                switch Int.random(in: 0..<9, using: &rng) {
                case 0: _ = try? p.split(atTimeline: Double.random(in: 0...dur, using: &rng))
                case 1: try? p.trimStart(sliceID: id, toSource: Double.random(in: -5...35, using: &rng))
                case 2: try? p.trimEnd(sliceID: id, toSource: Double.random(in: -5...35, using: &rng), recordingDuration: d)
                case 3: try? p.removeSlice(id)
                case 4: try? p.setSpeed(id, Double.random(in: 0...20, using: &rng))
                case 5: try? p.mergeWithNext(id)
                case 6: try? p.mergeWithPrevious(id)
                case 7: try? p.resetTrim(id, recordingDuration: d)
                default: p.resetAllTrimsAndCuts(recordingDuration: d)
                }
                #expect(p.isValid(recordingDuration: d), "invalid after edit: \(p.timeline.slices)")
            }
        }
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite("Undo history (ARCHITECTURE §5.3)")
struct UndoTests {
    @Test func undoRedo() {
        var h = UndoHistory<Int>()
        var v = 1
        h.willChange(from: v); v = 2
        h.willChange(from: v); v = 3
        v = h.undo(current: v)!
        #expect(v == 2)
        v = h.undo(current: v)!
        #expect(v == 1)
        #expect(h.undo(current: v) == nil)
        v = h.redo(current: v)!
        #expect(v == 2)
        h.willChange(from: v); v = 9                      // a new edit clears redo
        #expect(!h.canRedo)
    }

    @Test func aDragIsOneStep() {
        var h = UndoHistory<Int>()
        var v = 0
        h.beginGroup()
        for x in 1...50 { h.willChange(from: v); v = x }
        h.endGroup()
        #expect(h.undoStack == [0])
        #expect(h.undo(current: v) == 0)
    }

    @Test func limitIsKept() {
        var h = UndoHistory<Int>(limit: 3)
        for x in 0..<10 { h.willChange(from: x) }
        #expect(h.undoStack == [7, 8, 9])
    }
}

@Suite("Auto-zoom (ARCHITECTURE §7.3)")
struct AutoZoomTests {
    func click(_ t: Double, up: Double? = nil) -> [TelemetryEvent] {
        [.down(t: t, button: .left, x: 0, y: 0, clickCount: 1), .up(t: up ?? t + 0.1, button: .left, x: 0, y: 0)]
    }

    @Test func singleClickUsesLeadAndHold() {
        let z = AutoZoom.generate(events: click(5), recordingDuration: 30)
        #expect(z.count == 1)
        #expect(abs(z[0].sourceStart - 4.5) < 1e-9)                 // 0.5 s before the click
        // 1.0 s after mouse-up (5.1) = 6.1, then extended to the 2 s minimum → 6.5.
        #expect(abs(z[0].sourceEnd - 6.5) < 1e-9)
        #expect(z[0].scale == 2 && z[0].mode == .auto && z[0].origin == .generated)
    }

    @Test func dragHoldsUntilMouseUp() {
        let z = AutoZoom.generate(events: click(5, up: 9), recordingDuration: 30)
        #expect(abs(z[0].sourceEnd - 10) < 1e-9)
    }

    @Test func closeClicksMerge_farClicksDoNot() {
        let z = AutoZoom.generate(events: click(5) + click(7.9) + click(20), recordingDuration: 30)
        // 5 → [4.5, 6.6], 7.9 → [7.4, 9.0]: gap 0.8 < 1.5 → merged. 20 stays separate.
        #expect(z.count == 2)
        #expect(abs(z[0].sourceStart - 4.5) < 1e-9 && abs(z[0].sourceEnd - 9.0) < 1e-9)
    }

    @Test func shortSegmentsAreExtendedAndClamped() {
        // Near the end: [27.5, 29.1] is 1.6 s long → extended to 2 s; would pass D = 29.5 → extended left.
        let z = AutoZoom.generate(events: click(28.0, up: 28.1), recordingDuration: 29.5)
        #expect(abs(z[0].sourceEnd - 29.5) < 1e-9 && abs(z[0].sourceStart - 27.5) < 1e-9)
    }

    @Test func edgeClicksAreIgnored() {
        #expect(AutoZoom.generate(events: click(0.1) + click(29.9), recordingDuration: 30).isEmpty)
    }

    @Test func typingBurstsCountRealKeysOnly() {
        func key(_ t: Double, _ c: String = "a", mods: [String] = []) -> TelemetryEvent {
            .key(t: t, phase: .down, keyCode: 0, chars: c, mods: mods)
        }
        let typing = [key(10), key(10.3), key(10.6), key(11.0), key(11.4)]
        let z = AutoZoom.generate(events: typing, recordingDuration: 30)
        #expect(z.count == 1 && abs(z[0].sourceStart - 9.5) < 1e-9 && abs(z[0].sourceEnd - 12.4) < 1e-9)
        // Shortcuts (⌘) and too few keys do not zoom.
        let shortcuts = [key(10, mods: ["cmd"]), key(10.2, mods: ["cmd"]), key(10.4, mods: ["cmd"]), key(10.6, mods: ["cmd"])]
        #expect(AutoZoom.generate(events: shortcuts + [key(20), key(20.2)], recordingDuration: 30).isEmpty)
    }

    @Test func userZoomsWinOverGenerated() {
        let user = ZoomSegment(id: "Z1", sourceStart: 4, sourceEnd: 8, scale: 3, mode: .manual, origin: .user)
        let oldGenerated = ZoomSegment(id: "A9", sourceStart: 20, sourceEnd: 22, origin: .generated)
        let z = AutoZoom.generate(events: click(5) + click(15), recordingDuration: 30, existing: [user, oldGenerated])
        #expect(z.map(\.id).contains("Z1"))
        #expect(!z.map(\.id).contains("A9"))                       // old generated zooms are replaced
        #expect(z.count == 2)                                        // click at 5 overlaps the user zoom → dropped
        #expect(z.contains { $0.origin == .generated && abs($0.sourceStart - 14.5) < 1e-9 })
    }
}

@Suite("Command palette matching")
struct FuzzyTests {
    @Test func subsequenceAndRanking() throws {
        #expect(FuzzyMatcher.score("pad", in: "Padding") != nil)
        #expect(FuzzyMatcher.score("xyz", in: "Padding") == nil)
        let wordStart = try #require(FuzzyMatcher.score("bb", in: "Background blur"))
        let scattered = try #require(FuzzyMatcher.score("bb", in: "Rubber band"))
        #expect(wordStart > scattered)
        #expect(FuzzyMatcher.bestScore("shadow", label: "Shadow", synonyms: []) != nil)
        #expect(FuzzyMatcher.bestScore("dark", label: "Shadow", synonyms: ["drop shadow", "darkness"]) != nil)
    }
}

@Suite("Presets (ARCHITECTURE §5.4)")
struct PresetTests {
    @Test func saveListRenameDeleteApply() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screc-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PresetStore(directory: dir)
        var look = Look()
        look.frame.padding = 0.25
        look.aspect = .vertical
        try store.save(Preset(name: "Brand/Blue", from: look))
        #expect(store.list().map(\.name) == ["Brand/Blue"])
        try store.rename("Brand/Blue", to: "Brand")
        #expect(store.list().map(\.name) == ["Brand"])
        let applied = try #require(store.list().first).applied(to: Look())
        #expect(applied.frame.padding == 0.25)
        #expect(applied.aspect == .auto)                             // aspect is not part of a preset
        try store.delete(name: "Brand")
        #expect(store.list().isEmpty)
    }
}

@Suite("Click sounds")
struct ClickSoundTests {
    @Test(arguments: [CursorLook.ClickSound.soft, .crisp])
    func deterministicAndAudible(sound: CursorLook.ClickSound) {
        let a = ClickSounds.samples(sound), b = ClickSounds.samples(sound)
        #expect(a == b)
        let peak = a.map { abs($0) }.max() ?? 0
        #expect(peak > 0.2 && peak <= 1)
    }

    @Test func trackPlacesClicksOnTheTimeline() {
        let track = ClickSounds.track(clickTimes: [1.0, 2.5], duration: 3, sound: .crisp)
        #expect(track.count == 144_000)
        func energy(_ from: Double) -> Float {
            let s = Int(from * ClickSounds.sampleRate)
            return track[s..<(s + 1000)].map { $0 * $0 }.reduce(0, +)
        }
        #expect(energy(1.0) > 1 && energy(2.5) > 1)
        #expect(energy(0.5) == 0 && energy(1.8) == 0)
        #expect(ClickSounds.track(clickTimes: [1], duration: 2, sound: .none).allSatisfy { $0 == 0 })
    }
}

@Suite("Timeline hit testing")
struct TimelineHitTestTests {
    typealias H = TimelineHitTest
    // Two blocks: A 1…3 s, B 2.5…6 s (overlapping), 100 points per second, time 0 at x = 14.
    let spans = [H.Span(id: "A", start: 1, end: 3), H.Span(id: "B", start: 2.5, end: 6)]
    func hit(_ x: CGFloat) -> H.Hit { H.hit(x: x, spans: spans, inset: 14, pps: 100) }

    @Test func bodiesEdgesAndEmpty() {
        #expect(hit(14 + 50) == .none)                      // 0.5 s: empty track → click adds a zoom
        #expect(hit(14 + 180) == .body("A"))                // 1.8 s
        #expect(hit(14 + 102) == .startEdge("A"))           // within 6 pt of A's start
        #expect(hit(14 + 600) == .endEdge("B"))             // B's end
        #expect(hit(14 + 400) == .body("B"))
    }

    @Test func topmostWinsWhereBlocksOverlap() {
        #expect(hit(14 + 280) == .body("B"))                // 2.8 s: both cover it, B is drawn on top
    }

    @Test func narrowBlocksOfferOnlyTheirEndEdge() {
        let tiny = [H.Span(id: "T", start: 1, end: 1.1)]    // 10 pt wide
        #expect(H.hit(x: 14 + 109, spans: tiny, inset: 14, pps: 100) == .endEdge("T"))
        #expect(H.hit(x: 14 + 101, spans: tiny, inset: 14, pps: 100) == .body("T"))
    }
}

@Suite("Speed-up typing (Phase 5)")
struct TypingSpeedUpTests {
    func typing(from t0: Double, keys n: Int, every dt: Double, mods: [String] = []) -> [TelemetryEvent] {
        (0..<n).map { .key(t: t0 + Double($0) * dt, phase: .down, keyCode: 0, chars: "a", mods: mods) }
    }

    @Test func findsLongStretchesOnly() {
        let events = typing(from: 2, keys: 30, every: 0.25)          // 7.25 s of typing
            + typing(from: 15, keys: 6, every: 0.3)                   // too few keys
            + typing(from: 20, keys: 20, every: 0.3, mods: ["cmd"])   // shortcuts, not typing
        let s = TypingSpeedUp.stretches(events: events, recordingDuration: 40)
        #expect(s.count == 1)
        #expect(abs(s[0].sourceStart - 1.8) < 1e-9 && abs(s[0].sourceEnd - 9.45) < 1e-9)
        #expect(s[0].keyCount == 30 && s[0].suggestedSpeed == 2)
    }

    @Test func aPauseSplitsStretches() {
        let events = typing(from: 0, keys: 15, every: 0.3) + typing(from: 8, keys: 15, every: 0.3)
        #expect(TypingSpeedUp.stretches(events: events, recordingDuration: 30).count == 2)
    }

    @Test func applySpeedSplitsAndKeepsTheRest() throws {
        var p = Project.fresh(name: "p", duration: 30)
        try p.applySpeed(sourceStart: 10, sourceEnd: 16, speed: 2)
        #expect(p.timeline.slices.map(\.sourceStart) == [0, 10, 16])
        #expect(p.timeline.slices.map(\.speed) == [1, 2, 1])
        #expect(TimeMap(slices: p.timeline.slices).duration == 27)   // 6 s at 2× = 3 s saved
        #expect(p.isValid(recordingDuration: 30))
        // Applying again over the same range does not split further.
        try p.applySpeed(sourceStart: 10, sourceEnd: 16, speed: 3)
        #expect(p.timeline.slices.count == 3 && p.timeline.slices[1].speed == 3)
    }

    @Test func applySpeedAcrossACut() throws {
        var p = Project.fresh(name: "p", duration: 30)
        try p.split(atTimeline: 12)
        try p.removeSlice(p.timeline.slices[1].id)
        p.timeline.slices.append(Slice(id: p.newID("S"), sourceStart: 14, sourceEnd: 30))
        try p.applySpeed(sourceStart: 10, sourceEnd: 18, speed: 2)
        #expect(p.timeline.slices.map(\.speed) == [1, 2, 2, 1])
        #expect(p.isValid(recordingDuration: 30))
    }
}

@Suite("Zooms never overlap")
struct ZoomOverlapTests {
    func project() -> Project {
        var p = Project.fresh(name: "t", duration: 20)
        p.zooms = [ZoomSegment(id: "Z1", sourceStart: 2, sourceEnd: 4, scale: 2), ZoomSegment(id: "Z2", sourceStart: 8, sourceEnd: 10, scale: 2)]
        return p
    }

    @Test func movingStopsAtTheNeighbour() throws {
        var p = project()
        try p.moveZoom("Z1", toTimelineStart: 7)              // would cover Z2
        #expect(abs(p.zooms[0].sourceStart - 6) < 1e-9 && abs(p.zooms[0].sourceEnd - 8) < 1e-9)
        try p.moveZoom("Z2", toTimelineStart: 0)              // would jump over Z1's spot
        #expect(abs(p.zooms[1].sourceStart - 8) < 1e-9)
    }

    @Test func resizingStopsAtTheNeighbour() throws {
        var p = project()
        try p.resizeZoom("Z1", start: false, toTimeline: 12)
        #expect(abs(p.zooms[0].sourceEnd - 8) < 1e-9)
        try p.resizeZoom("Z2", start: true, toTimeline: 1)
        #expect(abs(p.zooms[1].sourceStart - 8) < 1e-9)
    }

    @Test func gapsForNewZooms() {
        let p = project()
        let map = TimeMap(slices: p.timeline.slices)
        #expect(p.zoomGap(at: 3, map: map) == nil)
        #expect(p.zoomGap(at: 5, map: map) == 4...8)
        #expect(p.zoomGap(at: 15, map: map) == 10...20)
    }
}
