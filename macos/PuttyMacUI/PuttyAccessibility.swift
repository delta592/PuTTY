import AppKit

/// System accessibility preferences used by the macOS GUI (Phase 9.2).
@MainActor
public enum PuttyAccessibility {
    /// True when the user enabled Reduce Motion in System Settings.
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// True when the user enabled Increase Contrast in System Settings.
    public static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Observe System Settings accessibility display option changes.
    @discardableResult
    public static func observeDisplayOptionsChanged(
        _ handler: @escaping @MainActor () -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
    }

    /// Apply chrome contrast to a bezel / border view (not the terminal palette).
    public static func applyChromeContrast(to view: NSView) {
        if increaseContrast {
            view.wantsLayer = true
            view.layer?.borderWidth = 1.5
            view.layer?.borderColor = NSColor.labelColor.cgColor
        } else {
            view.layer?.borderWidth = 0
            view.layer?.borderColor = nil
        }
    }

    /// Prefer no window transform animations when Reduce Motion is on.
    public static func applyWindowMotionPolicy(_ window: NSWindow) {
        if reduceMotion {
            window.animationBehavior = .none
        }
    }

    /// VoiceOver help text for the terminal surface (documented limitation).
    public static let terminalVoiceOverHelp =
        "PuTTY terminal emulator screen. Output is a character grid from a "
        + "remote or local session, not a navigable text document. VoiceOver "
        + "cannot read session contents line-by-line; copy a selection or open "
        + "the Event Log for readable history."

    /// Configure VoiceOver identity for the terminal drawing surface.
    public static func configureTerminalView(_ view: NSView, titleProvider: @escaping () -> String) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textArea)
        view.setAccessibilityRoleDescription("terminal")
        view.setAccessibilityLabel("Terminal")
        view.setAccessibilityHelp(terminalVoiceOverHelp)
        view.setAccessibilityValue(titleProvider())
    }

    /// Refresh the terminal accessibility value (typically the window title).
    public static func updateTerminalValue(_ view: NSView, title: String) {
        view.setAccessibilityValue(title.isEmpty ? "Terminal" : title)
    }
}
