import AppKit
import ScrecCapture
import SwiftUI

/// Floating panels used while recording. All of them belong to Screc, and the capture filter excludes
/// every Screc window, so none of them appear in the recording (REC-09, REC-10).
@MainActor
final class PanelController {
    static let shared = PanelController()

    private var controlBar: NSPanel?
    private var countdown: NSPanel?
    private var notes: NSPanel?

    // MARK: Control bar (REC-10)

    func showControlBar(model: AppModel) {
        guard controlBar == nil else { return }
        let panel = makePanel(size: CGSize(width: 330, height: 46), style: [.nonactivatingPanel, .borderless])
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: ControlBarView(model: model))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: f.midX - 165, y: f.minY + 40))
        }
        panel.orderFrontRegardless()
        controlBar = panel
    }

    func hideControlBar() {
        controlBar?.orderOut(nil)
        controlBar = nil
    }

    // MARK: Countdown (REC-03)

    func runCountdown(seconds: Int) async {
        guard seconds > 0 else { return }
        let panel = makePanel(size: CGSize(width: 160, height: 160), style: [.nonactivatingPanel, .borderless])
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        let state = CountdownState(value: seconds)
        panel.contentView = NSHostingView(rootView: CountdownView(state: state))
        if let screen = NSScreen.main { panel.setFrameOrigin(CGPoint(x: screen.frame.midX - 80, y: screen.frame.midY - 80)) }
        panel.orderFrontRegardless()
        countdown = panel
        for n in stride(from: seconds, through: 1, by: -1) {
            state.value = n
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
        countdown = nil
    }

    // MARK: Speaker notes (REC-09)

    func setNotesVisible(_ visible: Bool) {
        if visible {
            if notes == nil {
                let panel = makePanel(size: CGSize(width: 340, height: 260), style: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel])
                panel.title = "Speaker Notes"
                panel.contentView = NSHostingView(rootView: SpeakerNotesView())
                panel.center()
                notes = panel
            }
            notes?.orderFrontRegardless()
        } else {
            notes?.orderOut(nil)
        }
    }

    private func makePanel(size: CGSize, style: NSWindow.StyleMask) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Belt and braces: also ask macOS not to share these windows.
        panel.sharingType = .none
        return panel
    }
}

@MainActor @Observable
final class CountdownState {
    var value: Int
    init(value: Int) { self.value = value }
}

private struct CountdownView: View {
    let state: CountdownState
    var body: some View {
        Text("\(state.value)")
            .font(.system(size: 84, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 150, height: 150)
            .background(.black.opacity(0.65), in: Circle())
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: state.value)
    }
}

private struct ControlBarView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.session.state == .paused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(Self.format(model.session.elapsed))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .frame(width: 62, alignment: .leading)
            }
            Divider().frame(height: 22)
            if model.session.state == .paused {
                iconButton("play.fill", help: "Resume") { model.session.resume() }
            } else {
                iconButton("pause.fill", help: "Pause") { model.session.pause() }
            }
            iconButton("stop.fill", help: "Stop and save (\(model.hotKey.display))") { Task { await model.stopRecording() } }
            iconButton("arrow.counterclockwise", help: "Restart: discard this take and start again") { Task { await model.restartRecording() } }
            iconButton("trash", help: "Discard this take") { Task { await model.discardRecording() } }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    static func format(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%d:%02d.%d", total / 60, total % 60, Int((s - Double(total)) * 10))
    }
}

private struct SpeakerNotesView: View {
    @AppStorage("speakerNotes") private var text = ""
    @AppStorage("speakerNotesFontSize") private var fontSize = 16.0

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: fontSize))
                .scrollContentBackground(.hidden)
                .padding(8)
            HStack {
                Text("Not visible in the recording").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { fontSize = max(11, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                Button { fontSize = min(40, fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}
