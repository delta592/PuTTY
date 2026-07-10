import AppKit
import PuttyBridge

/// Window chrome updates from MacTermWin (Phase 4.8).
@MainActor
protocol TerminalWindowChrome: AnyObject {
    func ringBell(mode: Int32, termWin: OpaquePointer)
    func setWindowTitle(_ title: String)
    func setIconTitle(_ title: String)
}

/// Plays terminal bells per Conf beep mode.
@MainActor
enum TerminalBell {
    static func play(mode: Int32, termWin: OpaquePointer) {
        switch mode {
        case PUTTY_BRIDGE_BELL_DEFAULT, PUTTY_BRIDGE_BELL_PCSPEAKER:
            NSSound.beep()
        case PUTTY_BRIDGE_BELL_WAVEFILE:
            playWaveFile(termWin: termWin)
        case PUTTY_BRIDGE_BELL_VISUAL:
            /*
             * Reverse-video flash is scheduled by terminal.c after win_bell.
             * When Reduce Motion is on, add an audible cue so the bell is not
             * solely a screen flash (Phase 9.2).
             *
             * Query NSWorkspace directly (not PuttyAccessibility) so this
             * file stays self-contained under Xcode's per-file SwiftCompile.
             */
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSSound.beep()
            }
        default:
            break
        }
    }

    private static func playWaveFile(termWin: OpaquePointer) {
        var pathBuf = [CChar](repeating: 0, count: 4096)
        guard putty_bridge_termwin_bell_wavefile_path(
            termWin, &pathBuf, pathBuf.count
        ) else {
            NSSound.beep()
            return
        }

        let path = String(
            decoding: pathBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self)
        guard let sound = NSSound(contentsOfFile: path, byReference: false) else {
            NSSound.beep()
            return
        }
        sound.play()
    }
}
