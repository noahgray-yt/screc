import Foundation
import Testing
@testable import ScrecCore

@Suite("Captions (Phase 5)")
struct CaptionTests {
    /// "Hello and welcome." (0.0–1.2) pause, "This is Screc" (2.0–3.0), "and more words here" (3.1–4.0)
    let transcript = Transcript(language: "en_US", source: "mic.m4a", words: [
        .init(text: "Hello", start: 0.0, end: 0.4), .init(text: "and", start: 0.4, end: 0.6), .init(text: "welcome.", start: 0.6, end: 1.2),
        .init(text: "This", start: 2.0, end: 2.3), .init(text: "is", start: 2.3, end: 2.5), .init(text: "Screc", start: 2.5, end: 3.0),
        .init(text: "and", start: 3.1, end: 3.3), .init(text: "more", start: 3.3, end: 3.6), .init(text: "words", start: 3.6, end: 3.8),
        .init(text: "here", start: 3.8, end: 4.0),
    ])
    func map(_ slices: [Slice] = [Slice(id: "S1", sourceStart: 0, sourceEnd: 10)]) -> TimeMap { TimeMap(slices: slices) }

    @Test func linesBreakAtSentencesAndPauses() {
        let tr = CaptionTrack(transcript: transcript, timeMap: map())
        #expect(tr.lines.map(\.text) == ["Hello and welcome.", "This is Screc and more words here"])
        #expect(tr.lines[0].start == 0 && abs(tr.lines[0].end - 1.6) < 1e-9)       // last word + 0.4 s
        #expect(tr.active(at: 1.8) == nil)                                         // the pause
        let a = tr.active(at: 2.6)
        #expect(a?.lineIndex == 1 && a?.wordIndex == 2)                            // "Screc" is being spoken
    }

    @Test func wordsInCutsAreDroppedAndSpeedIsApplied() {
        var fast = Slice(id: "B", sourceStart: 2, sourceEnd: 10)
        fast.speed = 2
        let tr = CaptionTrack(transcript: transcript, timeMap: map([Slice(id: "A", sourceStart: 0, sourceEnd: 0.5), fast]))
        // "and"(0.4–0.6) and "welcome."(0.6–1.2) fall in the cut; "Hello" stays.
        #expect(tr.lines.first?.text == "Hello")
        let screc = tr.lines.flatMap(\.words).first { $0.text == "Screc" }
        #expect(abs((screc?.start ?? 0) - (0.5 + 0.25)) < 1e-9)                  // 0.5 + (2.5 − 2) / 2
    }

    @Test func srtMatchesTheTimeline() {
        let srt = CaptionTrack(transcript: transcript, timeMap: map()).srt()
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:01,600\nHello and welcome.\n\n2\n00:00:02,000 --> "))
    }

    @Test func correctionsKeepTheTimeSpan() {
        var t = transcript
        t.replace(words: 3..<6, with: "This is Screc app")
        #expect(t.words.count == 11)
        #expect(t.words[3].start == 2.0 && abs(t.words[6].end - 3.0) < 1e-9)
        #expect(t.words[6].text == "app")
    }

    @Test func roundTripAndDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screc-tx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try transcript.save(bundle: dir)
        #expect(Transcript.load(bundle: dir) == transcript)
        let p = try Project.decode(from: Data(#"{"name":"x","timeline":{"slices":[]}}"#.utf8))
        #expect(p.look.captions == CaptionLook())
    }
}

@Suite("Caption placement")
struct CaptionPlacementTests {
    @Test func defaultAndDraggedPositions() {
        var look = CaptionLook()
        let out = CGSize(width: 1920, height: 1080), box = CGSize(width: 400, height: 60)
        #expect(look.origin(box: box, output: out) == CGPoint(x: 760, y: 1080 - 75.6 - 60))
        look.center = [0.25, 0.5]
        #expect(look.origin(box: box, output: out) == CGPoint(x: 280, y: 510))
        look.center = [1, 1]                                   // kept inside the output
        #expect(look.origin(box: box, output: out) == CGPoint(x: 1520, y: 1020))
    }
}
