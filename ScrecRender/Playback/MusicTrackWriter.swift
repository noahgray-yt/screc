@preconcurrency import AVFoundation
import Foundation
import ScrecCore

/// Renders the audio lanes of a project (music and sound clips) into `cache/music-<hash>.caf` (Phase 5): stereo,
/// in **timeline** time, music ducked under the microphone's speech. Added to the composition like the click
/// sounds, so preview and export hear the same thing. Unchanged clips and edits reuse the file.
public enum MusicTrackWriter {
    public static let sampleRate = 48_000.0

    /// Returns the file for this project, writing it if needed, or nil without clips (or when every file is gone).
    public static func file(for p: PreparedProject, bundle: URL) async throws -> URL? {
        let m = p.project.music
        let clips = m.clips.filter { FileManager.default.fileExists(atPath: $0.file) && $0.start < p.timeMap.duration }
        guard !clips.isEmpty, p.timeMap.duration > 0 else { return nil }
        var hasher = Hasher()
        for c in clips {
            hasher.combine(c.id)
            hasher.combine(c.file)
            let attributes = try? FileManager.default.attributesOfItem(atPath: c.file)
            hasher.combine((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970)
            hasher.combine(attributes?[.size] as? Int)
            for v in [c.start, c.duration, c.offset, c.volume, c.fadeIn, c.fadeOut] { hasher.combine(v) }
            hasher.combine(c.loop)
            hasher.combine(c.lane.rawValue)
        }
        hasher.combine(m.duck)
        hasher.combine(m.duckLevel)
        for e in p.timeMap.entries {
            hasher.combine(e.sourceStart)
            hasher.combine(e.sourceEnd)
            hasher.combine(e.speed)
        }
        let name = String(format: "music-%016llx.caf", UInt64(bitPattern: Int64(hasher.finalize())))
        let dir = bundle.appendingPathComponent(BundleLayout.cache, isDirectory: true)
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        // Speech on the microphone, in timeline time.
        var duck: [Float] = []
        let mic = bundle.appendingPathComponent(BundleLayout.mic)
        if m.duck, clips.contains(where: { $0.lane == .music }), FileManager.default.fileExists(atPath: mic.path) {
            let activity = SpeechActivity(levels: try await AudioLevels.rms(url: mic), step: AudioLevels.step)
            var voice: [Range<Double>] = []
            for b in activity.blobs(from: 0, to: Double(activity.levels.count) * activity.step) {
                voice += p.timeMap.timelineIntervals(sourceStart: b.lowerBound, sourceEnd: b.upperBound).map { $0.lowerBound..<$0.upperBound }
            }
            duck = MusicMix.duck(duration: p.timeMap.duration, voice: voice, level: m.duckLevel)
        }

        // Each file once, decoded to 48 kHz stereo.
        var sources: [String: [[Float]]] = [:]
        for path in Set(clips.map(\.file)) {
            var left: [Float] = [], right: [Float] = []
            try await AudioLevels.readPCM(url: URL(fileURLWithPath: path), sampleRate: sampleRate, channels: 2) { s in
                left.reserveCapacity(left.count + s.count / 2)
                right.reserveCapacity(right.count + s.count / 2)
                var i = 0
                while i + 1 < s.count {
                    left.append(s[i])
                    right.append(s[i + 1])
                    i += 2
                }
            }
            if !left.isEmpty { sources[path] = [left, right] }
        }
        guard !sources.isEmpty else { return nil }
        try Task.checkCancellation()

        let length = Int((p.timeMap.duration * sampleRate).rounded())
        let mixed = MusicMix.render(clips: clips, sources: sources, channels: 2, length: length, sampleRate: sampleRate, duck: duck)
        try Task.checkCancellation()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(length)
        for c in 0..<2 {
            mixed[c].withUnsafeBufferPointer { src in buffer.floatChannelData![c].update(from: src.baseAddress!, count: length) }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("music-") { try? FileManager.default.removeItem(at: old) }
        let temp = dir.appendingPathComponent(".writing-" + name)
        try? FileManager.default.removeItem(at: temp)
        do {
            let file = try AVAudioFile(forWriting: temp, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }

    /// Length of an audio file in seconds (0 if it cannot be read).
    public static func duration(of path: String) -> Double {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
