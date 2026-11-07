@preconcurrency import AVFoundation
import CoreMedia
import ScrecCore

/// Writes one media file (`screen.mov`, `camera.mov`, `mic.m4a`, `system.m4a`) from sample buffers.
///
/// - Sample buffers arrive stamped in **host time**. `append(_:)` asks the shared `RecordingClock` for the
///   source time, drops the sample if it lies before `t0` or inside a pause, and re-stamps it.
/// - The `AVAssetWriter` is created lazily from the first sample's format (frame size, sample rate,
///   channel count), so the output settings always match what the device delivers.
/// - `movieFragmentInterval = 2 s`: after a crash the file is readable up to the last fragment (REC-06).
///
/// Concurrency: confined to the serial queue the owner calls it on (one capture output queue).
/// That rule is why the class is `@unchecked Sendable`.
public final class MediaFileWriter: @unchecked Sendable {
    public typealias SettingsMaker = (CMFormatDescription) -> [String: Any]

    public let url: URL
    private let fileType: AVFileType
    private let mediaType: AVMediaType
    private let makeSettings: SettingsMaker
    private let clock: RecordingClock

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var lastSample: CMSampleBuffer?
    private var failed = false

    public private(set) var appendedCount = 0
    public private(set) var droppedNotReady = 0
    /// Diagnostics (written to recording.json): samples delivered, samples outside the take,
    /// and how far the first sample's timestamp was from "now" (should be a few ms; seconds = wrong clock).
    public private(set) var receivedCount = 0
    public private(set) var outsideTakeCount = 0
    public private(set) var firstTimestampMinusNow: Double?
    /// Source time of the newest appended sample (end of its duration if known).
    public private(set) var lastSourceEnd: Double = 0
    public private(set) var errorDescription: String?

    public init(url: URL, fileType: AVFileType, mediaType: AVMediaType, clock: RecordingClock,
                makeSettings: @escaping SettingsMaker) {
        self.url = url
        self.fileType = fileType
        self.mediaType = mediaType
        self.clock = clock
        self.makeSettings = makeSettings
    }

    public var hasData: Bool { appendedCount > 0 }

    /// Appends a host-time stamped sample. Returns its source time if it was written.
    @discardableResult
    public func append(_ sample: CMSampleBuffer) -> Double? {
        guard !failed, CMSampleBufferDataIsReady(sample) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return nil }
        receivedCount += 1
        if firstTimestampMinusNow == nil { firstTimestampMinusNow = pts.seconds - HostTime.now }
        guard let source = clock.sourceTime(host: pts.seconds) else {
            outsideTakeCount += 1
            return nil
        }
        guard let retimed = Self.retime(sample, hostPTS: pts, sourceSeconds: source) else { return nil }
        return write(retimed, sourceStart: source)
    }

    /// Appends a copy of the newest sample at `sourceTime`. Used for the screen track at stop:
    /// ScreenCaptureKit sends no frames while the screen is still, so without this the video
    /// would end at the last change instead of at the moment the user pressed Stop.
    public func repeatLastSample(atSourceTime sourceTime: Double) {
        guard let lastSample, sourceTime > lastSourceEnd + 0.001 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(lastSample)
        guard let copy = Self.retime(lastSample, hostPTS: pts, sourceSeconds: sourceTime, keepDuration: false) else { return }
        _ = write(copy, sourceStart: sourceTime)
    }

    private func write(_ sample: CMSampleBuffer, sourceStart: Double) -> Double? {
        if writer == nil, !startWriter(with: sample) { return nil }
        guard let writer, let input else { return nil }
        guard writer.status == .writing else {
            fail(Self.describe(writer.error) ?? "writer status \(writer.status.rawValue)")
            return nil
        }
        guard input.isReadyForMoreMediaData else {
            droppedNotReady += 1
            return nil
        }
        guard input.append(sample) else {
            fail(Self.describe(writer.error) ?? "append failed")
            return nil
        }
        appendedCount += 1
        lastSample = sample
        let duration = CMSampleBufferGetDuration(sample)
        lastSourceEnd = max(lastSourceEnd, sourceStart + (duration.isValid ? duration.seconds : 0))
        return sourceStart
    }

    private func startWriter(with sample: CMSampleBuffer) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return false }
        do {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            writer.shouldOptimizeForNetworkUse = false
            let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: makeSettings(format), sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                fail("cannot add \(mediaType.rawValue) input")
                return false
            }
            writer.add(input)
            guard writer.startWriting() else {
                fail(Self.describe(writer.error) ?? "startWriting failed")
                return false
            }
            // Source time 0 = first screen frame, for every file of the take.
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    /// Finishes the file. Safe to call when nothing was written (then no file exists).
    public func finish() async {
        guard let writer, let input else { return }
        input.markAsFinished()
        if writer.status == .writing {
            await writer.finishWriting()
        }
        if writer.status == .failed {
            fail(Self.describe(writer.error) ?? "finishWriting failed")
        }
    }

    /// Extra numbers from the recorder that owns this writer, added to `diagnostics`.
    public var extraDiagnostics: [String: Double] = [:]

    /// The error text with its domain and code, and the underlying error (macOS often says only
    /// "The operation could not be completed").
    static func describe(_ error: Error?) -> String? {
        guard let e = error as NSError? else { return nil }
        var text = "\(e.localizedDescription) [\(e.domain) \(e.code)"
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { text += "; \(u.domain) \(u.code)" }
        return text + "]"
    }

    private func fail(_ message: String) {
        failed = true
        errorDescription = message
        NSLog("Screc: \(url.lastPathComponent): \(message)")
    }

    public var diagnostics: [String: Double] {
        var d: [String: Double] = ["received": Double(receivedCount), "written": Double(appendedCount),
                                   "outsideTake": Double(outsideTakeCount), "droppedNotReady": Double(droppedNotReady)]
        if let firstTimestampMinusNow { d["firstTimestampMinusNowMs"] = (firstTimestampMinusNow * 1000).rounded() }
        if let code = (writer?.error as NSError?)?.code { d["errorCode"] = Double(code) }
        return d.merging(extraDiagnostics) { a, _ in a }
    }

    /// Copies a capture-session sample buffer with all timestamps converted from the session's clock to host time.
    public static func convertedToHostTime(_ sample: CMSampleBuffer, from clock: CMClock) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return nil }
        let hostPTS = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        guard hostPTS.isValid else { return nil }
        let delta = CMTimeSubtract(pts, hostPTS)
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid { timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, delta) }
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, delta) }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                           sampleTimingEntryCount: timing.count, sampleTimingArray: &timing,
                                                           sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    /// Copies a sample buffer with every timestamp moved from host time to source time.
    /// The shift is computed in the buffer's own timescale, so consecutive audio buffers stay seamless.
    static func retime(_ sample: CMSampleBuffer, hostPTS: CMTime, sourceSeconds: Double, keepDuration: Bool = true) -> CMSampleBuffer? {
        let sourcePTS = CMTime(seconds: sourceSeconds, preferredTimescale: max(hostPTS.timescale, 600))
        let delta = CMTimeSubtract(hostPTS, sourcePTS)
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        if count > 0 {
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        } else {
            timing[0] = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: hostPTS, decodeTimeStamp: .invalid)
        }
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid {
                timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, delta)
            }
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, delta)
            }
            if !keepDuration { timing[i].duration = .invalid }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                           sampleTimingEntryCount: timing.count, sampleTimingArray: &timing,
                                                           sampleBufferOut: &out)
        return status == noErr ? out : nil
    }
}

/// Output settings for Screc's files.
public enum MediaSettings {
    /// HEVC for the screen. The bitrate scales with size and frame rate (≈ 0.08 bit per pixel per frame).
    public static func screenVideo(fps: Int) -> MediaFileWriter.SettingsMaker {
        { format in
            let d = CMVideoFormatDescriptionGetDimensions(format)
            let bitrate = min(Double(d.width) * Double(d.height) * Double(fps) * 0.08, 80_000_000)
            return [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(d.width),
                AVVideoHeightKey: Int(d.height),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(bitrate),
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                ],
            ]
        }
    }

    /// H.264 for the webcam.
    public static func cameraVideo() -> MediaFileWriter.SettingsMaker {
        { format in
            let d = CMVideoFormatDescriptionGetDimensions(format)
            return [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(d.width),
                AVVideoHeightKey: Int(d.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                ],
            ]
        }
    }

    /// AAC at 48 kHz. `maxChannels`: 1 for the microphone, 2 for system audio.
    public static func aac(maxChannels: Int) -> MediaFileWriter.SettingsMaker {
        { format in
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            let channels = min(max(Int(asbd?.mChannelsPerFrame ?? 1), 1), maxChannels)
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000,
            ]
        }
    }
}
