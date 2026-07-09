import AppKit
import PuttyBridge

/// Translates NSEvent keyboard input into PuTTY terminal key sequences (Phase 4.5).
@MainActor
enum OsxKeys {
    private static let scrollLinesPerTick = 3

    static func handleKeyDown(_ event: NSEvent, termWin: OpaquePointer) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            return false
        }

        let shift = flags.contains(.shift)
        let ctrl = flags.contains(.control)
        let alt = flags.contains(.option)

        if let special = translateSpecialKey(event, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt) {
            sendSpecial(special, termWin: termWin, prefixEsc: alt && !special.consumedAlt)
            return true
        }

        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            var bytes = [UInt8]()
            for scalar in chars.unicodeScalars {
                var byte = UInt8(truncatingIfNeeded: scalar.value)
                if ctrl {
                    byte = putty_bridge_termwin_apply_ctrl(byte)
                }
                bytes.append(byte)
            }
            if !bytes.isEmpty {
                if alt {
                    putty_bridge_termwin_key_bytes(termWin, -1, [0x1B], 1)
                }
                bytes.withUnsafeBytes { raw in
                    putty_bridge_termwin_key_bytes(
                        termWin, -1, raw.baseAddress, Int32(bytes.count)
                    )
                }
                return true
            }
        }

        return false
    }

    static func insertText(_ string: String, termWin: OpaquePointer) {
        var codepoints = [UInt32]()
        codepoints.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            codepoints.append(UInt32(scalar.value))
        }
        guard !codepoints.isEmpty else { return }
        codepoints.withUnsafeBufferPointer { buf in
            putty_bridge_termwin_key_wide(
                termWin,
                buf.baseAddress?.withMemoryRebound(to: wchar_t.self, capacity: buf.count) { $0 },
                Int32(buf.count)
            )
        }
    }

    // MARK: - Private

    private struct SpecialKeyResult {
        var buffer: [UInt8]
        var special: Bool
        var consumedAlt: Bool
    }

    private static func translateSpecialKey(
        _ event: NSEvent,
        termWin: OpaquePointer,
        shift: Bool,
        ctrl: Bool,
        alt: Bool
    ) -> SpecialKeyResult? {
        switch Int(event.keyCode) {
        case 0x7E: // Up
            return formatArrow("A", termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x7D: // Down
            return formatArrow("B", termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x7C: // Right
            return formatArrow("C", termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x7B: // Left
            return formatArrow("D", termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x72: // Insert
            return formatSmallKeypad(PUTTY_BRIDGE_SKK_INSERT, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x24: // Return
            return formatReturn(termWin: termWin)
        case 0x4C, 0x47: // Enter / keypad enter
            return formatReturn(termWin: termWin)
        case 0x30: // Tab
            if shift {
                return SpecialKeyResult(buffer: [0x1B, 0x5B, 0x5A], special: true, consumedAlt: false)
            }
            return SpecialKeyResult(buffer: [0x09], special: false, consumedAlt: false)
        case 0x33: // Delete (forward)
            return formatSmallKeypad(PUTTY_BRIDGE_SKK_DELETE, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x75: // Forward delete key on mac extended -> treat as Delete
            return formatSmallKeypad(PUTTY_BRIDGE_SKK_DELETE, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x35: // Escape
            return SpecialKeyResult(buffer: [0x1B], special: false, consumedAlt: false)
        case 0x73: // Home
            return formatSmallKeypad(PUTTY_BRIDGE_SKK_HOME, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x77: // End
            return formatSmallKeypad(PUTTY_BRIDGE_SKK_END, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x74: // Page up
            return formatSmallKeypad(PUTTY_BRIDGE_SKK_PGUP, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x79: // Page down
            return formatSmallKeypad(PUTTY_BRIDGE_SKK_PGDN, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x7A: // F1
            return formatFunction(1, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x78: // F2
            return formatFunction(2, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x63: // F3
            return formatFunction(3, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x76: // F4
            return formatFunction(4, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x60: // F5
            return formatFunction(5, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x61: // F6
            return formatFunction(6, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x62: // F7
            return formatFunction(7, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x64: // F8
            return formatFunction(8, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x65: // F9
            return formatFunction(9, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x6D: // F10
            return formatFunction(10, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x67: // F11
            return formatFunction(11, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x6F: // F12
            return formatFunction(12, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x69: // F13 -> F13
            return formatFunction(13, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x6B: // F14
            return formatFunction(14, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x71: // F15
            return formatFunction(15, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x6A: // F16
            return formatFunction(16, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x40: // F17
            return formatFunction(17, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x4F: // F18
            return formatFunction(18, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x50: // F19
            return formatFunction(19, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        case 0x5A: // F20
            return formatFunction(20, termWin: termWin, shift: shift, ctrl: ctrl, alt: alt)
        default:
            return nil
        }
    }

    private static func formatSmallKeypad(
        _ key: Int32,
        termWin: OpaquePointer,
        shift: Bool,
        ctrl: Bool,
        alt: Bool
    ) -> SpecialKeyResult? {
        if ctrl { return nil }
        var buf = [CChar](repeating: 0, count: 32)
        var consumedAlt: Bool = false
        let len = putty_bridge_termwin_format_small_keypad(
            termWin, key, shift, ctrl, alt, &buf, Int32(buf.count), &consumedAlt
        )
        guard len > 0 else { return nil }
        let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
        return SpecialKeyResult(buffer: Array(bytes), special: true, consumedAlt: consumedAlt)
    }

    private static func formatArrow(
        _ xkey: String,
        termWin: OpaquePointer,
        shift: Bool,
        ctrl: Bool,
        alt: Bool
    ) -> SpecialKeyResult? {
        var buf = [CChar](repeating: 0, count: 32)
        var consumedAlt: Bool = false
        let xkeyCode = Int32(xkey.utf8.first ?? 0)
        let len = putty_bridge_termwin_format_arrow(
            termWin, xkeyCode, shift, ctrl, alt, &buf, Int32(buf.count), &consumedAlt
        )
        guard len > 0 else { return nil }
        let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
        return SpecialKeyResult(buffer: Array(bytes), special: true, consumedAlt: consumedAlt)
    }

    private static func formatFunction(
        _ number: Int32,
        termWin: OpaquePointer,
        shift: Bool,
        ctrl: Bool,
        alt: Bool
    ) -> SpecialKeyResult? {
        var buf = [CChar](repeating: 0, count: 32)
        var consumedAlt: Bool = false
        let len = putty_bridge_termwin_format_function(
            termWin, number, shift, ctrl, alt, &buf, Int32(buf.count), &consumedAlt
        )
        guard len > 0 else { return nil }
        let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
        return SpecialKeyResult(buffer: Array(bytes), special: true, consumedAlt: consumedAlt)
    }

    private static func formatReturn(termWin: OpaquePointer) -> SpecialKeyResult? {
        var buf = [CChar](repeating: 0, count: 8)
        var special = false
        let len = putty_bridge_termwin_format_return(
            termWin, &buf, Int32(buf.count), &special
        )
        guard len > 0 else { return nil }
        let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
        return SpecialKeyResult(buffer: Array(bytes), special: special, consumedAlt: false)
    }

    private static func sendSpecial(
        _ result: SpecialKeyResult,
        termWin: OpaquePointer,
        prefixEsc: Bool
    ) {
        if prefixEsc && !result.consumedAlt {
            putty_bridge_termwin_key_bytes(termWin, -1, [0x1B], 1)
        }
        result.buffer.withUnsafeBytes { raw in
            if result.special {
                let cstr = raw.bindMemory(to: CChar.self)
                putty_bridge_termwin_key_special(termWin, cstr.baseAddress)
            } else {
                putty_bridge_termwin_key_bytes(
                    termWin, -1, raw.baseAddress, Int32(result.buffer.count)
                )
            }
        }
    }
}
