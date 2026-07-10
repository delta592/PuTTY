import AppKit
import CoreText
import PuttyBridge

public struct TerminalDrawRequest: Sendable {
    public let x: Int32
    public let y: Int32
    public let len: Int32
    public var attr: UInt32
    public let lattr: Int32
    public let codepoints: [UInt32]
    public let fgTrueColour: PuttyBridgeOptionalRgb?
    public let bgTrueColour: PuttyBridgeOptionalRgb?
    public let isCursor: Bool
    public var passiveCursor: Bool = false
    public var activeNonBlockCursor: Bool = false
}

public func terminalDrawRequest(
    from params: PuttyBridgeTermWinDrawParams,
    isCursor: Bool
) -> TerminalDrawRequest {
    var codepoints = [UInt32]()
    if params.len > 0, let text = params.text {
        codepoints.reserveCapacity(Int(params.len))
        for i in 0..<Int(params.len) {
            codepoints.append(UInt32(text[i]))
        }
    }

    let fg: PuttyBridgeOptionalRgb? = params.truecolour.fg.enabled ? params.truecolour.fg : nil
    let bg: PuttyBridgeOptionalRgb? = params.truecolour.bg.enabled ? params.truecolour.bg : nil

    return TerminalDrawRequest(
        x: params.x,
        y: params.y,
        len: params.len,
        attr: params.attr,
        lattr: params.lattr,
        codepoints: codepoints,
        fgTrueColour: fg,
        bgTrueColour: bg,
        isCursor: isCursor
    )
}

/// Core Text terminal renderer (Phase 4.3–4.4).
@MainActor
public final class TerminalTextRenderer {
    private struct PaintCell {
        var request: TerminalDrawRequest
        var columnSpan: Int
    }

    private let fontCache = TerminalFontCache()
    private let paletteCache = TerminalPaletteCache()

    private var rowCells: [Int32: [PaintCell]] = [:]
    private var rowsNeedSort = Set<Int32>()
    private var trustSigils: [(x: Int32, y: Int32)] = []

    private var lineScratch = NSMutableAttributedString()
    private var uniScratch = [UniChar]()
    private var glyphScratch = [CGGlyph]()
    private var advanceScratch = [CGSize]()

    private var termWin: OpaquePointer?
    private var cellWidth: CGFloat = 0
    private var cellHeight: CGFloat = 0
    private var ascent: CGFloat = 0
    private var cursorType: Int32 = PUTTY_BRIDGE_CURSOR_BLOCK
    private var boldStyle: Int32 = 0

    private var trustSigilImage: NSImage?
    private var lastEnqueueRow: Int32 = -1
    private var lastEnqueueX: Int32 = -1

    public init() {}

    public func attach(termWin: OpaquePointer) {
        self.termWin = termWin
        refreshMetrics()
    }

    public func refreshMetrics() {
        guard let termWin else { return }
        cellWidth = CGFloat(putty_bridge_termwin_cell_width_pt(termWin))
        cellHeight = CGFloat(putty_bridge_termwin_cell_height_pt(termWin))
        ascent = CGFloat(putty_bridge_termwin_ascent_pt(termWin))
        cursorType = putty_bridge_termwin_cursor_type(termWin)
        boldStyle = putty_bridge_termwin_bold_style(termWin)
        /*
         * Derive point size from measured ascent when available so glyphs
         * match the cell grid TerminalView configured.
         */
        if ascent > 0 {
            fontCache.setPointSize(ascent)
        } else if cellHeight > 0 {
            fontCache.setPointSize(cellHeight * 0.8)
        }
        paletteCache.invalidate()
    }

    public func beginPaint() {
        rowCells.removeAll(keepingCapacity: true)
        rowsNeedSort.removeAll(keepingCapacity: true)
        trustSigils.removeAll(keepingCapacity: true)
        lastEnqueueRow = -1
        lastEnqueueX = -1
    }

    public func enqueue(_ request: TerminalDrawRequest) {
        var adjusted = request
        prepareCursorAttributes(&adjusted)

        if adjusted.y != lastEnqueueRow {
            lastEnqueueRow = adjusted.y
            lastEnqueueX = -1
        }
        if lastEnqueueX >= 0, adjusted.x < lastEnqueueX {
            rowsNeedSort.insert(adjusted.y)
        }
        lastEnqueueX = adjusted.x

        let cell = PaintCell(
            request: adjusted,
            columnSpan: columnSpan(for: adjusted)
        )
        rowCells[adjusted.y, default: []].append(cell)
    }

    public func enqueueTrustSigil(x: Int32, y: Int32) {
        trustSigils.append((x, y))
    }

    public func endPaint() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        for y in rowCells.keys.sorted() {
            guard let cells = rowCells[y] else { continue }
            flushRow(cells, y: y, context: context)
        }

        for sigil in trustSigils {
            drawTrustSigil(atX: sigil.x, y: sigil.y, context: context)
        }
    }

    public func charWidth(for codepoint: Int32) -> Int32 {
        guard cellWidth > 0 else { return 1 }

        let font = fontCache.ctFont(bold: false, wide: false)
        let scalar = UInt32(bitPattern: codepoint)
        guard appendScalar(scalar, to: &uniScratch), !uniScratch.isEmpty else { return 1 }

        glyphScratch.removeAll(keepingCapacity: true)
        glyphScratch.append(0)
        guard CTFontGetGlyphsForCharacters(
            font, &uniScratch, &glyphScratch, uniScratch.count
        ) else {
            return 1
        }

        advanceScratch.removeAll(keepingCapacity: true)
        advanceScratch.append(.zero)
        CTFontGetAdvancesForGlyphs(
            font, .horizontal, &glyphScratch, &advanceScratch, 1
        )
        return advanceScratch[0].width > cellWidth * 1.05 ? 2 : 1
    }

    // MARK: - Row flush

    private func flushRow(_ cells: [PaintCell], y: Int32, context: CGContext) {
        let sorted: [PaintCell]
        if rowsNeedSort.contains(y) {
            sorted = cells.sorted { $0.request.x < $1.request.x }
        } else {
            sorted = cells
        }

        let originY = CGFloat(y) * cellHeight

        for cell in sorted {
            drawBackground(for: cell, originY: originY, context: context)
        }

        var index = 0
        while index < sorted.count {
            let cell = sorted[index]
            if needsIndividualDraw(cell.request) {
                drawIndividual(cell, originY: originY, context: context)
                index += 1
                continue
            }

            var run: [PaintCell] = [cell]
            var next = index + 1
            while next < sorted.count, !needsIndividualDraw(sorted[next].request) {
                run.append(sorted[next])
                next += 1
            }
            drawCTLineRun(run, originY: originY, context: context)
            index = next
        }

        for cell in sorted where cell.request.isCursor {
            drawCursorDecoration(for: cell, originY: originY, context: context)
        }
    }

    private func textAttributes(
        bold: Bool, fg: NSColor, requestAttr: UInt32
    ) -> [NSAttributedString.Key: Any] {
        /*
         * Use AppKit NSColor + NSFont. CTLineDraw was inheriting the CG fill
         * colour from the preceding background rect (black-on-black).
         */
        let nsFont = fontCache.nsFont(bold: bold, wide: false)
        // Ensure we never paint with an effectively-black foreground on black bg.
        var drawFg = fg
        if drawFg.redComponent + drawFg.greenComponent + drawFg.blueComponent < 0.05 {
            drawFg = NSColor(
                srgbRed: 0.73, green: 0.73, blue: 0.73, alpha: 1.0
            )
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: nsFont,
            .foregroundColor: drawFg,
        ]
        if (requestAttr & PUTTY_BRIDGE_ATTR_UNDER) != 0 {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if (requestAttr & PUTTY_BRIDGE_ATTR_STRIKE) != 0 {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    private func drawCTLineRun(_ run: [PaintCell], originY: CGFloat, context: CGContext) {
        _ = context
        lineScratch.deleteCharacters(in: NSRange(location: 0, length: lineScratch.length))

        for cell in run {
            let colours = resolvedColours(for: cell.request)
            let bold = (cell.request.attr & PUTTY_BRIDGE_ATTR_BOLD) != 0
            let attrs = textAttributes(
                bold: bold, fg: colours.fg, requestAttr: cell.request.attr
            )
            appendCodepoints(cell.request.codepoints, to: lineScratch, attributes: attrs)
        }

        guard lineScratch.length > 0 else { return }

        let originX = CGFloat(run[0].request.x) * cellWidth
        drawAttributedLine(lineScratch, originX: originX, originY: originY)
    }

    private func drawIndividual(_ cell: PaintCell, originY: CGFloat, context: CGContext) {
        let colours = resolvedColours(for: cell.request)
        let bold = (cell.request.attr & PUTTY_BRIDGE_ATTR_BOLD) != 0

        let originX = CGFloat(cell.request.x) * cellWidth
        let pixelWidth = CGFloat(cell.columnSpan) * cellWidth

        context.setFillColor(colours.bg.cgColor)
        context.fill(CGRect(x: originX, y: originY, width: pixelWidth, height: cellHeight))

        guard !cell.request.codepoints.isEmpty else { return }

        lineScratch.deleteCharacters(in: NSRange(location: 0, length: lineScratch.length))
        let attrs = textAttributes(
            bold: bold, fg: colours.fg, requestAttr: cell.request.attr
        )

        if (cell.request.attr & PUTTY_BRIDGE_ATTR_COMBINING) != 0 {
            var offsetX = originX
            for codepoint in cell.request.codepoints {
                lineScratch.deleteCharacters(in: NSRange(location: 0, length: lineScratch.length))
                appendCodepoints([codepoint], to: lineScratch, attributes: attrs)
                drawAttributedLine(lineScratch, originX: offsetX, originY: originY)
                offsetX += cellWidth
            }
        } else {
            appendCodepoints(cell.request.codepoints, to: lineScratch, attributes: attrs)
            drawAttributedLine(lineScratch, originX: originX, originY: originY)
        }
    }

    private func drawBackground(
        for cell: PaintCell, originY: CGFloat, context: CGContext
    ) {
        let colours = resolvedColours(for: cell.request)
        let originX = CGFloat(cell.request.x) * cellWidth
        let pixelWidth = CGFloat(cell.columnSpan) * cellWidth
        context.setFillColor(colours.bg.cgColor)
        context.fill(CGRect(x: originX, y: originY, width: pixelWidth, height: cellHeight))
    }

    private func drawAttributedLine(
        _ string: NSAttributedString, originX: CGFloat, originY: CGFloat
    ) {
        /*
         * In a flipped NSView, draw(with:options:.usesLineFragmentOrigin)
         * treats the rect origin as the top-left of the text box. draw(at:)
         * baseline placement was clipping glyphs to thin horizontal strips.
         */
        let rect = NSRect(
            x: originX,
            y: originY,
            width: max(cellWidth, CGFloat(string.length) * cellWidth + cellWidth),
            height: max(cellHeight, 1)
        )
        string.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    private func drawCursorDecoration(
        for cell: PaintCell, originY: CGFloat, context: CGContext
    ) {
        let colours = resolvedColours(for: cell.request)
        let originX = CGFloat(cell.request.x) * cellWidth
        let pixelWidth = CGFloat(cell.columnSpan) * cellWidth
        let rect = CGRect(x: originX, y: originY, width: pixelWidth, height: cellHeight)
        let fg = colours.fg.cgColor

        switch cursorType {
        case PUTTY_BRIDGE_CURSOR_BLOCK:
            if cell.request.passiveCursor {
                context.setStrokeColor(fg)
                context.setLineWidth(1)
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }

        case PUTTY_BRIDGE_CURSOR_UNDERLINE:
            if cell.request.activeNonBlockCursor || cell.request.passiveCursor {
                var underlineY = originY + ascent + 1
                if underlineY >= originY + cellHeight {
                    underlineY = originY + cellHeight - 1
                }
                context.setStrokeColor(fg)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: originX, y: underlineY))
                context.addLine(to: CGPoint(x: originX + pixelWidth, y: underlineY))
                context.strokePath()
            }

        case PUTTY_BRIDGE_CURSOR_VERTICAL_LINE:
            if cell.request.activeNonBlockCursor || cell.request.passiveCursor {
                var xPos = originX
                if (cell.request.attr & PUTTY_BRIDGE_ATTR_RIGHTCURS) != 0 {
                    xPos += pixelWidth - 1
                }
                context.setStrokeColor(fg)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: xPos, y: originY))
                context.addLine(to: CGPoint(x: xPos, y: originY + cellHeight))
                context.strokePath()
            }

        default:
            break
        }
    }

    private func drawTrustSigil(atX x: Int32, y: Int32, context: CGContext) {
        let originX = CGFloat(x) * cellWidth
        let originY = CGFloat(y) * cellHeight
        let width = cellWidth * 2
        let rect = CGRect(x: originX, y: originY, width: width, height: cellHeight)

        if trustSigilImage == nil {
            trustSigilImage = NSImage(named: "PuTTY") ?? NSImage(named: NSImage.applicationIconName)
        }

        if let image = trustSigilImage {
            context.saveGState()
            context.clip(to: rect)
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 0.95,
                respectFlipped: true,
                hints: nil
            )
            context.restoreGState()
            return
        }

        context.setStrokeColor(NSColor.systemOrange.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect.insetBy(dx: 1, dy: 1))
    }

    // MARK: - Helpers

    private func prepareCursorAttributes(_ request: inout TerminalDrawRequest) {
        guard request.isCursor else { return }

        if (request.attr & PUTTY_BRIDGE_ATTR_PASCURS) != 0 {
            request.passiveCursor = true
            request.attr &= ~UInt32(PUTTY_BRIDGE_ATTR_PASCURS)
        }

        if (request.attr & PUTTY_BRIDGE_ATTR_ACTCURS) != 0,
           cursorType != PUTTY_BRIDGE_CURSOR_BLOCK {
            request.activeNonBlockCursor = true
            request.attr &= ~UInt32(PUTTY_BRIDGE_ATTR_ACTCURS)
        }
    }

    private func needsIndividualDraw(_ request: TerminalDrawRequest) -> Bool {
        if (request.attr & PUTTY_BRIDGE_ATTR_WIDE) != 0 { return true }
        if (request.attr & PUTTY_BRIDGE_ATTR_COMBINING) != 0 { return true }
        if (request.lattr & PUTTY_BRIDGE_LATTR_MODE) != PUTTY_BRIDGE_LATTR_NORM { return true }
        return false
    }

    private func columnSpan(for request: TerminalDrawRequest) -> Int {
        if (request.attr & PUTTY_BRIDGE_ATTR_WIDE) != 0 { return 2 }
        if (request.lattr & PUTTY_BRIDGE_LATTR_MODE) != PUTTY_BRIDGE_LATTR_NORM { return 2 }
        return max(1, Int(request.len))
    }

    private func resolvedColours(for request: TerminalDrawRequest) -> (fg: NSColor, bg: NSColor) {
        guard let termWin else {
            return (.white, .black)
        }

        var fgIndex = Int((request.attr & PUTTY_BRIDGE_ATTR_FGMASK) >> PUTTY_BRIDGE_ATTR_FGSHIFT)
        var bgIndex = Int((request.attr & PUTTY_BRIDGE_ATTR_BGMASK) >> PUTTY_BRIDGE_ATTR_BGSHIFT)
        var fgTC = request.fgTrueColour
        var bgTC = request.bgTrueColour

        if (request.attr & PUTTY_BRIDGE_ATTR_REVERSE) != 0 {
            swap(&fgIndex, &bgIndex)
            swap(&fgTC, &bgTC)
        }

        /* Match unix/window.c: only brighten when BOLD/BLINK is set. */
        if (boldStyle & PUTTY_BRIDGE_BOLD_STYLE_COLOUR) != 0 {
            if (request.attr & PUTTY_BRIDGE_ATTR_BOLD) != 0 {
                if fgIndex < 16 {
                    fgIndex |= 8
                } else if fgIndex >= 256 {
                    fgIndex |= 1
                }
            }
            if (request.attr & PUTTY_BRIDGE_ATTR_BLINK) != 0 {
                if bgIndex < 16 {
                    bgIndex |= 8
                } else if bgIndex >= 256 {
                    bgIndex |= 1
                }
            }
        }

        if request.isCursor,
           (request.attr & PUTTY_BRIDGE_ATTR_ACTCURS) != 0,
           cursorType == PUTTY_BRIDGE_CURSOR_BLOCK {
            fgIndex = Int(PUTTY_BRIDGE_OSC4_CURSOR_FG)
            bgIndex = Int(PUTTY_BRIDGE_OSC4_CURSOR_BG)
        }

        var fg = paletteCache.nsColor(termWin: termWin, index: fgIndex)
        var bg = paletteCache.nsColor(termWin: termWin, index: bgIndex)

        if let tc = fgTC {
            fg = nsColorFromOptionalRgb(tc)
        }
        if let tc = bgTC {
            bg = nsColorFromOptionalRgb(tc)
        }

        if (request.attr & PUTTY_BRIDGE_ATTR_DIM) != 0 {
            fg = paletteCache.dimmed(fg)
            bg = paletteCache.dimmed(bg)
        }

        return (fg, bg)
    }

    private func nsColorFromOptionalRgb(_ rgb: PuttyBridgeOptionalRgb) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.r) / 255.0,
            green: CGFloat(rgb.g) / 255.0,
            blue: CGFloat(rgb.b) / 255.0,
            alpha: 1.0
        )
    }

    private func appendCodepoints(
        _ codepoints: [UInt32],
        to string: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        uniScratch.removeAll(keepingCapacity: true)
        for wc in codepoints {
            if wc <= 0xFFFF {
                uniScratch.append(UniChar(wc))
            } else if wc <= 0x10FFFF {
                let value = wc
                uniScratch.append(UniChar(0xD800 + ((value - 0x10000) >> 10)))
                uniScratch.append(UniChar(0xDC00 + (value & 0x3FF)))
            }
        }
        guard !uniScratch.isEmpty else { return }
        string.append(NSAttributedString(string: String(utf16CodeUnits: uniScratch, count: uniScratch.count), attributes: attributes))
    }

    private func appendScalar(_ scalar: UInt32, to buffer: inout [UniChar]) -> Bool {
        buffer.removeAll(keepingCapacity: true)
        if scalar <= 0xFFFF {
            buffer.append(UniChar(scalar))
            return true
        }
        if scalar <= 0x10FFFF {
            buffer.append(UniChar(0xD800 + ((scalar - 0x10000) >> 10)))
            buffer.append(UniChar(0xDC00 + (scalar & 0x3FF)))
            return true
        }
        return false
    }
}
