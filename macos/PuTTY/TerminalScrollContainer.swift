import AppKit
import PuttyBridge

/// Scrollbar and window-resize host for TerminalView (Phase 4.7).
@MainActor
protocol TerminalResizeScrolling: AnyObject {
    func updateScrollbar(total: Int, start: Int, page: Int)
    func requestTerminalResize(cols: Int, rows: Int)
}

/// Terminal surface plus a PuTTY-style vertical scrollback scroller.
@MainActor
final class TerminalScrollContainer: NSView, TerminalResizeScrolling {
    let terminalView = TerminalView()

    private let scroller = NSScroller()
    private var ignoreScrollbar = false
    private var scrollTotal = 0
    private var scrollStart = 0
    private var scrollPage = 0
    private var winResizePending = false

    weak var hostWindow: NSWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        terminalView.resizeScrollHost = self

        scroller.isEnabled = false
        scroller.target = self
        scroller.action = #selector(scrollerMoved(_:))

        addSubview(terminalView)
        addSubview(scroller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        var contentW: Double = 0
        var contentH: Double = 0
        putty_bridge_termwin_view_size_for_grid(
            termWin, Int32(cols), Int32(rows), &contentW, &contentH
        )

        let scrollerW = scroller.isHidden ? 0.0 : scrollerWidth()
        let contentSize = NSSize(width: contentW + scrollerW, height: contentH)

        guard let window = hostWindow ?? window else {
            putty_bridge_termwin_request_resize_completed(termWin)
            return
        }

        winResizePending = true
        let frame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        )
        window.setFrame(frame, display: true, animate: false)
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
}
