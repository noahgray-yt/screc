import AppKit
@preconcurrency import AVFoundation
import ScrecCapture
import ScrecCore
import Observation

/// App-wide state for the recorder window: chosen source, options, and the running session.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum SourceKind: String, CaseIterable, Identifiable {
        case display = "Display", window = "Window", area = "Area"
        var id: String { rawValue }
    }

    let session = RecordingSession()
    var catalog = SourceCatalog()
    var catalogError: String?

    // Source (REC-01)
    var sourceKind: SourceKind = .display { didSet { defaults.set(sourceKind.rawValue, forKey: "sourceKind") } }
    var displayID: CGDirectDisplayID?
    var windowID: CGWindowID?
    var area: CGRect? { didSet { if let area { defaults.set(NSStringFromRect(area), forKey: "area") } } }

    // Tracks (REC-02)
    var recordMicrophone: Bool {
        didSet {
            defaults.set(recordMicrophone, forKey: "recordMicrophone")
            if recordMicrophone { askAccess(.microphone) { $0.recordMicrophone = false } }
        }
    }
    var microphoneID: String? { didSet { defaults.set(microphoneID, forKey: "microphoneID") } }
    var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: "recordSystemAudio") } }
    var recordCamera: Bool {
        didSet {
            defaults.set(recordCamera, forKey: "recordCamera")
            if recordCamera { askAccess(.camera) { $0.recordCamera = false } }
            updateCameraPreview()
        }
    }
    var cameraID: String? { didSet { defaults.set(cameraID, forKey: "cameraID"); updateCameraPreview() } }
    /// Bumped when a camera or microphone is plugged in or out, so the recorder redraws its track rows.
    var deviceListVersion = 0
    /// The recorder window is on screen (the camera preview shows while it is, or while recording).
    var recorderVisible = false { didSet { updateCameraPreview() } }
    /// Editor windows that are open: the camera bubble hides while one is (unless a take is running).
    var openEditors = 0 { didSet { updateCameraPreview() } }

    // Options
    var countdown: Int { didSet { defaults.set(countdown, forKey: "countdown") } }                 // REC-03
    var fps: Int { didSet { defaults.set(fps, forKey: "fps") } }                                    // REC-12
    var hideDesktopIcons: Bool { didSet { defaults.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }   // REC-08
    var showSpeakerNotes = false { didSet { PanelController.shared.setNotesVisible(showSpeakerNotes) } }    // REC-09
    var hotKey: GlobalHotKey.Combo {                                                                // REC-04
        didSet {
            defaults.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey")
            registerHotKey()
        }
    }
    var hotKeyProblem: String?

    var isCountingDown = false
    var lastRecording: URL?
    var lastError: String?
    var lastWarnings: [String] = []
    /// Newest recordings in ~/Movies/Screc (until the Phase 3 editor exists, this is how to reach them).
    var recentRecordings: [URL] = []

    /// Where recordings go. `--recordings-dir <path>` overrides it (used for automated tests).
    static let recordingsDirectory: URL = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--recordings-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        return BundleLayout.defaultDirectory
    }()

    private let defaults = UserDefaults.standard
    private let iconCover = DesktopIconCover()
    private let areaSelector = AreaSelector()
    /// Extra own windows that must be captured (calibration backdrop).
    var extraIncludedWindowNumbers: [Int] = []

    private init() {
        let d = UserDefaults.standard
        sourceKind = SourceKind(rawValue: d.string(forKey: "sourceKind") ?? "") ?? .display
        area = d.string(forKey: "area").map { NSRectFromString($0) }
        recordMicrophone = d.bool(forKey: "recordMicrophone")
        microphoneID = d.string(forKey: "microphoneID")
        recordSystemAudio = d.bool(forKey: "recordSystemAudio")
        recordCamera = d.bool(forKey: "recordCamera")
        cameraID = d.string(forKey: "cameraID")
        countdown = d.object(forKey: "countdown") as? Int ?? 3
        fps = d.object(forKey: "fps") as? Int ?? 60
        hideDesktopIcons = d.bool(forKey: "hideDesktopIcons")
        hotKey = (d.data(forKey: "hotKey")).flatMap { try? JSONDecoder().decode(GlobalHotKey.Combo.self, from: $0) } ?? .default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.deviceListVersion += 1
                    self?.updateCameraPreview()
                }
            }
        }
    }

    var isRecording: Bool { session.state == .recording || session.state == .paused || session.state == .finishing }
    var isBusy: Bool { isRecording || isCountingDown || session.state == .starting }

    func registerHotKey() {
        let ok = GlobalHotKey.shared.register(hotKey) { [weak self] in
            Task { await self?.toggleRecording() }
        }
        hotKeyProblem = ok ? nil : "\(hotKey.display) is already used by another app. Pick a different shortcut."
    }

    func refreshRecent() {
        let fm = FileManager.default
        let dir = Self.recordingsDirectory
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        recentRecordings = items
            .filter { $0.pathExtension == BundleLayout.fileExtension }
            .filter { !fm.fileExists(atPath: $0.appendingPathComponent(BundleLayout.lock).path) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
            .prefix(6)
            .map { $0 }
    }

    // MARK: Sources

    func refreshSources() async {
        do {
            catalog = try await SourceCatalog.load()
            catalogError = nil
            if displayID == nil || !catalog.displays.contains(where: { $0.id == displayID }) {
                displayID = catalog.displays.first { $0.id == CGMainDisplayID() }?.id ?? catalog.displays.first?.id
            }
            if let windowID, !catalog.windows.contains(where: { $0.id == windowID }) { self.windowID = nil }
        } catch {
            catalogError = "Could not list screens and windows: \(error.localizedDescription). Is Screen Recording allowed?"
        }
    }

    var selectedWindow: SourceCatalog.WindowItem? { catalog.windows.first { $0.id == windowID } }

    func pickArea() async {
        guard let displayID, let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        if let rect = await areaSelector.select(on: screen, initial: area) { area = rect }
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// 120 fps only makes sense on a ProMotion display.
    var maxFPSForSelectedDisplay: Int {
        let id = sourceKind == .window ? (selectedWindowDisplayID ?? displayID) : displayID
        let screen = NSScreen.screens.first { $0.displayID == id }
        return (screen?.maximumFramesPerSecond ?? 60) >= 120 ? 120 : 60
    }

    private var selectedWindowDisplayID: CGDirectDisplayID? {
        guard let w = selectedWindow else { return nil }
        return catalog.displays.first { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }?.id
    }

    // MARK: Recording

    func makeOptions(calibration: Bool = false) -> RecordingOptions? {
        let source: RecordingOptions.Source
        var appName = FrontmostAppTracker.shared.lastOtherApp ?? "Recording"
        switch sourceKind {
        case .display:
            guard let displayID else { lastError = "Choose a display."; return nil }
            source = .display(displayID)
        case .window:
            guard let w = selectedWindow else { lastError = "Choose a window."; return nil }
            source = .window(w.id)
            appName = w.appName
        case .area:
            guard let displayID, let area else { lastError = "Select an area first."; return nil }
            source = .area(displayID, area)
        }
        var o = RecordingOptions(source: source, sourceApp: calibration ? "Calibration" : appName)
        // A switch left on from an earlier session is ignored when the device is gone (e.g. Mac mini without a microphone).
        o.recordMicrophone = recordMicrophone && !calibration && !Self.microphones.isEmpty
        o.microphoneID = microphoneID
        o.recordSystemAudio = recordSystemAudio && !calibration
        o.recordCamera = recordCamera && !calibration && !Self.cameras.isEmpty
        o.cameraID = cameraID
        o.fps = min(fps, maxFPSForSelectedDisplay)
        o.calibration = calibration
        o.includedOwnWindowNumbers = iconCover.windowNumbers + extraIncludedWindowNumbers
        o.directory = Self.recordingsDirectory
        return o
    }

    func toggleRecording() async {
        if isRecording { await stopRecording() } else if !isBusy { await startRecording() }
    }

    func startRecording(countdownOverride: Int? = nil, calibration: Bool = false) async {
        guard !isBusy else { return }
        lastError = nil
        lastWarnings = []
        // Missing permissions: say which one instead of failing halfway.
        if let missing = Permission.allCases.first(where: { $0.isRequired && $0.status != .granted }) {
            lastError = "Screc needs \(missing.title) permission first."
            PermissionAlert.show(missing)
            return
        }
        if hideDesktopIcons && sourceKind != .window && !calibration { iconCover.show() }
        guard let options = makeOptions(calibration: calibration) else {
            iconCover.hide()
            return
        }
        isCountingDown = true
        updateCameraPreview()                              // the live camera bubble, also when the recorder is closed
        await PanelController.shared.runCountdown(seconds: countdownOverride ?? countdown)
        isCountingDown = false
        do {
            try await session.start(options, cameraSource: options.recordCamera ? CameraPreview.shared.source : nil)
            PanelController.shared.showControlBar(model: self)
        } catch {
            iconCover.hide()
            lastError = "Recording could not start: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        PanelController.shared.hideControlBar()
        let url = await session.stop()
        iconCover.hide()
        lastWarnings = session.warnings
        if case let .failed(message) = session.state { lastError = message }
        if let url {
            lastRecording = url
            applyPreviewCorner(to: url)
        }
        refreshRecent()
        updateCameraPreview()
    }

    // MARK: Permissions

    /// Microphone and camera: macOS asks the moment the switch is turned on. If the permission is refused,
    /// the switch goes back off; if it was refused earlier, an alert leads to System Settings.
    private func askAccess(_ permission: Permission, turnOff: @escaping (AppModel) -> Void) {
        switch permission.status {
        case .granted:
            return
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: permission == .microphone ? .audio : .video)
                if granted { updateCameraPreview() } else { turnOff(self) }
            }
        case .denied:
            turnOff(self)
            PermissionAlert.show(permission)
        }
    }

    // MARK: Camera preview

    /// Shows the live camera bubble while the camera is on and the recorder is open with no editor (or a take is running).
    func updateCameraPreview() {
        let cameras = Self.cameras
        let show = recordCamera && !cameras.isEmpty && Permission.camera.status == .granted
            && ((recorderVisible && openEditors == 0) || isBusy)
        let screen = NSScreen.screens.first { $0.displayID == displayID }
        // A chosen camera that is gone falls back to the default one.
        let device = cameras.contains { $0.uniqueID == cameraID } ? cameraID : nil
        CameraPreview.shared.update(show: show, deviceID: device, screen: screen)
    }

    /// The corner the preview bubble was in becomes the new recording's camera corner.
    private func applyPreviewCorner(to bundle: URL) {
        let url = bundle.appendingPathComponent(BundleLayout.project)
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent(BundleLayout.camera).path),
              let data = try? Data(contentsOf: url), var project = try? Project.decode(from: data) else { return }
        project.look.webcam.corner = CameraPreview.shared.corner
        try? project.encoded().write(to: url, options: .atomic)
    }

    func discardRecording() async {
        PanelController.shared.hideControlBar()
        await session.discard()
        iconCover.hide()
    }

    /// REC-10 "restart": throw this take away and start a new one with the same settings.
    func restartRecording() async {
        await discardRecording()
        await startRecording()
    }

    // MARK: Utilities

    func resizeSelectedWindow(to size: CGSize) {
        guard let w = selectedWindow else { lastError = "Choose a window first."; return }
        do {
            try WindowResizer.resize(pid: w.pid, frame: w.frame, title: w.title, to: size)
            lastError = nil
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                await refreshSources()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}

extension Permission {
    static var allRequiredGranted: Bool { allCases.filter(\.isRequired).allSatisfy { $0.status == .granted } }

    /// At launch: the system prompts for Screen Recording and Input Monitoring, no window of Screc's own.
    @MainActor
    static func requestRequired() {
        for p in allCases where p.isRequired && p.status != .granted { p.request() }
    }
}

/// When a permission was refused before, macOS does not ask again; this points to the right System Settings pane.
@MainActor
enum PermissionAlert {
    static func show(_ permission: Permission) {
        let alert = NSAlert()
        alert.messageText = "Allow \(permission.title) for Screc"
        alert.informativeText = permission.explanation
            + "\n\nTurn on Screc in System Settings › Privacy & Security › \(permission.title)."
            + (permission == .screenRecording ? " macOS may then ask you to quit and reopen Screc." : "")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { permission.openSettings() }
    }
}
