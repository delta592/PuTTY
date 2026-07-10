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

        /*
         * Control letters must never fall through to AppKit's interpretKeyEvents
         * path: Ctrl-D becomes deleteForward:, Ctrl-A moveToBeginningOfLine:, etc.,
         * and a plain NSView does nothing with those — so EOF / interrupt appear
         * broken. Prefer NSEvent.characters (often already a C0 byte), then the
         * unshifted letter, then a US-QWERTY keyCode map.
         */
        if ctrl {
            if let bytes = controlBytes(for: event), !bytes.isEmpty {
                sendRawBytes(bytes, termWin: termWin, prefixEsc: alt)
                return true
            }
            /* Still consume Control so AppKit cannot swallow the key. */
            return true
        }

        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            var bytes = [UInt8]()
            for scalar in chars.unicodeScalars {
                bytes.append(UInt8(truncatingIfNeeded: scalar.value))
            }
            if !bytes.isEmpty {
                sendRawBytes(bytes, termWin: termWin, prefixEsc: alt)
                return true
            }
        }

        return false
    }

    /// True when AppKit's text-system `doCommand(by:)` selector is a Control-key
    /// editing binding that a terminal must not treat as a no-op.
    static func isControlEditingCommand(_ selector: Selector) -> Bool {
        controlEditingSelectors.contains(selector)
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
        case 0x33: // Backspace (macOS "Delete" key left of Return)
            return formatBackspace(termWin: termWin, shift: shift)
        case 0x75: // Forward delete (mac extended keyboards)
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

    private static func formatBackspace(
        termWin: OpaquePointer, shift: Bool
    ) -> SpecialKeyResult? {
        var buf = [CChar](repeating: 0, count: 4)
        var special = false
        let len = putty_bridge_termwin_format_backspace(
            termWin, shift, &buf, Int32(buf.count), &special
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

    private static func sendRawBytes(
        _ bytes: [UInt8], termWin: OpaquePointer, prefixEsc: Bool
    ) {
        if prefixEsc {
            putty_bridge_termwin_key_bytes(termWin, -1, [0x1B], 1)
        }
        bytes.withUnsafeBytes { raw in
            putty_bridge_termwin_key_bytes(
                termWin, -1, raw.baseAddress, Int32(bytes.count)
            )
        }
    }

    private static func controlBytes(for event: NSEvent) -> [UInt8]? {
        if let chars = event.characters, !chars.isEmpty {
            var bytes = [UInt8]()
            for scalar in chars.unicodeScalars {
                let value = scalar.value
                if value < 0x20 || value == 0x7F {
                    bytes.append(UInt8(truncatingIfNeeded: value))
                } else {
                    bytes.append(putty_bridge_termwin_apply_ctrl(
                        UInt8(truncatingIfNeeded: value)))
                }
            }
            if !bytes.isEmpty { return bytes }
        }

        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            var bytes = [UInt8]()
            for scalar in chars.unicodeScalars {
                bytes.append(putty_bridge_termwin_apply_ctrl(
                    UInt8(truncatingIfNeeded: scalar.value)))
            }
            if !bytes.isEmpty { return bytes }
        }

        if let letter = usQwertyLetter(forKeyCode: Int(event.keyCode)) {
            return [putty_bridge_termwin_apply_ctrl(letter)]
        }
        return nil
    }

    /// US-QWERTY letter/digit/punctuation for Control when NSEvent character
    /// strings are empty (layout / IME edge cases).
    private static func usQwertyLetter(forKeyCode keyCode: Int) -> UInt8? {
        switch keyCode {
        case 0x00: return UInt8(ascii: "a")
        case 0x01: return UInt8(ascii: "s")
        case 0x02: return UInt8(ascii: "d")
        case 0x03: return UInt8(ascii: "f")
        case 0x04: return UInt8(ascii: "h")
        case 0x05: return UInt8(ascii: "g")
        case 0x06: return UInt8(ascii: "z")
        case 0x07: return UInt8(ascii: "x")
        case 0x08: return UInt8(ascii: "c")
        case 0x09: return UInt8(ascii: "v")
        case 0x0B: return UInt8(ascii: "b")
        case 0x0C: return UInt8(ascii: "q")
        case 0x0D: return UInt8(ascii: "w")
        case 0x0E: return UInt8(ascii: "e")
        case 0x0F: return UInt8(ascii: "r")
        case 0x10: return UInt8(ascii: "y")
        case 0x11: return UInt8(ascii: "t")
        case 0x12: return UInt8(ascii: "1")
        case 0x13: return UInt8(ascii: "2")
        case 0x14: return UInt8(ascii: "3")
        case 0x15: return UInt8(ascii: "4")
        case 0x16: return UInt8(ascii: "6")
        case 0x17: return UInt8(ascii: "5")
        case 0x1C: return UInt8(ascii: "8")
        case 0x1D: return UInt8(ascii: "0")
        case 0x1F: return UInt8(ascii: "o")
        case 0x20: return UInt8(ascii: "u")
        case 0x22: return UInt8(ascii: "i")
        case 0x23: return UInt8(ascii: "p")
        case 0x25: return UInt8(ascii: "l")
        case 0x26: return UInt8(ascii: "j")
        case 0x28: return UInt8(ascii: "k")
        case 0x2D: return UInt8(ascii: "n")
        case 0x2E: return UInt8(ascii: "m")
        case 0x31: return UInt8(ascii: " ") // Space → NUL via apply_ctrl
        case 0x32: return UInt8(ascii: "`")
        default: return nil
        }
    }

    private static let controlEditingSelectors: Set<Selector> = [
        #selector(NSResponder.deleteForward(_:)),
        #selector(NSResponder.deleteBackward(_:)),
        #selector(NSResponder.deleteWordForward(_:)),
        #selector(NSResponder.deleteWordBackward(_:)),
        #selector(NSResponder.deleteToBeginningOfLine(_:)),
        #selector(NSResponder.deleteToEndOfLine(_:)),
        #selector(NSResponder.moveToBeginningOfLine(_:)),
        #selector(NSResponder.moveToEndOfLine(_:)),
        #selector(NSResponder.moveToBeginningOfParagraph(_:)),
        #selector(NSResponder.moveToEndOfParagraph(_:)),
        #selector(NSResponder.moveToBeginningOfDocument(_:)),
        #selector(NSResponder.moveToEndOfDocument(_:)),
        #selector(NSResponder.moveWordForward(_:)),
        #selector(NSResponder.moveWordBackward(_:)),
        #selector(NSResponder.moveForward(_:)),
        #selector(NSResponder.moveBackward(_:)),
        #selector(NSResponder.moveUp(_:)),
        #selector(NSResponder.moveDown(_:)),
        #selector(NSResponder.pageUp(_:)),
        #selector(NSResponder.pageDown(_:)),
        #selector(NSResponder.scrollPageUp(_:)),
        #selector(NSResponder.scrollPageDown(_:)),
        #selector(NSResponder.insertTab(_:)),
        #selector(NSResponder.insertBacktab(_:)),
        #selector(NSResponder.cancelOperation(_:)),
        #selector(NSResponder.transpose(_:)),
        #selector(NSResponder.capitalizeWord(_:)),
        #selector(NSResponder.lowercaseWord(_:)),
        #selector(NSResponder.uppercaseWord(_:)),
        #selector(NSObject.puttyNoop(_:)),
    ]
}

private extension NSObject {
    /// Declares AppKit's `noop:` for `#selector` (ignore-list only).
    @objc(noop:)
    func puttyNoop(_ sender: Any?) {
        _ = sender
    }
}
