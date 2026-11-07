import Foundation

/// A transcript of the recording's voice (Phase 5 item 3), in **source time**. Stored as `transcript.json` in the
/// bundle: it is slow-ish to make and depends on the chosen language, so it is kept, not cached.
public struct Transcript: Codable, Equatable, Sendable {
    public struct Word: Codable, Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        /// A sound the recogniser left out (often um, äh or a breath), found in the audio. Not shown in captions.
        public var sound: Bool?
        public init(text: String, start: Double, end: Double, sound: Bool? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.sound = sound
        }
        public var isSound: Bool { sound == true }
    }

    public var schemaVersion = 1
    /// True once word times were tightened to the speech in the audio (`refined(with:)`).
    public var refined: Bool?
    /// Locale identifier used for recognition, e.g. "en_US".
    public var language: String
    /// Which file was transcribed ("mic.m4a" or "system.m4a").
    public var source: String
    public var words: [Word]

    public init(language: String, source: String, words: [Word]) {
        self.language = language
        self.source = source
        self.words = words
    }

    public static let fileName = "transcript.json"

    public static func load(bundle: URL) -> Transcript? {
        (try? Data(contentsOf: bundle.appendingPathComponent(fileName))).flatMap { try? JSONCoding.decoder.decode(Transcript.self, from: $0) }
    }

    public func save(bundle: URL) throws {
        try JSONCoding.encoder.encode(self).write(to: bundle.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Replaces the text of the words `range` with `text`, keeping their overall time span (corrections in the
    /// Captions panel). New words share the span in proportion to their length.
    public mutating func replace(words range: Range<Int>, with text: String) {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= words.count else { return }
        let start = words[range.lowerBound].start, end = words[range.upperBound - 1].end
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else {
            words.removeSubrange(range)
            return
        }
        let total = Double(parts.reduce(0) { $0 + $1.count + 1 })
        var t = start
        var new: [Word] = []
        for p in parts {
            let d = (end - start) * Double(p.count + 1) / total
            new.append(Word(text: p, start: t, end: t + d))
            t += d
        }
        words.replaceSubrange(range, with: new)
    }
}

/// Caption settings (part of the look).
public struct CaptionLook: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        /// White text on a dark rounded box.
        case classic
        /// Large heavy white text with a dark outline, no box.
        case bold
        /// Like classic, the word being spoken is coloured.
        case highlight
        /// Small white text with a soft shadow.
        case minimal
    }
    public enum Position: String, Codable, Sendable, CaseIterable { case bottom, top }
    public enum Size: String, Codable, Sendable, CaseIterable {
        case small, medium, large
        /// Text height as a fraction of the output's short side.
        public var fraction: Double {
            switch self {
            case .small: 0.036
            case .medium: 0.046
            case .large: 0.06
            }
        }
    }

    public var enabled = false
    public var style: Style = .classic
    public var position: Position = .bottom
    public var size: Size = .medium
    /// "system", "rounded", "serif", "mono", or the name of an installed font family.
    public var font = "system"
    public var textColor = "#FFFFFF"
    /// Colour of the spoken word (Highlight style).
    public var highlightColor = "#FFD84D"
    /// Box behind the text (Classic and Highlight styles).
    public var boxColor = "#0A0A0F"
    public var boxOpacity = 0.72
    /// Where the caption was dragged on the canvas: its centre as a fraction of the output (x, y from the
    /// top left). nil = `position`.
    public var center: [Double]?

    public init() {}

    /// Top-left corner, in output pixels, of a caption box of `box` pixels. Kept inside the output.
    public func origin(box: CGSize, output: CGSize) -> CGPoint {
        let w = Double(box.width), h = Double(box.height), W = Double(output.width), H = Double(output.height)
        let margin = 0.07 * min(W, H)
        var x = (W - w) / 2
        var y = position == .bottom ? H - margin - h : margin
        if let c = center, c.count == 2 {
            x = c[0] * W - w / 2
            y = c[1] * H - h / 2
        }
        return CGPoint(x: min(max(x, 0), max(W - w, 0)), y: min(max(y, 0), max(H - h, 0)))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .classic
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? .bottom
        size = try c.decodeIfPresent(Size.self, forKey: .size) ?? .medium
        let d = CaptionLook()
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? d.font
        textColor = try c.decodeIfPresent(String.self, forKey: .textColor) ?? d.textColor
        highlightColor = try c.decodeIfPresent(String.self, forKey: .highlightColor) ?? d.highlightColor
        boxColor = try c.decodeIfPresent(String.self, forKey: .boxColor) ?? d.boxColor
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? d.boxOpacity
        center = try c.decodeIfPresent([Double].self, forKey: .center)
    }
}

/// Caption lines in **timeline** time, made from a transcript and the time map.
///
/// Words inside cuts are dropped; times follow slice speeds. A new line starts after a pause, after a sentence
/// end, or when a line would get too long. Each line stays at least `minShow` and briefly after its last word,
/// but never overlaps the next line.
public struct CaptionTrack: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        /// Index in the transcript (for corrections).
        public var index: Int
    }

    public struct Line: Equatable, Sendable {
        public var words: [Word]
        public var start: Double
        public var end: Double
        public var text: String { words.map(\.text).joined(separator: " ") }
    }

    public static let pauseBreak = 0.6
    public static let maxChars = 64
    public static let maxDuration = 5.0
    public static let minShow = 1.0
    public static let tail = 0.4

    public private(set) var lines: [Line]

    public init(transcript: Transcript?, timeMap: TimeMap) {
        guard let transcript else {
            lines = []
            return
        }
        // Map every word to the timeline; drop words in cuts.
        var mapped: [Word] = []
        for (i, w) in transcript.words.enumerated() where !w.isSound {
            let mid = (w.start + w.end) / 2
            guard timeMap.toTimeline(mid) != nil, let a = timeMap.toTimeline(w.start) ?? timeMap.timelineAtOrAfter(source: w.start) else { continue }
            let b = timeMap.toTimeline(w.end) ?? (a + (w.end - w.start))
            mapped.append(Word(text: w.text, start: a, end: max(b, a + 0.05), index: i))
        }
        var lines: [Line] = []
        var current: [Word] = []
        let source = transcript.words
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(Line(words: current, start: first.start, end: max(last.end + Self.tail, first.start + Self.minShow)))
            current.removeAll()
        }
        for w in mapped {
            if let last = current.last, let first = current.first {
                let length = current.map(\.text.count).reduce(0, +) + current.count + w.text.count
                let sentenceEnd = last.text.last.map { ".!?".contains($0) } ?? false
                // A pause in the recording, or a cut between the two words, also starts a new line.
                let sourceGap = source[w.index].start - source[last.index].end
                let cutBetween = timeMap.entry(containingSource: (source[last.index].start + source[last.index].end) / 2)?.sliceID
                    != timeMap.entry(containingSource: (source[w.index].start + source[w.index].end) / 2)?.sliceID
                if w.start - last.end > Self.pauseBreak || sourceGap > Self.pauseBreak || cutBetween
                    || length > Self.maxChars || w.end - first.start > Self.maxDuration || sentenceEnd {
                    flush()
                }
            }
            current.append(w)
        }
        flush()
        for i in lines.indices.dropLast() where lines[i].end > lines[i + 1].start {
            lines[i].end = max(lines[i + 1].start, lines[i].start + 0.05)
        }
        if let last = lines.indices.last { lines[last].end = min(lines[last].end, max(timeMap.duration, lines[last].start)) }
        self.lines = lines
    }

    /// The line on screen at `t`, and the index (within the line) of the word being spoken, if any.
    public func active(at t: Double) -> (line: Line, lineIndex: Int, wordIndex: Int?)? {
        guard let i = lines.lastIndex(where: { $0.start <= t && t < $0.end }) else { return nil }
        let word = lines[i].words.lastIndex { $0.start <= t }
        return (lines[i], i, word)
    }

    /// SubRip (.srt) text matching the edited timeline.
    public func srt() -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((max(t, 0) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return lines.enumerated().map { i, l in "\(i + 1)\n\(stamp(l.start)) --> \(stamp(l.end))\n\(l.text)\n" }.joined(separator: "\n")
    }
}
