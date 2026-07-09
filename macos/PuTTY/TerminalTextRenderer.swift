import AppKit
import CoreText
import PuttyBridge

struct TerminalDrawRequest: Sendable {
    let x: Int32
    let y: Int32
    let len: Int32
    var attr: UInt32
    let lattr: Int32
    let codepoints: [UInt32]
    let fgTrueColour: PuttyBridgeOptionalRgb?
    let bgTrueColour: PuttyBridgeOptionalRgb?
    let isCursor: Bool
    var passiveCursor: Bool = false
    var activeNonBlockCursor: Bool = false
}

func terminalDrawRequest(
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

/// Core Text terminal renderer (Phase 4.3).
@MainActor
final class TerminalTextRenderer {
    private struct PaintCell {
        var request: TerminalDrawRequest
        var columnSpan: Int
    }

    private let fontCache = TerminalFontCache()
    private var rowCells: [Int32: [PaintCell]] = [:]
    private var trustSigils: [(x: Int32, y: Int32)] = []

    private var termWin: OpaquePointer?
    private var cellWidth: CGFloat = 0
    private var cellHeight: CGFloat = 0
    private var ascent: CGFloat = 0
    private var cursorType: Int32 = PUTTY_BRIDGE_CURSOR_BLOCK
    private var boldStyle: Int32 = 0

    private var trustSigilImage: NSImage?

    func attach(termWin: OpaquePointer) {
        self.termWin = termWin
        refreshMetrics()
    }

    func refreshMetrics() {
        guard let termWin else { return }
        cellWidth = CGFloat(putty_bridge_termwin_cell_width_pt(termWin))
        cellHeight = CGFloat(putty_bridge_termwin_cell_height_pt(termWin))
        ascent = CGFloat(putty_bridge_termwin_ascent_pt(termWin))
        cursorType = putty_bridge_termwin_cursor_type(termWin)
        boldStyle = putty_bridge_termwin_bold_style(termWin)
        fontCache.invalidate()
    }

    func beginPaint() {
        rowCells.removeAll(keepingCapacity: true)
        trustSigils.removeAll(keepingCapacity: true)
    }

    func enqueue(_ request: TerminalDrawRequest) {
        var adjusted = request
        prepareCursorAttributes(&adjusted)

        let columnSpan = columnSpan(for: adjusted)
        let cell = PaintCell(request: adjusted, columnSpan: columnSpan)
        rowCells[adjusted.y, default: []].append(cell)
    }

    func enqueueTrustSigil(x: Int32, y: Int32) {
        trustSigils.append((x, y))
    }

    func endPaint() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        for y in rowCells.keys.sorted() {
            guard let cells = rowCells[y] else { continue }
            flushRow(cells, y: y, context: context)
        }

        for sigil in trustSigils {
            drawTrustSigil(atX: sigil.x, y: sigil.y, context: context)
        }
    }

    func charWidth(for codepoint: Int32) -> Int32 {
        guard cellWidth > 0 else { return 1 }
        let font = fontCache.nsFont(bold: false, wide: false)
        let scalar = UInt32(bitPattern: codepoint)
        let string = stringFromCodepoints([scalar])
        guard !string.isEmpty else { return 1 }
        let advance = (string as NSString).size(withAttributes: [.font: font]).width
        return advance > cellWidth * 1.05 ? 2 : 1
    }

    // MARK: - Row flush

    private func flushRow(_ cells: [PaintCell], y: Int32, context: CGContext) {
        let sorted = cells.sorted { $0.request.x < $1.request.x }
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

    private func drawCTLineRun(_ run: [PaintCell], originY: CGFloat, context: CGContext) {
        let lineString = NSMutableAttributedString()

        for cell in run {
            let colours = resolvedColours(for: cell.request)
            let bold = (cell.request.attr & PUTTY_BRIDGE_ATTR_BOLD) != 0
            let font = fontCache.nsFont(bold: bold, wide: false)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colours.fg,
            ]
            if (cell.request.attr & PUTTY_BRIDGE_ATTR_UNDER) != 0 {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if (cell.request.attr & PUTTY_BRIDGE_ATTR_STRIKE) != 0 {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            let text = stringFromCodepoints(cell.request.codepoints)
            lineString.append(NSAttributedString(string: text, attributes: attrs))
        }

        guard lineString.length > 0 else { return }

        let first = run[0]
        let originX = CGFloat(first.request.x) * cellWidth
        let line = CTLineCreateWithAttributedString(lineString)
        drawCTLine(line, originX: originX, originY: originY, context: context)
    }

    private func drawCTLine(
        _ line: CTLine, originX: CGFloat, originY: CGFloat, context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: originX, y: originY + cellHeight)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawIndividual(_ cell: PaintCell, originY: CGFloat, context: CGContext) {
        let colours = resolvedColours(for: cell.request)
        let bold = (cell.request.attr & PUTTY_BRIDGE_ATTR_BOLD) != 0
        let wide = (cell.request.attr & PUTTY_BRIDGE_ATTR_WIDE) != 0
        let font = fontCache.nsFont(bold: bold, wide: wide)

        let originX = CGFloat(cell.request.x) * cellWidth
        let pixelWidth = CGFloat(cell.columnSpan) * cellWidth

        context.setFillColor(colours.bg.cgColor)
        context.fill(CGRect(x: originX, y: originY, width: pixelWidth, height: cellHeight))

        let text = stringFromCodepoints(cell.request.codepoints)
        guard !text.isEmpty else { return }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colours.fg,
        ]
        if (cell.request.attr & PUTTY_BRIDGE_ATTR_UNDER) != 0 {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if (cell.request.attr & PUTTY_BRIDGE_ATTR_STRIKE) != 0 {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        if (cell.request.attr & PUTTY_BRIDGE_ATTR_COMBINING) != 0 {
            var offsetX = originX
            for codepoint in cell.request.codepoints {
                let glyph = stringFromCodepoints([codepoint])
                (glyph as NSString).draw(at: NSPoint(x: offsetX, y: originY), withAttributes: attrs)
                offsetX += cellWidth
            }
        } else {
            (text as NSString).draw(at: NSPoint(x: originX, y: originY), withAttributes: attrs)
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

    private func drawCursorDecoration(
        for cell: PaintCell, originY: CGFloat, context: CGContext
    ) {
        let colours = resolvedColours(for: cell.request)

        let originX = CGFloat(cell.request.x) * cellWidth
        let pixelWidth = CGFloat(cell.columnSpan) * cellWidth
        let rect = CGRect(x: originX, y: originY, width: pixelWidth, height: cellHeight)

        switch cursorType {
        case PUTTY_BRIDGE_CURSOR_BLOCK:
            if cell.request.passiveCursor {
                context.setStrokeColor(colours.fg.cgColor)
                context.setLineWidth(1)
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }

        case PUTTY_BRIDGE_CURSOR_UNDERLINE:
            if cell.request.activeNonBlockCursor || cell.request.passiveCursor {
                var underlineY = originY + ascent + 1
                if underlineY >= originY + cellHeight {
                    underlineY = originY + cellHeight - 1
                }
                context.setStrokeColor(colours.fg.cgColor)
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
                context.setStrokeColor(colours.fg.cgColor)
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
            return (.textColor, .textBackgroundColor)
        }

        var fgIndex = Int((request.attr & PUTTY_BRIDGE_ATTR_FGMASK) >> PUTTY_BRIDGE_ATTR_FGSHIFT)
        var bgIndex = Int((request.attr & PUTTY_BRIDGE_ATTR_BGMASK) >> PUTTY_BRIDGE_ATTR_BGSHIFT)
        var fgTC = request.fgTrueColour
        var bgTC = request.bgTrueColour

        if (request.attr & PUTTY_BRIDGE_ATTR_REVERSE) != 0 {
            swap(&fgIndex, &bgIndex)
            swap(&fgTC, &bgTC)
        }

        if (boldStyle & PUTTY_BRIDGE_BOLD_STYLE_COLOUR) != 0 {
            if (request.attr & PUTTY_BRIDGE_ATTR_BOLD) != 0, fgIndex < 16 {
                fgIndex |= 8
            } else if fgIndex >= 256 {
                fgIndex |= 1
            }
            if (request.attr & PUTTY_BRIDGE_ATTR_BLINK) != 0, bgIndex < 16 {
                bgIndex |= 8
            } else if bgIndex >= 256 {
                bgIndex |= 1
            }
        }

        if request.isCursor,
           (request.attr & PUTTY_BRIDGE_ATTR_ACTCURS) != 0,
           cursorType == PUTTY_BRIDGE_CURSOR_BLOCK {
            fgIndex = Int(PUTTY_BRIDGE_OSC4_CURSOR_FG)
            bgIndex = Int(PUTTY_BRIDGE_OSC4_CURSOR_BG)
        }

        var fg = paletteColour(termWin, index: fgIndex)
        var bg = paletteColour(termWin, index: bgIndex)

        if let tc = fgTC {
            fg = colourFromOptionalRgb(tc)
        }
        if let tc = bgTC {
            bg = colourFromOptionalRgb(tc)
        }

        if (request.attr & PUTTY_BRIDGE_ATTR_DIM) != 0 {
            fg = dimColour(fg)
            bg = dimColour(bg)
        }

        return (fg, bg)
    }

    private func paletteColour(_ termWin: OpaquePointer, index: Int) -> NSColor {
        var r: UInt8 = 0
        var g: UInt8 = 0
        var b: UInt8 = 0
        guard putty_bridge_termwin_palette_colour(termWin, UInt32(index), &r, &g, &b) else {
            return .textColor
        }
        return NSColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }

    private func colourFromOptionalRgb(_ rgb: PuttyBridgeOptionalRgb) -> NSColor {
        NSColor(
            red: CGFloat(rgb.r) / 255.0,
            green: CGFloat(rgb.g) / 255.0,
            blue: CGFloat(rgb.b) / 255.0,
            alpha: 1.0
        )
    }

    private func dimColour(_ colour: NSColor) -> NSColor {
        guard let rgb = colour.usingColorSpace(.deviceRGB) else { return colour }
        return NSColor(
            red: rgb.redComponent * 2.0 / 3.0,
            green: rgb.greenComponent * 2.0 / 3.0,
            blue: rgb.blueComponent * 2.0 / 3.0,
            alpha: 1.0
        )
    }
}

private func stringFromCodepoints(_ codepoints: [UInt32]) -> String {
    guard !codepoints.isEmpty else { return "" }
    var codeUnits = [UniChar]()
    codeUnits.reserveCapacity(codepoints.count)
    for wc in codepoints {
        if wc <= 0xFFFF {
            codeUnits.append(UniChar(wc))
        } else if wc <= 0x10FFFF {
            let value = wc
            let high = UniChar(0xD800 + ((value - 0x10000) >> 10))
            let low = UniChar(0xDC00 + (value & 0x3FF))
            codeUnits.append(high)
            codeUnits.append(low)
        }
    }
    return String(utf16CodeUnits: codeUnits, count: codeUnits.count)
}
