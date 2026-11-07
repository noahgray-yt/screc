import AppKit
import CoreGraphics
import ScrecCore
import os

/// The current global-points → recording-pixels mapping. Window capture updates it when the window moves.
public final class MapperBox: Sendable {
    private let state: OSAllocatedUnfairLock<CoordinateMapper>
    public init(_ mapper: CoordinateMapper) { state = OSAllocatedUnfairLock(initialState: mapper) }
    public var mapper: CoordinateMapper { state.withLock { $0 } }
    public func update(_ body: @Sendable (inout CoordinateMapper) -> Void) { state.withLock { body(&$0) } }
}

/// Listen-only `CGEventTap` for clicks, scrolls and keys (ARCHITECTURE §6.3).
/// Needs **Input Monitoring** permission. Runs on its own thread with its own run loop, so a busy main
/// thread never delays or drops events.
///
/// Mouse *positions* are not taken from here; the display-rate `PositionSampler` writes them.
public final class EventTapRecorder: @unchecked Sendable {
    public enum TapError: Error, CustomStringConvertible {
        case cannotCreateTap
        public var description: String {
            "Could not start the input event tap. Is Input Monitoring allowed for Screc in System Settings?"
        }
    }

    /// How `CGEventGetTimestamp` is converted to host seconds. Detected from the first event
    /// (ARCHITECTURE §13.4: nanoseconds or mach ticks, depending on the machine).
    public enum TimestampUnit: String, Sendable { case nanoseconds, machTicks }

    private let clock: RecordingClock
    private let writer: TelemetryWriter
    private let mapper: MapperBox
    private let layout: KeyboardLayout?

    // Only touched on the tap thread.
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let unitState = OSAllocatedUnfairLock<TimestampUnit?>(initialState: nil)

    public init(clock: RecordingClock, writer: TelemetryWriter, mapper: MapperBox, layout: KeyboardLayout? = nil) {
        self.clock = clock
        self.writer = writer
        self.mapper = mapper
        self.layout = layout
    }

    public var detectedTimestampUnit: TimestampUnit? { unitState.withLock { $0 } }

    public func start() throws {
        // Decide the timestamp unit now from a fresh event, so it is known before the first real one arrives.
        if let probe = CGEvent(source: nil) { _ = hostSeconds(of: probe) }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                                    .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: eventTapCallback, userInfo: refcon) else {
            throw TapError.cannotCreateTap
        }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        // CFMachPort is thread-safe for these calls; it is only handed over to the tap thread here.
        nonisolated(unsafe) let tapPort = tap
        let thread = Thread { [weak self] in
            guard let self, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0) else {
                ready.signal()
                return
            }
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tapPort, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "screc.event-tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    // MARK: Event handling (tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let t = clock.sourceTime(host: hostSeconds(of: event)) else { return }
        let m = mapper.mapper
        let p = m.recordingPixels(fromCG: event.location)
        let x = Double(p.x), y = Double(p.y)

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
            writer.append(.down(t: t, button: Self.button(type), x: x, y: y, clickCount: max(clicks, 1)))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            writer.append(.up(t: t, button: Self.button(type), x: x, y: y))
        case .scrollWheel:
            // Point deltas, converted to recording pixels like positions.
            let scale = m.captureRect.width > 0 ? Double(m.videoPixelSize.width / m.captureRect.width) : 1
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) * scale
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) * scale
            guard dx != 0 || dy != 0 else { return }
            writer.append(.scroll(t: t, dx: dx, dy: dy, x: x, y: y))
        case .keyDown, .keyUp:
            // Auto-repeat while a key is held is not a new key press.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            writer.append(.key(t: t, phase: type == .keyDown ? .down : .up, keyCode: keyCode,
                               chars: Self.characters(of: event), mods: Self.modifiers(event.flags),
                               key: layout?.plainCharacter(keyCode: keyCode)))
        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let flag = Self.modifierFlag(forKeyCode: keyCode) else { return }
            let isDown = event.flags.contains(flag)
            writer.append(.key(t: t, phase: isDown ? .down : .up, keyCode: keyCode, chars: "",
                               mods: Self.modifiers(event.flags)))
        default:
            break
        }
    }

    /// Converts the event timestamp to host seconds. The unit is decided once, from the first event:
    /// whichever interpretation lands closest to "now" is right.
    private func hostSeconds(of event: CGEvent) -> Double {
        let raw = event.timestamp
        let unit = unitState.withLock { state -> TimestampUnit in
            if let state { return state }
            let now = HostTime.now
            let asNanos = Double(raw) / 1e9
            let asTicks = HostTime.seconds(fromMachTicks: raw)
            let chosen: TimestampUnit = abs(asNanos - now) <= abs(asTicks - now) ? .nanoseconds : .machTicks
            state = chosen
            return chosen
        }
        switch unit {
        case .nanoseconds: return Double(raw) / 1e9
        case .machTicks: return HostTime.seconds(fromMachTicks: raw)
        }
    }

    static func button(_ type: CGEventType) -> MouseButton {
        switch type {
        case .leftMouseDown, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseUp: .right
        default: .other
        }
    }

    static func modifiers(_ flags: CGEventFlags) -> [String] {
        var mods: [String] = []
        if flags.contains(.maskControl) { mods.append("ctrl") }
        if flags.contains(.maskAlternate) { mods.append("opt") }
        if flags.contains(.maskShift) { mods.append("shift") }
        if flags.contains(.maskCommand) { mods.append("cmd") }
        if flags.contains(.maskSecondaryFn) { mods.append("fn") }
        if flags.contains(.maskAlphaShift) { mods.append("capsLock") }
        return mods
    }

    static func modifierFlag(forKeyCode code: Int) -> CGEventFlags? {
        switch code {
        case 54, 55: .maskCommand        // right / left command
        case 56, 60: .maskShift
        case 58, 61: .maskAlternate
        case 59, 62: .maskControl
        case 57: .maskAlphaShift         // caps lock
        case 63: .maskSecondaryFn
        default: nil
        }
    }

    static func characters(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }
}

/// C callback for the tap. `refcon` is an unretained `EventTapRecorder`; the recorder outlives the tap.
private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<EventTapRecorder>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
