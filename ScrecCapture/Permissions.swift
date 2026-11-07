import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import CoreGraphics
import IOKit.hid

/// The permissions Screc asks for (REC-16).
public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording, inputMonitoring, accessibility, microphone, camera

    public var id: String { rawValue }

    public enum Status: Equatable, Sendable {
        case granted, denied, notDetermined
    }

    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        case .camera: "Camera"
        }
    }

    /// Plain-language reason shown on the onboarding screen.
    public var explanation: String {
        switch self {
        case .screenRecording:
            "Needed to record your screen. Screc records without the mouse pointer and draws it again later."
        case .inputMonitoring:
            "Needed to log clicks, scrolls and key presses during a recording. Screc uses them for auto-zoom and cursor effects. Nothing leaves your Mac."
        case .accessibility:
            "Only needed for “Resize window before recording”. You can skip it."
        case .microphone:
            "Needed only if you record your voice."
        case .camera:
            "Needed only if you record your webcam."
        }
    }

    /// Required for every recording; the others are optional.
    public var isRequired: Bool { self == .screenRecording || self == .inputMonitoring }

    public var status: Status {
        switch self {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notDetermined
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .microphone:
            return Self.avStatus(.audio)
        case .camera:
            return Self.avStatus(.video)
        }
    }

    private static func avStatus(_ type: AVMediaType) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    /// Shows the system prompt where macOS has one. Returns immediately; poll `status` afterwards.
    @MainActor
    public func request() {
        switch self {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        }
    }

    /// The matching pane in System Settings › Privacy & Security.
    public var settingsURL: URL {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .accessibility: "Privacy_Accessibility"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    @MainActor
    public func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
