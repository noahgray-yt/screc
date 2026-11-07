@preconcurrency import AVFoundation
import Foundation
import ScrecCore

/// Noise reduction for the microphone (Phase 5): Apple's Voice Isolation audio unit (`AUSoundIsolation`), run
/// offline on `mic.m4a` into `cache/mic-clean-<hash>.m4a`. The unit's delay is removed, so the cleaned voice
/// lines up with the video exactly like the original. The original file is never changed.
public enum VoiceCleaner {
    static let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x766F_6973, // "vois"
                                                       componentManufacturer: kAudioUnitManufacturer_Apple,
                                                       componentFlags: 0, componentFlagsMask: 0)

    /// True if this Mac has Apple's Voice Isolation unit.
    public static var isAvailable: Bool { !AVAudioUnitComponentManager.shared().components(matching: description).isEmpty }

    /// The cleaned microphone file, writing it if needed; nil when noise reduction is off or there is no microphone.
    public static func file(bundle: URL, settings: VoiceSettings) async throws -> URL? {
        let mic = bundle.appendingPathComponent(BundleLayout.mic)
        guard settings.noiseReduction, isAvailable, FileManager.default.fileExists(atPath: mic.path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: mic.path)
        var hasher = Hasher()
        hasher.combine(attributes?[.size] as? Int)
        hasher.combine((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970)
        hasher.combine(Int((settings.amount * 100).rounded()))
        let name = String(format: "mic-clean-%016llx.m4a", UInt64(bitPattern: Int64(hasher.finalize())))
        let dir = bundle.appendingPathComponent(BundleLayout.cache, isDirectory: true)
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".writing-" + name)
        try? FileManager.default.removeItem(at: temp)
        try process(input: mic, output: temp, amount: settings.amount)
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("mic-clean-") { try? FileManager.default.removeItem(at: old) }
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }

    /// Runs the unit over the whole file (offline, faster than real time) and writes AAC with the same length.
    static func process(input: URL, output: URL, amount: Double) throws {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let engine = AVAudioEngine()
        let unit = AVAudioUnitEffect(audioComponentDescription: description)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(unit)
        engine.connect(player, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        if let mix = unit.auAudioUnit.parameterTree?.allParameters.first(where: { $0.address == 0 }) {
            mix.value = AUValue(min(max(amount, 0), 1) * 100)            // Wet/Dry Mix, percent
        }
        let block: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        try engine.start()
        defer { engine.stop() }

        // The unit delays its output; feed silence after the file so its end comes out too, then drop the delay.
        let delay = AVAudioFramePosition((unit.auAudioUnit.latency > 0 ? unit.auAudioUnit.latency : measuredLatency) * format.sampleRate)
        player.scheduleFile(file, at: nil)
        if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(delay) + block) {
            silence.frameLength = silence.frameCapacity
            player.scheduleBuffer(silence, at: nil)
        }
        player.play()

        let out = try AVAudioFile(forWriting: output, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                                                 AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 160_000],
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block),
              let trimmed = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block) else { return }
        var rendered: AVAudioFramePosition = 0
        var written: AVAudioFramePosition = 0
        while written < file.length {
            let status = try engine.renderOffline(block, to: buffer)
            guard status == .success else { throw CocoaError(.fileWriteUnknown) }
            // Skip the first `delay` frames; stop at the original length.
            let from = max(delay - rendered, 0)
            rendered += AVAudioFramePosition(buffer.frameLength)
            let available = AVAudioFramePosition(buffer.frameLength) - from
            let count = min(available, file.length - written)
            guard count > 0 else { continue }
            for c in 0..<Int(format.channelCount) {
                trimmed.floatChannelData![c].update(from: buffer.floatChannelData![c] + Int(from), count: Int(count))
            }
            trimmed.frameLength = AVAudioFrameCount(count)
            try out.write(from: trimmed)
            written += count
        }
    }

    /// Delay of the Voice Isolation unit measured on macOS 27 (it reports 0): 56.5 ms.
    static let measuredLatency = 0.0565
}
