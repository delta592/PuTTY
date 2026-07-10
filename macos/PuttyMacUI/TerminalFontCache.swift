import AppKit
import CoreText

/// CTFont / NSFont cache keyed by (bold, wide, pointSize) for the terminal font.
@MainActor
final class TerminalFontCache {
    struct Key: Hashable {
        let bold: Bool
        let wide: Bool
        let pointSize: CGFloat
    }

    private var postScriptName: String
    private var pointSize: CGFloat
    private var cache: [Key: CTFont] = [:]
    private var nsCache: [Key: NSFont] = [:]

    init(fontSpec: String = "mac:SFMono-Regular:12") {
        let parsed = Self.parseFontSpec(fontSpec)
        postScriptName = parsed.postScriptName
        pointSize = parsed.pointSize
    }

    /// Keep the cache in sync with TerminalView's measured cell font size.
    func setPointSize(_ size: CGFloat) {
        let clamped = max(6, min(72, size))
        if abs(clamped - pointSize) > 0.01 {
            pointSize = clamped
            invalidate()
        }
    }

    func setFontSpec(_ fontSpec: String) {
        let parsed = Self.parseFontSpec(fontSpec)
        if parsed.postScriptName != postScriptName || abs(parsed.pointSize - pointSize) > 0.01 {
            postScriptName = parsed.postScriptName
            pointSize = parsed.pointSize
            invalidate()
        }
    }

    func ctFont(bold: Bool, wide: Bool) -> CTFont {
        let key = Key(bold: bold, wide: wide, pointSize: pointSize)
        if let cached = cache[key] {
            return cached
        }

        let ns = makeNSFont(bold: bold)
        let ctFont = CTFontCreateWithName(ns.fontName as CFString, pointSize, nil)
        cache[key] = ctFont
        return ctFont
    }

    func nsFont(bold: Bool, wide: Bool) -> NSFont {
        let key = Key(bold: bold, wide: wide, pointSize: pointSize)
        if let cached = nsCache[key] {
            return cached
        }
        let font = makeNSFont(bold: bold)
        nsCache[key] = font
        return font
    }

    func nsFont(from ct: CTFont, bold: Bool = false) -> NSFont {
        let size = CTFontGetSize(ct)
        let name = CTFontCopyPostScriptName(ct) as String
        return NSFont(name: name, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    func invalidate() {
        cache.removeAll()
        nsCache.removeAll()
    }

    private func makeNSFont(bold: Bool) -> NSFont {
        let regular = Self.resolveFont(postScriptName: postScriptName, size: pointSize)
        guard bold else { return regular }
        let converted = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        if converted.fontDescriptor.symbolicTraits.contains(.bold) {
            return converted
        }
        /* Try a Bold face in the same family before falling back to system mono. */
        if let family = regular.familyName,
           let boldFace = NSFontManager.shared.font(
               withFamily: family,
               traits: .boldFontMask,
               weight: 9,
               size: pointSize
           ) {
            return boldFace
        }
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
    }

    /// Resolve PostScript name, then family name, then system monospaced.
    private static func resolveFont(postScriptName: String, size: CGFloat) -> NSFont {
        if let named = NSFont(name: postScriptName, size: size) {
            return named
        }
        /* Some installs expose only the family (e.g. "Inconsolata"). */
        if let familyFont = NSFontManager.shared.font(
            withFamily: postScriptName,
            traits: [],
            weight: 5,
            size: size
        ) {
            return familyFont
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func parseFontSpec(_ spec: String) -> (postScriptName: String, pointSize: CGFloat) {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[0] == "mac", let size = Double(parts[parts.count - 1]) {
            /* Join middle segments in case a PostScript name ever contains ':'. */
            let name = parts[1..<(parts.count - 1)].joined(separator: ":")
            if !name.isEmpty {
                return (name, CGFloat(size))
            }
        }
        return ("SFMono-Regular", 12)
    }

    /// Test/diagnostic: currently configured PostScript name.
    var currentPostScriptName: String { postScriptName }
    var currentPointSize: CGFloat { pointSize }
}
