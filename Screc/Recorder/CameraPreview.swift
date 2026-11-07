import AppKit
@preconcurrency import AVFoundation
import ScrecCapture
import ScrecCore

/// The live camera bubble (Phase 5): while the camera is on, a round, mirrored preview floats on screen so the
/// owner sees how they are framed, before and during recording. Like every Screc window it is left out of the
/// recording; the editor places the camera itself. Drag it anywhere; it snaps to the nearest corner, and that
/// corner becomes the recording's camera corner.
@MainActor
final class CameraPreview {
    static let shared = CameraPreview()

    private(set) var source: CameraSource?
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    /// The camera stopped delivering (unplugged, iPhone camera ended, taken by another app).
    private var sessionObservers: [NSObjectProtocol] = []
    static let diameter: CGFloat = 190
    static let margin: CGFloat = 24

    var corner: WebcamLook.Corner {
        get { WebcamLook.Corner(rawValue: UserDefaults.standard.string(forKey: "webcamCorner") ?? "") ?? .bottomRight }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "webcamCorner") }
    }

    /// Shows the bubble for `deviceID` on `screen`, or hides it.
    func update(show: Bool, deviceID: String?, screen: NSScreen?) {
        guard show else {
            hide()
            return
        }
        if let source, source.deviceID != deviceID { hide() }
        if source == nil {
            do {
                let s = try CameraSource(deviceID: deviceID)
                s.start()
                source = s
            } catch {
                return
            }
        }
        if panel == nil, let source { makePanel(source: source, screen: screen ?? NSScreen.main) }
    }

    func hide() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
        panel?.orderOut(nil)
        panel = nil
        if let source {
            self.source = nil
            Task { await source.stop() }
        }
    }

    private func makePanel(source: CameraSource, screen: NSScreen?) {
        let d = Self.diameter
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: d, height: d), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none                       // never in a screen recording
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let view = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: source.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.cornerRadius = d / 2
        layer.masksToBounds = true
        layer.borderWidth = 2
        layer.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true                      // like a mirror, as in video calls
        }
        view.layer?.addSublayer(layer)
        view.toolTip = "Your camera (not recorded here; the editor places it). Drag it to a corner."
        panel.contentView = view

        if let frame = (screen ?? NSScreen.main)?.visibleFrame { panel.setFrameOrigin(origin(for: corner, in: frame)) }
        panel.orderFrontRegardless()
        self.panel = panel
        // No empty ring: when the camera stops, the bubble goes away (it comes back when the camera is turned on again).
        let names: [Notification.Name] = [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification,
                                          AVCaptureSession.didStopRunningNotification]
        sessionObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: source.session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        // Snap to the nearest corner once a drag ends (the window stops moving).
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSnap() }
        }
    }

    private var snapTask: Task<Void, Never>?

    private func scheduleSnap() {
        snapTask?.cancel()
        snapTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, NSEvent.pressedMouseButtons == 0 else {
                if !Task.isCancelled { scheduleSnap() }
                return
            }
            snap()
        }
    }

    private func snap() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let f = screen.visibleFrame, c = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let right = c.x > f.midX, top = c.y > f.midY                     // AppKit: y grows upwards
        let new: WebcamLook.Corner = top ? (right ? .topRight : .topLeft) : (right ? .bottomRight : .bottomLeft)
        corner = new
        let target = origin(for: new, in: f)
        guard abs(target.x - panel.frame.minX) > 1 || abs(target.y - panel.frame.minY) > 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().setFrameOrigin(target)
        }
    }

    private func origin(for corner: WebcamLook.Corner, in f: CGRect) -> CGPoint {
        let d = Self.diameter, m = Self.margin
        let right = corner == .bottomRight || corner == .topRight, top = corner == .topRight || corner == .topLeft
        return CGPoint(x: right ? f.maxX - m - d : f.minX + m, y: top ? f.maxY - m - d : f.minY + m)
    }
}
