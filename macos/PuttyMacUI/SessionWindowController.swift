import AppKit
import PuttyBridge

/// Shared by PuTTY and pterm AppDelegates for Session menu enablement.
@MainActor
public protocol SessionMenuUpdating: AnyObject {
    func updateSessionActionMenus()
}

/// Owns one terminal session window (Phase 5.5).
@MainActor
public final class SessionWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [SessionWindowController] = []

    /// True while this controller is still in the live session-window list.
    static func isOpen(_ controller: SessionWindowController) -> Bool {
        openControllers.contains { $0 === controller }
    }

    private let scrollContainer: TerminalScrollContainer
    private let connectOnOpen: Bool
    /// Owned `PuttyConf *` until `present()`; then passed to TermWin open and freed.
    private var sessionConf: PuttyConfHandle?

    /**
     * Borrowed `PuttyBridgeTermWin *` from `TerminalView` (same lifetime as
     * the session window). Do not free; valid until `windowWillClose`.
     */
    public var activeTermWin: OpaquePointer? {
        scrollContainer.terminalView.termWin
    }

    /// Takes ownership of `conf` (caller must not `putty_conf_free` it).
    public static func openNew(conf: PuttyConfHandle?, connect: Bool) {
        let controller = SessionWindowController(conf: conf, connect: connect)
        openControllers.append(controller)
        /*
         * Present on the next run-loop turn. Opening immediately from the
         * config dialog's Open action races AppKit window-transform
         * animations and can crash in _NSWindowTransformAnimation dealloc
         * (macos/app_crash_004.txt).
         */
        PuttyMainHop.run {
            controller.present()
        }
    }

    /// Present immediately (UI tests / smoke). Production uses `openNew`.
    public func presentNow() {
        if !Self.isOpen(self) {
            Self.openControllers.append(self)
        }
        present()
    }

    public init(conf: PuttyConfHandle?, connect: Bool) {
        self.sessionConf = conf
        self.connectOnOpen = connect
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        scrollContainer = TerminalScrollContainer(frame: contentRect)
        scrollContainer.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "PuTTY"
        window.title = appName
        window.animationBehavior = .none
        PuttyAccessibility.applyWindowMotionPolicy(window)
        window.contentView = scrollContainer
        scrollContainer.hostWindow = window
        window.setAccessibilityLabel("\(appName) session")
        window.setAccessibilityRoleDescription("terminal session window")

        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        /*
         * Force the scroll container to size TerminalView before openSession
         * runs font metrics. Without this, the view stays at a zero frame
         * until the first user resize (blank white window). openSession then
         * sizes the NSWindow to Conf Columns×Rows (not the reverse).
         */
        window?.layoutIfNeeded()
        scrollContainer.layoutSubtreeIfNeeded()

        let conf = sessionConf
        sessionConf = nil
        let openResult = scrollContainer.terminalView.openSession(
            conf: conf, connect: connectOnOpen)
        if let conf {
            putty_conf_free(conf)
        }
        if case .failure(let error) = openResult {
            let alert = NSAlert()
            alert.messageText = "Session Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
        if let termWin = scrollContainer.terminalView.termWin {
            SessionSpecialsMenu.shared.installCallback(for: self, termWin: termWin)
            SessionEventLog.shared.installCallback(for: self, termWin: termWin)
            installRemoteExitCallback(termWin: termWin)
        }
        SessionSpecialsMenu.shared.setKeyController(self)
        SessionEventLog.shared.setKeyController(self)
        menuUpdater?.updateSessionActionMenus()
        scrollContainer.terminalView.setNeedsDisplay(scrollContainer.terminalView.bounds)
        window?.makeFirstResponder(scrollContainer.terminalView)
    }

    private var menuUpdater: SessionMenuUpdating? {
        NSApp.delegate as? SessionMenuUpdating
    }

    public func refreshSpecialsMenu() {
        SessionSpecialsMenu.shared.refresh(for: self)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
        SessionSpecialsMenu.shared.setKeyController(self)
        SessionEventLog.shared.setKeyController(self)
        menuUpdater?.updateSessionActionMenus()
    }

    private func installRemoteExitCallback(termWin: OpaquePointer) {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        putty_bridge_termwin_set_remote_exit_callback(
            termWin, SessionRemoteExitBridge.onExit, ctx)
    }

    public func sessionDidRemoteExit(closeWindow: Bool) {
        refreshSpecialsMenu()
        menuUpdater?.updateSessionActionMenus()
        if closeWindow {
            // Session is already inactive — skip the WarnOnClose prompt.
            window?.close()
        }
    }

    @objc func closeSession(_ sender: Any?) {
        _ = sender
        window?.performClose(nil)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = sender
        guard let termWin = scrollContainer.terminalView.termWin else { return true }
        if !putty_bridge_termwin_should_warn_on_close(termWin) {
            return true
        }

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "PuTTY"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(appName) Exit Confirmation"
        var message = "Are you sure you want to close this session?"
        if let extra = putty_bridge_termwin_close_warn_text(termWin) {
            message += "\n" + String(cString: extra)
            putty_bridge_termwin_free_close_warn_text(extra)
        }
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func windowWillClose(_ notification: Notification) {
        _ = notification
        if let conf = sessionConf {
            sessionConf = nil
            putty_conf_free(conf)
        }
        /*
         * Clear Special Commands before destroying TermWin so menu items
         * cannot retain a stale session UI, then free the bridge handle on
         * the main thread (AUDIT P1.3 / P1.5 / app_crash_006).
         */
        SessionSpecialsMenu.shared.sessionWillClose(self)
        scrollContainer.terminalView.destroyTermWin()
        SessionSpecialsMenu.shared.resignKeyController(self)
        SessionEventLog.shared.sessionWillClose(self)
        Self.openControllers.removeAll { $0 === self }
        putty_bridge_session_window_closed()
        menuUpdater?.updateSessionActionMenus()
    }
}

private enum SessionRemoteExitBridge {
    static let onExit: @convention(c) (
        UnsafeMutableRawPointer?, Int32, Bool
    ) -> Void = { ctx, _, closeWindow in
        guard let ctx else { return }
        let controller = Unmanaged<SessionWindowController>.fromOpaque(ctx).takeUnretainedValue()
        PuttyMainHop.run { [weak controller] in
            controller?.sessionDidRemoteExit(closeWindow: closeWindow)
        }
    }
}
