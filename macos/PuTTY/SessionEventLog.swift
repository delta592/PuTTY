import AppKit
import PuttyBridge

/// Owns per-session Event Log windows and the Window → Event Log menu (Phase 6.4).
@MainActor
final class SessionEventLog: NSObject {
    static let shared = SessionEventLog()

    private weak var menuItem: NSMenuItem?
    private weak var keyController: SessionWindowController?
    private var controllers: [ObjectIdentifier: EventLogWindowController] = [:]

    private override init() {
        super.init()
    }

    func install(into windowMenu: NSMenu) {
        let item = windowMenu.addItem(
            withTitle: "Event Log",
            action: #selector(showEventLogMenu(_:)),
            keyEquivalent: "e")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        menuItem = item
        updateMenuState()
    }

    func setKeyController(_ controller: SessionWindowController?) {
        keyController = controller
        updateMenuState()
    }

    func resignKeyController(_ controller: SessionWindowController) {
        if controller === keyController {
            setKeyController(nil)
        }
    }

    func installCallback(for controller: SessionWindowController, termWin: OpaquePointer) {
        let ctx = Unmanaged.passUnretained(controller).toOpaque()
        putty_bridge_termwin_set_eventlog_callback(
            termWin, SessionEventLogBridge.onAppend, ctx)
    }

    @objc func showEventLogMenu(_ sender: Any?) {
        _ = sender
        guard let controller = keyController else {
            NSSound.beep()
            return
        }
        showEventLog(for: controller)
    }

    func showEventLog(for controller: SessionWindowController) {
        guard let termWin = controller.activeTermWin else {
            NSSound.beep()
            return
        }
        let id = ObjectIdentifier(controller)
        if let existing = controllers[id] {
            existing.reloadText()
            existing.present()
            return
        }
        let log = EventLogWindowController(
            termWin: termWin, parent: controller.window)
        log.onWillClose = { [weak self] in
            self?.controllers.removeValue(forKey: id)
        }
        controllers[id] = log
        log.present()
    }

    func sessionDidReceiveEvent(for controller: SessionWindowController) {
        controllers[ObjectIdentifier(controller)]?.reloadText()
    }

    func sessionWillClose(_ controller: SessionWindowController) {
        let id = ObjectIdentifier(controller)
        if let log = controllers.removeValue(forKey: id) {
            log.onWillClose = nil
            log.close()
        }
        resignKeyController(controller)
    }

    private func updateMenuState() {
        menuItem?.isEnabled = keyController?.activeTermWin != nil
    }
}

private enum SessionEventLogBridge {
    static let onAppend: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
        guard let ctx else { return }
        let controller = Unmanaged<SessionWindowController>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated {
            SessionEventLog.shared.sessionDidReceiveEvent(for: controller)
        }
    }
}
