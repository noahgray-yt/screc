import Testing
@testable import ScrecCore

@Suite("Recording clock (ARCHITECTURE §6.2)")
struct RecordingClockTests {
    @Test func nothingBeforeStart() {
        var c = ClockState()
        #expect(c.sourceTime(host: 100) == nil)
        c.start(atHost: 100)
        #expect(c.sourceTime(host: 99.999) == nil)
        #expect(c.sourceTime(host: 100) == 0)
        #expect(c.sourceTime(host: 102.5) == 2.5)
    }

    @Test func startIsSetOnce() {
        var c = ClockState()
        c.start(atHost: 10)
        c.start(atHost: 20)
        #expect(c.t0Host == 10)
    }

    @Test func pauseRemovesTimeAndDropsSamplesInside() throws {
        var c = ClockState()
        c.start(atHost: 100)
        c.pause(atHost: 110)          // 10 s recorded
        #expect(c.sourceTime(host: 111) == nil)
        c.resume(atHost: 117)         // paused for 7 s
        #expect(c.sourceTime(host: 109) == 9)
        #expect(c.sourceTime(host: 112) == nil)
        #expect(try #require(c.sourceTime(host: 117)) == 10)
        #expect(try #require(c.sourceTime(host: 120)) == 13)
    }

    @Test func lateSampleFromBeforeThePauseIsKept() {
        var c = ClockState()
        c.start(atHost: 0)
        c.pause(atHost: 5)
        // An audio buffer stamped 4.9 arrives after pause() was called: still part of the take.
        #expect(c.sourceTime(host: 4.9) == 4.9)
        #expect(c.sourceTime(host: 5.1) == nil)
    }

    @Test func multiplePausesAndRecordingInfo() throws {
        var c = ClockState()
        c.start(atHost: 1000)
        c.pause(atHost: 1010); c.resume(atHost: 1012)   // 2 s
        c.pause(atHost: 1020); c.resume(atHost: 1025)   // 5 s
        #expect(try #require(c.sourceTime(host: 1030)) == 23)
        let records = c.pausesForRecordingInfo
        #expect(records == [.init(atSource: 10, pausedFor: 2), .init(atSource: 18, pausedFor: 5)])
    }

    @Test func doublePauseOrResumeIsIgnored() {
        var c = ClockState()
        c.start(atHost: 0)
        c.resume(atHost: 1)
        c.pause(atHost: 2); c.pause(atHost: 3)
        c.resume(atHost: 4); c.resume(atHost: 9)
        #expect(c.pauses.count == 1)
        #expect(c.sourceTime(host: 10) == 8)
    }

    @Test func stopCutsEverythingAfterIt() throws {
        var c = ClockState()
        c.start(atHost: 100)
        c.pause(atHost: 104); c.resume(atHost: 106)
        c.stop(atHost: 110)
        #expect(try #require(c.sourceTime(host: 110)) == 8)     // duration = 10 s − 2 s paused
        #expect(c.sourceTime(host: 110.01) == nil)               // a frame that arrives after Stop
        #expect(c.sourceTime(host: 109) == 7)                    // a late sample from before Stop is kept
    }

    @Test func stopWhilePausedEndsAtThePause() throws {
        var c = ClockState()
        c.start(atHost: 0)
        c.pause(atHost: 5)
        c.stop(atHost: 9)
        #expect(c.pausesForRecordingInfo == [.init(atSource: 5, pausedFor: 4)])
        #expect(try #require(c.sourceTime(host: 9)) == 5)
    }

    @Test func sharedClockReturnsDuration() throws {
        let clock = RecordingClock()
        clock.start(atHost: 50)
        #expect(try #require(clock.stop(atHost: 62.5)) == 12.5)
    }
}
