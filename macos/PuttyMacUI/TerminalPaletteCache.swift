import AppKit
import CoreGraphics
import PuttyBridge

/// Cached OSC4 palette colours (Phase 4.4 hot path).
@MainActor
final class TerminalPaletteCache {
    struct RGB {
        var r: UInt8
        var g: UInt8
        var b: UInt8
    }

    /// OSC4_NCOLOURS is 262; store densely by index.
    private static let capacity = 262

    private var rgb = [RGB?](repeating: nil, count: capacity)
    private var cgColours = [CGColor?](repeating: nil, count: capacity)
    private var nsColours = [NSColor?](repeating: nil, count: capacity)

    func invalidate() {
        rgb = [RGB?](repeating: nil, count: Self.capacity)
        cgColours = [CGColor?](repeating: nil, count: Self.capacity)
        nsColours = [NSColor?](repeating: nil, count: Self.capacity)
    }

    func rgb(termWin: OpaquePointer, index: Int) -> RGB {
        guard index >= 0, index < Self.capacity else {
            return RGB(r: 128, g: 128, b: 128)
        }
        if let cached = rgb[index] {
            return cached
        }

        var r: UInt8 = 0
        var g: UInt8 = 0
        var b: UInt8 = 0
        guard putty_bridge_termwin_palette_colour(termWin, UInt32(index), &r, &g, &b) else {
            return RGB(r: 128, g: 128, b: 128)
        }

        let value = RGB(r: r, g: g, b: b)
        rgb[index] = value
        return value
    }

    func cgColor(termWin: OpaquePointer, index: Int) -> CGColor {
        guard index >= 0, index < Self.capacity else {
            return CGColor(gray: 0.5, alpha: 1.0)
        }
        if let cached = cgColours[index] {
            return cached
        }
        let value = rgb(termWin: termWin, index: index)
        let colour = deviceRGBColor(
            red: CGFloat(value.r) / 255.0,
            green: CGFloat(value.g) / 255.0,
            blue: CGFloat(value.b) / 255.0
        )
        cgColours[index] = colour
        return colour
    }

    func nsColor(termWin: OpaquePointer, index: Int) -> NSColor {
        guard index >= 0, index < Self.capacity else {
            return .lightGray
        }
        if let cached = nsColours[index] {
            return cached
        }
        let value = rgb(termWin: termWin, index: index)
        let colour = NSColor(
            srgbRed: CGFloat(value.r) / 255.0,
            green: CGFloat(value.g) / 255.0,
            blue: CGFloat(value.b) / 255.0,
            alpha: 1.0
        )
        nsColours[index] = colour
        return colour
    }

    func dimmed(_ colour: CGColor) -> CGColor {
        guard let rgb = colour.components, rgb.count >= 3 else { return colour }
        return deviceRGBColor(
            red: rgb[0] * 2.0 / 3.0,
            green: rgb[1] * 2.0 / 3.0,
            blue: rgb[2] * 2.0 / 3.0
        )
    }

    func dimmed(_ colour: NSColor) -> NSColor {
        NSColor(
            calibratedRed: colour.redComponent * 2.0 / 3.0,
            green: colour.greenComponent * 2.0 / 3.0,
            blue: colour.blueComponent * 2.0 / 3.0,
            alpha: 1.0
        )
    }

    private func deviceRGBColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGColor {
        let space = CGColorSpaceCreateDeviceRGB()
        let comps: [CGFloat] = [red, green, blue, 1.0]
        return CGColor(colorSpace: space, components: comps) ?? CGColor(gray: red, alpha: 1.0)
    }
}
