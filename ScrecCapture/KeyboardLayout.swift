import Carbon.HIToolbox
import Foundation

/// The active keyboard layout, captured when recording starts, so key codes can be named the way the user's
/// keyboard labels them (German QWERTZ: the key right of T is Z, not Y as on a US keyboard).
/// The layout data is read on the main thread (Text Input Sources requires that) and only read afterwards.
public final class KeyboardLayout: @unchecked Sendable {
    private let source: TISInputSource?
    private let data: CFData?
    private let keyboardType: UInt32

    @MainActor
    public init() {
        let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        source = src
        if let src, let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) {
            data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        } else {
            data = nil
        }
        keyboardType = UInt32(LMGetKbdType())
    }

    /// The key's character without any modifiers, or nil (special keys, unknown layout).
    public func plainCharacter(keyCode: Int) -> String? {
        guard let data, let bytes = CFDataGetBytePtr(data) else { return nil }
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, keyboardType,
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        guard let scalar = s.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar), !s.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return s
    }
}
