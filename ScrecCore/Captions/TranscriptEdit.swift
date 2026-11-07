import Foundation

/// Transcript editing (Phase 5 item 4): deleting words cuts the video; one pass removes filler words and
/// shortens long pauses. Everything is a list of **source** ranges that `Project.cut(source:)` removes.
public enum TranscriptEdit {
    /// Hesitation sounds that are never real words (English and German). Ambiguous words like "like" are not
    /// included. Apple's recogniser often leaves these out of the text already.
    public static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "hm", "mm", "mhm",
                                              "äh", "ähm", "öh", "öhm", "ehm", "hä"]

    public static func isFiller(_ text: String) -> Bool {
        fillers.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    /// True if the word plays in the edited timeline (not inside a cut).
    public static func isVisible(_ w: Transcript.Word, timeMap: TimeMap) -> Bool {
        timeMap.toTimeline((w.start + w.end) / 2) != nil
    }

    /// The source range removed when the words `range` are deleted: the words plus half of the silence on each
    /// side, so the remaining pause between the neighbours sounds natural. Silence before the first word or after
    /// the last counts as at most 0.3 s.
    public static func cutRange(words range: Range<Int>, in t: Transcript, recordingDuration d: Double) -> Range<Double> {
        let first = t.words[range.lowerBound], last = t.words[range.upperBound - 1]
        let before = range.lowerBound > 0 ? first.start - t.words[range.lowerBound - 1].end : min(first.start, 0.3)
        let after = range.upperBound < t.words.count ? t.words[range.upperBound].start - last.end : min(d - last.end, 0.3)
        let a = max(first.start - max(before, 0) / 2, 0)
        let b = min(last.end + max(after, 0) / 2, d)
        return a..<max(b, a + 0.01)
    }

    /// Runs of consecutive filler words and unwritten sounds that still play, as word index ranges.
    public static func fillerRuns(in t: Transcript, timeMap: TimeMap) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (i, w) in t.words.enumerated() {
            if (w.isSound || isFiller(w.text)) && isVisible(w, timeMap: timeMap) {
                if start == nil { start = i }
            } else if let s = start {
                runs.append(s..<i)
                start = nil
            }
        }
        if let s = start { runs.append(s..<t.words.count) }
        return runs
    }

    public struct Pause: Equatable, Sendable {
        /// Source range that is removed (the middle of the pause).
        public var cut: Range<Double>
        /// How much shorter the timeline gets.
        public var saves: Double
    }

    /// Silences between two words that last longer than `minimum` seconds on the timeline, shortened to `keep`.
    /// Pauses with a click or a key press in them are kept: something happens on screen there.
    public static func longPauses(in t: Transcript, timeMap: TimeMap, events: [TelemetryEvent],
                                  minimum: Double = 1.0, keep: Double = 0.5) -> [Pause] {
        let actions = events.compactMap { e -> Double? in
            switch e {
            case let .down(t, _, _, _, _): t
            case let .key(t, .down, _, _, _, _): t
            default: nil
            }
        }.sorted()
        var pauses: [Pause] = []
        for (prev, next) in zip(t.words, t.words.dropFirst()) {
            // Both edges must be in the same slice (a cut between them is already an edit).
            guard let e = timeMap.entry(containingSource: prev.end), e.sliceID == timeMap.entry(containingSource: next.start)?.sliceID
            else { continue }
            let gap = next.start - prev.end
            guard gap / e.speed > minimum else { continue }
            if actions.contains(where: { $0 > prev.end && $0 < next.start }) { continue }
            let half = keep * e.speed / 2
            pauses.append(Pause(cut: (prev.end + half)..<(next.start - half), saves: (gap - keep * e.speed) / e.speed))
        }
        return pauses
    }
}

public extension Project {
    /// Removes the source ranges from the timeline, splitting slices where needed (pieces keep their settings).
    /// Leftover pieces shorter than 0.05 s are dropped. Throws `lastSlice` if nothing would remain.
    mutating func cut(source ranges: [Range<Double>]) throws {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        guard !sorted.isEmpty else { return }
        var used = Set(timeline.slices.map(\.id) + zooms.map(\.id) + masks.map(\.id))
        func freshID() -> String {
            var n = 1
            while used.contains("S\(n)") { n += 1 }
            used.insert("S\(n)")
            return "S\(n)"
        }
        var out: [Slice] = []
        for slice in timeline.slices {
            var pieces: [(Double, Double)] = [(slice.sourceStart, slice.sourceEnd)]
            for r in sorted where r.lowerBound < slice.sourceEnd && r.upperBound > slice.sourceStart {
                pieces = pieces.flatMap { a, b -> [(Double, Double)] in
                    guard r.lowerBound < b, r.upperBound > a else { return [(a, b)] }
                    return [(a, min(r.lowerBound, b)), (max(r.upperBound, a), b)].filter { $0.1 - $0.0 > 0 }
                }
            }
            for (k, (a, b)) in pieces.filter({ $0.1 - $0.0 >= 0.05 }).enumerated() {
                var s = slice
                if k > 0 { s.id = freshID() }
                s.sourceStart = a
                s.sourceEnd = b
                out.append(s)
            }
        }
        guard !out.isEmpty else { throw EditError.lastSlice }
        timeline.slices = out
    }

    /// Brings a source range back into the timeline (the parts of it that are cut), with the settings of the
    /// neighbouring slice.
    mutating func restore(source r: Range<Double>, recordingDuration d: Double) {
        let lo = max(r.lowerBound, 0), hi = min(r.upperBound, d)
        guard hi > lo else { return }
        var gaps: [(Double, Double)] = [(lo, hi)]
        for s in timeline.slices {
            gaps = gaps.flatMap { a, b -> [(Double, Double)] in
                guard s.sourceStart < b, s.sourceEnd > a else { return [(a, b)] }
                return [(a, min(s.sourceStart, b)), (max(s.sourceEnd, a), b)].filter { $0.1 - $0.0 > 0.001 }
            }
        }
        for (a, b) in gaps {
            let i = timeline.slices.firstIndex { $0.sourceStart >= b } ?? timeline.slices.count
            let neighbour = i > 0 ? timeline.slices[i - 1] : timeline.slices.first
            var s = neighbour ?? Slice(id: "", sourceStart: a, sourceEnd: b)
            s.id = newID("S")
            s.sourceStart = a
            s.sourceEnd = b
            timeline.slices.insert(s, at: i)
        }
    }
}
