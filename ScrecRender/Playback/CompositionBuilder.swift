@preconcurrency import AVFoundation
import Foundation
import ScrecCore

/// Builds the `AVMutableComposition` for a project from its `TimeMap` (ARCHITECTURE §8.4): for each slice,
/// the source range `[aᵢ, bᵢ)` of every track is inserted at `Tᵢ` and scaled to `dᵢ`. Preview and export use
/// the same builder, so they see the same timing.
public enum CompositionBuilder {
    public struct Result {
        public let composition: AVMutableComposition
        /// Per-slice volumes for microphone and system audio (10 ms ramps at slice boundaries).
        public let audioMix: AVAudioMix
        /// The source assets must stay alive as long as the composition is used.
        public let sources: [AVURLAsset]
    }

    /// - Parameter clickTrack: a click-sound file already in timeline time (`ClickTrackWriter`), added unscaled at 0.
    /// - Parameter musicTrack: background music already in timeline time (`MusicTrackWriter`), added like the clicks.
    /// - Parameter cleanMic: the noise-reduced microphone (`VoiceCleaner`), used instead of `mic.m4a`.
    public static func build(bundle: URL, timeMap: TimeMap, slices: [Slice], clickTrack: URL? = nil, musicTrack: URL? = nil,
                             cleanMic: URL? = nil) async throws -> Result {
        let composition = AVMutableComposition()
        var sources: [AVURLAsset] = []
        var mixParameters: [AVMutableAudioMixInputParameters] = []

        @discardableResult
        func add(file: String, type: AVMediaType, url override: URL? = nil) async throws -> AVMutableCompositionTrack? {
            let url = override ?? bundle.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            sources.append(asset)
            guard let track = try await asset.loadTracks(withMediaType: type).first,
                  let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            let available = try await track.load(.timeRange)
            for e in timeMap.entries {
                let source = CMTimeRange(start: time(e.sourceStart), end: time(e.sourceEnd)).intersection(available)
                guard source.duration > .zero else { continue }
                let at = CMTime(value: e.timelineStartTicks + ticks(source.start.seconds - e.sourceStart, speed: e.speed),
                                timescale: CMTimeScale(TimeMap.ticksPerSecond))
                try target.insertTimeRange(source, of: track, at: at)
                if e.speed != 1 {
                    let inserted = CMTimeRange(start: at, duration: source.duration)
                    let scaled = CMTime(value: ticks(source.duration.seconds, speed: e.speed), timescale: CMTimeScale(TimeMap.ticksPerSecond))
                    target.scaleTimeRange(inserted, toDuration: scaled)
                }
            }
            return target
        }

        /// Volume per slice: slice master × the track's own slider, ramped over 10 ms at each boundary. Where
        /// part of the recording is cut out, the sound fades out and back in over 15 ms so the splice never clicks.
        func volumes(_ track: AVMutableCompositionTrack, _ level: (Slice) -> Double) {
            let p = AVMutableAudioMixInputParameters(track: track)
            let scale = CMTimeScale(TimeMap.ticksPerSecond)
            let entries = timeMap.entries
            var previous: Float = 1
            for (k, e) in entries.enumerated() {
                guard let slice = slices.first(where: { $0.id == e.sliceID }) else { continue }
                let v = Float(min(max(slice.volume * level(slice), 0), 2))
                let cutBefore = k > 0 && abs(entries[k - 1].sourceEnd - e.sourceStart) > 0.001
                let cutAfter = k + 1 < entries.count && abs(e.sourceEnd - entries[k + 1].sourceStart) > 0.001
                let ramp = CMTime(value: min(cutBefore || cutAfter ? 15 : 10, Int64(e.timelineDuration * 1000 / 3)), timescale: 1000)
                let start = CMTime(value: e.timelineStartTicks, timescale: scale)
                p.setVolumeRamp(fromStartVolume: cutBefore ? 0 : previous, toEndVolume: v, timeRange: CMTimeRange(start: start, duration: ramp))
                if cutAfter {
                    let end = CMTime(value: e.timelineStartTicks + e.timelineDurationTicks, timescale: scale)
                    p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: end - ramp, duration: ramp))
                }
                previous = cutAfter ? 0 : v
            }
            mixParameters.append(p)
        }

        try await add(file: BundleLayout.screen, type: .video)
        if let mic = try await add(file: BundleLayout.mic, type: .audio, url: cleanMic) { volumes(mic) { $0.micVolume } }
        if let system = try await add(file: BundleLayout.system, type: .audio) { volumes(system) { $0.systemVolume } }
        for extra in [clickTrack, musicTrack].compactMap({ $0 }) {
            let asset = AVURLAsset(url: extra)
            sources.append(asset)
            if let track = try await asset.loadTracks(withMediaType: .audio).first,
               let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let range = try await track.load(.timeRange)
                let end = min(range.end, CMTime(value: timeMap.durationTicks, timescale: CMTimeScale(TimeMap.ticksPerSecond)))
                try target.insertTimeRange(CMTimeRange(start: .zero, end: end), of: track, at: .zero)
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParameters
        return Result(composition: composition, audioMix: mix, sources: sources)
    }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(value: Int64((seconds * Double(TimeMap.ticksPerSecond)).rounded()), timescale: CMTimeScale(TimeMap.ticksPerSecond))
    }

    static func ticks(_ sourceSeconds: Double, speed: Double) -> Int64 {
        Int64((sourceSeconds / speed * Double(TimeMap.ticksPerSecond)).rounded())
    }
}
