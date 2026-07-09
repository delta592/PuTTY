import AppKit
import CoreText

/// CTFont cache keyed by (bold, wide) for the configured macOS terminal font.
@MainActor
final class TerminalFontCache {
    struct Key: Hashable {
        let bold: Bool
        let wide: Bool
    }

    private let postScriptName: String
    private let pointSize: CGFloat
    private var cache: [Key: CTFont] = [:]

    init(fontSpec: String = "mac:SFMono-Regular:12") {
        let parsed = Self.parseFontSpec(fontSpec)
        postScriptName = parsed.postScriptName
        pointSize = parsed.pointSize
    }

    func ctFont(bold: Bool, wide: Bool) -> CTFont {
        let key = Key(bold: bold, wide: wide)
        if let cached = cache[key] {
            return cached
        }

        let nsFont: NSFont
        if bold, let boldFont = NSFontManager.shared.font(
            withFamily: postScriptName,
            traits: .boldFontMask,
            weight: 9,
            size: pointSize
        ) {
            nsFont = boldFont
        } else if let regular = NSFont(name: postScriptName, size: pointSize) {
            nsFont = regular
        } else {
            nsFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: bold ? .bold : .regular)
        }

        let ctFont = CTFontCreateWithName(nsFont.fontName as CFString, pointSize, nil)
        cache[key] = ctFont
        return ctFont
    }

    func nsFont(bold: Bool, wide: Bool) -> NSFont {
        let ct = ctFont(bold: bold, wide: wide)
        let name = CTFontCopyPostScriptName(ct) as String
        return NSFont(name: name, size: pointSize)
            ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: bold ? .bold : .regular)
    }

    func invalidate() {
        cache.removeAll()
    }

    private static func parseFontSpec(_ spec: String) -> (postScriptName: String, pointSize: CGFloat) {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "mac", let size = Double(parts[2]) {
            return (String(parts[1]), CGFloat(size))
        }
        return ("SFMono-Regular", 12)
    }
}
