@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ScrecCore

/// Webcam frames from `camera.mov` by **source** time (Phase 5 camera layouts), for the preview and the export.
/// Reads forward with one `AVAssetReader`; jumping back or far ahead restarts it at the new time.
public final class CameraFrameReader: @unchecked Sendable {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: (time: Double, buffer: CVPixelBuffer)?
    private var next: (time: Double, buffer: CVPixelBuffer)?
    private var startedAt = -1.0
    private let lock = NSLock()

    private init(asset: AVURLAsset, track: AVAssetTrack) {
        self.asset = asset
        self.track = track
    }

    /// Opens a camera file, or nil if it has no video.
    public static func open(url: URL) async -> CameraFrameReader? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        return CameraFrameReader(asset: asset, track: track)
    }

    private func start(at t: Double) {
        reader?.cancelReading()
        reader = nil
        current = nil
        next = nil
        guard let r = try? AVAssetReader(asset: asset) else { return }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        // The reader decodes ahead into reused buffers; a frame kept for drawing must be a copy, or a later frame
        // can overwrite it (measured: 9 frames too late without this).
        o.alwaysCopiesSampleData = true
        let from = max(t - 0.5, 0)
        r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: .positiveInfinity)
        r.add(o)
        guard r.startReading() else { return }
        reader = r
        output = o
        startedAt = from
    }

    private func readNext() -> (time: Double, buffer: CVPixelBuffer)? {
        while let s = output?.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(s) { return (CMSampleBufferGetPresentationTimeStamp(s).seconds, pb) }
        }
        return nil
    }

    /// The frame with the largest time ≤ `t` (source seconds), or the first one.
    public func frame(atSource t: Double) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let behind = current.map { t < $0.time - 0.05 } ?? (t < startedAt)
        let farAhead = next.map { t > $0.time + 1.0 } ?? false
        if reader == nil || behind || farAhead { start(at: t) }
        if current == nil { current = readNext() }
        if next == nil { next = readNext() }
        while let n = next, n.time <= t + 1e-6 {
            current = n
            next = readNext()
        }
        return current?.buffer
    }
}

public extension CameraFrameReader {
    /// The reader for a bundle's `camera.mov`, or nil when the recording has no camera.
    static func forBundle(_ bundle: URL?) async -> CameraFrameReader? {
        guard let url = bundle?.appendingPathComponent(BundleLayout.camera), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return await open(url: url)
    }
}
