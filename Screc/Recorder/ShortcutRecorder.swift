import AppKit
import SwiftUI

/// A field that records a key combination (REC-04).
///
/// While it is active it is the window's first responder, so it receives every key press directly,
/// including ⌘ combinations, which AppKit otherwise turns into menu commands before an event monitor
/// sees them. Esc cancels. Plain keys without ⌘, ⌥ or ⌃ are refused with a hint.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (GlobalHotKey.Combo) -> Void
    var onRejected: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        context.coordinator.parent = self
        if isRecording, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if !isRecording, view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator {
        var parent: ShortcutRecorder
        init(parent: ShortcutRecorder) { self.parent = parent }

        /// Returns true if the event was consumed.
        func handle(_ event: NSEvent) -> Bool {
            guard parent.isRecording else { return false }
            if event.keyCode == 53 {                 // Esc
                parent.isRecording = false
                return true
            }
            if let combo = GlobalHotKey.Combo(event: event) {
                parent.onCapture(combo)
                parent.isRecording = false
            } else {
                parent.onRejected()
            }
            return true
        }
    }

    final class KeyCaptureView: NSView {
        weak var coordinator: Coordinator?

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 1) }

        override func keyDown(with event: NSEvent) {
            if coordinator?.handle(event) != true { super.keyDown(with: event) }
        }

        // ⌘ combinations arrive here first (as key equivalents), not in keyDown.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else { return false }
            return coordinator?.handle(event) ?? false
        }
    }
}
