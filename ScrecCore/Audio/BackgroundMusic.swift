import Foundation

/// One piece of music or one sound on the timeline (Phase 5): the owner's own file, placed in **timeline**
/// time (music stays where it is when the video is edited). Clips on the same lane never overlap.
public struct AudioClip: Codable, Equatable, Sendable, Identifiable {
    public enum Lane: String, Codable, Sendable, CaseIterable { case music, sound }
    public var id: String
    public var lane: Lane
    /// Absolute path of the audio file (referenced, not copied).
    public var file: String
    /// Length of the file in seconds.
    public var fileDuration: Double
    public var start: Double
    public var duration: Double
    /// Seconds into the file where the clip begins (counting loops).
    public var offset: Double = 0
    /// 0…1 (linear gain).
    public var volume: Double
    /// Music repeats to fill the clip; a sound plays once.
    public var loop: Bool
    public var fadeIn: Double
    public var fadeOut: Double

    public var end: Double { start + duration }
    public var title: String { URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent }

    public init(id: String, lane: Lane, file: String, fileDuration: Double, start: Double, duration: Double) {
        self.id = id
        self.lane = lane
        self.file = file
        self.fileDuration = fileDuration
        self.start = start
        self.duration = duration
        volume = lane == .music ? 0.3 : 0.8
        loop = lane == .music
        fadeIn = lane == .music ? 0.5 : 0.02
        fadeOut = lane == .music ? 2.0 : 0.05
    }
}

/// The audio lanes: music and sound clips, plus ducking of the music under the voice.
public struct BackgroundMusic: Codable, Equatable, Sendable {
    public var clips: [AudioClip] = []
    /// Lower the music lane while the microphone has speech.
    public var duck = true
    /// Music level while speaking, as a fraction of the clip volume.
    public var duckLevel = 0.3

    /// Single track of the first 5.5 build (kept only to convert it into a clip when a project is opened).
    public var legacyTrack: String?
    public var legacyVolume: Double?

    public static let loopCrossfade = 1.5
    /// How fast the music goes down when speech starts, and back up after it ends.
    public static let duckAttack = 0.15
    public static let duckRelease = 0.6

    public init() {}

    enum CodingKeys: String, CodingKey { case clips, duck, duckLevel, track, volume }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackgroundMusic()
        clips = try c.decodeIfPresent([AudioClip].self, forKey: .clips) ?? []
        duck = try c.decodeIfPresent(Bool.self, forKey: .duck) ?? d.duck
        duckLevel = try c.decodeIfPresent(Double.self, forKey: .duckLevel) ?? d.duckLevel
        legacyTrack = try c.decodeIfPresent(String.self, forKey: .track)
        legacyVolume = try c.decodeIfPresent(Double.self, forKey: .volume)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clips, forKey: .clips)
        try c.encode(duck, forKey: .duck)
        try c.encode(duckLevel, forKey: .duckLevel)
    }

    public func clips(on lane: AudioClip.Lane) -> [AudioClip] { clips.filter { $0.lane == lane }.sorted { $0.start < $1.start } }
}

public extension Project {
    /// A new unique audio clip id ("A1", "A2", …).
    func newAudioID() -> String {
        let used = Set(music.clips.map(\.id))
        var n = 1
        while used.contains("A\(n)") { n += 1 }
        return "A\(n)"
    }

    /// Free room on a lane around timeline time `t` (nil if `t` is inside a clip), excluding clip `except`.
    func audioGap(lane: AudioClip.Lane, at t: Double, except: String? = nil) -> ClosedRange<Double>? {
        let end = max(TimeMap(slices: timeline.slices).duration, t)
        var lo = 0.0, hi = end
        for c in music.clips(on: lane) where c.id != except {
            if c.start <= t && t < c.end { return nil }
            if c.end <= t { lo = max(lo, c.end) } else { hi = min(hi, c.start) }
        }
        return lo...hi
    }

    /// Adds a file at `t` on a lane: music fills the free room (looping), a sound plays once.
    @discardableResult
    mutating func addAudio(file: String, fileDuration: Double, lane: AudioClip.Lane, at t: Double) throws -> String {
        guard fileDuration > 0, let gap = audioGap(lane: lane, at: t), gap.upperBound - gap.lowerBound >= 0.1 else { throw EditError.noRoom }
        let start = max(t, gap.lowerBound)
        let length = lane == .music ? gap.upperBound - start : min(fileDuration, gap.upperBound - start)
        guard length >= 0.1 else { throw EditError.noRoom }
        let id = newAudioID()
        music.clips.append(AudioClip(id: id, lane: lane, file: file, fileDuration: fileDuration, start: start, duration: length))
        return id
    }

    private func audioIndex(_ id: String) throws -> Int {
        guard let i = music.clips.firstIndex(where: { $0.id == id }) else { throw EditError.unknownClip }
        return i
    }

    /// Room for clip `id` between its neighbours on the lane.
    private func audioRoom(_ i: Int) -> ClosedRange<Double> {
        let c = music.clips[i]
        let end = max(TimeMap(slices: timeline.slices).duration, c.end)
        var lo = 0.0, hi = end
        for o in music.clips(on: c.lane) where o.id != c.id {
            if o.start < c.start || (o.start == c.start && o.id < c.id) { lo = max(lo, o.end) } else { hi = min(hi, o.start) }
        }
        return lo...max(hi, lo)
    }

    mutating func moveAudio(_ id: String, toStart t: Double) throws {
        let i = try audioIndex(id)
        let room = audioRoom(i)
        let length = min(music.clips[i].duration, room.upperBound - room.lowerBound)
        music.clips[i].duration = length
        music.clips[i].start = min(max(t, room.lowerBound), room.upperBound - length)
    }

    /// Moves one edge to `t`. Moving the start trims the beginning (the music under the clip stays in place).
    /// A sound cannot get longer than its file.
    mutating func resizeAudio(_ id: String, start: Bool, to t: Double) throws {
        let i = try audioIndex(id)
        let room = audioRoom(i)
        var c = music.clips[i]
        if start {
            let earliest = max(room.lowerBound, c.loop ? -Double.infinity : c.start - c.offset)
            let s = min(max(t, earliest), c.end - 0.1)
            c.offset += s - c.start
            c.duration = c.end - s
            c.start = s
        } else {
            let latest = min(room.upperBound, c.loop ? .infinity : c.start + c.fileDuration - c.offset)
            c.duration = max(min(t, latest), c.start + 0.1) - c.start
        }
        music.clips[i] = c
    }

    /// Splits a clip at timeline time `t`; the second part continues the music seamlessly.
    @discardableResult
    mutating func splitAudio(_ id: String, at t: Double) throws -> String {
        let i = try audioIndex(id)
        var left = music.clips[i]
        guard t - left.start >= 0.1, left.end - t >= 0.1 else { throw EditError.tooCloseToEdge }
        var right = left
        right.id = newAudioID()
        right.start = t
        right.duration = left.end - t
        right.offset = left.offset + (t - left.start)
        left.duration = t - left.start
        music.clips[i] = left
        music.clips.append(right)
        return right.id
    }

    mutating func updateAudio(_ id: String, _ change: (inout AudioClip) -> Void) throws {
        let i = try audioIndex(id)
        change(&music.clips[i])
        music.clips[i].volume = min(max(music.clips[i].volume, 0), 1)
    }

    /// Projects from the first 5.5 build had one track for the whole video: make it a music clip.
    mutating func migrateLegacyMusic(fileDuration: Double) {
        guard let track = music.legacyTrack, music.clips.isEmpty else { return }
        var c = AudioClip(id: "A1", lane: .music, file: track, fileDuration: fileDuration, start: 0,
                          duration: TimeMap(slices: timeline.slices).duration)
        c.volume = music.legacyVolume ?? c.volume
        music.clips = [c]
        music.legacyTrack = nil
        music.legacyVolume = nil
    }
}

/// The music folder: one subfolder per genre, or a `<track>.genre` text file next to a track.
public enum MusicLibrary {
    public struct Track: Equatable, Sendable, Identifiable {
        public var url: URL
        public var title: String
        public var genre: String
        public var id: String { url.path }
    }

    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/ScrecTracks", isDirectory: true)
    }

    public static let genres = ["Lo-Fi", "Commercial", "Electronic", "Instrumental"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]

    /// All tracks under `folder`, sorted by genre (the four standard ones first) and title.
    public static func scan(_ folder: URL = folder) -> [Track] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var tracks: [Track] = []
        for case let url as URL in walker where audioExtensions.contains(url.pathExtension.lowercased()) {
            let sidecar = url.appendingPathExtension("genre")
            let tagged = (try? String(contentsOf: sidecar, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = url.deletingLastPathComponent().standardizedFileURL
            let inSubfolder = parent.path != folder.standardizedFileURL.path
            let genre = (tagged?.isEmpty == false ? tagged : nil) ?? (inSubfolder ? parent.lastPathComponent : "Other")
            tracks.append(Track(url: url, title: url.deletingPathExtension().lastPathComponent, genre: genre))
        }
        func rank(_ g: String) -> Int { genres.firstIndex(of: g) ?? genres.count }
        return tracks.sorted { (rank($0.genre), $0.genre, $0.title.lowercased()) < (rank($1.genre), $1.genre, $1.title.lowercased()) }
    }
}

/// Mixes the audio lanes for the edited timeline: clips looped or played once, faded, the music ducked under
/// the voice.
public enum MusicMix {
    /// Music level per `step` seconds: 1, or `level` while speaking, with a short look-ahead and smooth
    /// attack and release. All 1 when `voice` is empty.
    public static func duck(duration: Double, voice: [Range<Double>], level: Double, step: Double = 0.01) -> [Float] {
        let n = max(Int((duration / step).rounded(.up)), 0)
        var target = [Float](repeating: 1, count: n)
        for v in voice {
            let a = max(Int((v.lowerBound / step).rounded(.down)), 0), b = min(Int((v.upperBound / step).rounded(.up)), n)
            if a < b { for i in a..<b { target[i] = Float(level) } }
        }
        // Look-ahead: start going down a little before speech, so the first word is not covered.
        let lead = Int(BackgroundMusic.duckAttack / step)
        var ahead = target
        for i in 0..<n where target[i] < 1 { for k in max(i - lead, 0)..<i { ahead[k] = min(ahead[k], target[i]) } }
        let span = Float(max(1 - level, 0.0001))
        let down = Float(step / BackgroundMusic.duckAttack) * span, up = Float(step / BackgroundMusic.duckRelease) * span
        var out = [Float](repeating: 1, count: n)
        var current: Float = ahead.first ?? 1
        for i in 0..<n {
            let t = ahead[i]
            if t < current { current = max(t, current - down) } else if t > current { current = min(t, current + up) }
            out[i] = current
        }
        return out
    }

    /// Fade gain of a clip at `t` seconds into it. Edges that continue in a neighbouring clip (a split) do not fade.
    public static func fade(_ c: AudioClip, at t: Double, length: Double, fadeInEdge: Bool, fadeOutEdge: Bool) -> Float {
        var g = 1.0
        if fadeInEdge, c.fadeIn > 0 { g = min(g, t / c.fadeIn) }
        if fadeOutEdge, c.fadeOut > 0 { g = min(g, (length - t) / c.fadeOut) }
        return Float(min(max(g, 0), 1))
    }

    /// True if `b` continues `a` without a seam (same file, adjacent, offsets in line).
    public static func continues(_ a: AudioClip, _ b: AudioClip) -> Bool {
        a.lane == b.lane && a.file == b.file && abs(a.end - b.start) < 0.001 && abs(a.offset + a.duration - b.offset) < 0.001
    }

    /// File frame for clip frame `i` (counting from the file start) when looping: per output frame, (frame A,
    /// weight A, frame B or -1), with a crossfade of `crossfadeFrames` at each loop seam.
    public static func loopSource(frame i: Int, sourceFrames: Int, crossfadeFrames: Int) -> (a: Int, wa: Float, b: Int) {
        let xf = min(crossfadeFrames, sourceFrames / 4)
        let period = sourceFrames - xf
        guard period > 0 else { return (i % max(sourceFrames, 1), 1, -1) }
        let k = i / period, pos = i % period
        // The tail of the previous pass fades out while the head of this pass fades in.
        if k > 0, pos < xf {
            let w = Float(pos) / Float(max(xf, 1))
            return (pos, w, period + pos)
        }
        return (pos, 1, -1)
    }

    /// Renders all clips into `length` frames per channel. `sources` holds each file's channels at `sampleRate`.
    public static func render(clips: [AudioClip], sources: [String: [[Float]]], channels: Int, length: Int, sampleRate: Double,
                              duck: [Float], step: Double = 0.01) -> [[Float]] {
        var out = [[Float]](repeating: [Float](repeating: 0, count: max(length, 0)), count: channels)
        let timelineEnd = Double(length) / sampleRate
        let xf = Int(BackgroundMusic.loopCrossfade * sampleRate)
        let block = max(Int(step * sampleRate), 1)
        for c in clips {
            guard let src = sources[c.file], let frames = src.first?.count, frames > 0 else { continue }
            let n0 = max(Int((c.start * sampleRate).rounded()), 0)
            let n1 = min(Int((min(c.end, timelineEnd) * sampleRate).rounded()), length)
            guard n0 < n1 else { continue }
            let lengthSeconds = Double(n1 - n0) / sampleRate
            let fadeIn = !clips.contains { continues($0, c) }
            let fadeOut = !clips.contains { continues(c, $0) } || c.end > timelineEnd
            let first = Int((c.offset * sampleRate).rounded())
            for ch in 0..<channels {
                let s = src[min(ch, src.count - 1)]
                s.withUnsafeBufferPointer { s in
                    out[ch].withUnsafeMutableBufferPointer { o in
                        for i in n0..<n1 {
                            let k = first + (i - n0)
                            var v: Float
                            if c.loop {
                                let (a, wa, b) = loopSource(frame: k, sourceFrames: frames, crossfadeFrames: xf)
                                v = s[a] * wa
                                if b >= 0 { v += s[b] * (1 - wa) }
                            } else {
                                guard k >= 0, k < frames else { continue }
                                v = s[k]
                            }
                            var g = Float(c.volume) * fade(c, at: Double(i - n0) / sampleRate, length: lengthSeconds, fadeInEdge: fadeIn, fadeOutEdge: fadeOut)
                            if c.lane == .music, !duck.isEmpty { g *= duck[min(i / block, duck.count - 1)] }
                            o[i] += v * g
                        }
                    }
                }
            }
        }
        // Keep the sum of overlapping lanes in range.
        for ch in 0..<channels { for i in 0..<out[ch].count where abs(out[ch][i]) > 1 { out[ch][i] = out[ch][i] > 0 ? 1 : -1 } }
        return out
    }
}
