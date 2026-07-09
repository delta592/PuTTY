import AppKit
import PuttyBridge

private struct TerminalDrawCellRequest: Sendable {
    let x: Int32
    let y: Int32
    let len: Int32
    let attr: UInt32
    let lattr: Int32
    let codepoints: [UInt32]
}

private func terminalDrawRequest(
    from params: PuttyBridgeTermWinDrawParams
) -> TerminalDrawCellRequest {
    var codepoints = [UInt32]()
    if params.len > 0, let text = params.text {
        codepoints.reserveCapacity(Int(params.len))
        for i in 0..<Int(params.len) {
            codepoints.append(UInt32(text[i]))
        }
    }
    return TerminalDrawCellRequest(
        x: params.x,
        y: params.y,
        len: params.len,
        attr: params.attr,
        lattr: params.lattr,
        codepoints: codepoints
    )
}

// MARK: - C callback trampolines (Swift 6: @convention(c) on function types)

private enum TerminalViewBridge {
    static let setupDrawCtx: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { ctx in
        guard let ctx else { return false }
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        return MainActor.assumeIsolated { view.beginDraw() }
    }

    static let freeDrawCtx: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
        guard let ctx else { return }
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated { view.endDraw() }
    }

    static let drawText: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<PuttyBridgeTermWinDrawParams>?
    ) -> Void = { ctx, params in
        guard let ctx, let params else { return }
        let request = terminalDrawRequest(from: params.pointee)
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated { view.drawCell(request, isCursor: false) }
    }

    static let drawCursor: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<PuttyBridgeTermWinDrawParams>?
    ) -> Void = { ctx, params in
        guard let ctx, let params else { return }
        let request = terminalDrawRequest(from: params.pointee)
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated { view.drawCell(request, isCursor: true) }
    }

    static let drawTrustSigil: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void =
        { ctx, x, y in
            guard let ctx else { return }
            let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { view.drawTrustSigil(atX: x, y: y) }
        }

    static let requestRedraw: @convention(c) (
        UnsafeMutableRawPointer?, PuttyBridgeTermWinRect
    ) -> Void = { ctx, dirty in
        guard let ctx else { return }
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated { view.scheduleRedraw(dirty) }
    }
}

/// AppKit terminal surface wired to MacTermWin (Phase 4.2).
///
/// `draw(_:)` drives `term_paint`, which invokes C TermWin draw callbacks back
/// into this view. Full Core Text row rendering arrives in Phase 4.3.
@MainActor
final class TerminalView: NSView {
    nonisolated(unsafe) private var termWin: OpaquePointer?
    private var isPainting = false

    private let terminalFont: NSFont = {
        if let font = NSFont(name: "SFMono-Regular", size: 12) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        if let termWin {
            putty_bridge_termwin_free(termWin)
        }
    }

    private func commonInit() {
        wantsLayer = true
        layer?.contentsScale = window?.backingScaleFactor ?? 1.0

        let handle = putty_bridge_termwin_new()
        termWin = handle

        var callbacks = PuttyBridgeTermWinCallbacks(
            setup_draw_ctx: TerminalViewBridge.setupDrawCtx,
            free_draw_ctx: TerminalViewBridge.freeDrawCtx,
            draw_text: TerminalViewBridge.drawText,
            draw_cursor: TerminalViewBridge.drawCursor,
            draw_trust_sigil: TerminalViewBridge.drawTrustSigil,
            request_redraw: TerminalViewBridge.requestRedraw
        )
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        putty_bridge_termwin_set_callbacks(handle, &callbacks, ctx)

        guard putty_bridge_termwin_init_demo(handle) else {
            fputs("TerminalView: putty_bridge_termwin_init_demo failed\n", stderr)
            return
        }

        updateFontMetrics()
        updateBackingScale()
        syncTerminalGridSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
        syncTerminalGridSize()
        setNeedsDisplay(bounds)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
        syncTerminalGridSize()
        setNeedsDisplay(bounds)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        syncTerminalGridSize()
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let termWin, !isPainting else { return }

        let cellW = putty_bridge_termwin_cell_width_pt(termWin)
        let cellH = putty_bridge_termwin_cell_height_pt(termWin)
        guard cellW > 0, cellH > 0 else { return }

        let left = max(0, Int32(floor(dirtyRect.minX / cellW)))
        let top = max(0, Int32(floor(dirtyRect.minY / cellH)))
        let right = min(
            putty_bridge_termwin_cols(termWin) - 1,
            Int32(ceil(dirtyRect.maxX / cellW)) - 1
        )
        let bottom = min(
            putty_bridge_termwin_rows(termWin) - 1,
            Int32(ceil(dirtyRect.maxY / cellH)) - 1
        )
        guard right >= left, bottom >= top else { return }

        isPainting = true
        putty_bridge_termwin_paint(termWin, left, top, right, bottom)
        isPainting = false
    }

    // MARK: - Layout / metrics

    private func updateBackingScale() {
        guard let termWin else { return }
        let scale = window?.backingScaleFactor ?? 1.0
        putty_bridge_termwin_set_backing_scale(termWin, scale)
        layer?.contentsScale = scale
    }

    private func updateFontMetrics() {
        guard let termWin else { return }

        let probe = "M" as NSString
        let charWidth = probe.size(withAttributes: [.font: terminalFont]).width
        let cellHeight = ceil(terminalFont.ascender - terminalFont.descender + terminalFont.leading)
        let ascent = terminalFont.ascender
        let descent = -terminalFont.descender

        putty_bridge_termwin_set_font_metrics(
            termWin, charWidth, cellHeight, ascent, descent
        )
    }

    private func syncTerminalGridSize() {
        guard let termWin else { return }
        updateFontMetrics()
        putty_bridge_termwin_resize_to_view(termWin, bounds.width, bounds.height)
    }

    fileprivate func scheduleRedraw(_ dirty: PuttyBridgeTermWinRect) {
        let rect: NSRect
        if dirty.width <= 0 || dirty.height <= 0 {
            rect = bounds
        } else {
            rect = NSRect(x: dirty.x, y: dirty.y, width: dirty.width, height: dirty.height)
        }
        setNeedsDisplay(rect)
    }

    // MARK: - C draw callbacks

    fileprivate func beginDraw() -> Bool {
        NSGraphicsContext.current != nil
    }

    fileprivate func endDraw() {}

    fileprivate func drawCell(_ request: TerminalDrawCellRequest, isCursor: Bool) {
        guard let termWin,
              let context = NSGraphicsContext.current?.cgContext else { return }

        let cellW = putty_bridge_termwin_cell_width_pt(termWin)
        let cellH = putty_bridge_termwin_cell_height_pt(termWin)
        let wide = (request.attr & PUTTY_BRIDGE_ATTR_WIDE) != 0
        let columnSpan = wide ? 2 : 1

        var fgIndex = Int((request.attr & PUTTY_BRIDGE_ATTR_FGMASK) >> PUTTY_BRIDGE_ATTR_FGSHIFT)
        var bgIndex = Int((request.attr & PUTTY_BRIDGE_ATTR_BGMASK) >> PUTTY_BRIDGE_ATTR_BGSHIFT)
        if (request.attr & PUTTY_BRIDGE_ATTR_REVERSE) != 0 {
            swap(&fgIndex, &bgIndex)
        }

        let originX = CGFloat(request.x) * cellW
        let originY = CGFloat(request.y) * cellH
        let pixelWidth = CGFloat(columnSpan) * cellW
        let pixelHeight = cellH

        context.setFillColor(paletteColour(termWin, index: bgIndex))
        context.fill(CGRect(x: originX, y: originY, width: pixelWidth, height: pixelHeight))

        guard request.len > 0, !request.codepoints.isEmpty else { return }

        let string = stringFromCodepoints(request.codepoints)
        guard !string.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: terminalFont,
            .foregroundColor: paletteNSColour(termWin, index: fgIndex),
        ]
        (string as NSString).draw(
            at: NSPoint(x: originX, y: originY),
            withAttributes: attributes
        )

        if isCursor {
            context.setStrokeColor(paletteNSColour(termWin, index: fgIndex).cgColor)
            context.setLineWidth(1)
            context.stroke(
                CGRect(
                    x: originX + 0.5,
                    y: originY + 0.5,
                    width: pixelWidth - 1,
                    height: pixelHeight - 1
                )
            )
        } else if (request.attr & PUTTY_BRIDGE_ATTR_UNDER) != 0 {
            let underlineY = originY + pixelHeight - 2
            context.setStrokeColor(paletteNSColour(termWin, index: fgIndex).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: originX, y: underlineY))
            context.addLine(to: CGPoint(x: originX + pixelWidth, y: underlineY))
            context.strokePath()
        }
    }

    fileprivate func drawTrustSigil(atX x: Int32, y: Int32) {
        guard let termWin,
              let context = NSGraphicsContext.current?.cgContext else { return }

        let cellW = putty_bridge_termwin_cell_width_pt(termWin)
        let cellH = putty_bridge_termwin_cell_height_pt(termWin)
        let rect = CGRect(
            x: CGFloat(x) * cellW + 1,
            y: CGFloat(y) * cellH + 1,
            width: cellW - 2,
            height: cellH - 2
        )

        context.setStrokeColor(NSColor.systemOrange.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect)
    }

    private func paletteColour(
        _ termWin: OpaquePointer, index: Int
    ) -> CGColor {
        var r: UInt8 = 0
        var g: UInt8 = 0
        var b: UInt8 = 0
        guard putty_bridge_termwin_palette_colour(termWin, UInt32(index), &r, &g, &b) else {
            return NSColor.textColor.cgColor
        }
        return CGColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }

    private func paletteNSColour(_ termWin: OpaquePointer, index: Int) -> NSColor {
        NSColor(cgColor: paletteColour(termWin, index: index)) ?? .textColor
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
}
