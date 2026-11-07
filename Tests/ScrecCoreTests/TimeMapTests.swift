import Foundation
import Testing
@testable import ScrecCore

@Suite("Time mapping timeline ⇄ source (ARCHITECTURE §8)")
struct TimeMapTests {
    /// S1 = [0, 10) at 1×, cut 10…16, S2 = [16, 28) at 2×, S3 = [28, 30) at 0.5×.
    func sample() -> TimeMap {
        var s1 = Slice(id: "S1", sourceStart: 0, sourceEnd: 10)
        var s2 = Slice(id: "S2", sourceStart: 16, sourceEnd: 28)
        s2.speed = 2
        var s3 = Slice(id: "S3", sourceStart: 28, sourceEnd: 30)
        s3.speed = 0.5
        s1.speed = 1
        return TimeMap(slices: [s2, s3, s1])        // unsorted on purpose
    }

    @Test func durationsAndStarts() {
        let m = sample()
        #expect(m.entries.map(\.sliceID) == ["S1", "S2", "S3"])
        #expect(m.entries.map(\.timelineStart) == [0, 10, 16])
        #expect(m.duration == 20)                    // 10 + 6 + 4
    }

    @Test func timelineToSource() {
        let m = sample()
        #expect(m.toSource(0) == 0)
        #expect(m.toSource(5) == 5)
        #expect(m.toSource(10) == 16)                // the cut is skipped
        #expect(m.toSource(13) == 22)                // 16 + 3 · 2
        #expect(m.toSource(18) == 29)                // 28 + 2 · 0.5
        #expect(m.toSource(20) == 30)                // t = T → end of the last slice
        #expect(m.toSource(99) == 30)                // clamped
    }

    @Test func sourceToTimelineAndCuts() {
        let m = sample()
        #expect(m.toTimeline(12) == nil)             // inside the cut
        #expect(m.toTimeline(22) == 13)
        #expect(m.toTimeline(30) == 20)
        #expect(m.timelineAtOrAfter(source: 12) == 10)
    }

    @Test(arguments: stride(from: 0.0, to: 20.0, by: 0.37).map { $0 })
    func roundTrip(t: Double) throws {
        let m = sample()
        let back = try #require(m.toTimeline(m.toSource(t)))
        #expect(abs(back - t) < 1e-9)
    }

    @Test func intervalAcrossACutBecomesTwoBlocks() {
        let m = sample()
        let r = m.timelineIntervals(sourceStart: 8, sourceEnd: 20)
        #expect(r.count == 2)
        #expect(r[0] == 8...10)
        #expect(r[1] == 10...12)                     // 16…20 at 2× = 4 s → 2 s on the timeline
        #expect(m.timelineIntervals(sourceStart: 11, sourceEnd: 15).isEmpty)
    }

    @Test func roundingUsesTicks() {
        var s = Slice(id: "A", sourceStart: 0, sourceEnd: 1)
        s.speed = 3                                  // 1/3 s cannot be represented exactly
        let m = TimeMap(slices: [s, Slice(id: "B", sourceStart: 1, sourceEnd: 2)])
        #expect(m.entries[0].timelineDurationTicks == 20_000)
        #expect(m.entries[1].timelineStartTicks == 20_000)
        #expect(m.frameCount(fps: 60) == 80)
    }
}
