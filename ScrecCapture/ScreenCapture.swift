@preconcurrency import AVFoundation
import CoreMedia
import ScrecCore
@preconcurrency import ScreenCaptureKit

/// One `SCStream` delivering screen frames, system audio and microphone (ARCHITECTURE §6.1).
/// One stream = one clock for all three.
///
/// Each output type has its own serial queue, and each `MediaFileWriter` is only touched on its queue.
public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let clock: RecordingClock

    private let videoQueue = DispatchQueue(label: "screc.capture.screen", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "screc.capture.system-audio", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "screc.capture.mic", qos: .userInitiated)

    public let screenWriter: MediaFileWriter
    public let systemWriter: MediaFileWriter?
    public let micWriter: MediaFileWriter?

    private var stream: SCStream?
    /// Called once, on the video queue, with the host time (seconds) of the first complete frame.
    private let onFirstFrame: @Sendable (Double) -> Void
    /// Called if the stream stops by itself (display sleep, permission revoked, …).
    private let onStreamError: @Sendable (Error) -> Void
    private var sawFirstFrame = false   // video queue

    public init(filter: SCContentFilter, configuration: SCStreamConfiguration, clock: RecordingClock,
                screenWriter: MediaFileWriter, systemWriter: MediaFileWriter?, micWriter: MediaFileWriter?,
                onFirstFrame: @escaping @Sendable (Double) -> Void,
                onStreamError: @escaping @Sendable (Error) -> Void) {
        self.filter = filter
        self.configuration = configuration
        self.clock = clock
        self.screenWriter = screenWriter
        self.systemWriter = systemWriter
        self.micWriter = micWriter
        self.onFirstFrame = onFirstFrame
        self.onStreamError = onStreamError
    }

    public func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if systemWriter != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if micWriter != nil {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    /// Stops the stream, extends the screen track to `stopSourceTime` and finishes all files.
    public func stop(stopSourceTime: Double?) async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        // Drain the queues so no sample is appended after finishing.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            videoQueue.async {
                if let stopSourceTime { self.screenWriter.repeatLastSample(atSourceTime: stopSourceTime) }
                c.resume()
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in audioQueue.async { c.resume() } }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in micQueue.async { c.resume() } }
        await screenWriter.finish()
        await systemWriter?.finish()
        await micWriter?.finish()
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            if !sawFirstFrame {
                sawFirstFrame = true
                let host = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                clock.start(atHost: host)
                onFirstFrame(host)
            }
            screenWriter.append(sampleBuffer)
        case .audio:
            systemWriter?.append(sampleBuffer)
        case .microphone:
            micWriter?.append(sampleBuffer)
        @unknown default:
            break
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError(error)
    }

    /// ScreenCaptureKit also delivers "idle" buffers without an image when nothing changed. Skip those.
    static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sample) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
