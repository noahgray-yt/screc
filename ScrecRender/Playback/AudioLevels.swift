@preconcurrency import AVFoundation
import Foundation
import ScrecCore

/// Loudness of an audio file over time (RMS in dB per 10 ms), mixed to mono at 16 kHz.
public enum AudioLevels {
    public static let step = 0.01

    public static func rms(url: URL) async throws -> [Float] {
        let rate = 16_000.0
        let window = Int(rate * step)
        var levels: [Float] = []
        var sum: Float = 0
        var count = 0
        try await readPCM(url: url, sampleRate: rate, channels: 1) { samples in
            for v in samples {
                sum += v * v
                count += 1
                if count == window {
                    levels.append(10 * log10(sum / Float(window) + 1e-12))
                    sum = 0
                    count = 0
                }
            }
        }
        return levels
    }

    /// Decodes any audio file AVFoundation can read to interleaved 32-bit float at the given rate and
    /// channel count, chunk by chunk.
    public static func readPCM(url: URL, sampleRate: Double, channels: Int, chunk: (UnsafeBufferPointer<Float>) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            try pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { try chunk(UnsafeBufferPointer(start: $0, count: length / 4)) }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    }

    /// Tightens a transcript's word times to the speech in its audio file (see `Transcript.refined`).
    public static func refine(_ transcript: Transcript, bundle: URL) async throws -> Transcript {
        let levels = try await rms(url: bundle.appendingPathComponent(transcript.source))
        return transcript.refined(with: SpeechActivity(levels: levels, step: step))
    }
}
