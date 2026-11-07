import AppKit
import ScrecCapture
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Displays and windows the user can record (REC-01).
struct SourceCatalog {
    struct DisplayItem: Identifiable, Hashable {
        var id: CGDirectDisplayID
        var name: String
        var frame: CGRect          // global CG points
    }

    struct WindowItem: Identifiable, Hashable {
        var id: CGWindowID
        var appName: String
        var title: String
        var pid: pid_t
        var frame: CGRect          // global CG points
        var label: String { title.isEmpty ? appName : "\(appName) – \(title)" }
    }

    var displays: [DisplayItem] = []
    var windows: [WindowItem] = []

    static func load() async throws -> SourceCatalog {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let screens = await MainActor.run { NSScreen.screens.map { ($0.displayID, $0.localizedName) } }
        let names = Dictionary(screens, uniquingKeysWith: { a, _ in a })
        let displays = content.displays.map {
            DisplayItem(id: $0.displayID, name: names[$0.displayID] ?? "Display \($0.displayID)", frame: $0.frame)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 80 }
            .filter { $0.owningApplication?.processID != ownPID }
            .compactMap { w -> WindowItem? in
                guard let app = w.owningApplication else { return nil }
                return WindowItem(id: w.windowID, appName: app.applicationName, title: w.title ?? "",
                                  pid: app.processID, frame: w.frame)
            }
            .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
        return SourceCatalog(displays: displays, windows: windows)
    }
}

// MARK: - Area selection (REC-01 "custom area")

/// A full-screen overlay on one display where the user drags a rectangle.
/// Returns the rectangle in that display's points (top-left origin), or nil when cancelled.
@MainActor
final class AreaSelector {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<CGRect?, Never>?

    func select(on screen: NSScreen, initial: CGRect?) async -> CGRect? {
        await withCheckedContinuation { c in
            continuation = c
            let w = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: AreaSelectionView(initial: initial) { [weak self] rect in
                self?.finish(rect)
            })
            w.setFrame(screen.frame, display: true)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            window = w
        }
    }

    private func finish(_ rect: CGRect?) {
        window?.orderOut(nil)
        window = nil
        continuation?.resume(returning: rect)
        continuation = nil
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct AreaSelectionView: View {
    var initial: CGRect?
    var done: (CGRect?) -> Void
    @State private var start: CGPoint?
    @State private var rect: CGRect?

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                // Dim everything except the selection.
                Canvas { ctx, size in
                    var path = Path(CGRect(origin: .zero, size: size))
                    if let rect { path.addRect(rect) }
                    ctx.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
                    if let rect {
                        ctx.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
                    }
                }
                if let rect, rect.width > 0 {
                    Text("\(Int(rect.width)) × \(Int(rect.height)) pt")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .offset(x: rect.minX, y: max(rect.minY - 24, 0))
                }
                VStack(spacing: 8) {
                    Text("Drag to select the area to record")
                        .font(.headline)
                    HStack {
                        Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                        Button("Use This Area") { done(rect) }
                            .keyboardShortcut(.defaultAction)
                            .disabled((rect?.width ?? 0) < 16 || (rect?.height ?? 0) < 16)
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 60)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { g in
                    let s = start ?? g.startLocation
                    start = s
                    rect = CGRect(x: min(s.x, g.location.x), y: min(s.y, g.location.y),
                                  width: abs(g.location.x - s.x), height: abs(g.location.y - s.y)).integral
                }
                .onEnded { _ in start = nil })
        }
        .onAppear { rect = initial }
    }
}
