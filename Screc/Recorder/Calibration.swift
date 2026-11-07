import AppKit
import ScrecCapture
import ScrecCore

/// Alignment calibration take (ARCHITECTURE §6.4, REC-14).
///
/// Records the main display for 20 s **with** the system cursor visible, over a plain grey backdrop,
/// while Screc moves the cursor along a known path (`CalibrationPath`). `screc-check align` then finds the
/// cursor in every video frame and compares it with the `pos` events in `events.jsonl`.
///
/// The cursor is moved with `CGWarpMouseCursorPosition`, which needs no permission.
/// Your mouse is taken over for 20 seconds; moving it yourself during the take spoils the measurement.
@MainActor
enum Calibration {
    private static var backdrop: NSWindow?

    static func run(model: AppModel, quitWhenDone: Bool) async {
        guard !model.isBusy else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) ?? NSScreen.main else { return }

        // Plain grey backdrop: everything that differs from it in the video is the cursor.
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        w.backgroundColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        backdrop = w
        model.extraIncludedWindowNumbers = [w.windowNumber]

        let saved = (model.sourceKind, model.displayID)
        model.sourceKind = .display
        model.displayID = screen.displayID
        await model.startRecording(countdownOverride: 0, calibration: true)
        model.sourceKind = saved.0
        model.displayID = saved.1
        model.extraIncludedWindowNumbers = []

        guard model.session.state == .recording else {
            finish(model: model, quit: quitWhenDone, bundle: nil)
            return
        }

        // Wait for the first frame (t0), then drive the cursor at 240 Hz for 20 s.
        while model.session.elapsed <= 0 { try? await Task.sleep(for: .milliseconds(10)) }
        let rect = CGRect(x: screen.frame.minX, y: 0, width: screen.frame.width, height: screen.frame.height)
        let cgRect = CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? rect.height) - screen.frame.maxY,
                            width: rect.width, height: rect.height)
        let start = HostTime.now
        CGDisplayShowCursor(screen.displayID)
        while HostTime.now - start < CalibrationPath.duration {
            CGWarpMouseCursorPosition(CalibrationPath.position(at: HostTime.now - start, in: cgRect))
            try? await Task.sleep(for: .microseconds(4167))
        }
        let url = await model.session.stop()
        model.lastRecording = url
        finish(model: model, quit: quitWhenDone, bundle: url)
    }

    private static func finish(model: AppModel, quit: Bool, bundle: URL?) {
        backdrop?.orderOut(nil)
        backdrop = nil
        PanelController.shared.hideControlBar()
        if let bundle {
            print("SCREC_CALIBRATION_BUNDLE=\(bundle.path)")
        } else {
            print("SCREC_CALIBRATION_FAILED=\(model.lastError ?? "unknown error")")
        }
        fflush(stdout)
        if quit { NSApp.terminate(nil) }
    }
}
