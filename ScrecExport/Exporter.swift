@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ScrecCore
import ScrecRender
import ImageIO
import Metal
import UniformTypeIdentifiers
import VideoToolbox

/// Export (SPEC §4, ARCHITECTURE §10). Frames come from the same `Compositor` as the preview; sound comes from
/// the same composition and audio mix. Frame `k` is at timeline time `k / fps`; `N = round(T · fps)` frames.
public enum Exporter {
    public struct Progress: Sendable {
        public var framesDone: Int
        public var totalFrames: Int
        public var elapsed: TimeInterval

        /// Estimated seconds left, once a few frames are done.
        public var remaining: TimeInterval? {
            guard framesDone >= 5, framesDone < totalFrames else { return nil }
            return elapsed / Double(framesDone) * Double(totalFrames - framesDone)
        }
        public var fraction: Double { totalFrames > 0 ? Double(framesDone) / Double(totalFrames) : 0 }
    }

    public enum ExportError: LocalizedError {
        case noVideoTrack, writer(String), reader(String), metal, cancelled
        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The recording has no video track."
            case let .writer(m): "The video file could not be written: \(m)"
            case let .reader(m): "The recording could not be read: \(m)"
            case .metal: "The graphics card could not be used for export."
            case .cancelled: "Export cancelled."
            }
        }
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    // MARK: MP4

    /// Exports an MP4 (EX-01). The partial file is deleted if export fails or is cancelled.
    public static func exportMP4(_ p: PreparedProject, bundle: URL, settings: ExportSettings, to url: URL,
                                 progress: ProgressHandler? = nil) async throws {
        do {
            try await writeMP4(p, bundle: bundle, settings: settings, to: url, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw Task.isCancelled ? ExportError.cancelled : error
        }
    }

    private static func writeMP4(_ p: PreparedProject, bundle: URL, settings s: ExportSettings, to url: URL,
                                 progress: ProgressHandler?) async throws {
        let fps = s.outputFPS
        let size = s.outputSize(layout: p.layout)
        let n = p.timeMap.frameCount(fps: fps)
        let end = CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps))

        let clicks = try ClickTrackWriter.file(for: p, bundle: bundle)
        let music = try await MusicTrackWriter.file(for: p, bundle: bundle)
        let cleanMic = try await VoiceCleaner.file(bundle: bundle, settings: p.project.voice)
        let built = try await CompositionBuilder.build(bundle: bundle, timeMap: p.timeMap, slices: p.project.timeline.slices,
                                                       clickTrack: clicks, musicTrack: music, cleanMic: cleanMic)
        let composition = built.composition

        // Writer.
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: s.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: s.bitrate(size: size),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(videoInput) else { throw ExportError.writer("cannot add the video track") }
        writer.add(videoInput)

        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        var audioInput: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        // Readers: one for frames, one for sound (separate, so neither stalls the other).
        let frames = try await SourceFrameReader(composition: composition, until: end)
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        if audioInput != nil {
            let r = try AVAssetReader(asset: composition)
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
            out.audioMix = built.audioMix
            out.audioTimePitchAlgorithm = .spectral            // speed changes keep the pitch
            r.timeRange = CMTimeRange(start: .zero, end: end)  // audio is cut to N / fps (§8.2)
            r.add(out)
            guard r.startReading() else { throw ExportError.reader(r.error?.localizedDescription ?? "audio") }
            audioReader = r
            audioOutput = out
        }

        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        // Sound is pumped on its own queue while the frames are rendered.
        let audioDone: Task<Void, Never>? = {
            guard let audioInput, let audioOutput else { return nil }
            let box = AudioPump(input: audioInput, output: audioOutput)
            return Task { await box.run() }
        }()

        // Frames.
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw ExportError.metal }
        let compositor = try Compositor(device: device)
        let webcam = p.layouts.hasCamera ? await CameraFrameReader.forBundle(bundle) : nil
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache, let pool = adaptor.pixelBufferPool else { throw ExportError.metal }
        let start = Date()
        for k in 0..<n {
            try Task.checkCancellation()
            let t = Double(k) / Double(fps)
            let source = try frames.frame(atOrBefore: t)
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
            guard let pb else { throw ExportError.writer("no pixel buffer") }
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            var tex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm_srgb, Int(size.width), Int(size.height), 0, &tex)
            guard let tex, let target = CVMetalTextureGetTexture(tex), let cb = queue.makeCommandBuffer() else { throw ExportError.metal }
            try compositor.render(p, frame: .init(t: t, frameInterval: 1 / Double(fps), source: source, bundle: bundle,
                                                  camera: webcam?.frame(atSource: p.timeMap.toSource(t))), into: target, commandBuffer: cb)
            cb.commit()
            await cb.completed()
            while !videoInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps))) else {
                throw ExportError.writer(writer.error?.localizedDescription ?? "append")
            }
            progress?(Progress(framesDone: k + 1, totalFrames: n, elapsed: Date().timeIntervalSince(start)))
        }
        videoInput.markAsFinished()
        if let audioDone {
            await withTaskCancellationHandler { await audioDone.value } onCancel: { audioDone.cancel() }
        }
        audioReader?.cancelReading()
        try Task.checkCancellation()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "finish") }
        frames.cancel()
    }

    /// Copies all sound into the writer when the writer asks for it.
    private final class AudioPump: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderAudioMixOutput
        let queue = DispatchQueue(label: "screc.export.audio")
        /// Only touched on `queue`.
        private var finished = false
        init(input: AVAssetWriterInput, output: AVAssetReaderAudioMixOutput) {
            self.input = input
            self.output = output
        }

        func run() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) {
                    while self.input.isReadyForMoreMediaData {
                        if let s = self.output.copyNextSampleBuffer() {
                            self.input.append(s)
                        } else {
                            self.input.markAsFinished()
                            if !self.finished { self.finished = true; c.resume() }
                            return
                        }
                    }
                }
            }
        }
    }

    // MARK: GIF

    /// Exports a looping GIF (EX-02) with Screc's own palette per frame.
    public static func exportGIF(_ p: PreparedProject, bundle: URL, settings: ExportSettings, to url: URL,
                                 progress: ProgressHandler? = nil) async throws {
        do {
            try await writeGIF(p, bundle: bundle, settings: settings, to: url, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw Task.isCancelled ? ExportError.cancelled : error
        }
    }

    private static func writeGIF(_ p: PreparedProject, bundle: URL, settings s: ExportSettings, to url: URL,
                                 progress: ProgressHandler?) async throws {
        var gif = s
        gif.format = .gif
        let fps = gif.outputFPS
        let size = gif.outputSize(layout: p.layout)
        let w = Int(size.width), h = Int(size.height)
        let n = p.timeMap.frameCount(fps: fps)
        let built = try await CompositionBuilder.build(bundle: bundle, timeMap: p.timeMap, slices: p.project.timeline.slices)
        let frames = try await SourceFrameReader(composition: built.composition,
                                                 until: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, n, nil) else {
            throw ExportError.writer("cannot create the GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw ExportError.metal }
        let compositor = try Compositor(device: device)
        let webcam = p.layouts.hasCamera ? await CameraFrameReader.forBundle(bundle) : nil
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { throw ExportError.metal }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let start = Date()
        for k in 0..<n {
            try Task.checkCancellation()
            let t = Double(k) / Double(fps)
            guard let cb = queue.makeCommandBuffer() else { throw ExportError.metal }
            try compositor.render(p, frame: .init(t: t, frameInterval: 1 / Double(fps), source: try frames.frame(atOrBefore: t), bundle: bundle,
                                                  camera: webcam?.frame(atSource: p.timeMap.toSource(t))),
                                  into: target, commandBuffer: cb)
            cb.commit()
            await cb.completed()
            target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let q = bytes.withUnsafeBytes { GIFQuantizer.quantize($0, width: w, height: h, bytesPerRow: w * 4, bgra: true) }
            guard let space = CGColorSpace(indexedBaseSpace: srgb, last: q.colorCount - 1, colorTable: q.palette),
                  let provider = CGDataProvider(data: Data(q.indices) as CFData),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                      decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw ExportError.writer("cannot build GIF frame \(k)") }
            // GIF delays are whole hundredths of a second. 1/15 s = 6.67 would round to 7 every time and play 5 % slow,
            // so each delay is the difference of the rounded running totals (7, 7, 6, 7, 7, 6, …): the total stays exact.
            let delay = Double(GIFTiming.delayHundredths(frame: k, fps: fps)) / 100
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFUnclampedDelayTime as String: delay,
                kCGImagePropertyGIFDelayTime as String: delay,
            ]] as CFDictionary)
            progress?(Progress(framesDone: k + 1, totalFrames: n, elapsed: Date().timeIntervalSince(start)))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writer("cannot finish the GIF") }
        frames.cancel()
    }
}

/// Reads the composition's video frames in order and applies the frame-selection rule (ARCHITECTURE §8.2):
/// for timeline time t, the decoded frame with the largest presentation time ≤ t. No blending.
public final class SourceFrameReader: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: (time: Double, buffer: CVPixelBuffer)?
    private var next: (time: Double, buffer: CVPixelBuffer)?
    private var exhausted = false

    public init(composition: AVAsset, until end: CMTime) async throws {
        guard let track = try await composition.loadTracks(withMediaType: .video).first else { throw Exporter.ExportError.noVideoTrack }
        reader = try AVAssetReader(asset: composition)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: .zero, end: end)
        reader.add(output)
        guard reader.startReading() else { throw Exporter.ExportError.reader(reader.error?.localizedDescription ?? "video") }
    }

    private func readNext() -> (time: Double, buffer: CVPixelBuffer)? {
        while !exhausted {
            guard let s = output.copyNextSampleBuffer() else {
                exhausted = true
                return nil
            }
            if let pb = CMSampleBufferGetImageBuffer(s) { return (CMSampleBufferGetPresentationTimeStamp(s).seconds, pb) }
        }
        return nil
    }

    /// The frame for timeline time `t` (times must not decrease between calls).
    public func frame(atOrBefore t: Double) throws -> CVPixelBuffer? {
        if reader.status == .failed { throw Exporter.ExportError.reader(reader.error?.localizedDescription ?? "video") }
        if current == nil { current = readNext() }
        if next == nil { next = readNext() }
        while let n = next, n.time <= t + 1e-6 {
            current = n
            next = readNext()
        }
        return current?.buffer
    }

    public func cancel() { reader.cancelReading() }
}
