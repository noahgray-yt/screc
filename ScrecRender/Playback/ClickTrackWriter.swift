@preconcurrency import AVFoundation
import Foundation
import ScrecCore

/// Renders the click sounds of a project into `cache/clicks-<hash>.caf` (ARCHITECTURE §8.4): one mono file
/// in **timeline** time, added to the composition as an extra audio track, so preview and export hear the
/// same clicks. The file name depends on the click times and the sound, so an unchanged project reuses it.
public enum ClickTrackWriter {
    /// Returns the file for this project, writing it if needed, or nil when click sounds are off.
    public static func file(for p: PreparedProject, bundle: URL) throws -> URL? {
        // The slice playing at each click decides (per-slice click overrides do not change the sound).
        let sound = p.project.look.cursor.clickSound
        guard sound != .none, !p.cursor.clicks.isEmpty else { return nil }
        let times = p.cursor.clicks.map(\.t)
        var hasher = Hasher()
        hasher.combine(sound.rawValue)
        hasher.combine(p.timeMap.durationTicks)
        for t in times { hasher.combine(Int64((t * 48_000).rounded())) }
        let name = String(format: "clicks-%016llx.caf", UInt64(bitPattern: Int64(hasher.finalize())))
        let dir = bundle.appendingPathComponent(BundleLayout.cache, isDirectory: true)
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Remove older click files of this bundle.
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("clicks-") { try? FileManager.default.removeItem(at: old) }

        let samples = ClickSounds.track(clickTimes: times, duration: p.timeMap.duration, sound: sound)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: ClickSounds.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
        let temp = dir.appendingPathComponent(".writing-" + name)
        try? FileManager.default.removeItem(at: temp)
        do {
            let file = try AVAudioFile(forWriting: temp, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }
}
