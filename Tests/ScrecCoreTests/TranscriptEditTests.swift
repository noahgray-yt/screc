import Foundation
import Testing
@testable import ScrecCore

@Suite("Transcript editing (Phase 5)")
struct TranscriptEditTests {
    // "So um this is uh the demo." with a 3 s silence before "the".
    let transcript = Transcript(language: "en_US", source: "mic.m4a", words: [
        .init(text: "So", start: 1.0, end: 1.2), .init(text: "um", start: 1.4, end: 1.6),
        .init(text: "this", start: 1.8, end: 2.0), .init(text: "is", start: 2.1, end: 2.2),
        .init(text: "uh,", start: 2.3, end: 2.5), .init(text: "the", start: 5.5, end: 5.7),
        .init(text: "demo.", start: 5.8, end: 6.2),
    ])

    func fresh(_ d: Double = 10) -> Project { Project.fresh(name: "t", duration: d) }

    @Test func deletingWordsCutsHalfTheSilenceAround() {
        let r = TranscriptEdit.cutRange(words: 2..<4, in: transcript, recordingDuration: 10)   // "this is"
        #expect(abs(r.lowerBound - 1.7) < 1e-9)       // half of the 0.2 s gap after "um"
        #expect(abs(r.upperBound - 2.25) < 1e-9)      // half of the 0.1 s gap before "uh,"
    }

    @Test func cutSplitsSlicesAndHidesTheWords() throws {
        var p = fresh()
        try p.cut(source: [TranscriptEdit.cutRange(words: 2..<4, in: transcript, recordingDuration: 10)])
        #expect(p.timeline.slices.count == 2)
        #expect(p.isValid(recordingDuration: 10))
        let map = TimeMap(slices: p.timeline.slices)
        #expect(!TranscriptEdit.isVisible(transcript.words[2], timeMap: map))
        #expect(TranscriptEdit.isVisible(transcript.words[1], timeMap: map))
        #expect(TranscriptEdit.isVisible(transcript.words[4], timeMap: map))
        #expect(abs(map.duration - (10 - 0.55)) < 1e-9)
    }

    @Test func restoreBringsTheWordsBack() throws {
        var p = fresh()
        let r = TranscriptEdit.cutRange(words: 2..<4, in: transcript, recordingDuration: 10)
        try p.cut(source: [r])
        p.restore(source: r, recordingDuration: 10)
        #expect(p.isValid(recordingDuration: 10))
        #expect(abs(TimeMap(slices: p.timeline.slices).duration - 10) < 1e-9)
        #expect(Set(p.timeline.slices.map(\.id)).count == p.timeline.slices.count)
    }

    @Test func fillersAreFoundWithPunctuationAndCase() {
        let map = TimeMap(slices: fresh().timeline.slices)
        #expect(TranscriptEdit.fillerRuns(in: transcript, timeMap: map) == [1..<2, 4..<5])
        #expect(TranscriptEdit.isFiller("Ähm"))
        #expect(!TranscriptEdit.isFiller("like"))
    }

    @Test func longPausesAreShortenedToKeep() {
        let map = TimeMap(slices: fresh().timeline.slices)
        let pauses = TranscriptEdit.longPauses(in: transcript, timeMap: map, events: [], minimum: 1, keep: 0.5)
        #expect(pauses.count == 1)
        #expect(abs(pauses[0].cut.lowerBound - 2.75) < 1e-9)
        #expect(abs(pauses[0].cut.upperBound - 5.25) < 1e-9)
        #expect(abs(pauses[0].saves - 2.5) < 1e-9)
    }

    @Test func pausesWithAClickOrKeyStay() {
        let map = TimeMap(slices: fresh().timeline.slices)
        let click: [TelemetryEvent] = [.down(t: 4, button: .left, x: 0, y: 0, clickCount: 1)]
        let key: [TelemetryEvent] = [.key(t: 3, phase: .down, keyCode: 0, chars: "a", mods: [])]
        #expect(TranscriptEdit.longPauses(in: transcript, timeMap: map, events: click).isEmpty)
        #expect(TranscriptEdit.longPauses(in: transcript, timeMap: map, events: key).isEmpty)
    }

    @Test func pausesFollowSpeed() throws {
        var p = fresh()
        try p.setSpeed(p.timeline.slices[0].id, 4)          // 3 s of silence plays in 0.75 s
        let map = TimeMap(slices: p.timeline.slices)
        #expect(TranscriptEdit.longPauses(in: transcript, timeMap: map, events: [], minimum: 1).isEmpty)
    }

    @Test func oneCleanUpPassIsValid() throws {
        var p = fresh()
        let map = TimeMap(slices: p.timeline.slices)
        let ranges = TranscriptEdit.fillerRuns(in: transcript, timeMap: map).map { TranscriptEdit.cutRange(words: $0, in: transcript, recordingDuration: 10) }
            + TranscriptEdit.longPauses(in: transcript, timeMap: map, events: []).map(\.cut)
        try p.cut(source: ranges)                           // the "uh," cut and the pause cut overlap
        #expect(p.isValid(recordingDuration: 10))
        let after = TimeMap(slices: p.timeline.slices)
        #expect(TranscriptEdit.fillerRuns(in: transcript, timeMap: after).isEmpty)
        #expect(["So", "this", "is", "the", "demo."].allSatisfy { w in
            transcript.words.contains { $0.text == w && TranscriptEdit.isVisible($0, timeMap: after) } })
    }

    @Test func cuttingEverythingThrows() {
        var p = fresh()
        #expect(throws: EditError.lastSlice) { try p.cut(source: [0..<10]) }
        #expect(p.timeline.slices.count == 1)
    }
}

@Suite("Speech activity (Phase 5)")
struct SpeechActivityTests {
    /// 10 ms levels: -60 dB silence with speech (-25 dB) in the given ranges.
    func activity(_ speech: [ClosedRange<Double>], length: Double = 6) -> SpeechActivity {
        let n = Int(length / 0.01)
        let levels: [Float] = (0..<n).map { i in speech.contains { $0.contains(Double(i) * 0.01) } ? -25 : -60 }
        return SpeechActivity(levels: levels, step: 0.01)
    }

    @Test func blobsBridgeShortGapsAndDropBlips() {
        let a = activity([1.0...1.3, 1.38...1.6, 2.0...2.04, 3.0...3.5])
        let b = a.blobs(from: 0, to: 6)
        #expect(b.count == 2)
        #expect(abs(b[0].lowerBound - 1.0) < 0.011 && abs(b[0].upperBound - 1.61) < 0.011)
    }

    @Test func refinementTightensWordsAndFindsSounds() {
        // Apple: "camera," 1.0–3.0 with 0.5 s silence first; "have." 3.0–5.0 = the word, a pause, then an "ähm".
        let t = Transcript(language: "en_US", source: "mic.m4a", words: [
            .init(text: "camera,", start: 1.0, end: 3.0), .init(text: "have.", start: 3.0, end: 5.0),
        ])
        let r = t.refined(with: activity([1.5...2.2, 3.0...3.25, 4.0...4.5]))
        #expect(r.refined == true)
        #expect(r.words.count == 3)
        #expect(abs(r.words[0].start - 1.45) < 0.02 && abs(r.words[0].end - 2.29) < 0.02)
        #expect(abs(r.words[1].end - 3.34) < 0.02)
        #expect(r.words[2].isSound && r.words[2].start > 3.9 && r.words[2].end < 4.6)
        // Now there are real gaps to find and cut: before "have." and before the sound.
        let map = TimeMap(slices: Project.fresh(name: "t", duration: 6).timeline.slices)
        #expect(TranscriptEdit.longPauses(in: r, timeMap: map, events: [], minimum: 0.4, keep: 0.3).count == 2)
        #expect(TranscriptEdit.fillerRuns(in: r, timeMap: map) == [2..<3])
    }

    @Test func quietWordsKeepTheirTimes() {
        let t = Transcript(language: "en_US", source: "mic.m4a", words: [.init(text: "hi", start: 1, end: 2)])
        #expect(t.refined(with: activity([4...5])).words == t.words)
    }

    @Test func soundsAreNotCaptioned() {
        let t = Transcript(language: "en_US", source: "mic.m4a", words: [
            .init(text: "Hello", start: 1, end: 1.5), .init(text: "…", start: 1.6, end: 2, sound: true),
        ])
        let track = CaptionTrack(transcript: t, timeMap: TimeMap(slices: Project.fresh(name: "t", duration: 4).timeline.slices))
        #expect(track.lines.map(\.text) == ["Hello"])
    }
}
