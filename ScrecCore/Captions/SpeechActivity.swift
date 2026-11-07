import Foundation

/// Where someone is speaking, from the loudness of the voice track (Phase 5: transcript editing).
///
/// Apple's recogniser gives words without gaps: the silence before or after a word is counted as part of it,
/// and sounds it does not write down (um, äh, breaths) disappear into the neighbouring word. Measuring the
/// loudness puts cuts into real silence and finds pauses and unwritten sounds.
public struct SpeechActivity: Sendable {
    /// Loudness in dB (RMS) per `step` seconds.
    public let levels: [Float]
    public let step: Double
    /// Frames above this count as speech: 40 % of the way from the noise floor (10th percentile) to the
    /// speech level (90th percentile).
    public let threshold: Float

    public init(levels: [Float], step: Double) {
        self.levels = levels
        self.step = step
        let sorted = levels.sorted()
        if sorted.count < 20 {
            threshold = -50
        } else {
            let floor = sorted[sorted.count / 10], speech = sorted[sorted.count * 9 / 10]
            threshold = floor + 0.4 * max(speech - floor, 12)
        }
    }

    public static let mergeGap = 0.15
    public static let minimumBlob = 0.08

    /// Stretches of speech within `[a, b)`; gaps shorter than `mergeGap` are bridged, blips shorter than
    /// `minimumBlob` are ignored.
    public func blobs(from a: Double, to b: Double) -> [Range<Double>] {
        let i0 = max(Int((a / step).rounded(.down)), 0), i1 = min(Int((b / step).rounded(.up)), levels.count)
        guard i0 < i1 else { return [] }
        var raw: [Range<Double>] = []
        var start: Int?
        for i in i0..<i1 {
            if levels[i] > threshold {
                if start == nil { start = i }
            } else if let s = start {
                raw.append(Double(s) * step..<Double(i) * step)
                start = nil
            }
        }
        if let s = start { raw.append(Double(s) * step..<Double(i1) * step) }
        var merged: [Range<Double>] = []
        for r in raw {
            if let last = merged.last, r.lowerBound - last.upperBound < Self.mergeGap {
                merged[merged.count - 1] = last.lowerBound..<r.upperBound
            } else {
                merged.append(r)
            }
        }
        return merged.filter { $0.upperBound - $0.lowerBound >= Self.minimumBlob }
            .map { max($0.lowerBound, a)..<min($0.upperBound, b) }
    }
}

public extension Transcript {
    /// Silence that must come before an unwritten sound, and its shortest length.
    static let soundGap = 0.25
    static let minimumSound = 0.2

    /// Word times tightened to the speech inside each word's span (a little air kept on both sides), and
    /// extra speech inside a span that the recogniser did not write down added as `sound` words.
    func refined(with activity: SpeechActivity) -> Transcript {
        var out: [Word] = []
        for w in words {
            if w.isSound {
                out.append(w)
                continue
            }
            let blobs = activity.blobs(from: w.start, to: w.end)
            guard let first = blobs.first else {
                out.append(w)                                   // too quiet to tell: keep Apple's times
                continue
            }
            // A first blob much shorter than the word needs is probably not the whole word: keep it together.
            let expected = 0.05 + 0.06 * Double(w.text.filter(\.isLetter).count)
            let split = first.upperBound - first.lowerBound >= 0.3 * expected
            // Later blobs belong to the word when they follow closely (stop consonants like the d in "paid"
            // leave a short silence); after a clear silence, a long enough blob is a sound of its own.
            var wordEnd = first.upperBound
            var sounds: [Range<Double>] = []
            var lastEnd = first.upperBound
            for b in blobs.dropFirst() {
                if !split || (sounds.isEmpty && b.lowerBound - lastEnd < Self.soundGap) {
                    if sounds.isEmpty { wordEnd = b.upperBound }
                } else if b.upperBound - b.lowerBound >= Self.minimumSound {
                    sounds.append(b)
                }
                lastEnd = b.upperBound
            }
            var word = w
            word.start = max(w.start, first.lowerBound - 0.05)
            word.end = min(w.end, wordEnd + 0.08)
            out.append(word)
            for b in sounds {
                let s = max(b.lowerBound - 0.03, out[out.count - 1].end)
                let e = min(b.upperBound + 0.05, w.end)
                if e - s >= Self.minimumSound { out.append(Word(text: "…", start: s, end: e, sound: true)) }
            }
        }
        var t = self
        t.words = out
        t.refined = true
        return t
    }
}
