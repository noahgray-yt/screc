import AppKit
import ScrecCapture
import ScrecCore
import SwiftUI

@main
struct ScrecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Screc", id: "recorder") {
            RecorderView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // One editor window per recording (Phase 3).
        WindowGroup("Editor", id: "editor", for: URL.self) { $url in
            if let url { EditorWindowContent(bundle: url) }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                    Task { await model.toggleRecording() }
                }
                Button("Open Recordings Folder") {
                    let dir = AppModel.recordingsDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
            }
            CommandMenu("Tools") {
                Button("Permissions…") { OnboardingWindow.show() }
                Button("Recover Interrupted Recordings…") { appDelegate.offerRecovery(force: true) }
                Divider()
                Button("Record Alignment Calibration (20 s)…") {
                    Task { await Calibration.run(model: model, quitWhenDone: false) }
                }
                .disabled(model.isBusy)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--snapshot-recorder <png>`: draws the recorder window with sample sources and saves an image of it.
    static let isSnapshot = ProcessInfo.processInfo.arguments.contains("--snapshot-recorder")

    func applicationDidFinishLaunching(_ notification: Notification) {
        FrontmostAppTracker.shared.start()
        AppModel.shared.registerHotKey()

        let args = ProcessInfo.processInfo.arguments
        if args.contains("--calibrate") {
            // Started from the command line for the alignment proof: screc-check reads the printed bundle path.
            Task {
                try? await Task.sleep(for: .seconds(1))
                await Calibration.run(model: AppModel.shared, quitWhenDone: args.contains("--quit"))
            }
            return
        }
        if let i = args.firstIndex(of: "--test-record"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            // Automated test take: main display, no audio, no countdown; stops after `seconds` and quits.
            Task { await Self.runTestRecording(seconds: seconds) }
            return
        }
        if let i = args.firstIndex(of: "--snapshot-editor"), i + 2 < args.count {
            // Lays out the editor for a bundle off-screen and saves an image of it (UI check without the screen).
            let bundle = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            let panel = args.firstIndex(of: "--panel").flatMap { args.indices.contains($0 + 1) ? EditorModel.Panel(rawValue: args[$0 + 1]) : nil }
            Task { await Self.snapshotEditor(bundle: bundle, out: out, panel: panel) }
            return
        }
        if let i = args.firstIndex(of: "--snapshot-recorder"), i + 1 < args.count {
            // Saves an image of the recorder window (UI check without the screen).
            Task { await Self.snapshotRecorder(out: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        if args.contains("--recover-all") {
            // Automated recovery without the dialog; prints one line per bundle and quits.
            Task {
                for b in BundleLayout.interruptedBundles(in: AppModel.recordingsDirectory) {
                    do {
                        let r = try await Recovery.recover(bundle: b)
                        print("SCREC_RECOVERED=\(b.path) duration=\(r.duration) rewritten=\(r.rewrittenFiles) droppedEvents=\(r.droppedEvents)")
                    } catch {
                        print("SCREC_RECOVERY_FAILED=\(b.path) \(error)")
                    }
                }
                fflush(stdout)
                NSApp.terminate(nil)
            }
            return
        }
        Permission.requestRequired()
        offerRecovery(force: false)
    }

    private static func snapshotEditor(bundle: URL, out: URL, panel: EditorModel.Panel?) async {
        do {
            let model = try EditorModel(bundle: bundle)
            if let panel { model.panel = panel }
            if let first = model.project.timeline.slices.dropFirst().first { model.selection = .slice(first.id) }
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: EditorView(model: model).frame(width: 1440, height: 900))
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(3))
            await model.seek(to: 9)
            try? await Task.sleep(for: .seconds(1))
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: out)
            print("SCREC_SNAPSHOT=\(out.path)")
        } catch {
            print("SCREC_SNAPSHOT_FAILED=\(error)")
        }
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private static func snapshotRecorder(out: URL) async {
        let model = AppModel.shared
        model.catalog = SourceCatalog(displays: [.init(id: CGMainDisplayID(), name: "Studio Display", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))],
                                      windows: [.init(id: 1, appName: "Safari", title: "Screc – Product Tour", pid: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))])
        model.displayID = CGMainDisplayID()
        model.windowID = 1
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            print("SCREC_SNAPSHOT_FAILED=no recorder window")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
        print("SCREC_SNAPSHOT=\(out.path)")
        // The options popover, drawn on its own next to it.
        let options = NSHostingView(rootView: RecorderOptionsView(model: model))
        options.frame.size = options.fittingSize
        let panel = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: options.frame.width, height: options.frame.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = options
        panel.backgroundColor = .windowBackgroundColor
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        if let frame = options.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            let url = out.deletingPathExtension().appendingPathExtension("options.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("SCREC_SNAPSHOT=\(url.path)")
        }
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private static func runTestRecording(seconds: Double) async {
        let model = AppModel.shared
        model.sourceKind = .display
        model.displayID = CGMainDisplayID()
        model.recordMicrophone = false
        model.recordSystemAudio = false
        model.recordCamera = false
        await model.startRecording(countdownOverride: 0)
        guard model.session.state == .recording else {
            print("SCREC_TEST_FAILED=\(model.lastError ?? "did not start")")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        print("SCREC_TEST_RECORDING=\(model.session.bundleURL?.path ?? "?")")
        fflush(stdout)
        try? await Task.sleep(for: .seconds(seconds))
        await model.stopRecording()
        print("SCREC_TEST_BUNDLE=\(model.lastRecording?.path ?? "?")")
        fflush(stdout)
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.isRecording
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.isRecording else { return .terminateNow }
        // Finish the take cleanly before quitting.
        Task {
            await AppModel.shared.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// REC-06: interrupted takes (bundles that still have a lock file) are offered for recovery at launch.
    func offerRecovery(force: Bool) {
        let bundles = BundleLayout.interruptedBundles(in: AppModel.recordingsDirectory)
        guard !bundles.isEmpty else {
            if force {
                let a = NSAlert()
                a.messageText = "No interrupted recordings found."
                a.runModal()
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = bundles.count == 1 ? "Screc found an interrupted recording." : "Screc found \(bundles.count) interrupted recordings."
        alert.informativeText = "They were not finished properly, probably because Screc or the Mac stopped during recording. "
            + "Screc can rebuild them up to the last saved moment (at most about 2 seconds are lost).\n\n"
            + bundles.map { "• " + $0.deletingPathExtension().lastPathComponent }.joined(separator: "\n")
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Move to Trash…")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await recover(bundles) }
        case .alertThirdButtonReturn:
            let confirm = NSAlert()
            confirm.messageText = "Move \(bundles.count == 1 ? "this recording" : "these recordings") to the Trash?"
            confirm.addButton(withTitle: "Move to Trash")
            confirm.addButton(withTitle: "Cancel")
            if confirm.runModal() == .alertFirstButtonReturn {
                for b in bundles { try? FileManager.default.trashItem(at: b, resultingItemURL: nil) }
            }
        default:
            break
        }
    }

    private func recover(_ bundles: [URL]) async {
        var lines: [String] = []
        for b in bundles {
            do {
                let r = try await Recovery.recover(bundle: b)
                lines.append("✓ \(b.deletingPathExtension().lastPathComponent): \(String(format: "%.1f", r.duration)) s recovered")
                AppModel.shared.lastRecording = b
            } catch {
                lines.append("✗ \(b.deletingPathExtension().lastPathComponent): \(error)")
            }
        }
        let a = NSAlert()
        a.messageText = "Recovery finished"
        a.informativeText = lines.joined(separator: "\n")
        a.runModal()
    }
}
