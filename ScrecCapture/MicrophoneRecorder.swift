@preconcurrency import AVFoundation
import CoreMedia
import ScrecCore

/// Records the microphone into `mic.m4a` (REC-02).
///
/// Uses its own `AVCaptureSession` (like the webcam) instead of ScreenCaptureKit's microphone output, so the
/// device can be opened, checked and reported on clearly. Timestamps are converted from the session clock to
/// host time with `CMSyncConvertTime` and then go through the shared `RecordingClock`, so the track stays
/// aligned with screen and telemetry (ARCHITECTURE §6.1). Not yet tested with real hardware: the owner's
/// Mac mini has no microphone.
public final class MicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum MicError: LocalizedError {
        case noMicrophone, cannotAddInput, cannotAddOutput
        public var errorDescription: String? {
            switch self {
            case .noMicrophone:
                "No microphone is connected to this Mac. Connect one (USB microphone, headset, AirPods) or switch the microphone off."
            case .cannotAddInput: "The microphone could not be opened. Another app may be using it exclusively."
            case .cannotAddOutput: "The microphone output could not be created."
            }
        }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "screc.capture.mic", qos: .userInitiated)
    private let output = AVCaptureAudioDataOutput()
    public let writer: MediaFileWriter
    public let deviceName: String

    public init(url: URL, deviceID: String?, clock: RecordingClock) throws {
        writer = MediaFileWriter(url: url, fileType: .m4a, mediaType: .audio, clock: clock,
                                 makeSettings: MediaSettings.aac(maxChannels: 1))
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw MicError.noMicrophone }
        deviceName = device.localizedName
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw MicError.cannotAddInput }
        session.addInput(input)
        // Ask for 48 kHz mono float PCM, whatever the device's native format is.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw MicError.cannotAddOutput }
        session.addOutput(output)
        session.commitConfiguration()
    }

    public func start() {
        queue.async { self.session.startRunning() }
    }

    public func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.session.stopRunning()
                c.resume()
            }
        }
        await writer.finish()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sessionClock = session.synchronizationClock,
              let hostStamped = MediaFileWriter.convertedToHostTime(sampleBuffer, from: sessionClock) else { return }
        writer.append(hostStamped)
    }
}
