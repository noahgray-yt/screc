import AppKit
@preconcurrency import AVFoundation
import ScrecCore
import Observation
@preconcurrency import ScreenCaptureKit

/// What to record (REC-01, REC-02, REC-12).
public struct RecordingOptions: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
        /// A rectangle in the display's own points (top-left origin of that display).
        case area(CGDirectDisplayID, CGRect)
    }

    public var source: Source
    public var sourceApp: String
    public var recordMicrophone = false
    public var microphoneID: String?
    public var recordSystemAudio = false
    public var recordCamera = false
    public var cameraID: String?
    /// 60, or 120 on ProMotion displays.
    public var fps = 60
    /// Calibration take: the system cursor is drawn into the video (ARCHITECTURE §6.4).
    public var calibration = false
    public var directory: URL = BundleLayout.defaultDirectory
    /// Screc's own windows that must stay visible in the recording (desktop-icon cover, calibration backdrop).
    public var includedOwnWindowNumbers: [Int] = []

    public init(source: Source, sourceApp: String) {
        self.source = source
        self.sourceApp = sourceApp
    }
}

/// Runs one take: ScreenCaptureKit stream, webcam, event tap, position sampler and bundle files.
/// Every timestamp goes through one `RecordingClock` (ARCHITECTURE §6.2).
@MainActor
@Observable
public final class RecordingSession {
    public enum State: Equatable {
        case idle, starting, recording, paused, finishing
        case finished(URL)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var bundleURL: URL?
    /// Non-fatal problems to show after the take (e.g. "microphone file could not be written").
    public private(set) var warnings: [String] = []

    @ObservationIgnored private var clock = RecordingClock()
    @ObservationIgnored private var capture: ScreenCapture?
    @ObservationIgnored private var camera: CameraRecorder?
    @ObservationIgnored private var cameraSource: CameraSource?
    @ObservationIgnored private var microphone: MicrophoneRecorder?
    @ObservationIgnored private var diagnostics: [String: [String: Double]] = [:]
    @ObservationIgnored private var tap: EventTapRecorder?
    @ObservationIgnored private var sampler: PositionSampler?
    @ObservationIgnored private var windowTracker: WindowFrameTracker?
    @ObservationIgnored private var telemetry: TelemetryWriter?
    @ObservationIgnored private var info: RecordingInfo?
    @ObservationIgnored private var projectName = ""

    public init() {}

    /// Seconds recorded so far (pauses excluded). Read it from a timer for the control bar.
    public var elapsed: Double {
        let snapshot = clock.snapshot
        guard snapshot.t0Host != nil else { return 0 }
        if snapshot.isPaused, let start = snapshot.pauses.last?.startHost {
            return snapshot.sourceTime(host: start - 1e-6) ?? 0
        }
        return clock.sourceTime(host: HostTime.now) ?? 0
    }

    // MARK: Start

    /// - Parameter cameraSource: the camera already open for the live preview (shared, so it is not opened twice).
    public func start(_ options: RecordingOptions, cameraSource: CameraSource? = nil) async throws {
        self.cameraSource = cameraSource
        guard state == .idle || isDone else { return }
        state = .starting
        warnings = []
        clock = RecordingClock()
        do {
            try await startCapture(options)
            state = .recording
        } catch {
            await tearDown(stopSourceTime: nil)
            if let bundleURL { try? FileManager.default.removeItem(at: bundleURL) }
            bundleURL = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private var isDone: Bool {
        switch state {
        case .finished, .failed: true
        default: false
        }
    }

    public enum StartError: LocalizedError {
        case permissionDenied(String)
        public var errorDescription: String? {
            switch self {
            case let .permissionDenied(what):
                "\(what) permission is off for Screc. Allow it in System Settings › Privacy & Security › \(what), or switch the \(what.lowercased()) off."
            }
        }
    }

    /// Microphone and camera need their own permission. ScreenCaptureKit does not ask for the
    /// microphone itself; without permission it just delivers no sound. So ask (or fail clearly) first.
    private static func ensureAccess(_ type: AVMediaType, name: String) async throws {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: type) { return }
            throw StartError.permissionDenied(name)
        default:
            throw StartError.permissionDenied(name)
        }
    }

    private func startCapture(_ options: RecordingOptions) async throws {
        if options.recordMicrophone { try await Self.ensureAccess(.audio, name: "Microphone") }
        if options.recordCamera { try await Self.ensureAccess(.video, name: "Camera") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let plan = try CapturePlan.make(options: options, content: content)

        // Bundle folder, lock file and the first recording.json.
        let fm = FileManager.default
        try fm.createDirectory(at: options.directory, withIntermediateDirectories: true)
        let startedAt = Date()
        projectName = BundleLayout.projectName(sourceApp: options.sourceApp, date: startedAt)
        let bundle = BundleLayout.uniqueBundleURL(in: options.directory, projectName: projectName)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: false)
        try fm.createDirectory(at: bundle.appendingPathComponent(BundleLayout.cache), withIntermediateDirectories: false)
        fm.createFile(atPath: bundle.appendingPathComponent(BundleLayout.lock).path, contents: Data())
        bundleURL = bundle

        let info = RecordingInfo(startedAt: startedAt, sourceApp: options.sourceApp, capture: plan.captureInfo,
                                 tracks: .init(camera: options.recordCamera ? BundleLayout.camera : nil,
                                               mic: options.recordMicrophone ? BundleLayout.mic : nil,
                                               system: options.recordSystemAudio ? BundleLayout.system : nil),
                                 calibration: options.calibration)
        self.info = info
        try writeRecordingInfo(info)

        // Writers.
        let clock = self.clock
        let screenWriter = MediaFileWriter(url: bundle.appendingPathComponent(BundleLayout.screen), fileType: .mov,
                                           mediaType: .video, clock: clock, makeSettings: MediaSettings.screenVideo(fps: options.fps))
        let systemWriter = options.recordSystemAudio
            ? MediaFileWriter(url: bundle.appendingPathComponent(BundleLayout.system), fileType: .m4a, mediaType: .audio,
                              clock: clock, makeSettings: MediaSettings.aac(maxChannels: 2)) : nil
        let telemetry = try TelemetryWriter(url: bundle.appendingPathComponent(BundleLayout.events))
        self.telemetry = telemetry

        let mapper = MapperBox(CoordinateMapper(captureRect: plan.captureRectPoints,
                                                videoPixelSize: CGSize(width: plan.videoPixelSize.width, height: plan.videoPixelSize.height)))
        let screen = NSScreen.screens.first { $0.displayID == plan.displayID } ?? NSScreen.main ?? NSScreen.screens[0]
        let sampler = PositionSampler(screen: screen, clock: clock, writer: telemetry, mapper: mapper)
        self.sampler = sampler
        let tap = EventTapRecorder(clock: clock, writer: telemetry, mapper: mapper, layout: KeyboardLayout())
        self.tap = tap

        let videoSize = plan.videoPixelSize
        let sampleHz = sampler.sampleHz
        let capture = ScreenCapture(
            filter: plan.filter, configuration: plan.configuration(options: options), clock: clock,
            screenWriter: screenWriter, systemWriter: systemWriter, micWriter: nil,
            onFirstFrame: { [weak self] host in
                telemetry.setHeader(TelemetryHeader(t0HostSeconds: host, sampleHz: sampleHz,
                                                    videoPixelSize: [Int(videoSize.width), Int(videoSize.height)],
                                                    eventTimestampUnit: tap.detectedTimestampUnit?.rawValue))
                Task { @MainActor in self?.didReceiveFirstFrame(host: host) }
            },
            onStreamError: { [weak self] error in
                Task { @MainActor in await self?.streamFailed(error) }
            })
        self.capture = capture

        if options.recordMicrophone {
            microphone = try MicrophoneRecorder(url: bundle.appendingPathComponent(BundleLayout.mic), deviceID: options.microphoneID, clock: clock)
        }
        if options.recordCamera {
            camera = try CameraRecorder(url: bundle.appendingPathComponent(BundleLayout.camera), deviceID: options.cameraID, clock: clock,
                                        source: cameraSource)
        }

        // Telemetry first, so nothing between the first frame and the tap start is missed.
        try tap.start()
        sampler.start()
        if case let .window(windowID) = options.source {
            let tracker = WindowFrameTracker(windowID: windowID, clock: clock, writer: telemetry, mapper: mapper,
                                             pointPixelScale: plan.pointPixelScale)
            tracker.start()
            windowTracker = tracker
        }
        camera?.start()
        microphone?.start()
        try await capture.start()
    }

    private func didReceiveFirstFrame(host: Double) {
        guard var info else { return }
        info.clock.t0HostSeconds = host
        self.info = info
        try? writeRecordingInfo(info)
    }

    // MARK: Pause / resume (REC-05)

    public func pause() {
        guard state == .recording else { return }
        clock.pause(atHost: HostTime.now)
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        clock.resume(atHost: HostTime.now)
        state = .recording
    }

    // MARK: Stop / discard

    /// Stops and finalises the bundle. Returns its URL.
    @discardableResult
    public func stop() async -> URL? {
        guard state == .recording || state == .paused else { return bundleURL }
        state = .finishing
        // From here on, every sample stamped later than now is dropped (also closes an open pause).
        let stopSource = clock.stop(atHost: HostTime.now)
        await tearDown(stopSourceTime: stopSource)
        guard let bundleURL else { return nil }
        do {
            try finalise(bundle: bundleURL, stopSourceTime: stopSource)
            state = .finished(bundleURL)
        } catch {
            state = .failed("Could not finish the recording: \(error.localizedDescription)")
        }
        return bundleURL
    }

    /// Stops and moves the bundle to the Trash (REC-10 "discard").
    public func discard() async {
        guard state == .recording || state == .paused || state == .starting else { return }
        state = .finishing
        await tearDown(stopSourceTime: nil)
        if let bundleURL { try? FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil) }
        bundleURL = nil
        state = .idle
    }

    private func streamFailed(_ error: Error) async {
        guard state == .recording || state == .paused else { return }
        warnings.append("Recording stopped by macOS: \(error.localizedDescription)")
        await stop()
    }

    private func tearDown(stopSourceTime: Double?) async {
        sampler?.stop()
        tap?.stop()
        windowTracker?.stop()
        await capture?.stop(stopSourceTime: stopSourceTime)
        await camera?.stop()
        await microphone?.stop()
        telemetry?.close()
        diagnostics = [:]
        let named: [(String, MediaFileWriter?)] = [("screen", capture?.screenWriter), ("system", capture?.systemWriter),
                                                    ("mic", microphone?.writer), ("camera", camera?.writer)]
        for (name, writer) in named {
            guard let writer else { continue }
            diagnostics[name] = writer.diagnostics
            if let message = writer.errorDescription { warnings.append("\(writer.url.lastPathComponent): \(message)") }
        }
        sampler = nil
        tap = nil
        windowTracker = nil
        capture = nil
        camera = nil
        microphone = nil
        telemetry = nil
    }

    private func finalise(bundle: URL, stopSourceTime: Double?) throws {
        guard var info else { return }
        let duration = stopSourceTime ?? 0
        info.duration = duration
        info.pauses = clock.snapshot.pausesForRecordingInfo
        info.finalised = true
        info.diagnostics = diagnostics.isEmpty ? nil : diagnostics
        // Drop tracks that produced no file (e.g. no microphone samples arrived).
        let fm = FileManager.default
        func existing(_ name: String?) -> String? {
            guard let name, fm.fileExists(atPath: bundle.appendingPathComponent(name).path) else { return nil }
            return name
        }
        let requested = info.tracks
        info.tracks = .init(screen: BundleLayout.screen, camera: existing(info.tracks.camera),
                            mic: existing(info.tracks.mic), system: existing(info.tracks.system))
        if requested.mic != nil && info.tracks.mic == nil {
            let d = diagnostics["mic"] ?? [:]
            warnings.append("The microphone was on, but no sound was saved (samples received \(Int(d["received"] ?? 0)), "
                            + "outside the take \(Int(d["outsideTake"] ?? 0))). Check the microphone permission and the selected device.")
        }
        if requested.system != nil && info.tracks.system == nil {
            warnings.append("System audio was on, but no sound was playing, so no system-audio file was written.")
        }
        if requested.camera != nil && info.tracks.camera == nil {
            warnings.append("The camera was on, but no picture arrived from it.")
        }
        self.info = info
        try writeRecordingInfo(info)
        let project = Project.fresh(name: projectName, duration: duration)
        try project.encoded().write(to: bundle.appendingPathComponent(BundleLayout.project), options: .atomic)
        try fm.removeItem(at: bundle.appendingPathComponent(BundleLayout.lock))
    }

    private func writeRecordingInfo(_ info: RecordingInfo) throws {
        guard let bundleURL else { return }
        try info.encoded().write(to: bundleURL.appendingPathComponent(BundleLayout.recording), options: .atomic)
    }
}

/// Turns `RecordingOptions` into a ScreenCaptureKit filter, a configuration and the geometry facts.
struct CapturePlan {
    var filter: SCContentFilter
    var displayID: CGDirectDisplayID
    var captureRectPoints: CGRect          // global CG points
    var pointPixelScale: Double
    var videoPixelSize: CGSize
    var sourceRect: CGRect?                // area capture, display-local points
    var captureInfo: RecordingInfo.Capture

    enum PlanError: Error, CustomStringConvertible {
        case displayNotFound, windowNotFound, emptyArea
        var description: String {
            switch self {
            case .displayNotFound: "The selected display is no longer available."
            case .windowNotFound: "The selected window is no longer available."
            case .emptyArea: "The selected area is empty."
            }
        }
    }

    static func make(options: RecordingOptions, content: SCShareableContent) throws -> CapturePlan {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApp = content.applications.first { $0.processID == pid }
        let keep = Set(options.includedOwnWindowNumbers)
        let ownKept = content.windows.filter { $0.owningApplication?.processID == pid && keep.contains(Int($0.windowID)) }

        func displayFilter(_ display: SCDisplay) -> SCContentFilter {
            // Exclude every window of Screc (control bar, countdown, notes, …), except the ones that must be visible.
            if let ownApp {
                return SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: ownKept)
            }
            return SCContentFilter(display: display, excludingWindows: [])
        }

        switch options.source {
        case let .display(id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw PlanError.displayNotFound }
            let filter = displayFilter(display)
            return plan(filter: filter, displayID: id, rect: display.frame, kind: .display, windowID: nil, sourceRect: nil, options: options)

        case let .area(id, rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw PlanError.displayNotFound }
            let r = rect.integral.intersection(CGRect(origin: .zero, size: display.frame.size))
            guard r.width >= 16, r.height >= 16 else { throw PlanError.emptyArea }
            let global = r.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
            return plan(filter: displayFilter(display), displayID: id, rect: global, kind: .area, windowID: nil, sourceRect: r, options: options)

        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw PlanError.windowNotFound }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let display = content.displays.first { $0.frame.contains(centre) } ?? content.displays.first
            return plan(filter: filter, displayID: display?.displayID ?? CGMainDisplayID(), rect: window.frame, kind: .window,
                        windowID: windowID, sourceRect: nil, options: options)
        }
    }

    private static func plan(filter: SCContentFilter, displayID: CGDirectDisplayID, rect: CGRect, kind: RecordingInfo.CaptureKind,
                             windowID: CGWindowID?, sourceRect: CGRect?, options: RecordingOptions) -> CapturePlan {
        let scale = Double(filter.pointPixelScale)
        // Even pixel sizes for 4:2:0 video.
        func even(_ v: Double) -> Double { max(2, (v / 2).rounded() * 2) }
        let size = CGSize(width: even(rect.width * scale), height: even(rect.height * scale))
        let displayPixels = [Int(CGDisplayPixelsWide(displayID)), Int(CGDisplayPixelsHigh(displayID))]
        let modePixels = CGDisplayCopyDisplayMode(displayID).map { [$0.pixelWidth, $0.pixelHeight] } ?? displayPixels
        let info = RecordingInfo.Capture(kind: kind, displayID: displayID, displayPixelSize: modePixels, pointPixelScale: scale,
                                         contentRectPoints: [rect.minX, rect.minY, rect.width, rect.height].map(Double.init),
                                         videoPixelSize: [Int(size.width), Int(size.height)], fps: options.fps, windowID: windowID)
        return CapturePlan(filter: filter, displayID: displayID, captureRectPoints: rect, pointPixelScale: scale,
                           videoPixelSize: size, sourceRect: sourceRect, captureInfo: info)
    }

    func configuration(options: RecordingOptions) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int(videoPixelSize.width)
        c.height = Int(videoPixelSize.height)
        if let sourceRect { c.sourceRect = sourceRect }
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        c.showsCursor = options.calibration       // REC-12: no cursor, except for calibration takes
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.colorSpaceName = CGColorSpace.sRGB
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.queueDepth = 8
        c.captureResolution = .best
        c.capturesAudio = options.recordSystemAudio
        c.excludesCurrentProcessAudio = true
        c.sampleRate = 48_000
        c.channelCount = 2
        // The microphone is recorded by MicrophoneRecorder (AVCaptureSession), not by this stream.
        c.captureMicrophone = false
        return c
    }
}

public extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
