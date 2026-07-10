import AppKit

/// System accent and chrome styling (Phase 9.3). Never applied to the terminal palette.
@MainActor
public enum PuttyChrome {
    /// User's System Settings accent colour.
    public static var accentColor: NSColor { .controlAccentColor }

    /// Border colour for chrome bezels (config panes, event log, session chrome).
    public static var chromeBorderColor: NSColor {
        if PuttyAccessibility.increaseContrast {
            return .labelColor
        }
        return accentColor.withAlphaComponent(0.55)
    }

    /// Border width for chrome bezels.
    public static var chromeBorderWidth: CGFloat {
        PuttyAccessibility.increaseContrast ? 1.5 : 1.0
    }

    /// Apply accent-aware chrome border (not terminal colours).
    public static func applyChromeBorder(to view: NSView) {
        view.wantsLayer = true
        view.layer?.borderWidth = chromeBorderWidth
        view.layer?.borderColor = chromeBorderColor.cgColor
    }
}
