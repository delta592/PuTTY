import AppKit
import PuttyBridge

/// Owns one terminal session window (Phase 5.5).
@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [SessionWindowController] = []

    private let scrollContainer: TerminalScrollContainer
    private let connectOnOpen: Bool
    private let sessionConf: PuttyConfHandle?

    /// TermWin handle for menu/specials bridge callbacks (Phase 5.6).
    var activeTermWin: OpaquePointer? {
        scrollContainer.terminalView.termWin
    }

    static func openNew(conf: PuttyConfHandle?, connect: Bool) {
        let controller = SessionWindowController(conf: conf, connect: connect)
        openControllers.append(controller)
        controller.present()
    }

    init(conf: PuttyConfHandle?, connect: Bool) {
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
        window.title = "PuTTY"
        window.contentView = scrollContainer
        scrollContainer.hostWindow = window

        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        scrollContainer.terminalView.openSession(conf: sessionConf, connect: connectOnOpen)
        if let termWin = scrollContainer.terminalView.termWin {
            SessionSpecialsMenu.shared.installCallback(for: self, termWin: termWin)
            SessionEventLog.shared.installCallback(for: self, termWin: termWin)
            installRemoteExitCallback(termWin: termWin)
        }
        SessionSpecialsMenu.shared.setKeyController(self)
        SessionEventLog.shared.setKeyController(self)
        (NSApp.delegate as? AppDelegate)?.updateSessionActionMenus()
    }

    func refreshSpecialsMenu() {
        SessionSpecialsMenu.shared.refresh(for: self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
        SessionSpecialsMenu.shared.setKeyController(self)
        SessionEventLog.shared.setKeyController(self)
        (NSApp.delegate as? AppDelegate)?.updateSessionActionMenus()
    }

    private func installRemoteExitCallback(termWin: OpaquePointer) {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        putty_bridge_termwin_set_remote_exit_callback(
            termWin, SessionRemoteExitBridge.onExit, ctx)
    }

    func sessionDidRemoteExit() {
        refreshSpecialsMenu()
        (NSApp.delegate as? AppDelegate)?.updateSessionActionMenus()
    }

    @objc func closeSession(_ sender: Any?) {
        _ = sender
        window?.performClose(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = sender
        guard let termWin = scrollContainer.terminalView.termWin else { return true }
        if !putty_bridge_termwin_should_warn_on_close(termWin) {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PuTTY Exit Confirmation"
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

    func windowWillClose(_ notification: Notification) {
        _ = notification
        SessionSpecialsMenu.shared.resignKeyController(self)
        SessionEventLog.shared.sessionWillClose(self)
        Self.openControllers.removeAll { $0 === self }
        putty_bridge_session_window_closed()
        (NSApp.delegate as? AppDelegate)?.updateSessionActionMenus()
    }
}

private enum SessionRemoteExitBridge {
    static let onExit: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ctx, _ in
        guard let ctx else { return }
        let controller = Unmanaged<SessionWindowController>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated {
            controller.sessionDidRemoteExit()
        }
    }
}
