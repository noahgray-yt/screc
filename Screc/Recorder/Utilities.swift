import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScrecCapture

// MARK: - Global shortcut (REC-04)

/// One global start/stop shortcut via Carbon `RegisterEventHotKey`. Needs no permission
/// and works while another app is in front (ARCHITECTURE §6.5).
@MainActor
final class GlobalHotKey {
    struct Combo: Codable, Equatable {
        var keyCode: UInt32
        var carbonModifiers: UInt32
        var keyLabel: String

        static let `default` = Combo(keyCode: UInt32(kVK_ANSI_R),
                                     carbonModifiers: UInt32(cmdKey | optionKey | shiftKey), keyLabel: "R")

        var display: String {
            var s = ""
            if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            return s + keyLabel
        }

        /// From a key-down event; nil unless at least one of ⌘ ⌥ ⌃ is held.
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: UInt32 = 0
            if flags.contains(.command) { mods |= UInt32(cmdKey) }
            if flags.contains(.option) { mods |= UInt32(optionKey) }
            if flags.contains(.control) { mods |= UInt32(controlKey) }
            let functionKey = Self.functionKeyLabels[Int(event.keyCode)]
            // Letters, digits etc. need ⌘, ⌥ or ⌃, otherwise typing that key anywhere would start a recording.
            // Function keys F1–F20 may be used alone.
            guard mods != 0 || functionKey != nil else { return nil }
            if flags.contains(.shift) { mods |= UInt32(shiftKey) }
            keyCode = UInt32(event.keyCode)
            carbonModifiers = mods
            keyLabel = functionKey ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        }

        static let functionKeyLabels: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
            kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
            kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]

        init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
            self.keyLabel = keyLabel
        }
    }

    static let shared = GlobalHotKey()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate var action: (() -> Void)?

    /// Registers `combo`, replacing any earlier one. Returns false if macOS refused (combo already taken).
    @discardableResult
    func register(_ combo: Combo, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x474C_4944), id: 1)   // 'GLID'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    // Carbon calls this on the main thread.
    MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
    return noErr
}

// MARK: - Source app tracking (REC-11)

/// Remembers the last app in front that is not Screc. For display and area capture that app names the project.
@MainActor
final class FrontmostAppTracker {
    static let shared = FrontmostAppTracker()
    private(set) var lastOtherApp: String?
    private var observer: NSObjectProtocol?

    func start() {
        if let app = NSWorkspace.shared.frontmostApplication, app != .current, app.activationPolicy == .regular {
            lastOtherApp = app.localizedName
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.localizedName
            let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            // Only normal apps with a Dock icon name a project. System popups (permission prompts,
            // notifications) also become "frontmost" for a moment and must not.
            let isRegular = app?.activationPolicy == .regular
            MainActor.assumeIsolated {
                if !isSelf, isRegular, let name { FrontmostAppTracker.shared.lastOtherApp = name }
            }
        }
    }
}

// MARK: - Resize window (REC-07)

/// Resizes another app's window with the Accessibility API. Asks for Accessibility only when used.
enum WindowResizer {
    enum ResizeError: LocalizedError {
        case noPermission, windowNotFound, failed(AXError)
        var errorDescription: String? {
            switch self {
            case .noPermission: "Screc needs Accessibility permission to resize windows. Allow it in System Settings and try again."
            case .windowNotFound: "The window could not be found through Accessibility."
            case let .failed(e): "macOS refused to resize the window (AXError \(e.rawValue)). Some apps limit their window size."
            }
        }
    }

    /// - Parameters: `frame`: the window's current frame in global CG points (to find it among the app's windows).
    ///               `size`: the new size in points.
    @MainActor
    static func resize(pid: pid_t, frame: CGRect, title: String?, to size: CGSize) throws {
        guard AXIsProcessTrusted() else {
            Permission.accessibility.request()
            throw ResizeError.noPermission
        }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { throw ResizeError.windowNotFound }

        func frameOf(_ w: AXUIElement) -> CGRect? {
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
            return CGRect(origin: p, size: s)
        }
        func titleOf(_ w: AXUIElement) -> String? {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return t as? String
        }

        let target = windows.first { w in
            guard let f = frameOf(w) else { return false }
            return abs(f.minX - frame.minX) < 2 && abs(f.minY - frame.minY) < 2
                && abs(f.width - frame.width) < 2 && abs(f.height - frame.height) < 2
        } ?? windows.first { title != nil && titleOf($0) == title }
        guard let target else { throw ResizeError.windowNotFound }

        var newSize = size
        guard let axSize = AXValueCreate(.cgSize, &newSize) else { throw ResizeError.windowNotFound }
        let result = AXUIElementSetAttributeValue(target, kAXSizeAttribute as CFString, axSize)
        guard result == .success else { throw ResizeError.failed(result) }
    }
}

// MARK: - Hide desktop icons (REC-08)

/// Covers the desktop icons with a window that shows the desktop picture (ARCHITECTURE §6.5).
/// Finder settings are never touched, so nothing needs undoing after a crash.
/// The cover windows are *included* in the recording; that is the point.
@MainActor
final class DesktopIconCover {
    private var windows: [NSWindow] = []

    var windowNumbers: [Int] { windows.map(\.windowNumber) }

    func show() {
        hide()
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = level
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.hasShadow = false
            let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.imageScaling = .scaleAxesIndependently
            view.autoresizingMask = [.width, .height]
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
                view.image = Self.aspectFill(image, to: screen.frame.size)
            } else {
                w.backgroundColor = .windowBackgroundColor
            }
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.orderFront(nil)
            windows.append(w)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// Crops the picture to the screen's aspect ratio, like the desktop's "Fill Screen".
    private static func aspectFill(_ image: NSImage, to size: CGSize) -> NSImage {
        let src = image.size
        guard src.width > 0, src.height > 0 else { return image }
        let scale = max(size.width / src.width, size.height / src.height)
        let crop = CGSize(width: size.width / scale, height: size.height / scale)
        let from = NSRect(x: (src.width - crop.width) / 2, y: (src.height - crop.height) / 2, width: crop.width, height: crop.height)
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: from, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}
