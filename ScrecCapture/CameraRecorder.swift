@preconcurrency import AVFoundation
import CoreMedia
import ScrecCore
import VideoToolbox

/// One camera, opened once and shared by the live preview bubble and the recorder (Phase 5 camera fix).
///
/// The camera has its own `AVCaptureSession` and therefore its own clock; frames are handed to the current
/// sink together with that clock.
public final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum CameraError: LocalizedError {
        case noCamera, cannotAddInput, cannotAddOutput
        public var errorDescription: String? {
            switch self {
            case .noCamera: "No camera is connected to this Mac. Connect one (or use an iPhone as Continuity Camera) or switch the camera off."
            case .cannotAddInput: "The camera could not be opened. Another app may be using it."
            case .cannotAddOutput: "The camera output could not be created."
            }
        }
    }

    public let session = AVCaptureSession()
    public let deviceID: String?
    private let queue = DispatchQueue(label: "screc.capture.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var sink: ((CMSampleBuffer, CMClock) -> Void)?

    public init(deviceID: String?) throws {
        self.deviceID = deviceID
        super.init()
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)
        session.commitConfiguration()
    }

    public var isRunning: Bool { session.isRunning }

    public func start() {
        queue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    public func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.session.stopRunning()
                c.resume()
            }
        }
    }

    /// Waits until a frame that is being handed out right now is done.
    func drain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    func setSink(_ sink: ((CMSampleBuffer, CMClock) -> Void)?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        guard let sink, let clock = session.synchronizationClock else { return }
        sink(sampleBuffer, clock)
    }
}

/// Records the webcam into `camera.mov` as a separate track (REC-02).
///
/// Each frame's timestamp is converted to host time with `CMSyncConvertTime` and then goes through the shared
/// `RecordingClock`, like every other track (ARCHITECTURE §6.1). An iPhone used as Continuity Camera can change
/// its picture size or repeat a timestamp while streaming; either stopped the file before. Frames are therefore
/// kept at the first frame's size, and late or repeated frames are skipped.
public final class CameraRecorder: @unchecked Sendable {
    private let source: CameraSource
    private let ownsSource: Bool
    private let clock: RecordingClock
    public let writer: MediaFileWriter
    private var size: CMVideoDimensions?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var lastHostPTS = -Double.infinity
    public private(set) var resized = 0
    public private(set) var skippedOutOfOrder = 0

    /// - Parameter source: the camera already open for the preview; without one the recorder opens its own.
    public init(url: URL, deviceID: String?, clock: RecordingClock, source: CameraSource? = nil) throws {
        self.clock = clock
        if let source, source.deviceID == deviceID {
            self.source = source
            ownsSource = false
        } else {
            self.source = try CameraSource(deviceID: deviceID)
            ownsSource = true
        }
        writer = MediaFileWriter(url: url, fileType: .mov, mediaType: .video, clock: clock, makeSettings: MediaSettings.cameraVideo())
    }

    public func start() {
        source.setSink { [weak self] sample, clock in self?.handle(sample, clock) }
        source.start()
    }

    public func stop() async {
        source.setSink(nil)
        if ownsSource { await source.stop() } else { await source.drain() }
        await writer.finish()
        if resized > 0 || skippedOutOfOrder > 0 {
            writer.extraDiagnostics = ["resized": Double(resized), "skippedOutOfOrder": Double(skippedOutOfOrder)]
        }
    }

    private func handle(_ sample: CMSampleBuffer, _ sessionClock: CMClock) {
        guard let host = MediaFileWriter.convertedToHostTime(sample, from: sessionClock) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(host).seconds
        guard pts > lastHostPTS else {
            skippedOutOfOrder += 1
            return
        }
        lastHostPTS = pts
        writer.append(conformed(host) ?? host)
    }

    /// The frame at the first frame's size (letterboxed if the shape changed), or nil if it already has it.
    private func conformed(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let w = Int32(CVPixelBufferGetWidth(pb)), h = Int32(CVPixelBufferGetHeight(pb))
        guard let size else {
            size = CMVideoDimensions(width: w, height: h)
            return nil
        }
        guard w != size.width || h != size.height else { return nil }
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            if let transfer { VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox) }
            CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(pb),
                                               kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
                                               kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
        }
        var out: CVPixelBuffer?
        guard let transfer, let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
              VTPixelTransferSessionTransferImage(transfer, from: pb, to: out) == noErr else { return nil }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: out, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                                        decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard let format else { return nil }
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: out, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result)
        resized += 1
        return result
    }
}
