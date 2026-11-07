// screc-check: verifies Screc recordings from the command line.
//
//   screc-check inspect <bundle.screc>   structure, durations, telemetry rate and ordering
//   screc-check align   <bundle.screc>   alignment proof on a calibration take (REC-14, ARCHITECTURE §6.4)
//   screc-check render  <bundle.screc> <timeline seconds> <out.png> [short side, default 1080]
//                                         one frame through the compositor (same code as preview/export)
//   screc-check bench   <bundle.screc> [short side]   GPU time per composited frame (120 frames)
//   screc-check timeline <bundle.screc>   composition tracks (cuts, speed) vs the time map
//   screc-check make-fixture <dir>        synthetic test recording (flashes + beeps, a cut and a 1.5× slice)
//   screc-check export <bundle.screc> <out.mp4|out.gif> [--res 720p|1080p|4K] [--fps 30|60] [--codec h264|hevc]
//   screc-check framediff <bundle.screc> <exported.mp4> [fps]   preview vs export frames (EX-06)
//
// Exit code 0 = PASS, 1 = FAIL, 2 = usage error.

@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ScrecCore
import ScrecExport
import ScrecRender
import ImageIO
import Metal
import UniformTypeIdentifiers

@main
struct ScrecCheck {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "render", args.count >= 4, let t = Double(args[2]) {
            do {
                try await render(URL(fileURLWithPath: args[1]), t: t, out: URL(fileURLWithPath: args[3]),
                                 shortSide: args.count > 4 ? Int(args[4]) ?? 1080 : 1080)
                exit(0)
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
        if args.first == "bench", args.count >= 2 {
            do {
                try await bench(URL(fileURLWithPath: args[1]), shortSide: args.count > 2 ? Int(args[2]) ?? 1080 : 1080)
                exit(0)
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
        if args.first == "make-fixture", args.count == 2 {
            do {
                let url = try await ExportChecks.makeFixture(in: URL(fileURLWithPath: args[1]))
                print("SCREC_FIXTURE=\(url.path)")
                exit(0)
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
        if args.first == "export", args.count >= 3 {
            var s = ExportSettings()
            let out = URL(fileURLWithPath: args[2])
            s.format = out.pathExtension.lowercased() == "gif" ? .gif : .mp4
            for (flag, value) in zip(args.dropFirst(3), args.dropFirst(4)) {
                switch flag {
                case "--res": s.resolution = ExportSettings.Resolution(rawValue: value) ?? s.resolution
                case "--fps": s.fps = Int(value) ?? s.fps; s.gifFPS = Int(value) ?? s.gifFPS
                case "--codec": s.codec = ExportSettings.Codec(rawValue: value) ?? s.codec
                default: break
                }
            }
            if let i = args.firstIndex(of: "--cancel-after"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
                // EX-04: cancel mid-export; the partial file must be gone afterwards.
                let task = Task { try await ExportChecks.export(bundle: URL(fileURLWithPath: args[1]), to: out, settings: s) }
                try? await Task.sleep(for: .seconds(seconds))
                task.cancel()
                let result = await task.result
                let exists = FileManager.default.fileExists(atPath: out.path)
                switch result {
                case .success: print("export finished before the cancel")
                case let .failure(e): print("export stopped: \(e.localizedDescription)")
                }
                print(exists ? "❌ partial file left behind" : "✅ no partial file left")
                exit(exists ? 1 : 0)
            }
            do {
                try await ExportChecks.export(bundle: URL(fileURLWithPath: args[1]), to: out, settings: s)
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        if args.first == "framediff", args.count >= 3 {
            do {
                let ok = try await ExportChecks.frameDiff(bundle: URL(fileURLWithPath: args[1]), exported: URL(fileURLWithPath: args[2]),
                                                          fps: args.count > 3 ? Int(args[3]) ?? 60 : 60)
                print(ok ? "RESULT: PASS" : "RESULT: FAIL")
                exit(ok ? 0 : 1)
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
        if args.first == "transcribe", args.count >= 3, #available(macOS 26, *) {
            // screc-check transcribe <bundle.screc> <locale>   → writes transcript.json and prints the captions as .srt
            do {
                let bundle = URL(fileURLWithPath: args[1])
                let start = Date()
                let t = try await Transcriber.transcribe(bundle: bundle, locale: Locale(identifier: args[2]))
                try t.save(bundle: bundle)
                let p = try PreparedProject.load(bundle: bundle)
                print(String(format: "%d words from %@ in %.1f s (%@), %d caption lines", t.words.count, t.source, Date().timeIntervalSince(start),
                             t.language, p.captions.lines.count))
                print(p.captions.srt())
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        if args.first == "denoise", args.count == 2 {
            // screc-check denoise <bundle.screc>   → writes the noise-reduced microphone into cache/ and prints its path
            do {
                var settings = VoiceSettings()
                settings.noiseReduction = true
                let start = Date()
                guard let url = try await VoiceCleaner.file(bundle: URL(fileURLWithPath: args[1]), settings: settings) else {
                    print("no microphone, or Voice Isolation is not available")
                    exit(1)
                }
                print(String(format: "%@ (%.2f s)", url.path, Date().timeIntervalSince(start)))
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        if args.first == "make-music", args.count == 2 {
            // screc-check make-music <folder>   → writes Screc's original example tracks and sounds into genre subfolders
            do {
                try MusicSynth.run(folder: URL(fileURLWithPath: args[1]))
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        if args.first == "refine", args.count == 2 {
            // screc-check refine <bundle.screc>   → tightens transcript.json word times to the speech in the audio
            do {
                let bundle = URL(fileURLWithPath: args[1])
                guard let t = Transcript.load(bundle: bundle) else { print("no transcript.json"); exit(1) }
                let r = try await AudioLevels.refine(t, bundle: bundle)
                for w in r.words { print(String(format: "%7.2f–%6.2f  %@", w.start, w.end, w.isSound ? "(sound)" : w.text)) }
                print("\(r.words.filter { !$0.isSound }.count) words, \(r.words.filter(\.isSound).count) sounds")
                try r.save(bundle: bundle)
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        if args.first == "cleanup", args.count == 2 {
            // screc-check cleanup <bundle.screc>   → what "Clean Up" in the Transcript panel would remove (changes nothing)
            do {
                let p = try PreparedProject.load(bundle: URL(fileURLWithPath: args[1]))
                guard let t = p.transcript else { print("no transcript.json"); exit(1) }
                let events = (try? TelemetryCodec.decodeFile(Data(contentsOf: URL(fileURLWithPath: args[1]).appendingPathComponent(BundleLayout.events))).events) ?? []
                let d = (try? RecordingInfo.decode(from: Data(contentsOf: URL(fileURLWithPath: args[1]).appendingPathComponent(BundleLayout.recording))))?.duration ?? p.timeMap.duration
                let fillers = TranscriptEdit.fillerRuns(in: t, timeMap: p.timeMap)
                let pauses = TranscriptEdit.longPauses(in: t, timeMap: p.timeMap, events: events)
                for r in fillers { print("filler: \(t.words[r].map(\.text).joined(separator: " ")) at \(String(format: "%.2f", t.words[r.lowerBound].start)) s") }
                for x in pauses { print(String(format: "pause: %.2f–%.2f s cut, saves %.2f s", x.cut.lowerBound, x.cut.upperBound, x.saves)) }
                var project = p.project
                try project.cut(source: fillers.map { TranscriptEdit.cutRange(words: $0, in: t, recordingDuration: d) } + pauses.map(\.cut))
                let after = TimeMap(slices: project.timeline.slices).duration
                print(String(format: "%d filler runs, %d pauses: %.2f s → %.2f s, %d slices, valid: %@", fillers.count, pauses.count,
                             p.timeMap.duration, after, project.timeline.slices.count, project.isValid(recordingDuration: d) ? "yes" : "NO"))
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        if args.first == "timeline", args.count == 2 {
            do {
                let ok = try await timeline(URL(fileURLWithPath: args[1]))
                print(ok ? "RESULT: PASS" : "RESULT: FAIL")
                exit(ok ? 0 : 1)
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
        guard args.count == 2, ["inspect", "align"].contains(args[0]) else {
            print("usage: screc-check inspect|align <bundle.screc>   |   screc-check render <bundle.screc> <t> <out.png> [short side]")
            exit(2)
        }
        let bundle = URL(fileURLWithPath: args[1])
        do {
            let ok = args[0] == "inspect" ? try await inspect(bundle) : try await align(bundle)
            print(ok ? "RESULT: PASS" : "RESULT: FAIL")
            exit(ok ? 0 : 1)
        } catch {
            print("error: \(error)")
            print("RESULT: FAIL")
            exit(1)
        }
    }

    // MARK: inspect

    static func inspect(_ bundle: URL) async throws -> Bool {
        var ok = true
        func check(_ pass: Bool, _ text: String) {
            print("\(pass ? "✅" : "❌") \(text)")
            if !pass { ok = false }
        }
        let fm = FileManager.default
        let info = try RecordingInfo.decode(from: Data(contentsOf: bundle.appendingPathComponent(BundleLayout.recording)))
        let duration = info.duration ?? 0
        let fps = Double(info.capture.fps)
        print("Bundle:   \(bundle.lastPathComponent)")
        print("Source:   \(info.capture.kind.rawValue), app \"\(info.sourceApp)\", \(info.capture.videoPixelSize[0])×\(info.capture.videoPixelSize[1]) px @ \(info.capture.fps) fps")
        print(String(format: "Duration: %.3f s, pauses: %d", duration, info.pauses.count))

        check(info.finalised, "recording.json is finalised")
        check(!fm.fileExists(atPath: bundle.appendingPathComponent(BundleLayout.lock).path), "no lock file left")
        check(fm.fileExists(atPath: bundle.appendingPathComponent(BundleLayout.project).path), "project.json exists")
        if let data = try? Data(contentsOf: bundle.appendingPathComponent(BundleLayout.project)) {
            let project = try Project.decode(from: data)
            check(project.timeline.slices.count == 1 && abs(project.timeline.slices[0].sourceEnd - duration) < 1e-6,
                  "project.json has one slice covering the take")
        }

        // Media tracks: each file's duration should match the take (screen within one frame).
        let screen = AVURLAsset(url: bundle.appendingPathComponent(info.tracks.screen))
        let videoTracks = try await screen.loadTracks(withMediaType: .video)
        check(!videoTracks.isEmpty, "screen.mov has a video track")
        if let track = videoTracks.first {
            let size = try await track.load(.naturalSize)
            let range = try await track.load(.timeRange)
            let end = range.end.seconds
            check(Int(size.width) == info.capture.videoPixelSize[0] && Int(size.height) == info.capture.videoPixelSize[1],
                  "screen.mov is \(Int(size.width))×\(Int(size.height)) px as recorded in recording.json")
            check(abs(end - duration) <= 1.0 / fps + 1e-3,
                  String(format: "screen.mov ends at %.3f s, take duration %.3f s (|Δ| = %.1f ms, limit one frame = %.1f ms)",
                         end, duration, abs(end - duration) * 1000, 1000 / fps))
        }
        for (label, name) in [("camera", info.tracks.camera), ("mic", info.tracks.mic), ("system audio", info.tracks.system)] {
            guard let name else { continue }
            let asset = AVURLAsset(url: bundle.appendingPathComponent(name))
            let tracks = try await asset.load(.tracks)
            let end = try await asset.load(.duration).seconds
            check(!tracks.isEmpty && end > 0, String(format: "%@ track %@: %.3f s", label, name, end))
        }

        // Telemetry.
        let (header, events) = try TelemetryCodec.decodeFile(Data(contentsOf: bundle.appendingPathComponent(BundleLayout.events)))
        check(header.t0HostSeconds == info.clock.t0HostSeconds, "events.jsonl header t0 matches recording.json")
        let pos = events.filter { if case .pos = $0 { true } else { false } }
        let rate = duration > 0 ? Double(pos.count) / duration : 0
        check(rate >= 55, String(format: "position samples: %d (%.1f Hz, display %.0f Hz)", pos.count, rate, header.sampleHz))
        let outside = events.filter { $0.t < 0 || $0.t > duration + 0.05 }
        check(outside.isEmpty, "all \(events.count) events lie inside the take (\(outside.count) outside)")
        var biggestGap = 0.0
        for (a, b) in zip(pos, pos.dropFirst()) { biggestGap = max(biggestGap, b.t - a.t) }
        let pauseTolerance = info.pauses.isEmpty ? 0.1 : .infinity
        check(biggestGap <= pauseTolerance, String(format: "largest gap between position samples: %.1f ms", biggestGap * 1000))
        var counts: [String: Int] = [:]
        for e in events { counts[e.typeName, default: 0] += 1 }
        print("Events:   " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        if let unit = header.eventTimestampUnit { print("CGEvent timestamp unit on this Mac: \(unit)") }
        return ok
    }

    // MARK: align

    static func align(_ bundle: URL) async throws -> Bool {
        let info = try RecordingInfo.decode(from: Data(contentsOf: bundle.appendingPathComponent(BundleLayout.recording)))
        guard info.calibration == true else {
            print("This is not a calibration take. Record one with Tools ▸ Record Alignment Calibration, or `Screc --calibrate`.")
            return false
        }
        let fps = Double(info.capture.fps)
        let (_, events) = try TelemetryCodec.decodeFile(Data(contentsOf: bundle.appendingPathComponent(BundleLayout.events)))
        let pos = events.compactMap { e -> AlignmentEstimator.Sample? in
            if case let .pos(t, x, y) = e { return .init(t: t, x: x, y: y) }
            return nil
        }

        // Find the cursor in every frame.
        let asset = AVURLAsset(url: bundle.appendingPathComponent(info.tracks.screen))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CheckError("no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw CheckError("cannot read video: \(reader.error?.localizedDescription ?? "?")") }

        var video: [AlignmentEstimator.Sample] = []
        var frames = 0, missed = 0
        var background: (b: UInt8, g: UInt8, r: UInt8)?
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames += 1
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels), bpr = CVPixelBufferGetBytesPerRow(pixels)
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { continue }
            let buffer = UnsafeRawBufferPointer(start: base, count: bpr * h)
            let bg = background ?? CursorLocator.dominantColor(bgra: buffer, width: w, height: h, bytesPerRow: bpr)
            background = bg
            // A cursor is at most ~128 points; larger changed areas are system dialogs etc. → skip the frame.
            if let found = CursorLocator.locate(bgra: buffer, width: w, height: h, bytesPerRow: bpr, background: bg,
                                                maxExtent: 128 * info.capture.pointPixelScale) {
                video.append(.init(t: t, x: found.x, y: found.y))
            } else {
                missed += 1
            }
        }
        print("Frames read: \(frames), cursor found in \(video.count), skipped \(missed) (no cursor, or something larger than a cursor on screen)")
        print("Position events: \(pos.count)")

        let r = try AlignmentEstimator.estimate(video: video, events: pos)
        let frameMs = 1000 / fps
        print(String(format: "Time offset video vs telemetry: %+.2f ms  (limit ±%.2f ms = one frame at %.0f fps)", r.offset * 1000, frameMs, fps))
        print(String(format: "RMS position error at best offset: %.2f px  (at offset 0: %.2f px)", r.rmsError, r.rmsErrorAtZero))
        print(String(format: "Constant cursor-image offset removed: (%.1f, %.1f) px, samples used: %d", r.meanOffset.x, r.meanOffset.y, r.samplesUsed))
        let offsetOK = abs(r.offset * 1000) <= frameMs
        let rmsOK = r.rmsError <= 6
        print("\(offsetOK ? "✅" : "❌") |offset| ≤ one frame")
        print("\(rmsOK ? "✅" : "❌") RMS position error ≤ 6 px")
        return offsetOK && rmsOK
    }

    // MARK: timeline

    /// Builds the composition for the project's slices and checks every track against the time map.
    static func timeline(_ bundle: URL) async throws -> Bool {
        let prepared = try PreparedProject.load(bundle: bundle)
        let map = prepared.timeMap
        for e in map.entries {
            print(String(format: "slice %@: source %.3f–%.3f at %.2f× → timeline %.3f–%.3f", e.sliceID, e.sourceStart, e.sourceEnd,
                         e.speed, e.timelineStart, e.timelineEnd))
        }
        let result = try await CompositionBuilder.build(bundle: bundle, timeMap: map, slices: prepared.project.timeline.slices)
        var ok = true
        let frame = 1.0 / 60
        for track in try await result.composition.load(.tracks) {
            let range = try await track.load(.timeRange)
            let segments = try await track.load(.segments).filter { !$0.isEmpty }
            let pass = abs(range.end.seconds - map.duration) <= frame
            if !pass && track.mediaType == .video { ok = false }
            print(String(format: "%@ %@ track: ends at %.4f s, time map %.4f s, %d segments%@", pass ? "✅" : (track.mediaType == .video ? "❌" : "ℹ️"),
                         track.mediaType.rawValue, range.end.seconds, map.duration, segments.count,
                         pass ? "" : (track.mediaType == .video ? "" : " (audio file shorter than the video)")))
            // Each slice must map to a segment with the right source range and scaled duration.
            for (e, seg) in zip(map.entries, segments) {
                let src = seg.timeMapping.source, dst = seg.timeMapping.target
                let srcOK = abs(src.start.seconds - e.sourceStart) < 0.02
                let durOK = abs(dst.duration.seconds - e.timelineDuration) <= frame
                if track.mediaType == .video && !(srcOK && durOK) { ok = false }
                print(String(format: "   segment: source %.3f+%.3f → timeline %.3f+%.3f %@", src.start.seconds, src.duration.seconds,
                             dst.start.seconds, dst.duration.seconds, (srcOK && durOK) ? "✓" : "✗"))
            }
        }
        return ok
    }

    // MARK: bench

    /// Renders 120 frames across the timeline (one decoded source frame reused) and reports the time per frame.
    static func bench(_ bundle: URL, shortSide: Int) async throws {
        let prepared = try PreparedProject.load(bundle: bundle)
        let asset = AVURLAsset(url: bundle.appendingPathComponent(BundleLayout.screen))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CheckError("no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        reader.add(output)
        reader.startReading()
        let frame = output.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer)
        reader.cancelReading()

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw CheckError("no Metal device") }
        let compositor = try Compositor(device: device)
        let size = prepared.layout.outputSize(shortSide: shortSide)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d) else { throw CheckError("cannot create target") }
        let n = 120
        var gpu = 0.0
        let start = Date()
        for i in 0..<n {
            guard let cb = queue.makeCommandBuffer() else { continue }
            let t = prepared.timeMap.duration * Double(i) / Double(n)
            try compositor.render(prepared, frame: .init(t: t, frameInterval: 1 / 60, source: frame, bundle: bundle,
                                                             camera: await CameraFrameReader.forBundle(bundle)?.frame(atSource: prepared.timeMap.toSource(t))), into: target, commandBuffer: cb)
            cb.commit()
            await cb.completed()
            gpu += cb.gpuEndTime - cb.gpuStartTime
        }
        let wall = Date().timeIntervalSince(start)
        print(String(format: "%d frames at %d×%d: GPU %.2f ms/frame, total incl. CPU %.2f ms/frame (budget at 60 fps: 16.7 ms)",
                     n, Int(size.width), Int(size.height), gpu / Double(n) * 1000, wall / Double(n) * 1000))
    }

    // MARK: render

    static func render(_ bundle: URL, t: Double, out: URL, shortSide: Int) async throws {
        let prepared = try PreparedProject.load(bundle: bundle)
        let s = prepared.timeMap.toSource(t)

        // Frame selection rule (ARCHITECTURE §8.2): the decoded frame with the largest PTS ≤ s.
        let asset = AVURLAsset(url: bundle.appendingPathComponent(BundleLayout.screen))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CheckError("no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: s + 0.001, preferredTimescale: 60_000))
        guard reader.startReading() else { throw CheckError("cannot read video") }
        var frame: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds <= s + 1e-6, let pb = CMSampleBufferGetImageBuffer(sample) { frame = pb }
        }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let cb = queue.makeCommandBuffer()
        else { throw CheckError("no Metal device") }
        let compositor = try Compositor(device: device)
        let size = prepared.layout.outputSize(shortSide: shortSide)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { throw CheckError("cannot create target") }
        try compositor.render(prepared, frame: .init(t: t, frameInterval: 1 / 60, source: frame, bundle: bundle,
                                                             camera: await CameraFrameReader.forBundle(bundle)?.frame(atSource: prepared.timeMap.toSource(t))), into: target, commandBuffer: cb)
        cb.commit()
        await cb.completed()

        let w = target.width, h = target.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CheckError("cannot write PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CheckError("cannot write PNG") }
        let cam = prepared.camera.state(at: t), cur = prepared.cursor.sample(at: t)
        print(String(format: "rendered t=%.3f s (source %.3f s) → %@ (%d×%d), zoom %.2f, cursor (%.0f, %.0f) %@",
                     t, s, out.path, w, h, cam.scale, cur.x, cur.y, cur.shape.rawValue))
    }

    struct CheckError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }
}
