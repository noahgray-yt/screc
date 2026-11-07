import AppKit
import ScrecCapture
import SwiftUI

/// Permission onboarding (REC-16): one row per permission with a plain explanation, the live status,
/// and a button that asks macOS or opens the right System Settings pane.
struct OnboardingView: View {
    var body: some View {
        // Re-check every second: macOS does not notify apps when a permission changes.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 16) {
                Text("Permissions").font(.title2.bold())
                Text("Screc records locally on this Mac. The first two are needed for every recording; the rest only for the features named.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Permission.allCases) { PermissionRow(permission: $0) }
                Divider()
                Text("After allowing Screen Recording, macOS may ask you to quit and reopen Screc.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Quit & Reopen Screc") { Self.relaunch() }
                    Button("Done") { OnboardingWindow.close() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!Permission.allRequiredGranted)
                }
            }
            .padding(24)
            .frame(width: 560)
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

private struct PermissionRow: View {
    let permission: Permission

    var body: some View {
        let status = permission.status
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : (permission.isRequired ? "exclamationmark.circle.fill" : "circle"))
                .foregroundStyle(status == .granted ? .green : (permission.isRequired ? .orange : .secondary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(permission.title).font(.headline)
                    Text(permission.isRequired ? "required" : "optional")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(permission.explanation)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status == .granted {
                Text("Allowed").foregroundStyle(.green)
            } else {
                VStack(alignment: .trailing) {
                    if status == .notDetermined {
                        Button("Allow…") { permission.request() }
                    }
                    Button("Open System Settings") { permission.openSettings() }
                        .buttonStyle(.link)
                }
            }
        }
    }
}

@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Screc Permissions"
            w.contentView = NSHostingView(rootView: OnboardingView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func close() {
        window?.close()
    }
}
