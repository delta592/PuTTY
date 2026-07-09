import AppKit
import PuttyBridge

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
        let request = terminalDrawRequest(from: params.pointee, isCursor: false)
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated { view.enqueueDraw(request) }
    }

    static let drawCursor: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<PuttyBridgeTermWinDrawParams>?
    ) -> Void = { ctx, params in
        guard let ctx, let params else { return }
        let request = terminalDrawRequest(from: params.pointee, isCursor: true)
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated { view.enqueueDraw(request) }
    }

    static let drawTrustSigil: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void =
        { ctx, x, y in
            guard let ctx else { return }
            let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { view.enqueueTrustSigil(x: x, y: y) }
        }

    static let requestRedraw: @convention(c) (
        UnsafeMutableRawPointer?, PuttyBridgeTermWinRect
    ) -> Void = { ctx, dirty in
        guard let ctx else { return }
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated { view.scheduleRedraw(dirty) }
    }

    static let charWidth: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32 = { ctx, uc in
        guard let ctx else { return 1 }
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        return MainActor.assumeIsolated { view.measureCharWidth(uc) }
    }
}

/// AppKit terminal surface wired to MacTermWin (Phase 4.2–4.3).
@MainActor
final class TerminalView: NSView {
    nonisolated(unsafe) private var termWin: OpaquePointer?
    private var isPainting = false
    private let renderer = TerminalTextRenderer()
    private var pendingDirty: NSRect?
    private var dirtyFlushScheduled = false

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
        renderer.attach(termWin: handle!)

        var callbacks = PuttyBridgeTermWinCallbacks(
            setup_draw_ctx: TerminalViewBridge.setupDrawCtx,
            free_draw_ctx: TerminalViewBridge.freeDrawCtx,
            draw_text: TerminalViewBridge.drawText,
            draw_cursor: TerminalViewBridge.drawCursor,
            draw_trust_sigil: TerminalViewBridge.drawTrustSigil,
            request_redraw: TerminalViewBridge.requestRedraw,
            char_width: TerminalViewBridge.charWidth
        )
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        putty_bridge_termwin_set_callbacks(handle, &callbacks, ctx)

        guard putty_bridge_termwin_init_demo(handle) else {
            fputs("TerminalView: putty_bridge_termwin_init_demo failed\n", stderr)
            return
        }

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

        let font = NSFont(name: "SFMono-Regular", size: 12)
            ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let probe = "M" as NSString
        let charWidth = probe.size(withAttributes: [.font: font]).width
        let cellHeight = ceil(font.ascender - font.descender + font.leading)

        putty_bridge_termwin_set_font_metrics(
            termWin, charWidth, cellHeight, font.ascender, -font.descender
        )
        renderer.refreshMetrics()
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

        if let pending = pendingDirty {
            pendingDirty = pending.union(rect)
        } else {
            pendingDirty = rect
        }

        guard !dirtyFlushScheduled else { return }
        dirtyFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dirtyFlushScheduled = false
            guard let rect = self.pendingDirty else { return }
            self.pendingDirty = nil
            self.setNeedsDisplay(rect)
        }
    }

    // MARK: - C draw callbacks

    fileprivate func beginDraw() -> Bool {
        guard NSGraphicsContext.current != nil else { return false }
        renderer.beginPaint()
        return true
    }

    fileprivate func endDraw() {
        renderer.endPaint()
    }

    fileprivate func enqueueDraw(_ request: TerminalDrawRequest) {
        renderer.enqueue(request)
    }

    fileprivate func enqueueTrustSigil(x: Int32, y: Int32) {
        renderer.enqueueTrustSigil(x: x, y: y)
    }

    fileprivate func measureCharWidth(_ codepoint: Int32) -> Int32 {
        renderer.charWidth(for: codepoint)
    }
}
