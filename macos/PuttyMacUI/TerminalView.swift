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

    static let setCursorPos: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void =
        { ctx, x, y in
            guard let ctx else { return }
            let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { view.updateCaretCell(x: x, y: y) }
        }

    static let setRawMouseMode: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void =
        { ctx, enable in
            guard let ctx else { return }
            let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { view.setRawMouseMode(enable) }
        }

    static let setRawMouseModePointer: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void =
        { ctx, enable in
            guard let ctx else { return }
            let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { view.setRawMousePointer(enable) }
        }

    static let clipWrite: @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafePointer<wchar_t>?, Int32, Bool
    ) -> Void = { ctx, clipboard, text, len, mustDeselect in
        guard let ctx, let text, len > 0 else { return }
        let codepoints = (0..<Int(len)).map { UInt32(bitPattern: Int32(text[$0])) }
        let string = String(decoding: codepoints, as: UTF32.self)
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        Task { @MainActor in
            view.writeToClipboard(string, clipboard: clipboard, mustDeselect: mustDeselect)
        }
    }

    static let clipRequestPaste: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void =
        { ctx, clipboard in
            guard let ctx else { return }
            let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in
                view.requestClipboardPaste(clipboard: clipboard)
            }
        }

    static let setScrollbar: @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Int32
    ) -> Void = { ctx, total, start, page in
        guard let ctx else { return }
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated {
            view.resizeScrollHost?.updateScrollbar(
                total: Int(total), start: Int(start), page: Int(page)
            )
        }
    }

    static let requestResize: @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32
    ) -> Void = { ctx, cols, rows in
        guard let ctx else { return }
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated {
            view.resizeScrollHost?.requestTerminalResize(
                cols: Int(cols), rows: Int(rows)
            )
        }
    }

    static let bell: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void =
        { ctx, mode in
            guard let ctx else { return }
            let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let termWin = view.termWin else { return }
                view.windowChromeHost?.ringBell(mode: mode, termWin: termWin)
            }
        }

    static let setTitle: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> Void = { ctx, title in
        guard let ctx, let title else { return }
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        let string = String(cString: title)
        MainActor.assumeIsolated {
            view.windowChromeHost?.setWindowTitle(string)
        }
    }

    static let setIconTitle: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> Void = { ctx, title in
        guard let ctx, let title else { return }
        let view = Unmanaged<TerminalView>.fromOpaque(ctx).takeUnretainedValue()
        let string = String(cString: title)
        MainActor.assumeIsolated {
            view.windowChromeHost?.setIconTitle(string)
        }
    }
}

/// AppKit terminal surface wired to MacTermWin (Phase 4.2–4.8).
@MainActor
final class TerminalView: NSView {
    nonisolated(unsafe) private(set) var termWin: OpaquePointer?
    weak var resizeScrollHost: TerminalResizeScrolling?
    weak var windowChromeHost: TerminalWindowChrome?

    private var isPainting = false
    private let renderer = TerminalTextRenderer()
    private var pendingDirty: NSRect?
    private var dirtyFlushScheduled = false
    private var fontPointSize: CGFloat = 12

    private var markedText = ""
    private var caretCell = NSPoint(x: 0, y: 0)
    private var rawMousePointer = false
    private var scrollAccumulator: CGFloat = 0
    private let scrollLineHeight: CGFloat = 3
    private var clipboard: TerminalClipboard?

    private lazy var contextMenu: NSMenu = buildContextMenu()

    override var acceptsFirstResponder: Bool { true }

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
            /*
             * Clear C→Swift hooks before freeing: seat teardown may still
             * call seat_update_specials_menu (app_crash_006).
             */
            putty_bridge_termwin_set_specials_menu_callback(termWin, nil, nil)
            putty_bridge_termwin_set_eventlog_callback(termWin, nil, nil)
            putty_bridge_termwin_set_remote_exit_callback(termWin, nil, nil)
            putty_bridge_termwin_free(termWin)
            self.termWin = nil
        }
    }

    private func commonInit() {
        wantsLayer = true
        /*
         * Layer-backed custom views must opt into OnSetNeedsDisplay; otherwise
         * AppKit can leave the layer's solid backgroundColor on screen and
         * never call draw(_:) after SSH output schedules a redraw — which
         * looks like a permanently blank black terminal.
         */
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsScale = window?.backingScaleFactor ?? 1.0
        layer?.backgroundColor = NSColor.black.cgColor

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
            char_width: TerminalViewBridge.charWidth,
            set_cursor_pos: TerminalViewBridge.setCursorPos,
            set_raw_mouse_mode: TerminalViewBridge.setRawMouseMode,
            set_raw_mouse_mode_pointer: TerminalViewBridge.setRawMouseModePointer,
            clip_write: TerminalViewBridge.clipWrite,
            clip_request_paste: TerminalViewBridge.clipRequestPaste,
            set_scrollbar: TerminalViewBridge.setScrollbar,
            request_resize: TerminalViewBridge.requestResize,
            bell: TerminalViewBridge.bell,
            set_title: TerminalViewBridge.setTitle,
            set_icon_title: TerminalViewBridge.setIconTitle
        )
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        putty_bridge_termwin_set_callbacks(handle, &callbacks, ctx)
    }

    /// Open the MacGuiSeat-backed session (Phase 5.5). Call once after the view is in a window.
    func openSession(conf: PuttyConfHandle?, connect: Bool) {
        guard let termWin else { return }

        if !putty_bridge_termwin_open(termWin, conf, connect) {
            fputs("TerminalView: putty_bridge_termwin_open failed\n", stderr)
            return
        }

        clipboard = TerminalClipboard(termWin: termWin)

        updateBackingScale()
        updateFontMetrics()
        /*
         * Seat already applied Conf Columns×Rows. Size the NSWindow to that
         * grid — do not derive cols/rows from the placeholder 800×600 frame
         * (that discarded saved Window dimensions on every Open).
         */
        if let resizeScrollHost {
            resizeScrollHost.sizeWindowToConfiguredGrid()
        } else {
            syncTerminalGridSize()
        }
        resetCursorRects()
        /* Metrics must be live before the first paint; force a draw pass. */
        setNeedsDisplay(bounds)
        window?.displayIfNeeded()
        window?.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            putty_bridge_set_parent_window(Unmanaged.passUnretained(window).toOpaque())
        } else {
            putty_bridge_set_parent_window(nil)
        }
        updateBackingScale()
        syncTerminalGridSizeIfNeeded()
        setNeedsDisplay(bounds)
        window?.makeFirstResponder(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
        syncTerminalGridSizeIfNeeded()
        setNeedsDisplay(bounds)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let termWin, !isPainting else { return }

        let cellW = putty_bridge_termwin_cell_width_pt(termWin)
        let cellH = putty_bridge_termwin_cell_height_pt(termWin)
        guard cellW > 0, cellH > 0 else {
            /* Pre-openSession draw; openSession will display again. */
            return
        }

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

        /*
         * AppKit clips to dirtyRect, which can be a sub-cell strip after
         * selection updates. Reset the clip to the full cell-aligned rect
         * so highlight backgrounds are not left as thin leftover bands.
         */
        let cellRect = CGRect(
            x: CGFloat(left) * cellW,
            y: CGFloat(top) * cellH,
            width: CGFloat(right - left + 1) * cellW,
            height: CGFloat(bottom - top + 1) * cellH
        )
        let cg = NSGraphicsContext.current?.cgContext
        cg?.saveGState()
        cg?.resetClip()
        cg?.clip(to: cellRect)

        isPainting = true
        putty_bridge_termwin_paint(termWin, left, top, right, bottom)
        isPainting = false

        cg?.restoreGState()
    }

    // MARK: - Keyboard (Phase 4.5)

    override func keyDown(with event: NSEvent) {
        guard let termWin else {
            super.keyDown(with: event)
            return
        }
        if !OsxKeys.handleKeyDown(event, termWin: termWin) {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            copySelection(nil)
            return true
        case "v":
            pasteFromClipboard(nil)
            return true
        case "a":
            selectAllAction(nil)
            return true
        default:
            return false
        }
    }

    // MARK: - NSTextInputClient (IME / dead keys) — see extension below

    nonisolated override func doCommand(by selector: Selector) {
        MainActor.assumeIsolated {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                guard let termWin else { return }
                if let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: "",
                    charactersIgnoringModifiers: "",
                    isARepeat: false,
                    keyCode: 0x24
                ) {
                    _ = OsxKeys.handleKeyDown(event, termWin: termWin)
                }
                return
            }
            /*
             * Control bindings (Ctrl-D → deleteForward:, Ctrl-A →
             * moveToBeginningOfLine:, …) must not fall through as no-ops.
             * keyDown should already have sent the C0 byte; if AppKit still
             * delivers the selector, swallow it.
             */
            if OsxKeys.isControlEditingCommand(selector) {
                return
            }
            super.doCommand(by: selector)
        }
    }

    // MARK: - Mouse (Phase 4.5)

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(event: event, action: mouseAction(for: event))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let termWin else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = mods.contains(.control)
        if putty_bridge_termwin_right_click_shows_menu(termWin, control) {
            /*
             * Windows mouse mode (or Control+right-click): show the
             * context menu instead of paste/extend.
             */
            putty_bridge_termwin_cancel_selection_drag(termWin)
            NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
            return
        }
        sendMouse(event: event, button: PUTTY_BRIDGE_MBT_RIGHT, action: PUTTY_BRIDGE_MA_CLICK)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(event: event, button: PUTTY_BRIDGE_MBT_MIDDLE, action: PUTTY_BRIDGE_MA_CLICK)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouse(event: event, action: PUTTY_BRIDGE_MA_DRAG)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouse(event: event, action: PUTTY_BRIDGE_MA_RELEASE)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let termWin else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if putty_bridge_termwin_right_click_shows_menu(termWin, mods.contains(.control)) {
            return
        }
        sendMouse(event: event, button: PUTTY_BRIDGE_MBT_RIGHT, action: PUTTY_BRIDGE_MA_RELEASE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouse(event: event, button: PUTTY_BRIDGE_MBT_MIDDLE, action: PUTTY_BRIDGE_MA_RELEASE)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouse(event: event, button: PUTTY_BRIDGE_MBT_RIGHT, action: PUTTY_BRIDGE_MA_DRAG)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMouse(event: event, button: PUTTY_BRIDGE_MBT_MIDDLE, action: PUTTY_BRIDGE_MA_DRAG)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let termWin else { return }
        let cell = cellAt(pointInView: convert(event.locationInWindow, from: nil))
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = mods.contains(.shift)
        let ctrl = mods.contains(.control)
        let alt = mods.contains(.option)

        let rawMouse = putty_bridge_termwin_raw_mouse_active(termWin)
        let overrideShift = putty_bridge_termwin_mouse_override_shift(termWin)
        if rawMouse && !(shift && overrideShift) {
            scrollAccumulator += event.scrollingDeltaY
            while scrollAccumulator <= -scrollLineHeight {
                scrollAccumulator += scrollLineHeight
                putty_bridge_termwin_mouse(
                    termWin, PUTTY_BRIDGE_MBT_WHEEL_DOWN, PUTTY_BRIDGE_MA_CLICK,
                    cell.x, cell.y, shift, ctrl, alt
                )
            }
            while scrollAccumulator >= scrollLineHeight {
                scrollAccumulator -= scrollLineHeight
                putty_bridge_termwin_mouse(
                    termWin, PUTTY_BRIDGE_MBT_WHEEL_UP, PUTTY_BRIDGE_MA_CLICK,
                    cell.x, cell.y, shift, ctrl, alt
                )
            }
            return
        }

        scrollAccumulator += event.scrollingDeltaY
        let lines = Int32(scrollAccumulator / scrollLineHeight)
        if lines != 0 {
            scrollAccumulator -= CGFloat(lines) * scrollLineHeight
            putty_bridge_termwin_scroll_lines(termWin, -lines)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        /*
         * AppKit may ask for a menu independently of rightMouseDown
         * (e.g. Control+click). Only supply one when Conf says so.
         */
        guard let termWin else { return contextMenu }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if putty_bridge_termwin_right_click_shows_menu(termWin, mods.contains(.control)) {
            return contextMenu
        }
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor = rawMousePointer ? .arrow : .iBeam
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Context menu actions

    @objc private func copySelection(_ sender: Any?) {
        _ = sender
        guard let termWin else { return }
        putty_bridge_termwin_copy_selection(termWin)
    }

    @objc private func pasteFromClipboard(_ sender: Any?) {
        _ = sender
        guard let termWin else { return }
        putty_bridge_termwin_request_paste(termWin, PUTTY_BRIDGE_CLIP_CLIPBOARD)
    }

    @objc private func pasteSpecial(_ sender: Any?) {
        _ = sender
        guard let termWin else { return }
        putty_bridge_termwin_request_paste(termWin, PUTTY_BRIDGE_CLIP_LOCAL)
    }

    @objc private func selectAllAction(_ sender: Any?) {
        _ = sender
        guard let termWin else { return }
        putty_bridge_termwin_select_all(termWin)
    }

    @objc private func copyAllAction(_ sender: Any?) {
        _ = sender
        guard let termWin else { return }
        putty_bridge_termwin_copy_all(termWin)
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

        let font = NSFont(name: "SFMono-Regular", size: fontPointSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontPointSize, weight: .regular)
        let probe = "M" as NSString
        let charWidth = probe.size(withAttributes: [.font: font]).width
        let cellHeight = ceil(font.ascender - font.descender + font.leading)

        putty_bridge_termwin_set_font_metrics(
            termWin, charWidth, cellHeight, font.ascender, -font.descender
        )
        renderer.refreshMetrics(pointSize: fontPointSize)
    }

    /// Resize the font to keep a fixed terminal grid when Conf uses RESIZE_FONT.
    func fitFontToView(width: CGFloat, height: CGFloat) {
        guard let termWin else { return }
        let cols = CGFloat(putty_bridge_termwin_cols(termWin))
        let rows = CGFloat(putty_bridge_termwin_rows(termWin))
        guard cols > 0, rows > 0, width > 0, height > 0 else { return }

        let sizeFromHeight = (height / rows) * 0.78
        fontPointSize = max(6, min(72, sizeFromHeight))
        updateFontMetrics()
    }

    private func syncTerminalGridSizeIfNeeded() {
        guard let termWin else { return }
        if resizeScrollHost != nil {
            return
        }
        updateFontMetrics()
        putty_bridge_termwin_resize_to_view(termWin, bounds.width, bounds.height)
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

    fileprivate func updateCaretCell(x: Int32, y: Int32) {
        caretCell = NSPoint(x: CGFloat(x), y: CGFloat(y))
    }

    fileprivate func setRawMouseMode(_ enable: Bool) {
        _ = enable
        resetCursorRects()
    }

    fileprivate func setRawMousePointer(_ enable: Bool) {
        rawMousePointer = enable
        resetCursorRects()
    }

    fileprivate func writeToClipboard(
        _ string: String, clipboard: Int32, mustDeselect: Bool
    ) {
        self.clipboard?.write(text: string, clipboard: clipboard, mustDeselect: mustDeselect)
    }

    fileprivate func requestClipboardPaste(clipboard: Int32) {
        self.clipboard?.requestPaste(clipboard: clipboard)
    }

    // MARK: - Input helpers

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(pasteFromClipboard(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste Special", action: #selector(pasteSpecial(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy All", action: #selector(copyAllAction(_:)), keyEquivalent: "")
        return menu
    }

    private func cellAt(pointInView point: NSPoint) -> (x: Int32, y: Int32) {
        guard let termWin else { return (0, 0) }
        let cellW = putty_bridge_termwin_cell_width_pt(termWin)
        let cellH = putty_bridge_termwin_cell_height_pt(termWin)
        guard cellW > 0, cellH > 0 else { return (0, 0) }
        let x = max(0, min(putty_bridge_termwin_cols(termWin) - 1, Int32(point.x / cellW)))
        let y = max(0, min(putty_bridge_termwin_rows(termWin) - 1, Int32(point.y / cellH)))
        return (x, y)
    }

    private func mouseAction(for event: NSEvent) -> Int32 {
        switch event.clickCount {
        case 2: return PUTTY_BRIDGE_MA_2CLK
        case 3...: return PUTTY_BRIDGE_MA_3CLK
        default: return PUTTY_BRIDGE_MA_CLICK
        }
    }

    private func sendMouse(event: NSEvent, action: Int32) {
        sendMouse(event: event, button: PUTTY_BRIDGE_MBT_LEFT, action: action)
    }

    private func sendMouse(event: NSEvent, button: Int32, action: Int32) {
        guard let termWin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let cell = cellAt(pointInView: point)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        putty_bridge_termwin_mouse(
            termWin, button, action, cell.x, cell.y,
            mods.contains(.shift), mods.contains(.control), mods.contains(.option)
        )
    }

    private func caretRectInView() -> NSRect {
        guard let termWin else { return .zero }
        let cellW = putty_bridge_termwin_cell_width_pt(termWin)
        let cellH = putty_bridge_termwin_cell_height_pt(termWin)
        return NSRect(
            x: caretCell.x * cellW,
            y: caretCell.y * cellH,
            width: max(cellW, 1),
            height: max(cellH, 1)
        )
    }
}

// MARK: - NSTextInputClient

extension TerminalView: NSTextInputClient {
    nonisolated func insertText(_ string: Any, replacementRange: NSRange) {
        _ = replacementRange
        let captured: String?
        if let s = string as? String {
            captured = s
        } else if let attr = string as? NSAttributedString {
            captured = attr.string
        } else {
            captured = nil
        }
        guard let text = captured else { return }
        MainActor.assumeIsolated {
            guard let termWin else { return }
            markedText = ""
            OsxKeys.insertText(text, termWin: termWin)
        }
    }

    nonisolated func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        _ = selectedRange
        _ = replacementRange
        let captured: String
        if let s = string as? String {
            captured = s
        } else if let attr = string as? NSAttributedString {
            captured = attr.string
        } else {
            captured = ""
        }
        MainActor.assumeIsolated {
            markedText = captured
            setNeedsDisplay(caretRectInView())
        }
    }

    nonisolated func unmarkText() {
        MainActor.assumeIsolated {
            markedText = ""
            setNeedsDisplay(caretRectInView())
        }
    }

    nonisolated func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    nonisolated func markedRange() -> NSRange {
        MainActor.assumeIsolated {
            markedText.isEmpty
                ? NSRange(location: NSNotFound, length: 0)
                : NSRange(location: 0, length: markedText.utf16.count)
        }
    }

    nonisolated func hasMarkedText() -> Bool {
        MainActor.assumeIsolated { !markedText.isEmpty }
    }

    nonisolated func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        _ = range
        _ = actualRange
        return nil
    }

    nonisolated func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    nonisolated func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        _ = range
        _ = actualRange
        return MainActor.assumeIsolated {
            let rect = caretRectInView()
            guard window != nil else { return rect }
            return convert(rect, to: nil)
        }
    }

    nonisolated func characterIndex(for point: NSPoint) -> Int {
        _ = point
        return 0
    }
}
