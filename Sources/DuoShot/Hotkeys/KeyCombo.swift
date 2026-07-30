import AppKit
import Carbon.HIToolbox

/// A recorded shortcut.
///
/// `NSEvent.keyCode` and Carbon's `kVK_*` constants are the **same** virtual
/// keycode numbering, so there is no translation on that axis — only modifiers
/// need mapping.
nonisolated struct KeyCombo: Codable, Hashable, Sendable {
    let keyCode: UInt16
    /// `NSEvent.ModifierFlags.rawValue`, already masked.
    let modifiers: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        // Masking is mandatory. Without it the left/right-modifier and numeric
        // keypad bits get persisted too, and the combo no longer compares equal
        // when it is replayed from disk.
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// True for combos macOS will not let a normal app own, or that would trap
    /// the user (a bare letter, ⌘Q, ⎋ …).
    var isAcceptable: Bool {
        let modifierCount = [flags.contains(.command), flags.contains(.control),
                             flags.contains(.option)].filter { $0 }.count
        let isFunctionKey = (UInt16(kVK_F1)...UInt16(kVK_F20)).contains(keyCode)
            || keyCode == UInt16(kVK_F20)
        guard modifierCount > 0 || isFunctionKey else { return false }
        if keyCode == UInt16(kVK_Escape) || keyCode == UInt16(kVK_Tab) { return false }
        if flags.contains(.command), keyCode == UInt16(kVK_ANSI_Q) { return false }
        return true
    }

    // MARK: - Display

    var displayString: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// The character actually printed on the user's key.
    ///
    /// Resolved through the current keyboard layout rather than a hardcoded US
    /// table, so a Dvorak or AZERTY user sees their own legend.
    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }

        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                base, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "␣",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Help: "?",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}
