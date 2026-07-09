import CoreGraphics
import PuttyBridge

/// Cached OSC4 palette colours as CGColor (Phase 4.4 hot path).
@MainActor
final class TerminalPaletteCache {
    private static let capacity = 262

    private var keys = [UInt32](repeating: 0, count: capacity)
    private var colours = [CGColor?](repeating: nil, count: capacity)

    func invalidate() {
        keys = [UInt32](repeating: 0, count: Self.capacity)
        colours = [CGColor?](repeating: nil, count: Self.capacity)
    }

    func cgColor(termWin: OpaquePointer, index: Int) -> CGColor {
        let slot = index & (Self.capacity - 1)
        var r: UInt8 = 0
        var g: UInt8 = 0
        var b: UInt8 = 0

        guard putty_bridge_termwin_palette_colour(termWin, UInt32(index), &r, &g, &b) else {
            return CGColor(gray: 0.5, alpha: 1.0)
        }

        let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        if keys[slot] == key, let cached = colours[slot] {
            return cached
        }

        let colour = CGColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
        keys[slot] = key
        colours[slot] = colour
        return colour
    }

    func dimmed(_ colour: CGColor) -> CGColor {
        guard let rgb = colour.components, rgb.count >= 3 else { return colour }
        return CGColor(
            red: rgb[0] * 2.0 / 3.0,
            green: rgb[1] * 2.0 / 3.0,
            blue: rgb[2] * 2.0 / 3.0,
            alpha: 1.0
        )
    }
}
