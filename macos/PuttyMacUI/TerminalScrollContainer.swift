import AppKit
import PuttyBridge

/// Scrollbar and window-resize host for TerminalView (Phase 4.7).
@MainActor
protocol TerminalResizeScrolling: AnyObject {
    func updateScrollbar(total: Int, start: Int, page: Int)
    func requestTerminalResize(cols: Int, rows: Int)
    /// Size the host window to the terminal's current Conf grid (cols×rows).
    func sizeWindowToConfiguredGrid()
}

/// Terminal surface plus a PuTTY-style vertical scrollback scroller.
@MainActor
final class TerminalScrollContainer: NSView, TerminalResizeScrolling, TerminalWindowChrome {
    let terminalView = TerminalView()

    private let scroller = NSScroller()
    private var ignoreScrollbar = false
    private var scrollTotal = 0
    private var scrollStart = 0
    private var scrollPage = 0
    private var winResizePending = false
    private var windowTitle = "PuTTY"
    private var iconTitle = ""

    weak var hostWindow: NSWindow?
    nonisolated(unsafe) private var accessibilityObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        terminalView.resizeScrollHost = self
        terminalView.windowChromeHost = self

        scroller.isEnabled = false
        scroller.target = self
        scroller.action = #selector(scrollerMoved(_:))
        scroller.setAccessibilityElement(true)
        scroller.setAccessibilityRole(.scrollBar)
        scroller.setAccessibilityLabel("Terminal scrollback")

        addSubview(terminalView)
        addSubview(scroller)
        layoutSubviews()
        applyAccessibilityChrome()
        accessibilityObserver = PuttyAccessibility.observeDisplayOptionsChanged {
            [weak self] in
            self?.applyAccessibilityChrome()
            if let window = self?.hostWindow ?? self?.window {
                PuttyAccessibility.applyWindowMotionPolicy(window)
            }
        }
    }

    deinit {
        if let accessibilityObserver {
            NotificationCenter.default.removeObserver(accessibilityObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layoutSubviews()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        layoutSubtreeIfNeeded()
        applyLiveResize()
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutSubviews()
        applyLiveResize()
        completePendingWinResizeIfNeeded()
    }

    // MARK: - TerminalResizeScrolling

    func updateScrollbar(total: Int, start: Int, page: Int) {
        scrollTotal = total
        scrollStart = start
        scrollPage = page

        guard let termWin = terminalView.termWin else { return }
        let showScroller = putty_bridge_termwin_scrollbar_enabled(termWin)
        scroller.isHidden = !showScroller
        layoutSubviews()

        guard showScroller else { return }

        ignoreScrollbar = true
        if total <= page {
            scroller.isEnabled = false
        } else {
            scroller.isEnabled = true
            let range = max(total - page, 1)
            scroller.knobProportion = CGFloat(page) / CGFloat(max(total, 1))
            scroller.doubleValue = CGFloat(start) / CGFloat(range)
        }
        ignoreScrollbar = false
    }

    func requestTerminalResize(cols: Int, rows: Int) {
        guard let termWin = terminalView.termWin else { return }

        let action = putty_bridge_termwin_resize_action(termWin)
        if action == PUTTY_BRIDGE_RESIZE_DISABLED {
            putty_bridge_termwin_request_resize_completed(termWin)
            return
        }

        let currentCols = putty_bridge_termwin_cols(termWin)
        let currentRows = putty_bridge_termwin_rows(termWin)
        if cols == currentCols && rows == currentRows {
            putty_bridge_termwin_request_resize_completed(termWin)
            return
        }

        if action == PUTTY_BRIDGE_RESIZE_FONT {
            _ = putty_bridge_termwin_resize_grid(
                termWin, Int32(cols), Int32(rows)
            )
            let viewSize = terminalView.bounds.size
            terminalView.fitFontToView(width: viewSize.width, height: viewSize.height)
            putty_bridge_termwin_request_resize_completed(termWin)
            terminalView.setNeedsDisplay(terminalView.bounds)
            return
        }

        guard applyWindowContentSize(cols: cols, rows: rows, termWin: termWin) else {
            putty_bridge_termwin_request_resize_completed(termWin)
            return
        }
        winResizePending = true
    }

    func sizeWindowToConfiguredGrid() {
        guard let termWin = terminalView.termWin else { return }
        let cols = Int(putty_bridge_termwin_cols(termWin))
        let rows = Int(putty_bridge_termwin_rows(termWin))
        guard cols > 0, rows > 0 else { return }
        /*
         * Always set the window frame from Conf cols/rows. Unlike
         * requestTerminalResize, do not early-out when the terminal grid
         * already matches — that is the normal open path (seat applies
         * Conf size, then the placeholder 800×600 window must grow/shrink).
         */
        _ = applyWindowContentSize(cols: cols, rows: rows, termWin: termWin)
    }

    /// Resize the host window so the terminal view fits `cols`×`rows`.
    @discardableResult
    private func applyWindowContentSize(
        cols: Int, rows: Int, termWin: OpaquePointer
    ) -> Bool {
        var contentW: Double = 0
        var contentH: Double = 0
        putty_bridge_termwin_view_size_for_grid(
            termWin, Int32(cols), Int32(rows), &contentW, &contentH
        )

        let scrollerW = scroller.isHidden ? 0.0 : scrollerWidth()
        let contentSize = NSSize(width: contentW + scrollerW, height: contentH)

        guard let window = hostWindow ?? window else { return false }

        let oldFrame = window.frame
        var newFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        )
        /* Keep the window centred on its previous centre (matches open). */
        newFrame.origin.x = oldFrame.midX - newFrame.width / 2
        newFrame.origin.y = oldFrame.midY - newFrame.height / 2
        window.setFrame(newFrame, display: true, animate: false)
        return true
    }

    // MARK: - TerminalWindowChrome

    func ringBell(mode: Int32, termWin: OpaquePointer) {
        TerminalBell.play(mode: mode, termWin: termWin)
    }

    func setWindowTitle(_ title: String) {
        windowTitle = title
        hostWindow?.title = title
        PuttyAccessibility.updateTerminalValue(terminalView, title: title)
        updateDockTile()
    }

    func setIconTitle(_ title: String) {
        iconTitle = title
        updateDockTile()
    }

    private func updateDockTile() {
        guard let termWin = terminalView.termWin else { return }
        let dockTile = NSApp.dockTile

        if putty_bridge_termwin_win_name_always(termWin) {
            dockTile.contentView = nil
            dockTile.display()
            return
        }

        let label = iconTitle.isEmpty ? windowTitle : iconTitle
        guard !label.isEmpty else {
            dockTile.contentView = nil
            dockTile.display()
            return
        }

        let field = NSTextField(labelWithString: label)
        field.font = .systemFont(ofSize: 11, weight: .medium)
        field.textColor = .labelColor
        field.backgroundColor = .clear
        field.isBezeled = false
        field.isEditable = false
        field.sizeToFit()
        field.frame.origin = NSPoint(
            x: (dockTile.size.width - field.frame.width) / 2,
            y: (dockTile.size.height - field.frame.height) / 2
        )
        dockTile.contentView = field
        dockTile.display()
    }

    // MARK: - Layout

    private func layoutSubviews() {
        let scrollerW = scroller.isHidden ? 0.0 : scrollerWidth()
        terminalView.frame = NSRect(
            x: 0, y: 0,
            width: max(0, bounds.width - scrollerW),
            height: bounds.height
        )
        scroller.frame = NSRect(
            x: bounds.width - scrollerW, y: 0,
            width: scrollerW, height: bounds.height
        )
    }

    private func scrollerWidth() -> CGFloat {
        NSScroller.scrollerWidth(
            for: scroller.controlSize,
            scrollerStyle: scroller.scrollerStyle
        )
    }

    private func applyLiveResize() {
        guard let termWin = terminalView.termWin else { return }
        let action = putty_bridge_termwin_resize_action(termWin)
        let viewSize = terminalView.bounds.size

        switch action {
        case PUTTY_BRIDGE_RESIZE_FONT:
            terminalView.fitFontToView(width: viewSize.width, height: viewSize.height)
        case PUTTY_BRIDGE_RESIZE_DISABLED:
            break
        default:
            putty_bridge_termwin_apply_live_resize(
                termWin, viewSize.width, viewSize.height
            )
        }
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    private func completePendingWinResizeIfNeeded() {
        guard winResizePending, let termWin = terminalView.termWin else { return }
        winResizePending = false
        putty_bridge_termwin_request_resize_completed(termWin)
    }

    @objc private func scrollerMoved(_ sender: NSScroller) {
        guard !ignoreScrollbar, let termWin = terminalView.termWin else { return }
        let range = max(scrollTotal - scrollPage, 1)
        let pos = Int(sender.doubleValue * CGFloat(range))
        putty_bridge_termwin_scroll_to(termWin, Int32(pos))
    }

    private func applyAccessibilityChrome() {
        /*
         * System accent (or Increase Contrast label) on session chrome only —
         * never the terminal colour palette (Phase 9.2 / 9.3).
         */
        PuttyChrome.applyChromeBorder(to: self)
        if PuttyAccessibility.increaseContrast {
            scroller.controlSize = .regular
            scroller.knobStyle = .light
        }
    }
}
