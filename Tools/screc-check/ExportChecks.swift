@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ScrecCore
import ScrecExport
import ScrecRender
import Metal

/// Phase 4 proof tools: a synthetic test recording, headless export, and the preview-vs-export frame diff.
enum ExportChecks {
    /// Flash/beep moments in the fixture recording (source time). A white frame for 2 frames, a 1 kHz beep for 40 ms.
    static let flashTimes: [Double] = [1.0, 2.5, 4.0, 6.0]
    static let fixtureDuration = 8.0
    static let fixtureFPS = 60

    // MARK: make-fixture

    /// Writes `Fixture.screc` into `directory`: black video with white flashes, system audio with beeps at the same
    /// moments, and a project with a cut (3.0–3.5 s) and a 1.5× slice, so the export has to map time correctly.
    static func makeFixture(in directory: URL) async throws -> URL {
        let bundle = directory.appendingPathComponent("Fixture.screc", isDirectory: true)
        try? FileManager.default.removeItem(at: bundle)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent(BundleLayout.cache), withIntermediateDirectories: true)
        let w = 1280, h = 720

        // Video.
        let writer = try AVAssetWriter(outputURL: bundle.appendingPathComponent(BundleLayout.screen), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoAllowFrameReorderingKey: false],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let flashFrames = Set(flashTimes.flatMap { t in [Int((t * Double(fixtureFPS)).rounded()), Int((t * Double(fixtureFPS)).rounded()) + 1] })
        for k in 0..<Int(fixtureDuration * Double(fixtureFPS)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), flashFrames.contains(k) ? 255 : 0, CVPixelBufferGetBytesPerRow(pb!) * h)
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fixtureFPS)))
        }
        input.markAsFinished()
        await writer.finishWriting()

        // Audio: a beep at each flash.
        let rate = 48_000.0
        let total = Int(fixtureDuration * rate)
        var samples = [Float](repeating: 0, count: total)
        for t in flashTimes {
            let s0 = Int(t * rate)
            for i in 0..<Int(0.04 * rate) where s0 + i < total { samples[s0 + i] = 0.6 * Float(sin(2 * .pi * 1000 * Double(i) / rate)) }
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: total) }
        do {
            let file = try AVAudioFile(forWriting: bundle.appendingPathComponent(BundleLayout.system),
                                       settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }

        // recording.json, events.jsonl, project.json.
        var info = RecordingInfo(startedAt: Date(), sourceApp: "Fixture",
                                 capture: .init(kind: .display, displayID: 1, displayPixelSize: [w, h], pointPixelScale: 1,
                                                contentRectPoints: [0, 0, Double(w), Double(h)], videoPixelSize: [w, h], fps: fixtureFPS),
                                 tracks: .init(system: BundleLayout.system))
        info.clock.t0HostSeconds = 0
        info.duration = fixtureDuration
        info.finalised = true
        try info.encoded().write(to: bundle.appendingPathComponent(BundleLayout.recording))
        let header = TelemetryHeader(t0HostSeconds: 0, sampleHz: 60, videoPixelSize: [w, h])
        try Data((TelemetryCodec.encode(header) + "\n").utf8).write(to: bundle.appendingPathComponent(BundleLayout.events))
        var project = Project(name: "Fixture", timeline: Timeline(slices: [Slice(id: "S1", sourceStart: 0, sourceEnd: 3.0),
                                                                            Slice(id: "S2", sourceStart: 3.5, sourceEnd: fixtureDuration)]))
        project.timeline.slices[1].speed = 1.5
        project.autoZoomDone = true
        project.look.background.kind = .color
        project.look.background.color = "#3060C0"
        try project.encoded().write(to: bundle.appendingPathComponent(BundleLayout.project))
        return bundle
    }

    /// Timeline times at which the fixture's flashes must appear.
    static func expectedTimelineTimes(_ map: TimeMap) -> [Double] { flashTimes.compactMap { map.toTimeline($0) } }

    // MARK: export

    static func export(bundle: URL, to out: URL, settings: ExportSettings) async throws {
        let p = try PreparedProject.load(bundle: bundle)
        let start = Date()
        let report: Exporter.ProgressHandler = { pr in
            // Every 10 % (stateless, so it is safe from any thread).
            let step = max(pr.totalFrames / 10, 1)
            if pr.framesDone % step == 0 || pr.framesDone == pr.totalFrames {
                print(String(format: "  %3d %%  %d/%d frames", Int(pr.fraction * 100), pr.framesDone, pr.totalFrames))
            }
        }
        if settings.format == .gif {
            try await Exporter.exportGIF(p, bundle: bundle, settings: settings, to: out, progress: report)
        } else {
            try await Exporter.exportMP4(p, bundle: bundle, settings: settings, to: out, progress: report)
        }
        let n = p.timeMap.frameCount(fps: settings.outputFPS)
        print(String(format: "exported %@ in %.1f s: %d frames at %d fps, timeline %.4f s → expected duration %.4f s",
                     out.lastPathComponent, Date().timeIntervalSince(start), n, settings.outputFPS, p.timeMap.duration,
                     Double(n) / Double(settings.outputFPS)))
        if bundle.lastPathComponent == "Fixture.screc" {
            print("expected flash/beep timeline times: " + expectedTimelineTimes(p.timeMap).map { String(format: "%.4f", $0) }.joined(separator: ", "))
        }
    }

    // MARK: framediff (EX-06)

    /// For three timestamps: render the frame through the *preview* path (AVPlayer + AVPlayerItemVideoOutput) and through
    /// the *export* path (AVAssetReader), compare them (must be bit-identical before encoding), then compare with the
    /// frame decoded from the exported file (PSNR ≥ 40 dB, allowing for encoder loss).
    @MainActor
    static func frameDiff(bundle: URL, exported: URL, fps: Int) async throws -> Bool {
        let p = try PreparedProject.load(bundle: bundle)
        let built = try await CompositionBuilder.build(bundle: bundle, timeMap: p.timeMap, slices: p.project.timeline.slices)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Exporter.ExportError.metal }
        let compositor = try Compositor(device: device)
        let size = p.project.export.outputSize(layout: p.layout)
        let w = Int(size.width), h = Int(size.height)

        func render(_ source: CVPixelBuffer?, t: Double) async throws -> [UInt8] {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            let tex = device.makeTexture(descriptor: d)!
            let cb = queue.makeCommandBuffer()!
            try compositor.render(p, frame: .init(t: t, frameInterval: 1 / Double(fps), source: source, bundle: bundle), into: tex, commandBuffer: cb)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                cb.addCompletedHandler { _ in c.resume() }
                cb.commit()
            }
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return bytes
        }

        // Preview path: the same player + video output the editor uses.
        let item = AVPlayerItem(asset: built.composition)
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(videoOutput)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        // Exported file, decoded.
        let exportedAsset = AVURLAsset(url: exported)
        let generator = AVAssetImageGenerator(asset: exportedAsset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let duration = p.timeMap.duration
        let times = [0.25, 0.5, 0.8].map { (duration * $0 * Double(fps)).rounded() / Double(fps) }
        var ok = true
        for t in times {
            let target = CMTime(value: CMTimeValue((t * Double(fps)).rounded()), timescale: CMTimeScale(fps))
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            var previewFrame: CVPixelBuffer?
            for _ in 0..<200 {
                if let pb = videoOutput.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) { previewFrame = pb; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let exportReader = try await SourceFrameReader(composition: built.composition, until: CMTime(seconds: t + 1, preferredTimescale: 60_000))
            let exportFrame = try exportReader.frame(atOrBefore: t)
            exportReader.cancel()

            let a = try await render(previewFrame, t: t)
            let b = try await render(exportFrame, t: t)
            let identical = a == b

            // Exported frame k decoded to BGRA by AVAssetReader: a plain YUV → RGB conversion with the file's own
            // matrix and no colour management (AVAssetImageGenerator colour-manages and shifts levels by 2–3).
            let c = try await decodedFrame(exportedAsset, index: Int((t * Double(fps)).rounded()), fps: fps, width: w, height: h)
            _ = generator
            let psnr = Self.psnr(b, c)
            var mean = [0.0, 0.0, 0.0]
            var i = 0
            while i < b.count { for k in 0..<3 { mean[k] += Double(Int(c[i + k]) - Int(b[i + k])) }; i += 4 }
            let px = Double(b.count / 4)
            print(String(format: "   mean decoded − rendered: B %+.2f  G %+.2f  R %+.2f", mean[0] / px, mean[1] / px, mean[2] / px))
            let pass = identical && psnr >= 40
            if !pass { ok = false }
            print(String(format: "%@ t = %.3f s: preview vs export render %@, exported file PSNR %.1f dB (limit 40)%@",
                         pass ? "✅" : "❌", t, identical ? "bit-identical" : "DIFFERENT",
                         psnr, previewFrame == nil ? " (preview delivered no frame)" : ""))
        }
        return ok
    }

    static func decodedFrame(_ asset: AVAsset, index: Int, fps: Int, width w: Int, height h: Int) async throws -> [UInt8] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Exporter.ExportError.noVideoTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)), duration: CMTime(value: 1, timescale: CMTimeScale(fps)))
        reader.add(output)
        reader.startReading()
        guard let sample = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) else { throw Exporter.ExportError.reader("frame \(index)") }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<min(h, CVPixelBufferGetHeight(pb)) {
            for x in 0..<(min(w, CVPixelBufferGetWidth(pb)) * 4) { out[y * w * 4 + x] = base[y * bpr + x] }
        }
        return out
    }

    /// PSNR over the RGB channels of two BGRA images.
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0.0, n = 0.0
        var i = 0
        while i < min(a.count, b.count) {
            for k in 0..<3 {
                let d = Double(a[i + k]) - Double(b[i + k])
                sum += d * d
            }
            n += 3
            i += 4
        }
        let mse = sum / max(n, 1)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
}
